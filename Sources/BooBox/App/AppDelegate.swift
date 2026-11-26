import Darwin
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var store: SessionStore?
    private var pendingIncomingURLs: [URL] = []
    private var didFinishLaunching = false
    private var handledStartupTarget = false
    private var ipcServer: AppIPCServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Ensure config.json + Ghostty override exist BEFORE GhosttyRuntime starts
        let configManager = BooBoxConfigManager.shared
        // Start host-side secret vault / egress proxy sidecar before launching sessions
        _ = SecretsVaultManager.shared.startIfNeeded()

        // Schedule automatic GitHub update checks from `apguan/boo_box` if enabled in Settings
        UpdateManager.shared.startIfEnabled()
        // Configure clickable macOS desktop notifications for background sessions
        NotificationManager.shared.setup()

        do {
            try GhosttyRuntime.shared.start()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to initialize Ghostty"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let sessionStore = SessionStore()
        self.store = sessionStore

        sessionStore.onOpenSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        sessionStore.onThemeBackgroundChanged = { [weak self] color in
            self?.mainWindow?.backgroundColor = color
        }

        configManager.onConfigChanged = { [weak sessionStore] old, new in
            if old.appearance != new.appearance {
                sessionStore?.reloadGhosttyConfig()
            }
            if old.ephemeralSetup.privateVMSetupScript != new.ephemeralSetup.privateVMSetupScript
                || old.ephemeralSetup.injectEnvIntoPrivateVM != new.ephemeralSetup.injectEnvIntoPrivateVM
                || (new.ephemeralSetup.injectEnvIntoPrivateVM && old.ephemeralSetup.envVars != new.ephemeralSetup.envVars)
                || old.privateVM != new.privateVM {
                MicroVMManager.shared.invalidateWarmPool()
            }
            if old.secretsNetwork != new.secretsNetwork {
                SecretsVaultManager.shared.syncPolicyToProxy()
            }
        }

        setupMainMenu()
        createMainWindow(store: sessionStore)
        didFinishLaunching = true

        // Start local Unix domain socket IPC server (`~/boo_box/run/app.sock`) for <1 ms `boo` CLI handoff
        let ipc = AppIPCServer { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleIPCMessage(message)
            }
        }
        ipc.start()
        self.ipcServer = ipc

        // 1. Process any folder / boobox:// URLs delivered before didFinishLaunching
        if !pendingIncomingURLs.isEmpty {
            let queued = pendingIncomingURLs
            pendingIncomingURLs.removeAll()
            handleIncomingURLs(queued)
        }

        // 2. Process direct CLI arguments (`--dir <path>`, `--no-env`, `--scratch`)
        handleCommandLineArguments()

        // 3. Restore previously open sessions (reattaching straight to live `booboxd` shells/agents!)
        //    or create a fresh default scratch tab if none were restored and no CLI target was passed.
        DispatchQueue.main.async { [weak self] in
            guard let self, let store = self.store else { return }
            if !self.handledStartupTarget && store.sessions.isEmpty && store.cloningProjectName == nil {
                let restored = store.restoreLastOpenSessionsIfEnabled()
                if !restored {
                    store.newSession(mode: .sandbox)
                }
            }
            store.refreshSavedMacSessions()
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !didFinishLaunching {
            pendingIncomingURLs.append(contentsOf: urls)
            return
        }
        handleIncomingURLs(urls)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleCommandLineArguments() {
        let args = Array(CommandLine.arguments.dropFirst())
        let noEnv = args.contains("--no-env")
        let customName: String? = {
            if let idx = args.firstIndex(of: "--name"), idx + 1 < args.count {
                return args[idx + 1]
            }
            return nil
        }()
        if args.contains("--scratch") {
            handledStartupTarget = true
            store?.newScratchSession()
            return
        }
        if let idx = args.firstIndex(of: "--ready-session"), idx + 1 < args.count,
           let uuid = UUID(uuidString: args[idx + 1]),
           let tmplIdx = args.firstIndex(of: "--template"), tmplIdx + 1 < args.count {
            handledStartupTarget = true
            let tmplURL = URL(fileURLWithPath: args[tmplIdx + 1], isDirectory: true)
            store?.adoptReadyProjectSession(
                id: uuid,
                displayName: customName ?? tmplURL.lastPathComponent,
                templateDirURL: tmplURL,
                excludeEnvOverride: noEnv ? true : nil
            )
            return
        }
        if let idx = args.firstIndex(of: "--dir"), idx + 1 < args.count {
            handledStartupTarget = true
            let url = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
            store?.openProjectFolder(url, displayName: customName, excludeEnvOverride: noEnv ? true : nil)
        }
    }

    private func handleIncomingURLs(_ urls: [URL]) {
        for url in urls {
            if url.scheme == "boobox" {
                handledStartupTarget = true
                let host = url.host?.lowercased() ?? ""
                if host == "scratch" {
                    store?.newScratchSession()
                } else if host == "ready",
                          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let idStr = comps.queryItems?.first(where: { $0.name == "id" })?.value,
                          let uuid = UUID(uuidString: idStr),
                          let tmplPath = comps.queryItems?.first(where: { $0.name == "template" })?.value,
                          !tmplPath.isEmpty {
                    let noEnv = comps.queryItems?.first(where: { $0.name == "noenv" })?.value == "1"
                    let customName = comps.queryItems?.first(where: { $0.name == "name" })?.value ?? "project"
                    store?.adoptReadyProjectSession(
                        id: uuid,
                        displayName: customName,
                        templateDirURL: URL(fileURLWithPath: tmplPath, isDirectory: true),
                        excludeEnvOverride: noEnv ? true : nil
                    )
                } else if host == "open",
                          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let rawPath = comps.queryItems?.first(where: { $0.name == "path" })?.value,
                          !rawPath.isEmpty {
                    let noEnv = comps.queryItems?.first(where: { $0.name == "noenv" })?.value == "1"
                    let customName = comps.queryItems?.first(where: { $0.name == "name" })?.value
                    store?.openProjectFolder(
                        URL(fileURLWithPath: rawPath, isDirectory: true),
                        displayName: customName,
                        excludeEnvOverride: noEnv ? true : nil
                    )
                }
            } else if url.isFileURL {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    handledStartupTarget = true
                    store?.openProjectFolder(url)
                }
            }
        }
    }

    private func handleIPCMessage(_ msg: AppIPCMessage) {
        handledStartupTarget = true
        switch msg.op {
        case "scratch":
            store?.newScratchSession()
        case "ready":
            if let idStr = msg.id,
               let uuid = UUID(uuidString: idStr),
               let tmplPath = msg.template, !tmplPath.isEmpty {
                store?.adoptReadyProjectSession(
                    id: uuid,
                    displayName: msg.name ?? URL(fileURLWithPath: tmplPath).lastPathComponent,
                    templateDirURL: URL(fileURLWithPath: tmplPath, isDirectory: true),
                    excludeEnvOverride: (msg.noEnv == true) ? true : nil
                )
            }
        case "open":
            if let path = msg.path, !path.isEmpty {
                store?.openProjectFolder(
                    URL(fileURLWithPath: path, isDirectory: true),
                    displayName: msg.name,
                    excludeEnvOverride: (msg.noEnv == true) ? true : nil
                )
            }
        case "reload_config":
            BooBoxConfigManager.shared.reloadFromDisk()
            store?.reloadGhosttyConfig()
            return
        case "activate":
            break
        default:
            break
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        GhosttyRuntime.shared.setAppFocus(true)
        store?.refocusActiveTerminal()
    }

    func applicationDidResignActive(_ notification: Notification) {
        GhosttyRuntime.shared.setAppFocus(false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer?.stop()
        ipcServer = nil
        let preserveDetached = (store?.hasLiveDaemonPanes == true)
            && BooBoxConfigManager.shared.config.general.persistentSessionsEnabled
        store?.shutdownAll(preserveDaemonPanes: preserveDetached)
        // Keep boobox-proxy alive across restarts/auto-updates when detached booboxd agents are still running!
        if !preserveDetached {
            SecretsVaultManager.shared.stop()
        }
        GhosttyRuntime.shared.shutdown()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        GhosttyRuntime.shared.syncColorScheme()
        if (notification.object as? NSWindow) === mainWindow {
            store?.refocusActiveTerminal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === mainWindow else { return }
        if let settings = settingsWindow {
            settingsWindow = nil
            settings.close()
        }
    }
    // MARK: - Window Setup

    private func createMainWindow(store: SessionStore) {
        let rootView = MainWorkspaceView(store: store)
        let hostingView = NSHostingView(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "boo_box"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = store.themeBackground
        window.contentView = hostingView
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("BooBoxMainWindow")
        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window
    }

    // MARK: - Menu Bar & Shortcuts

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "boo_box")
        appMenu.addItem(withTitle: "About boo_box", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Reload Config & Themes", action: #selector(reloadConfig(_:)), keyEquivalent: "R")
            .keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide boo_box", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit boo_box", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Session menu
        let sessionMenuItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        sessionMenu.addItem(.sectionHeader(title: "Sandboxed"))
        sessionMenu.addItem(withTitle: "New Session", action: #selector(newSandboxSession(_:)), keyEquivalent: "t")
        let openFolderItem = sessionMenu.addItem(withTitle: "Open Folder in Sandbox…", action: #selector(openProjectFolder(_:)), keyEquivalent: "o")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        let privateVMItem = sessionMenu.addItem(withTitle: "New Private VM", action: #selector(newPrivateVMSession(_:)), keyEquivalent: "n")
        privateVMItem.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(.sectionHeader(title: "Unsandboxed"))
        let rawItem = sessionMenu.addItem(withTitle: "New Host Shell", action: #selector(newRawHostSession(_:)), keyEquivalent: "t")
        rawItem.keyEquivalentModifierMask = [.command, .option]
        sessionMenu.addItem(.separator())
        let configureItem = sessionMenu.addItem(withTitle: "Configure Sandbox…", action: #selector(configureActiveSandbox(_:)), keyEquivalent: ",")
        configureItem.keyEquivalentModifierMask = [.command, .option]
        let renameItem = sessionMenu.addItem(withTitle: "Rename Session…", action: #selector(renameActiveSession(_:)), keyEquivalent: "e")
        renameItem.keyEquivalentModifierMask = [.command, .shift]
        let searchItem = sessionMenu.addItem(withTitle: "Search Sessions…", action: #selector(searchSessions(_:)), keyEquivalent: "f")
        searchItem.keyEquivalentModifierMask = [.command, .shift]
        let paletteItem = sessionMenu.addItem(withTitle: "Quick Switcher & Commands…", action: #selector(toggleCommandPalette(_:)), keyEquivalent: "p")
        paletteItem.keyEquivalentModifierMask = [.command]
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(withTitle: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "d")
        let splitDown = sessionMenu.addItem(withTitle: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        let prevSplit = sessionMenu.addItem(withTitle: "Previous Split", action: #selector(focusPreviousSplit(_:)), keyEquivalent: "[")
        prevSplit.keyEquivalentModifierMask = [.command, .option]
        let nextSplit = sessionMenu.addItem(withTitle: "Next Split", action: #selector(focusNextSplit(_:)), keyEquivalent: "]")
        nextSplit.keyEquivalentModifierMask = [.command, .option]
        sessionMenu.addItem(.separator())
        let resetItem = sessionMenu.addItem(withTitle: "Reset Private VM", action: #selector(resetActiveSessionVM(_:)), keyEquivalent: "k")
        resetItem.keyEquivalentModifierMask = [.command, .shift]
        sessionMenu.addItem(.separator())
        sessionMenu.addItem(withTitle: "Close Pane", action: #selector(closeActivePane(_:)), keyEquivalent: "w")
        let closeSessionItem = sessionMenu.addItem(withTitle: "Close Session", action: #selector(closeActiveSession(_:)), keyEquivalent: "w")
        closeSessionItem.keyEquivalentModifierMask = [.command, .shift]
        sessionMenuItem.submenu = sessionMenu
        mainMenu.addItem(sessionMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(TerminalSurfaceView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(TerminalSurfaceView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(TerminalSurfaceView.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find in Terminal…", action: #selector(findInTerminal(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(findNextInTerminal(_:)), keyEquivalent: "g")
        let findPrev = editMenu.addItem(withTitle: "Find Previous", action: #selector(findPreviousInTerminal(_:)), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Clear Screen", action: #selector(clearActiveScreen(_:)), keyEquivalent: "k")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View / Sidebar menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "b")
        let flipSidebar = viewMenu.addItem(withTitle: "Flip Sidebar Left / Right", action: #selector(flipSidebarPosition(_:)), keyEquivalent: "s")
        flipSidebar.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: "Dock Sidebar Left", action: #selector(dockSidebarLeft(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Dock Sidebar Right", action: #selector(dockSidebarRight(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        let prevSession = viewMenu.addItem(withTitle: "Previous Session", action: #selector(selectPreviousSession(_:)), keyEquivalent: "[")
        prevSession.keyEquivalentModifierMask = [.command, .shift]
        let nextSession = viewMenu.addItem(withTitle: "Next Session", action: #selector(selectNextSession(_:)), keyEquivalent: "]")
        nextSession.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        for n in 1...9 {
            let item = viewMenu.addItem(
                withTitle: "Select Session \(n)",
                action: #selector(selectSessionByNumber(_:)),
                keyEquivalent: "\(n)"
            )
            item.tag = n - 1
        }
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func newSandboxSession(_ sender: Any?) {
        store?.newSession(mode: .sandbox)
    }

    @objc private func openProjectFolder(_ sender: Any?) {
        store?.openProjectFolderPicker()
    }

    @objc private func newPrivateVMSession(_ sender: Any?) {
        store?.newSession(mode: .linuxVM)
    }

    @objc private func newRawHostSession(_ sender: Any?) {
        store?.newSession(mode: .rawHost)
    }

    @objc private func splitRight(_ sender: Any?) {
        store?.splitFocusedPane(direction: .right)
    }

    @objc private func splitDown(_ sender: Any?) {
        store?.splitFocusedPane(direction: .down)
    }

    @objc private func focusPreviousSplit(_ sender: Any?) {
        store?.focusAdjacentSplit(direction: .previous)
    }

    @objc private func focusNextSplit(_ sender: Any?) {
        store?.focusAdjacentSplit(direction: .next)
    }

    @objc private func closeActivePane(_ sender: Any?) {
        if let key = NSApp.keyWindow, key !== mainWindow {
            key.performClose(sender)
            return
        }
        if store?.sessions.isEmpty == true {
            mainWindow?.performClose(nil)
            return
        }
        store?.closeFocusedPane()
    }

    @objc private func closeActiveSession(_ sender: Any?) {
        guard let id = store?.selectedSessionID else {
            mainWindow?.performClose(nil)
            return
        }
        store?.closeSession(id)
    }

    @objc private func resetActiveSessionVM(_ sender: Any?) {
        guard let id = store?.selectedSessionID else { return }
        store?.resetSessionVM(id)
    }
    @objc private func clearActiveScreen(_ sender: Any?) {
        store?.selectedSession?.focusedPane?.surfaceView.clearScreen()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        store?.toggleSidebarVisibility()
    }

    @objc private func flipSidebarPosition(_ sender: Any?) {
        store?.toggleSidebarPosition()
    }

    @objc private func dockSidebarLeft(_ sender: Any?) {
        store?.setSidebarPosition(.left)
    }

    @objc private func dockSidebarRight(_ sender: Any?) {
        store?.setSidebarPosition(.right)
    }

    @objc private func selectPreviousSession(_ sender: Any?) {
        store?.selectAdjacentSession(delta: -1)
    }

    @objc private func selectNextSession(_ sender: Any?) {
        store?.selectAdjacentSession(delta: 1)
    }

    @objc private func selectSessionByNumber(_ sender: NSMenuItem) {
        store?.selectSession(at: sender.tag)
    }
    @objc private func openSettings(_ sender: Any?) {
        showSettingsWindow()
    }
    @objc private func checkForUpdates(_ sender: Any?) {
        SettingsNavState.shared.selectedTab = .general
        showSettingsWindow()
        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    @objc private func configureActiveSandbox(_ sender: Any?) {
        store?.openActiveSandboxConfig()
    }

    @objc private func renameActiveSession(_ sender: Any?) {
        store?.beginRenameActiveSession()
    }

    @objc private func searchSessions(_ sender: Any?) {
        store?.focusSessionSearch()
    }

    @objc private func toggleCommandPalette(_ sender: Any?) {
        store?.toggleCommandPalette()
    }

    @objc private func findInTerminal(_ sender: Any?) {
        store?.openTerminalSearch()
    }

    @objc private func findNextInTerminal(_ sender: Any?) {
        store?.navigateTerminalSearch(next: true)
    }

    @objc private func findPreviousInTerminal(_ sender: Any?) {
        store?.navigateTerminalSearch(next: false)
    }

    private func showSettingsWindow() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let rootView = SettingsView(configManager: BooBoxConfigManager.shared)
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "boo_box Settings"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reloadConfig(_ sender: Any?) {
        BooBoxConfigManager.shared.reloadFromDisk()
        store?.reloadGhosttyConfig()
        if let bg = store?.themeBackground {
            mainWindow?.backgroundColor = bg
        }
    }
}

// MARK: - Local Unix Domain Socket IPC (`~/boo_box/run/app.sock`)

private struct AppIPCMessage: Decodable, Sendable {
    let op: String
    let id: String?
    let name: String?
    let template: String?
    let path: String?
    let noEnv: Bool?
}

private final class AppIPCServer: @unchecked Sendable {
    let socketPath: String
    private let onMessage: @Sendable (AppIPCMessage) -> Void
    private let queue = DispatchQueue(label: "dev.boo-box.app-ipc", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var stopped = false

    init(onMessage: @escaping @Sendable (AppIPCMessage) -> Void) {
        let realHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let runDir = "\(realHome)/boo_box/run"
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        chmod(runDir, 0o700)
        self.socketPath = "\(runDir)/app.sock"
        self.onMessage = onMessage
    }

    func start() {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < maxLen else {
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, addrLen) == 0
            }
        }
        guard bound, listen(fd, 16) == 0 else {
            close(fd)
            return
        }
        chmod(socketPath, 0o600)
        self.listenFD = fd

        queue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    func stop() {
        stopped = true
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop(fd: Int32) {
        while !stopped {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            handleClient(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer { close(clientFD) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 16384 {
            let n = Darwin.read(clientFD, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if buf[0..<n].contains(0x0A) { break }
        }
        if let msg = try? JSONDecoder().decode(AppIPCMessage.self, from: data) {
            onMessage(msg)
            let ok = "OK\n"
            _ = ok.withCString { Darwin.write(clientFD, $0, 3) }
        } else {
            let err = "ERR\n"
            _ = err.withCString { Darwin.write(clientFD, $0, 4) }
        }
    }
}
