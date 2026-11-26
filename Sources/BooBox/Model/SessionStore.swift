import AppKit
import Combine
import Foundation
import GhosttyKit

enum SidebarPosition: String, CaseIterable, Sendable {
    case left
    case right

    var toggled: SidebarPosition {
        self == .left ? .right : .left
    }

    var label: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        }
    }
}

enum SessionMode: String, Codable, Equatable, Sendable {
    case sandbox    // Default: Native macOS Seatbelt sandbox persisted in ~/boo_box/sessions/<id>/
    case linuxVM    // Private VM: Clean ephemeral arm64 Linux 6.18 microVM (zero Mac files, wiped on close)
    case rawHost    // Unsandboxed host macOS shell

    var shortBadge: String {
        switch self {
        case .sandbox: "BOX"
        case .linuxVM: "VM"
        case .rawHost: "RAW"
        }
    }

    var label: String {
        switch self {
        case .sandbox: "macOS Sandbox"
        case .linuxVM: "Private VM"
        case .rawHost: "Host Shell"
        }
    }

    var isRawHost: Bool {
        self == .rawHost
    }

    var isLinuxVM: Bool {
        self == .linuxVM
    }
}

enum SplitAxis: Sendable {
    case horizontal // side-by-side (left | right)
    case vertical   // stacked (top / bottom)
}

@MainActor
final class TerminalPane: ObservableObject, Identifiable {
    let id: UUID
    let surfaceView: TerminalSurfaceView

    @Published var title: String = ""
    @Published var pwd: String?
    @Published var progress: TerminalProgress?
    @Published var hasExited: Bool = false
    @Published var isFocused: Bool = false
    /// Non-nil when this pane's shell/sandbox runs inside detached `booboxd`.
    var daemonPaneID: String?

    var onBell: (() -> Void)?
    var onDesktopNotification: ((String, String) -> Void)?
    var onCommandFinished: ((Int, UInt64) -> Void)?
    var onStartSearch: ((String?) -> Void)?
    var onEndSearch: (() -> Void)?
    var onSearchTotal: ((Int?) -> Void)?
    var onSearchSelected: ((Int?) -> Void)?
    var onBecameFocused: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onPwdChange: ((String) -> Void)?
    init(launchOptions: SurfaceLaunchOptions = SurfaceLaunchOptions(), daemonPaneID: String? = nil) {
        let paneID = UUID()
        self.id = paneID
        self.daemonPaneID = daemonPaneID
        self.surfaceView = TerminalSurfaceView(paneID: paneID, launchOptions: launchOptions)

        self.surfaceView.onTitleChange = { [weak self] newTitle in
            self?.title = newTitle
            self?.onTitleChange?(newTitle)
        }
        self.surfaceView.onPwdChange = { [weak self] newPwd in
            self?.pwd = newPwd
            self?.onPwdChange?(newPwd)
        }
        self.surfaceView.onProgressChange = { [weak self] newProgress in
            self?.progress = newProgress
        }
        self.surfaceView.onBell = { [weak self] in
            self?.onBell?()
        }
        self.surfaceView.onDesktopNotification = { [weak self] title, body in
            self?.onDesktopNotification?(title, body)
        }
        self.surfaceView.onCommandFinished = { [weak self] exitCode, durationNs in
            self?.onCommandFinished?(exitCode, durationNs)
        }
        self.surfaceView.onStartSearch = { [weak self] needle in
            self?.onStartSearch?(needle)
        }
        self.surfaceView.onEndSearch = { [weak self] in
            self?.onEndSearch?()
        }
        self.surfaceView.onSearchTotal = { [weak self] total in
            self?.onSearchTotal?(total)
        }
        self.surfaceView.onSearchSelected = { [weak self] selected in
            self?.onSearchSelected?(selected)
        }
        self.surfaceView.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.isFocused = focused
            if focused {
                self.onBecameFocused?()
            }
        }
        self.surfaceView.onChildExited = { [weak self] _ in
            self?.hasExited = true
        }
    }

    func destroy() {
        surfaceView.destroySurface()
    }

    func killDaemonPane() {
        if let dp = daemonPaneID {
            daemonPaneID = nil
            DaemonClient.shared.killPane(dp)
        }
    }
}

indirect enum SplitNode: Identifiable {
    case leaf(TerminalPane)
    case split(id: UUID, axis: SplitAxis, first: SplitNode, second: SplitNode)

    var id: UUID {
        switch self {
        case .leaf(let pane): pane.id
        case .split(let id, _, _, _): id
        }
    }

    var allPanes: [TerminalPane] {
        switch self {
        case .leaf(let pane):
            return [pane]
        case .split(_, _, let first, let second):
            return first.allPanes + second.allPanes
        }
    }

    func contains(paneID: UUID) -> Bool {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID
        case .split(_, _, let first, let second):
            return first.contains(paneID: paneID) || second.contains(paneID: paneID)
        }
    }

    func splitting(
        paneID: UUID,
        axis: SplitAxis,
        newPane: TerminalPane,
        insertBefore: Bool = false
    ) -> SplitNode {
        switch self {
        case .leaf(let existing) where existing.id == paneID:
            if insertBefore {
                return .split(id: UUID(), axis: axis, first: .leaf(newPane), second: .leaf(existing))
            } else {
                return .split(id: UUID(), axis: axis, first: .leaf(existing), second: .leaf(newPane))
            }
        case .leaf:
            return self
        case .split(let id, let existingAxis, let first, let second):
            return .split(
                id: id,
                axis: existingAxis,
                first: first.splitting(paneID: paneID, axis: axis, newPane: newPane, insertBefore: insertBefore),
                second: second.splitting(paneID: paneID, axis: axis, newPane: newPane, insertBefore: insertBefore)
            )
        }
    }

    func removing(paneID: UUID) -> SplitNode? {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? nil : self
        case .split(let id, let axis, let first, let second):
            let newFirst = first.removing(paneID: paneID)
            let newSecond = second.removing(paneID: paneID)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let f?, nil): return f
            case (nil, let s?): return s
            case (let f?, let s?): return .split(id: id, axis: axis, first: f, second: s)
            }
        }
    }
}

enum SandboxConfigTarget: Identifiable {
    case active(TerminalSession)
    case saved(MacSandboxSession)

    var id: UUID {
        switch self {
        case .active(let session): session.id
        case .saved(let sandbox): sandbox.id
        }
    }
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    let mode: SessionMode
    let sequenceNumber: Int
    let createdAt = Date()

    @Published var customTitle: String?
    @Published var rootNode: SplitNode
    @Published var focusedPaneID: UUID
    @Published var hasUnreadBell: Bool = false
    @Published var isRunningCommand: Bool = false
    @Published var runningProcessName: String?
    @Published var isDetachedLive: Bool = false
    @Published var pendingProxyAlert: ProxyAuditEventItem?
    @Published var macSandbox: MacSandboxSession?
    @Published var overrides: SandboxOverrideConfig = .default
    @Published var vmState: VMState?
    @Published var bootTimeMs: Double?
    @Published var wasWarmPooled: Bool = false

    var vmSocketPath: String?
    var attachBinaryPath: String?
    // Mirrored from focused pane for clean SwiftUI sidebar updates
    @Published private(set) var focusedTitle: String = ""
    @Published private(set) var focusedPwd: String?
    @Published private(set) var activeProgress: TerminalProgress?

    private var paneCancellables: [UUID: AnyCancellable] = [:]

    var focusedPane: TerminalPane? {
        rootNode.allPanes.first(where: { $0.id == focusedPaneID }) ?? rootNode.allPanes.first
    }

    var paneCount: Int {
        rootNode.allPanes.count
    }

    var displayTitle: String {
        if let customTitle, !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }
        switch mode {
        case .sandbox:
            if let sb = macSandbox {
                return sb.name
            }
            return sequenceNumber == 1 ? "scratch" : "scratch #\(sequenceNumber)"
        case .linuxVM:
            if !focusedTitle.isEmpty && focusedTitle != displayPwd && focusedTitle != "~" && focusedTitle != "zsh" && focusedTitle != "sh" {
                return focusedTitle
            }
            if let pwd = focusedPwd, !pwd.isEmpty, pwd != "/root", pwd != "/" {
                let folder = URL(fileURLWithPath: pwd).lastPathComponent
                if !folder.isEmpty { return "linux-vm · \(folder)" }
            }
            return sequenceNumber == 1 ? "linux-vm" : "linux-vm #\(sequenceNumber)"
        case .rawHost:
            if !focusedTitle.isEmpty && focusedTitle != displayPwd && focusedTitle != "~" && focusedTitle != "zsh" && focusedTitle != "-zsh" && focusedTitle != "bash" {
                return focusedTitle
            }
            if let pwd = focusedPwd, !pwd.isEmpty {
                let home = NSHomeDirectory()
                if pwd == home { return "~" }
                let folder = URL(fileURLWithPath: pwd).lastPathComponent
                if !folder.isEmpty { return folder }
            }
            return sequenceNumber == 1 ? "host" : "host #\(sequenceNumber)"
        }
    }

    var displayPwd: String? {
        if mode == .sandbox, let sb = macSandbox {
            guard let pwd = focusedPwd, !pwd.isEmpty else {
                return sb.shortID
            }
            let ws = sb.workspaceDir.path
            if pwd == ws { return "\(sb.shortID)/workspace" }
            if pwd.hasPrefix(ws + "/") {
                return "\(sb.shortID)/" + pwd.dropFirst(ws.count + 1)
            }
            let home = sb.homeDir.path
            if pwd == home { return "\(sb.shortID)/~" }
            if pwd.hasPrefix(home + "/") {
                return "\(sb.shortID)/~" + pwd.dropFirst(home.count)
            }
            return pwd
        }

        guard let pwd = focusedPwd, !pwd.isEmpty else {
            return nil
        }
        if mode == .linuxVM {
            if pwd == "/root" { return "~" }
            if pwd.hasPrefix("/root/") { return "~" + pwd.dropFirst("/root".count) }
            return pwd
        }
        let home = NSHomeDirectory()
        if pwd == home {
            return "~"
        }
        if pwd.hasPrefix(home + "/") {
            return "~" + pwd.dropFirst(home.count)
        }
        return pwd
    }

    init(id: UUID = UUID(), mode: SessionMode, sequenceNumber: Int, initialPane: TerminalPane) {
        self.id = id
        self.mode = mode
        self.sequenceNumber = sequenceNumber
        self.rootNode = .leaf(initialPane)
        self.focusedPaneID = initialPane.id
        observePane(initialPane)
        refreshMirroredState()
    }

    func observePane(_ pane: TerminalPane) {
        paneCancellables[pane.id] = pane.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshMirroredState()
            }
        }
    }

    func stopObservingPane(_ paneID: UUID) {
        paneCancellables.removeValue(forKey: paneID)
    }

    func refreshMirroredState() {
        let pane = focusedPane
        focusedTitle = pane?.title ?? ""
        focusedPwd = pane?.pwd
        activeProgress = pane?.progress ?? rootNode.allPanes.compactMap(\.progress).first
    }

    func destroyAllPanes(killDaemonPanes: Bool = false) {
        paneCancellables.removeAll()
        for pane in rootNode.allPanes {
            if killDaemonPanes {
                pane.killDaemonPane()
            }
            pane.destroy()
        }
    }
}

private struct PersistedOpenSession: Codable {
    let id: UUID
    let mode: SessionMode
    let sandboxShortID: String?
    let daemonPaneID: String?
    let rawWorkingDirectory: String?
}

private struct PersistedWorkspaceState: Codable {
    let sessions: [PersistedOpenSession]
    let selectedSessionID: UUID?
}

@MainActor
final class SessionStore: ObservableObject {
    private enum DefaultsKey {
        static let sidebarPosition = "boobox.sidebar.position"
        static let sidebarVisible = "boobox.sidebar.visible"
        static let sidebarWidth = "boobox.sidebar.width"
    }

    static let minSidebarWidth: CGFloat = 190
    static let maxSidebarWidth: CGFloat = 380

    @Published var sessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID?
    @Published var savedMacSessions: [SavedMacSandboxItem] = []
    @Published var sidebarPosition: SidebarPosition {
        didSet {
            UserDefaults.standard.set(sidebarPosition.rawValue, forKey: DefaultsKey.sidebarPosition)
        }
    }
    @Published var sidebarVisible: Bool {
        didSet {
            UserDefaults.standard.set(sidebarVisible, forKey: DefaultsKey.sidebarVisible)
        }
    }
    @Published var sidebarWidth: CGFloat {
        didSet {
            let clamped = min(max(sidebarWidth, Self.minSidebarWidth), Self.maxSidebarWidth)
            if clamped != sidebarWidth {
                sidebarWidth = clamped
            } else {
                UserDefaults.standard.set(Double(sidebarWidth), forKey: DefaultsKey.sidebarWidth)
            }
        }
    }
    @Published var themeBackground: NSColor
    @Published var renamingSessionID: UUID?
    @Published var renamingSavedSessionID: UUID?
    @Published var searchQuery: String = ""
    @Published var searchFocusRequestID: Int = 0
    @Published var cloningProjectName: String?
    @Published var pinnedFolderPaths: [String] = []
    private let pinnedFoldersURL: URL = {
        BooBoxPaths.rootDirURL.appendingPathComponent("pinned-folders.json")
    }()
    @Published var configuringTarget: SandboxConfigTarget?
    @Published var isCommandPaletteOpen: Bool = false
    @Published var isTerminalSearchOpen: Bool = false
    @Published var terminalSearchQuery: String = ""
    @Published var terminalSearchTotal: Int? = nil
    @Published var terminalSearchSelected: Int? = nil
    @Published var terminalSearchFocusToken: Int = 0
    let stageView = TerminalStageView()
    var onOpenSettings: (() -> Void)?
    var onThemeBackgroundChanged: ((NSColor) -> Void)?

    private var monitorTimer: Timer?
    private var lastProxyEventSeq: UInt64 = 0
    private var dismissedProxyAlertKeys: Set<String> = []
    private let persistedStateURL: URL = {
        BooBoxPaths.rootDirURL.appendingPathComponent("run/last-open-sessions.json")
    }()
    var filteredSessions: [TerminalSession] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { session in
            session.displayTitle.lowercased().contains(q)
                || (session.macSandbox?.shortID.lowercased().contains(q) ?? false)
                || (session.displayPwd?.lowercased().contains(q) ?? false)
                || session.mode.label.lowercased().contains(q)
        }
    }

    var filteredSavedMacSessions: [SavedMacSandboxItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return savedMacSessions }
        return savedMacSessions.filter { item in
            item.sandbox.name.lowercased().contains(q)
                || item.sandbox.shortID.lowercased().contains(q)
        }
    }

    var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    init() {
        let savedPos = UserDefaults.standard.string(forKey: DefaultsKey.sidebarPosition)
            .flatMap(SidebarPosition.init(rawValue:)) ?? .left
        self.sidebarPosition = savedPos

        if UserDefaults.standard.object(forKey: DefaultsKey.sidebarVisible) != nil {
            self.sidebarVisible = UserDefaults.standard.bool(forKey: DefaultsKey.sidebarVisible)
        } else {
            self.sidebarVisible = true
        }

        let savedWidth = UserDefaults.standard.double(forKey: DefaultsKey.sidebarWidth)
        self.sidebarWidth = savedWidth >= Double(Self.minSidebarWidth)
            ? min(CGFloat(savedWidth), Self.maxSidebarWidth)
            : 248

        self.themeBackground = GhosttyRuntime.shared.themeColors.background
        self.stageView.backgroundColor = self.themeBackground
        wireRuntimeCallbacks()
        self.pinnedFolderPaths = loadPinnedFolderPaths()
        NotificationManager.shared.onSelectSession = { [weak self] sessionID in
            self?.selectSession(sessionID)
        }
        startLiveMonitors()
    }
    private func wireRuntimeCallbacks() {
        GhosttyRuntime.shared.onHostAction = { [weak self] action, surfaceView in
            guard let self else { return false }
            return self.handleGhosttyAction(action, from: surfaceView)
        }

        GhosttyRuntime.shared.onCloseSurface = { [weak self] surfaceView, _ in
            guard let self else { return }
            self.closePane(surfaceView: surfaceView)
        }
    }

    // MARK: - Session Management

    @discardableResult
    func newSession(mode: SessionMode = .sandbox, workingDirectory: String? = nil) -> TerminalSession? {
        let sessionID = UUID()
        let seq = nextAvailableSequenceNumber(for: mode)

        switch mode {
        case .rawHost:
            let dir = workingDirectory ?? selectedSession?.focusedPane?.pwd ?? NSHomeDirectory()
            let opts = SurfaceLaunchOptions(
                workingDirectory: dir,
                command: nil,
                environmentVariables: ["BOOBOX_MODE": "raw_host"],
                context: GHOSTTY_SURFACE_CONTEXT_TAB
            )
            let pane = TerminalPane(launchOptions: opts)
            let session = TerminalSession(id: sessionID, mode: .rawHost, sequenceNumber: seq, initialPane: pane)
            attachPaneHandlers(pane, in: session)

            sessions.append(session)
            selectedSessionID = session.id
            stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
            return session

        case .sandbox:
            return createScratchMacSandboxSession(sequenceNumber: seq)
        case .linuxVM:
            // Isolated Apple Silicon arm64 Linux 6.18 microVM. Never falls back to host shell.
            let vm: SandboxVM
            let attachBinary: URL
            let fromWarmPool: Bool
            do {
                let started = try MicroVMManager.shared.startVM(for: sessionID)
                vm = started.vm
                attachBinary = started.attachBinary
                fromWarmPool = started.fromWarmPool
            } catch {
                presentVMError(error)
                return nil
            }

            let guestCwd = workingDirectory ?? "/root"
            let opts = SurfaceLaunchOptions(
                workingDirectory: NSHomeDirectory(),
                command: Self.buildAttachCommand(attachBinary: attachBinary.path, socketPath: vm.socketPath, guestCwd: guestCwd),
                environmentVariables: ["BOOBOX_MODE": "linux_vm"],
                context: GHOSTTY_SURFACE_CONTEXT_TAB
            )

            let pane = TerminalPane(launchOptions: opts)
            let session = TerminalSession(id: sessionID, mode: .linuxVM, sequenceNumber: seq, initialPane: pane)
            session.vmSocketPath = vm.socketPath
            session.attachBinaryPath = attachBinary.path
            session.wasWarmPooled = fromWarmPool && vm.isReady
            session.vmState = vm.isReady ? .running : vm.currentState
            if session.wasWarmPooled {
                session.bootTimeMs = 1
            }

            vm.onStateChange = { [weak session] state in
                session?.vmState = state
            }
            vm.onBootReady = { [weak session] ms in
                session?.bootTimeMs = ms
            }
            attachPaneHandlers(pane, in: session)

            sessions.append(session)
            selectedSessionID = session.id
            stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
            return session
        }
    }

    @discardableResult
    func newScratchSession() -> TerminalSession? {
        let seq = nextAvailableSequenceNumber(for: .sandbox)
        return createScratchMacSandboxSession(sequenceNumber: seq)
    }

    func openProjectFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Open Folder in Isolated Sandbox"
        let isOverlay = BooBoxConfigManager.shared.config.general.workspaceMode == .overlay
        panel.message = isOverlay
            ? "Mounts this folder in ~20 ms via an isolated Copy-on-Write overlay. Edits stay inside ~/boo_box/sessions/ — your source folder is never modified."
            : "Creates an isolated APFS clone of this folder inside ~/boo_box/sessions/. New sessions (⌘T) will spawn fresh isolated copies of this folder."
        panel.prompt = "Open in Sandbox"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProjectFolder(url)
    }

    func openProjectFolder(
        _ url: URL,
        displayName: String? = nil,
        excludeEnvOverride: Bool? = nil,
        forceOverlay: Bool = false
    ) {
        do {
            let validated = try MacOSSandboxManager.shared.validateProjectDirectory(url)
            let cleanName = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? displayName!.trimmingCharacters(in: .whitespacesAndNewlines)
                : validated.lastPathComponent
            spawnClonedProjectSession(
                from: validated,
                displayName: cleanName,
                excludeEnvOverride: excludeEnvOverride,
                forceOverlay: forceOverlay
            )
        } catch {
            presentProjectError(error)
        }
    }
    func cancelActiveProjectClone() {
        cloningProjectName = nil
        MacOSSandboxManager.shared.cancelActiveClone()
    }


    // MARK: - Explicit Opt-In Pinned Folders (Never Auto-Pinned)

    func isFolderPinned(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
        return pinnedFolderPaths.contains(resolved)
    }

    func togglePinFolder(_ path: String) {
        let resolved = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
        if let idx = pinnedFolderPaths.firstIndex(of: resolved) {
            pinnedFolderPaths.remove(at: idx)
            savePinnedFolderPaths()
            return
        }
        do {
            let validated = try MacOSSandboxManager.shared.validateProjectDirectory(URL(fileURLWithPath: resolved, isDirectory: true))
            if !pinnedFolderPaths.contains(validated.path) {
                pinnedFolderPaths.append(validated.path)
                savePinnedFolderPaths()
            }
        } catch {
            presentProjectError(error)
        }
    }

    func unpinFolder(_ path: String) {
        let resolved = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
        pinnedFolderPaths.removeAll { $0 == path || $0 == resolved }
        savePinnedFolderPaths()
    }

    func pinFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Pin Folder to Sidebar"
        panel.message = "Pinned folders appear in the sidebar for 1-click isolated sandbox launches. Folders are never pinned automatically."
        panel.prompt = "Pin Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let validated = try MacOSSandboxManager.shared.validateProjectDirectory(url)
            if !pinnedFolderPaths.contains(validated.path) {
                pinnedFolderPaths.append(validated.path)
                savePinnedFolderPaths()
            }
        } catch {
            presentProjectError(error)
        }
    }

    private func loadPinnedFolderPaths() -> [String] {
        guard let data = try? Data(contentsOf: pinnedFoldersURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        let fm = FileManager.default
        return paths.filter { fm.fileExists(atPath: $0) }
    }

    private func savePinnedFolderPaths() {
        try? FileManager.default.createDirectory(at: pinnedFoldersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pinnedFolderPaths) {
            try? data.write(to: pinnedFoldersURL, options: .atomic)
        }
    }

    /// Immediately adopts a session already APFS-cloned by `boo` CLI (0ms extra wait!)
    /// and stages a clean background template snapshot so future `⌘T` presses clone fresh copies.
    func adoptReadyProjectSession(
        id: UUID,
        displayName: String,
        templateDirURL: URL,
        excludeEnvOverride: Bool? = nil
    ) {
        let seq = nextAvailableSequenceNumber(for: .sandbox)
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = cleanName.isEmpty ? templateDirURL.lastPathComponent : cleanName
        let autoNameEnabled = BooBoxConfigManager.shared.config.general.autoNameSessions
        let existingNames = Set(sessions.map(\.displayTitle) + savedMacSessions.map { $0.sandbox.name })
        let preclonedWS = MacOSSandboxManager.shared.sessionsRootURL
            .appendingPathComponent("s-\(String(id.uuidString.prefix(8)).lowercased())/workspace", isDirectory: true)
        let initialName: String
        if autoNameEnabled {
            initialName = MacOSSandboxManager.shared.semanticProjectName(
                projectName: projectName,
                sourceDir: preclonedWS,
                avoiding: existingNames
            )
        } else {
            initialName = MacOSSandboxManager.shared.disambiguatedName(base: projectName, avoiding: existingNames)
        }

        do {
            let sandbox = try MacOSSandboxManager.shared.adoptPreclonedSession(
                id: id,
                name: initialName,
                sourceProjectPath: templateDirURL.path
            )
            _ = startSessionWithMacSandbox(sandbox, sequenceNumber: seq)

            // Snapshot untouched copy into ~/boo_box/templates/ in background for future ⌘T tabs
            let cfg = BooBoxConfigManager.shared.config.general
            MacOSSandboxManager.shared.snapshotTemplateInBackground(
                from: sandbox.workspaceDir,
                to: templateDirURL,
                excludeEnvFiles: excludeEnvOverride ?? cfg.excludeEnvFilesWhenCloning,
                skipHeavyDirs: cfg.skipHeavyDirsWhenCloning
            )
        } catch {
            presentProjectError(error)
        }
    }
    private func createScratchMacSandboxSession(sequenceNumber seq: Int) -> TerminalSession? {
        let sessionID = UUID()
        let autoNameEnabled = BooBoxConfigManager.shared.config.general.autoNameSessions
        let existing = Set(sessions.map(\.displayTitle) + savedMacSessions.map { $0.sandbox.name })
        let initialName: String = autoNameEnabled
            ? MacOSSandboxManager.shared.semanticScratchName(avoiding: existing)
            : "Session \(seq)"
        let sandbox: MacSandboxSession
        do {
            sandbox = try MacOSSandboxManager.shared.createSession(
                id: sessionID,
                name: initialName,
                hasUserCustomName: false
            )
        } catch {
            presentVMError(error)
            return nil
        }
        return startSessionWithMacSandbox(sandbox, sequenceNumber: seq)
    }

    private func spawnClonedProjectSession(
        from projectURL: URL,
        displayName: String,
        excludeEnvOverride: Bool?,
        forceOverlay: Bool = false
    ) {
        let sessionID = UUID()
        let seq = nextAvailableSequenceNumber(for: .sandbox)
        let projectName = displayName
        let autoNameEnabled = BooBoxConfigManager.shared.config.general.autoNameSessions
        let existingNames = Set(sessions.map(\.displayTitle) + savedMacSessions.map { $0.sandbox.name })
        let initialName: String
        if autoNameEnabled {
            initialName = MacOSSandboxManager.shared.semanticProjectName(
                projectName: projectName,
                sourceDir: projectURL,
                avoiding: existingNames
            )
        } else {
            initialName = MacOSSandboxManager.shared.disambiguatedName(base: projectName, avoiding: existingNames)
        }
        cloningProjectName = projectName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<MacSandboxSession, Error> = Result {
                try MacOSSandboxManager.shared.createSession(
                    id: sessionID,
                    name: initialName,
                    hasUserCustomName: false,
                    sourceProjectURL: projectURL,
                    excludeEnvFilesOverride: excludeEnvOverride,
                    workspaceModeOverride: forceOverlay ? .overlay : nil
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cloningProjectName = nil
                switch result {
                case .success(let sandbox):
                    _ = self.startSessionWithMacSandbox(sandbox, sequenceNumber: seq)
                    if !sandbox.isOverlay {
                        let cfg = BooBoxConfigManager.shared.config.general
                        MacOSSandboxManager.shared.replenishWarmCloneInBackground(
                            for: projectURL,
                            excludeEnvFiles: excludeEnvOverride ?? cfg.excludeEnvFilesWhenCloning,
                            skipHeavyDirs: cfg.skipHeavyDirsWhenCloning
                        )
                    }
                case .failure(MacSandboxError.cancelled):
                    break
                case .failure(let error):
                    self.presentProjectError(error)
                }
            }
        }
    }
    private func presentProjectError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not open folder in sandbox"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Native macOS Sandboxed Sessions (~/boo_box/sessions/<id>/)

    @discardableResult
    func resumeSavedMacSession(_ sandbox: MacSandboxSession) -> TerminalSession? {
        savedMacSessions.removeAll { $0.id == sandbox.id }
        let refreshed: MacSandboxSession
        do {
            refreshed = try MacOSSandboxManager.shared.prepareForResume(sandbox)
        } catch {
            presentVMError(error)
            return nil
        }
        let seq = nextAvailableSequenceNumber(for: .sandbox)
        return startSessionWithMacSandbox(refreshed, sequenceNumber: seq)
    }

    private func makeSandboxPane(
        for sandbox: MacSandboxSession,
        cwd: String,
        context: ghostty_surface_context_e,
        reattachPane: DaemonPaneStatus? = nil
    ) -> TerminalPane {
        let useDaemon = BooBoxConfigManager.shared.config.general.persistentSessionsEnabled
        if useDaemon {
            if let existing = reattachPane, existing.alive,
               let attachCmd = DaemonClient.shared.buildAttachCommand(socketPath: existing.socketPath, cwd: cwd) {
                // Ensure proxy policy is synced for this reattached session
                _ = SecretsVaultManager.shared.sandboxEnvironment(for: sandbox.shortID, overrides: sandbox.overrides)
                let opts = SurfaceLaunchOptions(
                    workingDirectory: NSHomeDirectory(),
                    command: attachCmd,
                    environmentVariables: ["BOOBOX_MODE": "mac_sandbox"],
                    context: context
                )
                return TerminalPane(launchOptions: opts, daemonPaneID: existing.paneId)
            }
            let paneID = UUID().uuidString
            let cmd = MacOSSandboxManager.shared.launchCommand(for: sandbox)
            if let sockPath = DaemonClient.shared.spawnPane(paneId: paneID, sessionId: sandbox.shortID, cwd: cwd, command: cmd),
               let attachCmd = DaemonClient.shared.buildAttachCommand(socketPath: sockPath, cwd: cwd) {
                let opts = SurfaceLaunchOptions(
                    workingDirectory: NSHomeDirectory(),
                    command: attachCmd,
                    environmentVariables: ["BOOBOX_MODE": "mac_sandbox"],
                    context: context
                )
                return TerminalPane(launchOptions: opts, daemonPaneID: paneID)
            }
        }

        let opts = SurfaceLaunchOptions(
            workingDirectory: cwd,
            command: MacOSSandboxManager.shared.launchCommand(for: sandbox),
            environmentVariables: MacOSSandboxManager.shared.launchEnvironment(for: sandbox),
            context: context
        )
        return TerminalPane(launchOptions: opts)
    }

    private func startSessionWithMacSandbox(
        _ sandbox: MacSandboxSession,
        sequenceNumber: Int,
        reattachPane: DaemonPaneStatus? = nil,
        focusImmediately: Bool = true
    ) -> TerminalSession {
        let pane = makeSandboxPane(
            for: sandbox,
            cwd: sandbox.workspaceDir.path,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            reattachPane: reattachPane
        )
        let session = TerminalSession(id: sandbox.id, mode: .sandbox, sequenceNumber: sequenceNumber, initialPane: pane)
        session.macSandbox = sandbox
        session.overrides = sandbox.overrides
        session.isDetachedLive = pane.daemonPaneID != nil
        attachPaneHandlers(pane, in: session)
        sessions.append(session)
        if focusImmediately || selectedSessionID == nil {
            selectedSessionID = session.id
        }
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: focusImmediately)
        saveOpenSessionsState()
        return session
    }

    func revealSessionInFinder(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if let sb = session.macSandbox {
            revealMacSandboxInFinder(sb)
        }
    }

    func revealMacSandboxInFinder(_ sandbox: MacSandboxSession) {
        NSWorkspace.shared.activateFileViewerSelecting([sandbox.workspaceDir])
    }

    func openSettings() {
        onOpenSettings?()
    }

    func focusSessionSearch() {
        if !sidebarVisible {
            sidebarVisible = true
        }
        searchFocusRequestID += 1
    }

    func beginRenameActiveSession() {
        guard let id = selectedSessionID else { return }
        if !sidebarVisible {
            sidebarVisible = true
        }
        if !searchQuery.isEmpty {
            searchQuery = ""
        }
        renamingSessionID = id
    }

    private func confirmPermanentSessionDeletion(name: String, shortID: String, isOverlay: Bool) -> Bool {
        guard BooBoxConfigManager.shared.config.general.confirmBeforeDeletingSession else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete entire session \"\(name)\"?"
        alert.informativeText = isOverlay
            ? "This unmounts and permanently deletes only this sandbox's isolated edits (~/boo_box/sessions/\(shortID)/.overlay/) and home config. Your source folder is never touched."
            : "This permanently deletes the entire session directory (~/boo_box/sessions/\(shortID)/), including all files in workspace/ and its isolated home config. This cannot be undone."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again (can be re-enabled in Settings)"
        let deleteBtn = alert.addButton(withTitle: "Delete Entire Session")
        deleteBtn.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        if alert.suppressionButton?.state == .on {
            BooBoxConfigManager.shared.config.general.confirmBeforeDeletingSession = false
        }
        return true
    }

    func deleteSavedMacSession(_ sandbox: MacSandboxSession) {
        guard confirmPermanentSessionDeletion(name: sandbox.name, shortID: sandbox.shortID, isOverlay: sandbox.isOverlay) else { return }
        // Instant UI removal + atomic POSIX rename to .trash-* + background deletion (0 ms UI hang)
        savedMacSessions.removeAll { $0.id == sandbox.id }
        MacOSSandboxManager.shared.deleteSessionDir(sandbox)
    }

    func openActiveSandboxConfig() {
        guard let id = selectedSessionID else { return }
        openSandboxConfig(for: id)
    }

    func openSandboxConfig(for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }), !session.mode.isRawHost else { return }
        configuringTarget = .active(session)
    }

    func openSandboxConfig(forSaved sandbox: MacSandboxSession) {
        configuringTarget = .saved(sandbox)
    }

    func applySandboxOverrides(_ overrides: SandboxOverrideConfig, to sessionID: UUID, restart: Bool) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        session.overrides = overrides

        if session.mode == .sandbox, let sb = session.macSandbox {
            do {
                let updated = try MacOSSandboxManager.shared.updateOverrides(overrides, for: sb)
                session.macSandbox = updated
                if restart {
                    restartMacSandboxSession(session, with: updated)
                }
            } catch {
                presentProjectError(error)
            }
        } else if session.mode == .linuxVM {
            if restart {
                resetSessionVM(session.id)
            }
        }
    }

    func applySandboxOverrides(_ overrides: SandboxOverrideConfig, toSaved sandbox: MacSandboxSession) {
        do {
            let updated = try MacOSSandboxManager.shared.updateOverrides(overrides, for: sandbox)
            if let idx = savedMacSessions.firstIndex(where: { $0.id == sandbox.id }) {
                savedMacSessions[idx] = SavedMacSandboxItem(sandbox: updated, fileCount: savedMacSessions[idx].fileCount)
            }
        } catch {
            presentProjectError(error)
        }
    }

    private func restartMacSandboxSession(_ session: TerminalSession, with sandbox: MacSandboxSession) {
        let currentPwd = session.focusedPane?.pwd
        let launchDir = (currentPwd != nil && currentPwd!.hasPrefix(sandbox.workspaceDir.path))
            ? currentPwd!
            : sandbox.workspaceDir.path

        session.destroyAllPanes(killDaemonPanes: true)
        let freshPane = makeSandboxPane(for: sandbox, cwd: launchDir, context: GHOSTTY_SURFACE_CONTEXT_TAB)
        attachPaneHandlers(freshPane, in: session)
        session.observePane(freshPane)
        session.isDetachedLive = freshPane.daemonPaneID != nil
        session.pendingProxyAlert = nil
        session.rootNode = .leaf(freshPane)
        session.focusedPaneID = freshPane.id
        session.refreshMirroredState()

        stageView.rebuildSession(session)
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
        saveOpenSessionsState()
    }
    func deleteActiveSessionPermanently(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }),
              let sb = session.macSandbox else {
            closeSession(id)
            return
        }
        guard confirmPermanentSessionDeletion(name: session.displayTitle, shortID: sb.shortID, isOverlay: sb.isOverlay) else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removed = sessions.remove(at: idx)
        removed.destroyAllPanes(killDaemonPanes: true)
        DaemonClient.shared.killSession(sb.shortID)
        SecretsVaultManager.shared.unregisterSession(sb.shortID)
        MacOSSandboxManager.shared.deleteSessionDir(sb)
        stageView.removeSession(id)

        if selectedSessionID == id {
            if sessions.isEmpty {
                selectedSessionID = nil
            } else {
                let nextIdx = min(idx, sessions.count - 1)
                selectedSessionID = sessions[nextIdx].id
            }
        }
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: !sessions.isEmpty)
        updateDockBadge()
        saveOpenSessionsState()
        refreshSavedMacSessions()
    }

    func renameSavedMacSession(_ sandbox: MacSandboxSession, to newName: String?) {
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            MacOSSandboxManager.shared.updateSessionName(sandbox, to: trimmed, isUserCustom: true)
            refreshSavedMacSessions()
        }
        if renamingSavedSessionID == sandbox.id {
            renamingSavedSessionID = nil
        }
    }
    func refreshSavedMacSessions() {
        let activeIDs = Set(sessions.compactMap { $0.macSandbox?.id })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = MacOSSandboxManager.shared.loadSavedSessions(excludingActive: activeIDs)
            DispatchQueue.main.async { [weak self] in
                self?.savedMacSessions = loaded
            }
        }
    }

    func resetSessionVM(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }),
              session.mode == .linuxVM else { return }

        // Tear down all current panes + old VM
        session.destroyAllPanes()
        MicroVMManager.shared.destroyVM(for: id)
        session.vmState = .booting
        session.bootTimeMs = nil

        // Boot brand-new APFS-cloned Private VM for this session
        let vm: SandboxVM
        let attachBinary: URL
        let fromWarmPool: Bool
        do {
            let started = try MicroVMManager.shared.startVM(for: id, overrides: session.overrides)
            vm = started.vm
            attachBinary = started.attachBinary
            fromWarmPool = started.fromWarmPool
        } catch {
            session.vmState = .failed(error.localizedDescription)
            presentVMError(error)
            return
        }

        let opts = SurfaceLaunchOptions(
            workingDirectory: NSHomeDirectory(),
            command: Self.buildAttachCommand(attachBinary: attachBinary.path, socketPath: vm.socketPath, guestCwd: "/root"),
            environmentVariables: ["BOOBOX_MODE": "linux_vm"],
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        let freshPane = TerminalPane(launchOptions: opts)
        attachPaneHandlers(freshPane, in: session)
        session.observePane(freshPane)
        session.vmSocketPath = vm.socketPath
        session.attachBinaryPath = attachBinary.path
        session.wasWarmPooled = fromWarmPool && vm.isReady
        session.vmState = vm.isReady ? .running : vm.currentState
        if session.wasWarmPooled {
            session.bootTimeMs = 1
        }
        session.rootNode = .leaf(freshPane)
        session.focusedPaneID = freshPane.id
        session.refreshMirroredState()

        vm.onStateChange = { [weak session] state in
            session?.vmState = state
        }
        vm.onBootReady = { [weak session] ms in
            session?.bootTimeMs = ms
        }

        stageView.rebuildSession(session)
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
    }

    private static func buildAttachCommand(attachBinary: String, socketPath: String, guestCwd: String) -> String {
        func quote(_ s: String) -> String {
            if s.contains(" ") || s.contains("'") {
                return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return s
        }
        return "\(quote(attachBinary)) \(quote(socketPath)) \(quote(guestCwd))"
    }

    private func presentVMError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Failed to start Linux microVM"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    func selectSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if selectedSessionID != id && isTerminalSearchOpen {
            closeTerminalSearch(refocusTerminal: false)
        }
        selectedSessionID = id
        session.hasUnreadBell = false
        updateDockBadge()
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
        saveOpenSessionsState()
    }

    func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectSession(sessions[index].id)
    }

    func selectAdjacentSession(delta: Int) {
        guard sessions.count > 1,
              let currentID = selectedSessionID,
              let idx = sessions.firstIndex(where: { $0.id == currentID }) else { return }
        let nextIndex = (idx + delta + sessions.count) % sessions.count
        selectSession(sessions[nextIndex].id)
    }

    func closeSession(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removed = sessions.remove(at: idx)
        removed.destroyAllPanes(killDaemonPanes: true)

        if removed.mode == .linuxVM {
            MicroVMManager.shared.destroyVM(for: id)
        }
        if let sb = removed.macSandbox {
            DaemonClient.shared.killSession(sb.shortID)
            SecretsVaultManager.shared.unregisterSession(sb.shortID)
            // Keep persisted session directory if files were saved in workspace/; auto-delete if empty.
            if MacOSSandboxManager.shared.workspaceFileCount(for: sb) == 0 {
                MacOSSandboxManager.shared.deleteSessionDir(sb)
            } else if sb.isOverlay {
                // Unmount CoW overlay cleanly while preserving .overlay/upper + whiteouts for instant PAST resume
                DispatchQueue.global(qos: .utility).async {
                    OverlayClient.shared.unmount(sessionID: sb.shortID, mountPoint: sb.workspaceDir.path)
                }
            }
        }
        stageView.removeSession(id)

        if selectedSessionID == id {
            if sessions.isEmpty {
                selectedSessionID = nil
            } else {
                let nextIdx = min(idx, sessions.count - 1)
                selectedSessionID = sessions[nextIdx].id
            }
        }
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: !sessions.isEmpty)
        updateDockBadge()
        saveOpenSessionsState()
        if removed.macSandbox != nil {
            refreshSavedMacSessions()
        }
    }

    private func nextAvailableSequenceNumber(for mode: SessionMode) -> Int {
        let used = Set(sessions.filter { $0.mode == mode }.map(\.sequenceNumber))
        var n = 1
        while used.contains(n) { n += 1 }
        return n
    }

    func duplicateSession(_ id: UUID) {
        guard let source = sessions.first(where: { $0.id == id }) else { return }
        if source.mode == .sandbox,
           let srcPath = source.macSandbox?.sourceProjectPath,
           FileManager.default.fileExists(atPath: srcPath) {
            openProjectFolder(
                URL(fileURLWithPath: srcPath, isDirectory: true),
                excludeEnvOverride: source.macSandbox?.excludeEnvFiles,
                forceOverlay: source.macSandbox?.isOverlay == true
            )
            return
        }
        newSession(mode: source.mode, workingDirectory: source.focusedPane?.pwd)
    }

    func renameSession(_ id: UUID, to newName: String?) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCustom = (trimmed?.isEmpty == false)
        session.customTitle = hasCustom ? trimmed : nil
        if var sb = session.macSandbox, let finalName = session.customTitle {
            sb.name = finalName
            sb.hasUserCustomName = true
            session.macSandbox = sb
            MacOSSandboxManager.shared.updateSessionName(sb, to: finalName, isUserCustom: true)
        }
        if renamingSessionID == id {
            renamingSessionID = nil
        }
        refocusActiveTerminal()
    }

    func updateAutoNameIfNeeded(for session: TerminalSession) {
        guard BooBoxConfigManager.shared.config.general.autoNameSessions,
              session.mode == .sandbox,
              session.customTitle == nil,
              var sb = session.macSandbox,
              !sb.hasUserCustomName else { return }
        let existingNames = Set(sessions.map(\.displayTitle) + savedMacSessions.map { $0.sandbox.name })
        if let inferred = MacOSSandboxManager.shared.inferSemanticSessionName(
            for: sb,
            currentPwd: session.focusedPwd,
            oscTitle: session.focusedTitle,
            avoiding: existingNames
        ), inferred != sb.name {
            sb.name = inferred
            session.macSandbox = sb
            MacOSSandboxManager.shared.updateSessionName(sb, to: inferred, isUserCustom: false)
        }
    }
    func moveSession(from sourceIndex: Int, to destinationIndex: Int) {
        guard sessions.indices.contains(sourceIndex),
              destinationIndex >= 0,
              destinationIndex <= sessions.count else { return }
        let item = sessions.remove(at: sourceIndex)
        let adjusted = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        sessions.insert(item, at: min(max(adjusted, 0), sessions.count))
    }

    // MARK: - Split Management

    func splitFocusedPane(direction: SplitDirection) {
        guard let session = selectedSession,
              let currentPane = session.focusedPane else { return }

        let axis: SplitAxis = (direction == .left || direction == .right) ? .horizontal : .vertical
        let insertBefore = (direction == .left || direction == .up)

        let opts: SurfaceLaunchOptions
        switch session.mode {
        case .sandbox:
            if let sb = session.macSandbox {
                let candidate = currentPane.pwd ?? sb.workspaceDir.path
                let splitCwd = candidate.hasPrefix(sb.sessionDir.path) ? candidate : sb.workspaceDir.path
                let newPane = makeSandboxPane(for: sb, cwd: splitCwd, context: GHOSTTY_SURFACE_CONTEXT_SPLIT)
                attachPaneHandlers(newPane, in: session)
                session.observePane(newPane)
                session.rootNode = session.rootNode.splitting(
                    paneID: currentPane.id,
                    axis: axis,
                    newPane: newPane,
                    insertBefore: insertBefore
                )
                session.focusedPaneID = newPane.id
                session.refreshMirroredState()
                stageView.rebuildSession(session)
                stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
                return
            } else {
                return
            }

        case .linuxVM:
            if let sockPath = session.vmSocketPath,
               let attachPath = session.attachBinaryPath {
                let guestCwd = currentPane.pwd ?? "/root"
                opts = SurfaceLaunchOptions(
                    workingDirectory: NSHomeDirectory(),
                    command: Self.buildAttachCommand(attachBinary: attachPath, socketPath: sockPath, guestCwd: guestCwd),
                    environmentVariables: ["BOOBOX_MODE": "linux_vm"],
                    context: GHOSTTY_SURFACE_CONTEXT_SPLIT
                )
            } else {
                return
            }

        case .rawHost:
            opts = SurfaceLaunchOptions(
                workingDirectory: currentPane.pwd ?? NSHomeDirectory(),
                command: nil,
                environmentVariables: ["BOOBOX_MODE": "raw_host"],
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
        }
        let newPane = TerminalPane(launchOptions: opts)
        attachPaneHandlers(newPane, in: session)
        session.observePane(newPane)
        session.rootNode = session.rootNode.splitting(
            paneID: currentPane.id,
            axis: axis,
            newPane: newPane,
            insertBefore: insertBefore
        )
        session.focusedPaneID = newPane.id
        session.refreshMirroredState()

        stageView.rebuildSession(session)
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
    }

    func closeFocusedPane() {
        guard let session = selectedSession,
              let pane = session.focusedPane else { return }
        closePane(paneID: pane.id, in: session)
    }

    func closePane(surfaceView: TerminalSurfaceView) {
        for session in sessions {
            if session.rootNode.contains(paneID: surfaceView.paneID) {
                closePane(paneID: surfaceView.paneID, in: session)
                return
            }
        }
    }

    private func closePane(paneID: UUID, in session: TerminalSession) {
        guard let targetPane = session.rootNode.allPanes.first(where: { $0.id == paneID }) else { return }

        guard let remaining = session.rootNode.removing(paneID: paneID) else {
            closeSession(session.id)
            return
        }

        session.stopObservingPane(paneID)
        targetPane.killDaemonPane()
        targetPane.destroy()
        session.rootNode = remaining
        if session.focusedPaneID == paneID, let fallback = remaining.allPanes.first {
            session.focusedPaneID = fallback.id
        }
        session.refreshMirroredState()

        stageView.rebuildSession(session)
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
    }

    func focusAdjacentSplit(direction: SplitFocusDirection) {
        guard let session = selectedSession else { return }
        let panes = session.rootNode.allPanes
        guard panes.count > 1,
              let idx = panes.firstIndex(where: { $0.id == session.focusedPaneID }) else { return }

        let delta: Int = switch direction {
        case .previous, .left, .up: -1
        case .next, .right, .down: 1
        }

        let target = panes[(idx + delta + panes.count) % panes.count]
        session.focusedPaneID = target.id
        session.refreshMirroredState()
        stageView.updateFocusVisuals(for: session)
        stageView.focusSurface(target.surfaceView)
    }

    // MARK: - Sidebar Configuration

    func toggleSidebarPosition() {
        sidebarPosition = sidebarPosition.toggled
        refocusActiveTerminal()
    }

    func setSidebarPosition(_ position: SidebarPosition) {
        guard sidebarPosition != position else { return }
        sidebarPosition = position
        refocusActiveTerminal()
    }

    func toggleSidebarVisibility() {
        sidebarVisible.toggle()
        refocusActiveTerminal()
    }

    func refocusActiveTerminal() {
        guard let surface = selectedSession?.focusedPane?.surfaceView else { return }
        DispatchQueue.main.async {
            self.stageView.focusSurface(surface)
        }
    }

    func reloadGhosttyConfig() {
        GhosttyRuntime.shared.reloadConfig()
        if let cfg = GhosttyRuntime.shared.config {
            for session in sessions {
                for pane in session.rootNode.allPanes {
                    pane.surfaceView.updateConfig(cfg)
                }
            }
        }
        themeBackground = GhosttyRuntime.shared.themeColors.background
        stageView.backgroundColor = themeBackground
        onThemeBackgroundChanged?(themeBackground)
    }

    /// Immediately refreshes `.boobox-env.sh` and `boobox-git-cred` across every open macOS sandbox
    /// so newly connected/disconnected Keychain tokens take effect on the very next command (`preexec`).
    func syncLiveSandboxEnvironments() {
        let activeSandboxes = sessions.compactMap { $0.mode == .sandbox ? $0.macSandbox : nil }
        guard !activeSandboxes.isEmpty else { return }
        let cfg = BooBoxConfigManager.shared.config
        DispatchQueue.global(qos: .userInitiated).async {
            MacOSSandboxManager.shared.syncLiveEnvFiles(for: activeSandboxes, config: cfg)
        }
    }

    // MARK: - Command Palette (`⌘P`)

    func toggleCommandPalette() {
        isCommandPaletteOpen.toggle()
        if !isCommandPaletteOpen {
            refocusActiveTerminal()
        }
    }

    func closeCommandPalette() {
        guard isCommandPaletteOpen else { return }
        isCommandPaletteOpen = false
        refocusActiveTerminal()
    }

    // MARK: - In-Terminal Find (`⌘F` / `⌘G` / `⇧⌘G`) Powered by libghostty

    func openTerminalSearch(initialNeedle: String? = nil, fromGhosttyAction: Bool = false) {
        guard let surfaceView = selectedSession?.focusedPane?.surfaceView else { return }
        isCommandPaletteOpen = false
        if !isTerminalSearchOpen {
            isTerminalSearchOpen = true
            if !fromGhosttyAction {
                _ = surfaceView.performBindingAction("start_search")
            }
        }
        if let needle = initialNeedle, !needle.isEmpty {
            terminalSearchQuery = needle
            if !fromGhosttyAction {
                _ = surfaceView.performBindingAction("search:\(needle)")
            }
        } else if !terminalSearchQuery.isEmpty && !fromGhosttyAction {
            _ = surfaceView.performBindingAction("search:\(terminalSearchQuery)")
        }
        terminalSearchFocusToken += 1
    }

    func updateTerminalSearchQuery(_ query: String) {
        terminalSearchQuery = query
        guard let surfaceView = selectedSession?.focusedPane?.surfaceView else { return }
        if query.isEmpty {
            terminalSearchTotal = nil
            terminalSearchSelected = nil
            _ = surfaceView.performBindingAction("search:")
        } else {
            _ = surfaceView.performBindingAction("search:\(query)")
        }
    }

    func navigateTerminalSearch(next: Bool) {
        guard let surfaceView = selectedSession?.focusedPane?.surfaceView else { return }
        if !isTerminalSearchOpen {
            openTerminalSearch()
            return
        }
        _ = surfaceView.performBindingAction(next ? "navigate_search:next" : "navigate_search:previous")
    }

    func closeTerminalSearch(refocusTerminal: Bool = true) {
        if let surfaceView = selectedSession?.focusedPane?.surfaceView {
            _ = surfaceView.performBindingAction("end_search")
        }
        isTerminalSearchOpen = false
        terminalSearchTotal = nil
        terminalSearchSelected = nil
        if refocusTerminal {
            refocusActiveTerminal()
        }
    }

    // MARK: - 1-Click Proxy Blocked-Domain / Leak Toast Actions

    func allowBlockedDomainForSession(_ domain: String, sessionID: UUID) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty,
              let session = sessions.first(where: { $0.id == sessionID }) else { return }
        var next = session.overrides
        if !next.extraAllowedDomains.contains(where: { $0.lowercased() == clean }) {
            next.extraAllowedDomains.append(clean)
        }
        session.pendingProxyAlert = nil
        applySandboxOverrides(next, to: sessionID, restart: false)
    }

    func allowBlockedDomainGlobally(_ domain: String, sessionID: UUID) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }
        var domains = BooBoxConfigManager.shared.config.secretsNetwork.customAllowedDomains
        if !domains.contains(where: { $0.lowercased() == clean }) {
            domains.append(clean)
            BooBoxConfigManager.shared.config.secretsNetwork.customAllowedDomains = domains
        }
        for s in sessions where s.pendingProxyAlert?.host.lowercased() == clean {
            s.pendingProxyAlert = nil
        }
    }

    func dismissProxyAlert(for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if let ev = session.pendingProxyAlert {
            dismissedProxyAlertKeys.insert("\(ev.sessionId)|\(ev.host)|\(ev.decision)")
        }
        session.pendingProxyAlert = nil
    }

    // MARK: - Open Session Persistence & Detached Reattach (`booboxd`)

    var hasLiveDaemonPanes: Bool {
        sessions.contains { s in
            s.rootNode.allPanes.contains { $0.daemonPaneID != nil }
        }
    }

    func saveOpenSessionsState() {
        let entries: [PersistedOpenSession] = sessions.compactMap { s in
            switch s.mode {
            case .sandbox:
                guard let sb = s.macSandbox else { return nil }
                return PersistedOpenSession(
                    id: s.id,
                    mode: .sandbox,
                    sandboxShortID: sb.shortID,
                    daemonPaneID: s.focusedPane?.daemonPaneID,
                    rawWorkingDirectory: nil
                )
            case .rawHost:
                return PersistedOpenSession(
                    id: s.id,
                    mode: .rawHost,
                    sandboxShortID: nil,
                    daemonPaneID: nil,
                    rawWorkingDirectory: s.focusedPane?.pwd ?? NSHomeDirectory()
                )
            case .linuxVM:
                return nil // Ephemeral Linux VMs always boot clean
            }
        }
        let state = PersistedWorkspaceState(sessions: entries, selectedSessionID: selectedSessionID)
        let url = persistedStateURL
        if let data = try? JSONEncoder().encode(state) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    @discardableResult
    func restoreLastOpenSessionsIfEnabled() -> Bool {
        guard BooBoxConfigManager.shared.config.general.restoreSessionsOnLaunch,
              let data = try? Data(contentsOf: persistedStateURL),
              let saved = try? JSONDecoder().decode(PersistedWorkspaceState.self, from: data),
              !saved.sessions.isEmpty else {
            return false
        }

        let liveDaemonPanes = Dictionary(
            uniqueKeysWithValues: DaemonClient.shared.listPanes().filter(\.alive).map { ($0.paneId, $0) }
        )
        var restoredAny = false

        for entry in saved.sessions {
            switch entry.mode {
            case .sandbox:
                guard let shortID = entry.sandboxShortID,
                      let sb = MacOSSandboxManager.shared.loadSession(shortID: shortID) else { continue }
                let livePane = entry.daemonPaneID.flatMap { liveDaemonPanes[$0] }
                let readySandbox: MacSandboxSession
                if livePane != nil {
                    if sb.isOverlay {
                        try? MacOSSandboxManager.shared.ensureOverlayMountedIfNeeded(sb)
                    }
                    readySandbox = sb
                } else if let refreshed = try? MacOSSandboxManager.shared.prepareForResume(sb) {
                    readySandbox = refreshed
                } else {
                    continue
                }
                let seq = nextAvailableSequenceNumber(for: .sandbox)
                _ = startSessionWithMacSandbox(
                    readySandbox,
                    sequenceNumber: seq,
                    reattachPane: livePane,
                    focusImmediately: false
                )
                restoredAny = true

            case .rawHost:
                let dir = entry.rawWorkingDirectory ?? NSHomeDirectory()
                let validDir = FileManager.default.fileExists(atPath: dir) ? dir : NSHomeDirectory()
                _ = newSession(mode: .rawHost, workingDirectory: validDir)
                restoredAny = true

            case .linuxVM:
                break
            }
        }

        if restoredAny {
            if let wanted = saved.selectedSessionID, sessions.contains(where: { $0.id == wanted }) {
                selectedSessionID = wanted
            } else {
                selectedSessionID = sessions.first?.id
            }
            stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
            saveOpenSessionsState()
        }
        return restoredAny
    }

    func shutdownAll(preserveDaemonPanes: Bool = true) {
        monitorTimer?.invalidate()
        monitorTimer = nil
        saveOpenSessionsState()
        let killDaemons = !preserveDaemonPanes || !BooBoxConfigManager.shared.config.general.persistentSessionsEnabled
        for session in sessions {
            session.destroyAllPanes(killDaemonPanes: killDaemons)
        }
        sessions.removeAll()
        selectedSessionID = nil
        NotificationManager.shared.updateDockBadge(unreadCount: 0)
        MicroVMManager.shared.shutdownAll()
    }

    // MARK: - Live Daemon Busy-Status & Proxy Alert Monitors

    private func startLiveMonitors() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollLiveStatusOnce()
            }
        }
    }

    private func pollLiveStatusOnce() {
        guard !sessions.isEmpty else { return }

        // 1. Poll `booboxd` for live foreground running command status per detached sandbox tab
        if hasLiveDaemonPanes {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let panes = DaemonClient.shared.listPanes()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let byID = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0) })
                    for session in self.sessions {
                        var anyBusy = false
                        var procName: String? = nil
                        for pane in session.rootNode.allPanes {
                            if let dp = pane.daemonPaneID, let st = byID[dp], st.alive, st.fgBusy {
                                anyBusy = true
                                if procName == nil { procName = st.fgName }
                            }
                        }
                        if session.isRunningCommand != anyBusy {
                            session.isRunningCommand = anyBusy
                        }
                        if session.runningProcessName != procName {
                            session.runningProcessName = procName
                        }
                    }
                }
            }
        }

        // 2. Poll `boobox-proxy` incrementally for blocked-domain and secret-leak events
        if SecretsVaultManager.shared.currentProxyPort != nil {
            let since = lastProxyEventSeq
            SecretsVaultManager.shared.fetchAuditEventsSince(since) { [weak self] events in
                guard let self, !events.isEmpty else { return }
                for ev in events {
                    if let s = ev.seq, s > self.lastProxyEventSeq {
                        self.lastProxyEventSeq = s
                    }
                    guard ev.decision == "blocked" || ev.decision == "leak_blocked" else { continue }
                    let dismissKey = "\(ev.sessionId)|\(ev.host)|\(ev.decision)"
                    if ev.decision != "leak_blocked" && self.dismissedProxyAlertKeys.contains(dismissKey) {
                        continue
                    }
                    guard let target = self.sessions.first(where: { $0.macSandbox?.shortID == ev.sessionId }) else {
                        continue
                    }
                    target.pendingProxyAlert = ev
                    if ev.decision == "leak_blocked" {
                        target.hasUnreadBell = true
                        self.updateDockBadge()
                        NotificationManager.shared.postSessionNotification(
                            sessionID: target.id,
                            title: "Blocked secret exfiltration",
                            body: "\(ev.host) — \(ev.reason)",
                            subtitle: target.displayTitle,
                            isUrgent: true
                        )
                    }
                }
            }
        }
    }

    private func updateDockBadge() {
        let unread = sessions.filter { $0.hasUnreadBell && $0.id != selectedSessionID }.count
        NotificationManager.shared.updateDockBadge(unreadCount: unread)
    }

    // MARK: - Internal Helpers

    private func attachPaneHandlers(_ pane: TerminalPane, in session: TerminalSession) {
        pane.onBell = { [weak self, weak session] in
            guard let self, let session else { return }
            let isBackground = (self.selectedSessionID != session.id) || !NSApp.isActive
            if isBackground {
                if self.selectedSessionID != session.id {
                    session.hasUnreadBell = true
                }
                self.updateDockBadge()
                NotificationManager.shared.postSessionNotification(
                    sessionID: session.id,
                    title: session.displayTitle,
                    body: "Session needs attention"
                )
            }
        }

        pane.onDesktopNotification = { [weak self, weak session] title, body in
            guard let self, let session else { return }
            let isBackground = (self.selectedSessionID != session.id) || !NSApp.isActive
            if isBackground {
                if self.selectedSessionID != session.id {
                    session.hasUnreadBell = true
                }
                self.updateDockBadge()
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                NotificationManager.shared.postSessionNotification(
                    sessionID: session.id,
                    title: cleanTitle.isEmpty ? session.displayTitle : cleanTitle,
                    body: cleanBody.isEmpty ? "Agent notification" : cleanBody,
                    subtitle: cleanTitle.isEmpty ? nil : session.displayTitle
                )
            }
        }

        pane.onCommandFinished = { [weak self, weak session] exitCode, durationNs in
            guard let self, let session else { return }
            session.isRunningCommand = false
            session.runningProcessName = nil
            // Notify on unfocused/background commands that ran at least 5 seconds
            let secs = Double(durationNs) / 1_000_000_000.0
            let isBackground = (self.selectedSessionID != session.id) || !NSApp.isActive
            if secs >= 5.0 && isBackground {
                if self.selectedSessionID != session.id {
                    session.hasUnreadBell = true
                }
                self.updateDockBadge()
                let durStr = secs >= 60 ? String(format: "%.0fm %.0fs", floor(secs / 60), secs.truncatingRemainder(dividingBy: 60)) : String(format: "%.1fs", secs)
                let msg = exitCode == 0 ? "Command finished in \(durStr)" : "Command exited (\(exitCode)) after \(durStr)"
                NotificationManager.shared.postSessionNotification(
                    sessionID: session.id,
                    title: session.displayTitle,
                    body: msg
                )
            }
        }

        pane.onStartSearch = { [weak self, weak session] needle in
            guard let self, let session, self.selectedSessionID == session.id else { return }
            self.openTerminalSearch(initialNeedle: needle, fromGhosttyAction: true)
        }
        pane.onEndSearch = { [weak self, weak session] in
            guard let self, let session, self.selectedSessionID == session.id else { return }
            self.isTerminalSearchOpen = false
            self.terminalSearchTotal = nil
            self.terminalSearchSelected = nil
            self.refocusActiveTerminal()
        }
        pane.onSearchTotal = { [weak self, weak session] total in
            guard let self, let session, self.selectedSessionID == session.id else { return }
            self.terminalSearchTotal = total
        }
        pane.onSearchSelected = { [weak self, weak session] selected in
            guard let self, let session, self.selectedSessionID == session.id else { return }
            self.terminalSearchSelected = selected
        }

        pane.onBecameFocused = { [weak self, weak session, weak pane] in
            guard let self, let session, let pane else { return }
            if session.focusedPaneID != pane.id {
                session.focusedPaneID = pane.id
                session.refreshMirroredState()
                self.stageView.updateFocusVisuals(for: session)
            }
            self.updateAutoNameIfNeeded(for: session)
        }
        pane.onTitleChange = { [weak self, weak session] _ in
            guard let self, let session else { return }
            session.refreshMirroredState()
            self.updateAutoNameIfNeeded(for: session)
        }
        pane.onPwdChange = { [weak self, weak session] _ in
            guard let self, let session else { return }
            session.refreshMirroredState()
            self.updateAutoNameIfNeeded(for: session)
        }
    }

    private func handleGhosttyAction(_ action: GhosttyHostAction, from surfaceView: TerminalSurfaceView?) -> Bool {
        switch action {
        case .newTab:
            newSession(mode: selectedSession?.mode ?? .sandbox)
            return true
        case .closeTab:
            if let id = selectedSessionID {
                closeSession(id)
            }
            return true
        case .newSplit(let direction):
            splitFocusedPane(direction: direction)
            return true
        case .gotoSplit(let direction):
            focusAdjacentSplit(direction: direction)
            return true
        case .gotoTab(let target):
            switch target {
            case -1: selectAdjacentSession(delta: -1)
            case -2: selectAdjacentSession(delta: 1)
            case -3:
                if let last = sessions.last { selectSession(last.id) }
            default:
                if target >= 1 { selectSession(at: target - 1) }
            }
            return true
        case .toggleCommandPalette:
            toggleCommandPalette()
            return true
        case .reloadConfig:
            reloadGhosttyConfig()
            return true
        case .quit:
            NSApp.terminate(nil)
            return true
        }
    }
}
