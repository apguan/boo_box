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

enum SessionMode: Equatable, Sendable {
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

    var onBell: (() -> Void)?
    var onBecameFocused: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onPwdChange: ((String) -> Void)?

    init(launchOptions: SurfaceLaunchOptions = SurfaceLaunchOptions()) {
        let paneID = UUID()
        self.id = paneID
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

    func destroyAllPanes() {
        paneCancellables.removeAll()
        for pane in rootNode.allPanes {
            pane.destroy()
        }
    }
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
    @Published var activeProjectTemplateURL: URL?
    @Published var activeProjectDisplayName: String?
    @Published var activeProjectExcludeEnvOverride: Bool?
    @Published var cloningProjectName: String?
    @Published var configuringTarget: SandboxConfigTarget?
    let stageView = TerminalStageView()
    var onOpenSettings: (() -> Void)?
    var onThemeBackgroundChanged: ((NSColor) -> Void)?
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
        refreshSavedMacSessions()
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
            if let templateURL = activeProjectTemplateURL {
                let projectName = activeProjectDisplayName ?? templateURL.lastPathComponent
                let cfg = BooBoxConfigManager.shared.config.general
                let excludeEnv = activeProjectExcludeEnvOverride ?? cfg.excludeEnvFilesWhenCloning
                let existingNames = Set(sessions.map(\.displayTitle) + savedMacSessions.map { $0.sandbox.name })
                let initialName: String = cfg.autoNameSessions
                    ? MacOSSandboxManager.shared.semanticProjectName(projectName: projectName, sourceDir: templateURL, avoiding: existingNames)
                    : MacOSSandboxManager.shared.disambiguatedName(base: projectName, avoiding: existingNames)
                // Fast path (<5ms): pop pre-warmed APFS clone via atomic rename!
                if let warmSandbox = MacOSSandboxManager.shared.popWarmProjectSession(
                    for: templateURL,
                    id: sessionID,
                    name: initialName,
                    excludeEnvFiles: excludeEnv,
                    skipHeavyDirs: cfg.skipHeavyDirsWhenCloning
                ) {
                    return startSessionWithMacSandbox(warmSandbox, sequenceNumber: seq)
                }

                // Fallback if warm spare is still building in background
                let sourceURL: URL
                if FileManager.default.fileExists(atPath: templateURL.path) {
                    sourceURL = templateURL
                } else if let fallback = sessions.last(where: { $0.macSandbox?.sourceProjectPath != nil })?.macSandbox?.workspaceDir {
                    sourceURL = fallback
                } else {
                    return createScratchMacSandboxSession(sequenceNumber: seq)
                }
                spawnClonedProjectSession(
                    from: sourceURL,
                    displayName: projectName,
                    excludeEnvOverride: activeProjectExcludeEnvOverride
                )
                return nil
            }
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
        panel.message = "Creates a zero-copy APFS clone of this folder inside ~/boo_box/sessions/. New sessions (⌘T) will spawn fresh isolated copies of this folder."
        panel.prompt = "Open in Sandbox"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProjectFolder(url)
    }

    func openProjectFolder(_ url: URL, displayName: String? = nil, excludeEnvOverride: Bool? = nil) {
        do {
            let validated = try MacOSSandboxManager.shared.validateProjectDirectory(url)
            let cleanName = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? displayName!.trimmingCharacters(in: .whitespacesAndNewlines)
                : validated.lastPathComponent
            activeProjectTemplateURL = validated
            activeProjectDisplayName = cleanName
            activeProjectExcludeEnvOverride = excludeEnvOverride
            spawnClonedProjectSession(from: validated, displayName: cleanName, excludeEnvOverride: excludeEnvOverride)
        } catch {
            presentProjectError(error)
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
        activeProjectTemplateURL = templateDirURL
        activeProjectDisplayName = projectName
        activeProjectExcludeEnvOverride = excludeEnvOverride

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
    func clearProjectTemplate() {
        activeProjectTemplateURL = nil
        activeProjectDisplayName = nil
        activeProjectExcludeEnvOverride = nil
        MacOSSandboxManager.shared.cleanupWarmClones()
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

    private func spawnClonedProjectSession(from projectURL: URL, displayName: String, excludeEnvOverride: Bool?) {
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
                    excludeEnvFilesOverride: excludeEnvOverride
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cloningProjectName = nil
                switch result {
                case .success(let sandbox):
                    _ = self.startSessionWithMacSandbox(sandbox, sequenceNumber: seq)
                    if let templateURL = self.activeProjectTemplateURL {
                        let cfg = BooBoxConfigManager.shared.config.general
                        MacOSSandboxManager.shared.replenishWarmCloneInBackground(
                            for: templateURL,
                            excludeEnvFiles: excludeEnvOverride ?? cfg.excludeEnvFilesWhenCloning,
                            skipHeavyDirs: cfg.skipHeavyDirsWhenCloning
                        )
                    }
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

    private func startSessionWithMacSandbox(_ sandbox: MacSandboxSession, sequenceNumber: Int) -> TerminalSession {
        let opts = SurfaceLaunchOptions(
            workingDirectory: sandbox.workspaceDir.path,
            command: MacOSSandboxManager.shared.launchCommand(for: sandbox),
            environmentVariables: MacOSSandboxManager.shared.launchEnvironment(for: sandbox),
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        let pane = TerminalPane(launchOptions: opts)
        let session = TerminalSession(id: sandbox.id, mode: .sandbox, sequenceNumber: sequenceNumber, initialPane: pane)
        session.macSandbox = sandbox
        session.overrides = sandbox.overrides
        attachPaneHandlers(pane, in: session)
        sessions.append(session)
        selectedSessionID = session.id
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
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

    private func confirmPermanentSessionDeletion(name: String, shortID: String) -> Bool {
        guard BooBoxConfigManager.shared.config.general.confirmBeforeDeletingSession else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete entire session \"\(name)\"?"
        alert.informativeText = "This permanently deletes the entire session directory (~/boo_box/sessions/\(shortID)/), including all files in workspace/ and its isolated home config. This cannot be undone."
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
        guard confirmPermanentSessionDeletion(name: sandbox.name, shortID: sandbox.shortID) else { return }
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

        session.destroyAllPanes()
        let opts = SurfaceLaunchOptions(
            workingDirectory: launchDir,
            command: MacOSSandboxManager.shared.launchCommand(for: sandbox),
            environmentVariables: MacOSSandboxManager.shared.launchEnvironment(for: sandbox),
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        let freshPane = TerminalPane(launchOptions: opts)
        attachPaneHandlers(freshPane, in: session)
        session.observePane(freshPane)
        session.rootNode = .leaf(freshPane)
        session.focusedPaneID = freshPane.id
        session.refreshMirroredState()

        stageView.rebuildSession(session)
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
    }
    func deleteActiveSessionPermanently(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }),
              let sb = session.macSandbox else {
            closeSession(id)
            return
        }
        guard confirmPermanentSessionDeletion(name: session.displayTitle, shortID: sb.shortID) else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removed = sessions.remove(at: idx)
        removed.destroyAllPanes()
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
        selectedSessionID = id
        session.hasUnreadBell = false
        stageView.sync(sessions: sessions, selectedSessionID: selectedSessionID, focusActive: true)
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
        removed.destroyAllPanes()

        if removed.mode == .linuxVM {
            MicroVMManager.shared.destroyVM(for: id)
        }
        if let sb = removed.macSandbox {
            SecretsVaultManager.shared.unregisterSession(sb.shortID)
            // Keep persisted session directory if files were saved in workspace/; auto-delete if empty.
            if MacOSSandboxManager.shared.workspaceFileCount(for: sb) == 0 {
                MacOSSandboxManager.shared.deleteSessionDir(sb)
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
                opts = SurfaceLaunchOptions(
                    workingDirectory: splitCwd,
                    command: MacOSSandboxManager.shared.launchCommand(for: sb),
                    environmentVariables: MacOSSandboxManager.shared.launchEnvironment(for: sb),
                    context: GHOSTTY_SURFACE_CONTEXT_SPLIT
                )
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

    func shutdownAll() {
        for session in sessions {
            session.destroyAllPanes()
        }
        sessions.removeAll()
        selectedSessionID = nil
        MicroVMManager.shared.shutdownAll()
    }

    // MARK: - Internal Helpers

    private func attachPaneHandlers(_ pane: TerminalPane, in session: TerminalSession) {
        pane.onBell = { [weak self, weak session] in
            guard let self, let session else { return }
            if self.selectedSessionID != session.id {
                session.hasUnreadBell = true
            }
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
        case .reloadConfig:
            reloadGhosttyConfig()
            return true
        case .quit:
            NSApp.terminate(nil)
            return true
        }
    }
}
