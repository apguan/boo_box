import AppKit
import Darwin
import Foundation

enum MacSandboxError: LocalizedError {
    case invalidProjectDirectory(String)
    case cloneFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidProjectDirectory(let reason): reason
        case .cloneFailed(let reason): "Failed to clone project into sandbox: \(reason)"
        case .cancelled: "Cloning cancelled."
        }
    }
}

struct MacSandboxMetadata: Codable, Sendable {
    let id: UUID
    let shortID: String
    var name: String
    let createdAt: Date
    var hasUserCustomName: Bool
    var sourceProjectPath: String?
    var overrides: SandboxOverrideConfig
    var isOverlay: Bool

    init(
        id: UUID,
        shortID: String,
        name: String,
        createdAt: Date,
        hasUserCustomName: Bool = false,
        sourceProjectPath: String? = nil,
        overrides: SandboxOverrideConfig = .default,
        isOverlay: Bool = false
    ) {
        self.id = id
        self.shortID = shortID
        self.name = name
        self.createdAt = createdAt
        self.hasUserCustomName = hasUserCustomName
        self.sourceProjectPath = sourceProjectPath
        self.overrides = overrides
        self.isOverlay = isOverlay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.shortID = try c.decode(String.self, forKey: .shortID)
        self.name = try c.decode(String.self, forKey: .name)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.hasUserCustomName = try c.decodeIfPresent(Bool.self, forKey: .hasUserCustomName) ?? false
        self.sourceProjectPath = try c.decodeIfPresent(String.self, forKey: .sourceProjectPath)
        self.overrides = try c.decodeIfPresent(SandboxOverrideConfig.self, forKey: .overrides) ?? .default
        self.isOverlay = try c.decodeIfPresent(Bool.self, forKey: .isOverlay) ?? false
    }
}

struct MacSandboxSession: Identifiable, Sendable {
    let id: UUID
    let shortID: String
    var name: String
    let createdAt: Date
    var hasUserCustomName: Bool
    let sourceProjectPath: String?
    var overrides: SandboxOverrideConfig
    let isOverlay: Bool
    let sessionDir: URL
    let workspaceDir: URL
    let homeDir: URL
    let tmpDir: URL
    let profileURL: URL
    let metadataURL: URL

    var overlayDir: URL {
        sessionDir.appendingPathComponent(".overlay", isDirectory: true)
    }

    var overlayUpperDir: URL {
        overlayDir.appendingPathComponent("upper", isDirectory: true)
    }

    var overlayWhiteoutURL: URL {
        overlayDir.appendingPathComponent("whiteouts.json")
    }

    var shortDisplayPath: String {
        "~/boo_box/sessions/\(shortID)/workspace"
    }
}

struct SavedMacSandboxItem: Identifiable, Sendable {
    var id: UUID { sandbox.id }
    let sandbox: MacSandboxSession
    let fileCount: Int
}

/// Manages macOS kernel-level Seatbelt (`sandbox-exec`) sessions persisted under
/// `~/boo_box/sessions/<session-id>/`.
///
/// Security model:
/// - Default-denies ALL reads under the user's real `$HOME` (blocking Desktop, Documents,
///   Downloads, `~/.ssh`, `~/.aws`, Keychain, other repos, and all sibling sessions).
/// - Allows read-only access to system/Homebrew/user CLI toolchains so existing Mac tools
///   (`omp`, `opencode`, `bun`, `node`, `pnpm`, `uv`, `git`, `cargo`) work immediately with
///   zero setup.
/// - Default-denies ALL filesystem writes everywhere except this session's own directory
///   (`~/boo_box/sessions/<id>/`) and standard POSIX TTY/null device nodes.
final class MacOSSandboxManager: @unchecked Sendable {
    static let shared = MacOSSandboxManager()

    let realHomeURL: URL
    let sessionsRootURL: URL

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        self.realHomeURL = home
        self.sessionsRootURL = home.appendingPathComponent("boo_box/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRootURL, withIntermediateDirectories: true)
        cleanupStaleTemplateArtifacts()
        cleanupStaleSessionTrash()
    }

    // MARK: - Create / Load / Cleanup

    func validateProjectDirectory(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else {
            throw MacSandboxError.invalidProjectDirectory("Not a valid directory: \(url.path)")
        }
        let path = resolved.path
        let realHome = realHomeURL.path
        let booRoot = realHomeURL.appendingPathComponent("boo_box").path
        let templatesRoot = realHomeURL.appendingPathComponent("boo_box/templates").path
        if path == "/" || path == "/Users" || path == realHome {
            throw MacSandboxError.invalidProjectDirectory("Refusing to clone \(path) into a sandbox. Open a specific project directory instead.")
        }
        let isManagedTemplate = path.hasPrefix(templatesRoot + "/")
        if !isManagedTemplate && (path == booRoot || path.hasPrefix(booRoot + "/")) {
            throw MacSandboxError.invalidProjectDirectory("Refusing to recursively clone ~/boo_box into a sandbox.")
        }
        return resolved
    }

    private let activeCloneLock = NSLock()
    private var activeCloneProcess: Process?
    private var activeCloneSessionDir: URL?
    private var activeCloneCancelled = false

    /// Immediately cancels an in-flight GUI project clone and reaps its partial session directory in the background.
    func cancelActiveClone() {
        activeCloneLock.lock()
        activeCloneCancelled = true
        let proc = activeCloneProcess
        let dir = activeCloneSessionDir
        activeCloneProcess = nil
        activeCloneSessionDir = nil
        activeCloneLock.unlock()

        if let proc, proc.isRunning {
            proc.terminate()
        }
        if let dir {
            reapDirectoryAsync(dir, afterProcess: proc)
        }
    }

    private func reapDirectoryAsync(_ dir: URL, afterProcess proc: Process? = nil) {
        let root = sessionsRootURL
        let trashName = ".trash-cancel-\(UUID().uuidString.prefix(8))"
        let trashURL = root.appendingPathComponent(trashName, isDirectory: true)
        DispatchQueue.global(qos: .background).async {
            if let proc, proc.isRunning {
                proc.waitUntilExit()
            }
            let fm = FileManager.default
            guard fm.fileExists(atPath: dir.path) else { return }
            if (try? fm.moveItem(at: dir, to: trashURL)) != nil {
                let rm = Process()
                rm.executableURL = URL(fileURLWithPath: "/bin/rm")
                rm.arguments = ["-rf", trashURL.path]
                try? rm.run()
            } else {
                try? fm.removeItem(at: dir)
            }
        }
    }

    func createSession(
        id: UUID = UUID(),
        name: String,
        hasUserCustomName: Bool = false,
        sourceProjectURL: URL? = nil,
        excludeEnvFilesOverride: Bool? = nil,
        forceAPFSClone: Bool = false
    ) throws -> MacSandboxSession {
        let shortID = "s-\(id.uuidString.prefix(8).lowercased())"
        let sessionDir = sessionsRootURL.appendingPathComponent(shortID, isDirectory: true).resolvingSymlinksInPath()
        let validatedSource = try sourceProjectURL.map { try validateProjectDirectory($0) }
        let cfg = BooBoxConfigManager.currentSnapshot().general
        let excludeEnv = excludeEnvFilesOverride ?? cfg.excludeEnvFilesWhenCloning
        let useOverlay = (validatedSource != nil) && !forceAPFSClone && (cfg.workspaceMode == .overlay)

        if let src = validatedSource, useOverlay {
            let overlayDir = sessionDir.appendingPathComponent(".overlay", isDirectory: true)
            let upperDir = overlayDir.appendingPathComponent("upper", isDirectory: true)
            let whiteoutFile = overlayDir.appendingPathComponent("whiteouts.json")
            let workspaceDir = sessionDir.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: upperDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            do {
                try OverlayClient.shared.mount(
                    sessionID: shortID,
                    lowerDir: src.path,
                    upperDir: upperDir.path,
                    whiteoutFile: whiteoutFile.path,
                    mountPoint: workspaceDir.path,
                    excludeEnv: excludeEnv
                )
            } catch {
                reapDirectoryAsync(sessionDir)
                throw error
            }
            return try materializeSession(
                id: id,
                shortID: shortID,
                name: name,
                createdAt: Date(),
                hasUserCustomName: hasUserCustomName,
                sourceProjectPath: src.path,
                sessionDir: sessionDir,
                isOverlay: true
            )
        }

        let sandbox = try materializeSession(
            id: id,
            shortID: shortID,
            name: name,
            createdAt: Date(),
            hasUserCustomName: hasUserCustomName,
            sourceProjectPath: validatedSource?.path,
            sessionDir: sessionDir,
            isOverlay: false
        )
        if let src = validatedSource {
            activeCloneLock.lock()
            activeCloneCancelled = false
            activeCloneSessionDir = sessionDir
            activeCloneLock.unlock()
            defer {
                activeCloneLock.lock()
                activeCloneProcess = nil
                activeCloneSessionDir = nil
                activeCloneLock.unlock()
            }
            do {
                try cloneProjectDirectory(
                    from: src,
                    to: sandbox.workspaceDir,
                    excludeEnvFiles: excludeEnv,
                    skipHeavyDirs: cfg.skipHeavyDirsWhenCloning,
                    trackAsActiveClone: true
                )
                activeCloneLock.lock()
                let wasCancelled = activeCloneCancelled
                activeCloneLock.unlock()
                if wasCancelled {
                    throw MacSandboxError.cancelled
                }
                applyQuarantineAttribute(to: sandbox.workspaceDir.path)
            } catch {
                reapDirectoryAsync(sessionDir)
                throw error
            }
        }
        return sandbox
    }

    /// Adopts a session whose `workspace/` was already APFS-cloned by the `boo` CLI
    /// (zero double-cloning and zero macOS TCC Desktop/Documents hangs).
    func adoptPreclonedSession(
        id: UUID,
        name: String,
        sourceProjectPath: String?
    ) throws -> MacSandboxSession {
        let shortID = "s-\(id.uuidString.prefix(8).lowercased())"
        let sessionDir = sessionsRootURL.appendingPathComponent(shortID, isDirectory: true).resolvingSymlinksInPath()
        let sandbox = try materializeSession(
            id: id,
            shortID: shortID,
            name: name,
            createdAt: Date(),
            hasUserCustomName: false,
            sourceProjectPath: sourceProjectPath,
            sessionDir: sessionDir
        )
        applyQuarantineAttribute(to: sandbox.workspaceDir.path)
        return sandbox
    }

    func resolveCloneHelperURL() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("boobox-clone"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/boobox-clone"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release/boobox-clone"),
        ]
        for case let url? in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Refreshes `templateDir` from `workspaceDir` asynchronously (skipping full re-clone when unchanged
    /// or using ~0.5s `--delta-in-place` when only a few files changed) AND pre-warms 1 spare APFS clone
    /// (`warmCloneURL(for:)`) with matching `.warm-meta-*.json` so both `⌘T` (<1 ms) and `boo .` (~0.5 s) are instant.
    func snapshotTemplateInBackground(from workspaceDir: URL, to templateDir: URL, excludeEnvFiles: Bool, skipHeavyDirs: Bool) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let fm = FileManager.default
            let parent = templateDir.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

            let sessMetaURL = workspaceDir.deletingLastPathComponent().appendingPathComponent(".clone-meta.json")
            let tmplMetaURL = self.templateMetaURL(for: templateDir)
            let sessMetaData = try? Data(contentsOf: sessMetaURL)
            let tmplMetaData = try? Data(contentsOf: tmplMetaURL)

            // Fast path 1: template already exists and metadata matches byte-for-byte — skip template clone completely!
            if fm.fileExists(atPath: templateDir.path),
               let sData = sessMetaData,
               let tData = tmplMetaData,
               sData == tData {
                self.replenishWarmCloneInBackground(for: templateDir, excludeEnvFiles: excludeEnvFiles, skipHeavyDirs: skipHeavyDirs)
                return
            }

            // Fast path 2: template exists with prior metadata — try ~0.9s delta-in-place sync before full re-clone
            if fm.fileExists(atPath: templateDir.path),
               fm.fileExists(atPath: tmplMetaURL.path),
               let helperURL = self.resolveCloneHelperURL(),
               self.runDeltaInPlace(
                   helperURL: helperURL,
                   from: workspaceDir,
                   into: templateDir,
                   metaURL: tmplMetaURL,
                   excludeEnvFiles: excludeEnvFiles,
                   skipHeavyDirs: skipHeavyDirs
               ) {
                if let sData = sessMetaData {
                    try? sData.write(to: tmplMetaURL, options: .atomic)
                }
                self.replenishWarmCloneInBackground(for: templateDir, excludeEnvFiles: excludeEnvFiles, skipHeavyDirs: skipHeavyDirs)
                return
            }

            // Full template snapshot (first time ever or flag change)
            let stageDir = parent.appendingPathComponent(".stage-\(UUID().uuidString.prefix(8))", isDirectory: true)
            do {
                try cloneProjectDirectory(
                    from: workspaceDir,
                    to: stageDir,
                    excludeEnvFiles: excludeEnvFiles,
                    skipHeavyDirs: skipHeavyDirs
                )
                if fm.fileExists(atPath: templateDir.path) {
                    let trashDir = parent.appendingPathComponent(".trash-\(UUID().uuidString.prefix(8))", isDirectory: true)
                    if (try? fm.moveItem(at: templateDir, to: trashDir)) != nil {
                        DispatchQueue.global(qos: .background).async {
                            try? FileManager.default.removeItem(at: trashDir)
                        }
                    } else {
                        try? fm.removeItem(at: templateDir)
                    }
                }
                if let sData = sessMetaData {
                    try? sData.write(to: tmplMetaURL, options: .atomic)
                } else {
                    try? fm.removeItem(at: tmplMetaURL)
                }
                try fm.moveItem(at: stageDir, to: templateDir)
                self.replenishWarmCloneInBackground(for: templateDir, excludeEnvFiles: excludeEnvFiles, skipHeavyDirs: skipHeavyDirs)
            } catch {
                try? fm.removeItem(at: stageDir)
            }
        }
    }

    private func runDeltaInPlace(
        helperURL: URL,
        from workspaceDir: URL,
        into templateDir: URL,
        metaURL: URL,
        excludeEnvFiles: Bool,
        skipHeavyDirs: Bool
    ) -> Bool {
        let proc = Process()
        proc.executableURL = helperURL
        var args = [
            workspaceDir.path,
            templateDir.path,
            "--delta-in-place", metaURL.path,
            "--write-meta", metaURL.path,
            "--quiet",
        ]
        if excludeEnvFiles { args.append("--no-env") }
        if !skipHeavyDirs { args.append("--include-ignored") }
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - 1-Slot Warm APFS Clone Pool (<1ms ⌘T & ~0.5s `boo .` on huge monorepos)

    private let warmCloneLock = NSLock()
    private var warmCloneBuilding: Set<String> = []

    func warmCloneURL(for templateDir: URL) -> URL {
        let templatesRoot = realHomeURL.appendingPathComponent("boo_box/templates", isDirectory: true)
        let key = templateDir.lastPathComponent
        return templatesRoot.appendingPathComponent(".warm-\(key)", isDirectory: true)
    }

    func templateMetaURL(for templateDir: URL) -> URL {
        let templatesRoot = realHomeURL.appendingPathComponent("boo_box/templates", isDirectory: true)
        let key = templateDir.lastPathComponent
        return templatesRoot.appendingPathComponent(".meta-\(key).json")
    }

    func warmMetaURL(for templateDir: URL) -> URL {
        let templatesRoot = realHomeURL.appendingPathComponent("boo_box/templates", isDirectory: true)
        let key = templateDir.lastPathComponent
        return templatesRoot.appendingPathComponent(".warm-meta-\(key).json")
    }

    /// Atomically moves a pre-warmed APFS clone into a brand-new session workspace (<1 ms!)
    /// and schedules replenishing the next warm spare in the background.
    func popWarmProjectSession(
        for templateDir: URL,
        id: UUID,
        name: String,
        excludeEnvFiles: Bool,
        skipHeavyDirs: Bool
    ) -> MacSandboxSession? {
        let warmURL = warmCloneURL(for: templateDir)
        let warmMeta = warmMetaURL(for: templateDir)
        let fm = FileManager.default
        warmCloneLock.lock()
        let ready = fm.fileExists(atPath: warmURL.path) && !warmCloneBuilding.contains(warmURL.path)
        if ready {
            warmCloneBuilding.insert(warmURL.path)
        }
        warmCloneLock.unlock()

        guard ready else { return nil }

        let shortID = "s-\(id.uuidString.prefix(8).lowercased())"
        let sessionDir = sessionsRootURL.appendingPathComponent(shortID, isDirectory: true).resolvingSymlinksInPath()
        let wsDir = sessionDir.appendingPathComponent("workspace", isDirectory: true)
        do {
            try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            try fm.moveItem(at: warmURL, to: wsDir)
            try? fm.removeItem(at: warmMeta)
            let sandbox = try materializeSession(
                id: id,
                shortID: shortID,
                name: name,
                createdAt: Date(),
                hasUserCustomName: false,
                sourceProjectPath: templateDir.path,
                sessionDir: sessionDir
            )
            applyQuarantineAttribute(to: wsDir.path)

            warmCloneLock.lock()
            warmCloneBuilding.remove(warmURL.path)
            warmCloneLock.unlock()

            replenishWarmCloneInBackground(for: templateDir, excludeEnvFiles: excludeEnvFiles, skipHeavyDirs: skipHeavyDirs)
            return sandbox
        } catch {
            warmCloneLock.lock()
            warmCloneBuilding.remove(warmURL.path)
            warmCloneLock.unlock()
            try? fm.removeItem(at: sessionDir)
            return nil
        }
    }

    func replenishWarmCloneInBackground(for templateDir: URL, excludeEnvFiles: Bool, skipHeavyDirs: Bool) {
        let warmURL = warmCloneURL(for: templateDir)
        let warmMeta = warmMetaURL(for: templateDir)
        let tmplMeta = templateMetaURL(for: templateDir)
        let fm = FileManager.default
        warmCloneLock.lock()
        let warmDirExists = fm.fileExists(atPath: warmURL.path)
        let warmIsFresh: Bool = {
            guard warmDirExists else { return false }
            if let tData = try? Data(contentsOf: tmplMeta) {
                guard let wData = try? Data(contentsOf: warmMeta) else { return false }
                return tData == wData
            }
            return true
        }()
        if warmCloneBuilding.contains(warmURL.path) || warmIsFresh {
            warmCloneLock.unlock()
            return
        }
        warmCloneBuilding.insert(warmURL.path)
        warmCloneLock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                warmCloneLock.lock()
                warmCloneBuilding.remove(warmURL.path)
                warmCloneLock.unlock()
            }
            let fm = FileManager.default
            guard fm.fileExists(atPath: templateDir.path) else { return }
            let parent = warmURL.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let stageDir = parent.appendingPathComponent(".warm-stage-\(UUID().uuidString.prefix(8))", isDirectory: true)
            do {
                try cloneProjectDirectory(
                    from: templateDir,
                    to: stageDir,
                    excludeEnvFiles: excludeEnvFiles,
                    skipHeavyDirs: skipHeavyDirs
                )
                if fm.fileExists(atPath: warmURL.path) {
                    let trashDir = parent.appendingPathComponent(".trash-\(UUID().uuidString.prefix(8))", isDirectory: true)
                    if (try? fm.moveItem(at: warmURL, to: trashDir)) != nil {
                        DispatchQueue.global(qos: .background).async {
                            try? FileManager.default.removeItem(at: trashDir)
                        }
                    } else {
                        try? fm.removeItem(at: warmURL)
                    }
                }
                // Write `.warm-meta-*.json` BEFORE exposing `.warm-*` so `boo .` never observes a dir without metadata
                if let metaData = try? Data(contentsOf: tmplMeta) {
                    try? metaData.write(to: warmMeta, options: .atomic)
                } else {
                    try? fm.removeItem(at: warmMeta)
                }
                try fm.moveItem(at: stageDir, to: warmURL)
            } catch {
                try? fm.removeItem(at: stageDir)
            }
        }
    }

    func cleanupWarmClones() {
        let templatesRoot = realHomeURL.appendingPathComponent("boo_box/templates", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: templatesRoot.path) else { return }
            for name in entries where name.hasPrefix(".warm-") {
                try? fm.removeItem(at: templatesRoot.appendingPathComponent(name))
            }
        }
    }

    /// Reaps any orphaned `.stage-*`, `.warm-stage-*`, and `.trash-*` temp folders left by interrupted runs.
    func cleanupStaleTemplateArtifacts() {
        let templatesRoot = realHomeURL.appendingPathComponent("boo_box/templates", isDirectory: true)
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: templatesRoot.path) else { return }
            for name in entries where name.hasPrefix(".stage-") || name.hasPrefix(".warm-stage-") || name.hasPrefix(".trash-") {
                try? fm.removeItem(at: templatesRoot.appendingPathComponent(name))
            }
        }
    }
    func cleanupStaleSessionTrash() {
        let root = sessionsRootURL
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return }
            for name in entries where name.hasPrefix(".trash-") {
                try? fm.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    func prepareForResume(_ sandbox: MacSandboxSession) throws -> MacSandboxSession {
        if sandbox.isOverlay, let srcPath = sandbox.sourceProjectPath,
           !OverlayClient.isPathNFSMounted(sandbox.workspaceDir.path) {
            let cfg = BooBoxConfigManager.currentSnapshot().general
            try OverlayClient.shared.mount(
                sessionID: sandbox.shortID,
                lowerDir: srcPath,
                upperDir: sandbox.overlayUpperDir.path,
                whiteoutFile: sandbox.overlayWhiteoutURL.path,
                mountPoint: sandbox.workspaceDir.path,
                excludeEnv: cfg.excludeEnvFilesWhenCloning
            )
        }
        return try materializeSession(
            id: sandbox.id,
            shortID: sandbox.shortID,
            name: sandbox.name,
            createdAt: sandbox.createdAt,
            hasUserCustomName: sandbox.hasUserCustomName,
            sourceProjectPath: sandbox.sourceProjectPath,
            sessionDir: sandbox.sessionDir,
            overrides: sandbox.overrides,
            isOverlay: sandbox.isOverlay
        )
    }

    func updateOverrides(_ overrides: SandboxOverrideConfig, for sandbox: MacSandboxSession) throws -> MacSandboxSession {
        let updated = try materializeSession(
            id: sandbox.id,
            shortID: sandbox.shortID,
            name: sandbox.name,
            createdAt: sandbox.createdAt,
            hasUserCustomName: sandbox.hasUserCustomName,
            sourceProjectPath: sandbox.sourceProjectPath,
            sessionDir: sandbox.sessionDir,
            overrides: overrides,
            isOverlay: sandbox.isOverlay
        )
        SecretsVaultManager.shared.updateSessionPolicy(for: sandbox.shortID, overrides: overrides)
        return updated
    }

    func updateSessionName(_ sandbox: MacSandboxSession, to newName: String, isUserCustom: Bool) {
        let meta = MacSandboxMetadata(
            id: sandbox.id,
            shortID: sandbox.shortID,
            name: newName,
            createdAt: sandbox.createdAt,
            hasUserCustomName: isUserCustom,
            sourceProjectPath: sandbox.sourceProjectPath,
            overrides: sandbox.overrides,
            isOverlay: sandbox.isOverlay
        )
        writeMetadata(meta, to: sandbox.metadataURL)
    }

    // MARK: - APFS Zero-Copy Project Cloning (`clonefile(2)`)

    private static let heavyDirs: Set<String> = [
        "node_modules", ".venv", "venv", "target", ".build", "__pycache__",
    ]
    private static let bulkCloneableDirs: Set<String> = [
        ".git", "node_modules", ".venv", "venv", "target", ".build", ".next", ".turbo", "dist", "build",
    ]
    private static let envTemplateAllowlist: Set<String> = [
        ".env.example", ".env.sample", ".env.template", ".env.dist",
    ]

    private func cloneProjectDirectory(
        from sourceDir: URL,
        to destDir: URL,
        excludeEnvFiles: Bool,
        skipHeavyDirs: Bool,
        trackAsActiveClone: Bool = false
    ) throws {
        // Prefer compiled multi-threaded native `boobox-clone` helper (~2s on 70k-file monorepos)
        if let helperURL = resolveCloneHelperURL() {
            let proc = Process()
            proc.executableURL = helperURL
            var helperArgs = [sourceDir.path, destDir.path, "--quiet"]
            if excludeEnvFiles { helperArgs.append("--no-env") }
            if !skipHeavyDirs { helperArgs.append("--include-ignored") }
            proc.arguments = helperArgs
            let errPipe = Pipe()
            proc.standardError = errPipe
            if trackAsActiveClone {
                activeCloneLock.lock()
                if activeCloneCancelled {
                    activeCloneLock.unlock()
                    throw MacSandboxError.cancelled
                }
                activeCloneProcess = proc
                activeCloneLock.unlock()
            }
            try proc.run()
            proc.waitUntilExit()
            if trackAsActiveClone {
                activeCloneLock.lock()
                let wasCancelled = activeCloneCancelled
                if activeCloneProcess === proc { activeCloneProcess = nil }
                activeCloneLock.unlock()
                if wasCancelled {
                    throw MacSandboxError.cancelled
                }
            }
            if proc.terminationStatus == 0 {
                return
            }
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(proc.terminationStatus)"
            throw MacSandboxError.cloneFailed(errText)
        }
        let fm = FileManager.default
        if !excludeEnvFiles && !skipHeavyDirs {
            _ = try? fm.removeItem(at: destDir)
            if clonefile(sourceDir.path, destDir.path, 0) == 0 {
                return
            }
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        try cloneDirectoryFiltered(
            from: sourceDir,
            to: destDir,
            excludeEnvFiles: excludeEnvFiles,
            skipHeavyDirs: skipHeavyDirs
        )
    }

    private func cloneDirectoryFiltered(
        from sourceDir: URL,
        to destDir: URL,
        excludeEnvFiles: Bool,
        skipHeavyDirs: Bool
    ) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        let entries = try fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
            options: []
        )
        for srcItem in entries {
            let name = srcItem.lastPathComponent
            if name == ".DS_Store" { continue }

            let vals = try? srcItem.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            let isSymlink = vals?.isSymbolicLink == true
            let isDir = !isSymlink && (vals?.isDirectory == true)
            let isRegular = vals?.isRegularFile == true

            // Skip Unix domain sockets, FIFOs, and special device nodes (e.g. .turbo daemon sockets)
            if !isDir && !isSymlink && !isRegular {
                continue
            }

            if !isDir && excludeEnvFiles {
                let lower = name.lowercased()
                if (lower == ".env" || lower.hasPrefix(".env.")) && !Self.envTemplateAllowlist.contains(lower) {
                    continue
                }
            }
            if isDir && skipHeavyDirs && Self.heavyDirs.contains(name) {
                continue
            }

            let dstItem = destDir.appendingPathComponent(name, isDirectory: isDir)
            if isDir {
                if Self.bulkCloneableDirs.contains(name), clonefile(srcItem.path, dstItem.path, 0) == 0 {
                    continue
                }
                try cloneDirectoryFiltered(
                    from: srcItem,
                    to: dstItem,
                    excludeEnvFiles: excludeEnvFiles,
                    skipHeavyDirs: skipHeavyDirs
                )
            } else {
                if clonefile(srcItem.path, dstItem.path, 0) != 0 {
                    do {
                        try fm.copyItem(at: srcItem, to: dstItem)
                    } catch {
                        throw MacSandboxError.cloneFailed("\(srcItem.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Semantic Session Naming (Tier 1 Initial + Tier 2 Live Context Upgrades)

    private static let boringBranches: Set<String> = ["main", "master", "HEAD"]
    private static let subpackageMarkers: [String] = [
        "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Package.swift",
    ]
    private static let genericShellTitles: Set<String> = [
        "zsh", "-zsh", "sh", "-sh", "bash", "-bash", "fish", "-fish",
        "login", "env", "sandbox-exec", "boo_box", "workspace", "~", "/",
    ]

    /// Appends `#2`, `#3`, … only when `base` collides with an existing session name.
    func disambiguatedName(base: String, avoiding existingNames: Set<String>) -> String {
        let cleanBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = cleanBase.isEmpty ? "scratch" : cleanBase
        let lowered = Set(existingNames.map { $0.lowercased() })
        if !lowered.contains(seed.lowercased()) {
            return seed
        }
        for n in 2...999 {
            let candidate = "\(seed) #\(n)"
            if !lowered.contains(candidate.lowercased()) {
                return candidate
            }
        }
        return "\(seed) #\(Int.random(in: 1000...9999))"
    }

    /// Clean initial name for a scratch sandbox: `scratch`, `scratch #2`, …
    func semanticScratchName(avoiding existingNames: Set<String>) -> String {
        disambiguatedName(base: "scratch", avoiding: existingNames)
    }

    /// Clean initial name for a cloned project sandbox: `<repo>` (or `<repo> · <branch>` when on a feature branch),
    /// disambiguated with `#2`, `#3`, … only if another open/saved session already shares that exact name.
    func semanticProjectName(
        projectName: String,
        sourceDir: URL?,
        avoiding existingNames: Set<String>
    ) -> String {
        let cleanRepo = Self.stripTemplateHashSuffix(projectName)
        let branch = sourceDir.flatMap { readGitBranch(in: $0.path, boundaryDir: $0.path) }
        let base: String
        if let branch, !Self.boringBranches.contains(branch) {
            base = "\(cleanRepo) · \(Self.compactBranch(branch))"
        } else {
            base = cleanRepo
        }
        return disambiguatedName(base: base, avoiding: existingNames)
    }

    /// Reads the active Git branch from `.git/HEAD` directly (~0.05 ms, zero subprocess forks).
    /// Walks upward from `directory` up to `boundaryDir` to handle subdirectories and cloned repos.
    func readGitBranch(in directory: String, boundaryDir: String) -> String? {
        let fm = FileManager.default
        let boundary = URL(fileURLWithPath: boundaryDir).standardizedFileURL.path
        var cur = URL(fileURLWithPath: directory).standardizedFileURL

        for _ in 0..<10 {
            let curPath = cur.path
            let gitPath = cur.appendingPathComponent(".git").path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitPath, isDirectory: &isDir) {
                let headPath: String
                if isDir.boolValue {
                    headPath = gitPath + "/HEAD"
                } else if let pointer = try? String(contentsOfFile: gitPath, encoding: .utf8),
                          pointer.hasPrefix("gitdir:") {
                    let rel = pointer.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = rel.hasPrefix("/") ? rel : cur.appendingPathComponent(rel).standardizedFileURL.path
                    headPath = resolved + "/HEAD"
                } else {
                    return nil
                }
                if let raw = try? String(contentsOfFile: headPath, encoding: .utf8) {
                    let head = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if head.hasPrefix("ref: refs/heads/") {
                        let branch = String(head.dropFirst("ref: refs/heads/".count))
                        return branch.isEmpty ? nil : branch
                    }
                }
                return nil
            }
            if curPath == boundary || curPath == "/" || !curPath.hasPrefix(boundary) {
                break
            }
            cur.deleteLastPathComponent()
        }
        return nil
    }

    /// Live Tier 2 semantic session name inferred from current workspace state:
    /// 1) Non-shell agent/tool OSC title (e.g. Claude / omp / Codex task title),
    /// 2) Cloned project + active Git feature branch + monorepo sub-package (`repo/api · feat/auth`),
    /// 3) Scratch workspace cloned repo folder + branch (`my-repo · fix-bug`).
    func inferSemanticSessionName(
        for sandbox: MacSandboxSession,
        currentPwd: String?,
        oscTitle: String?,
        avoiding existingNames: Set<String>
    ) -> String? {
        let wsPath = sandbox.workspaceDir.path
        let activeDir: String
        if let pwd = currentPwd, pwd == wsPath || pwd.hasPrefix(wsPath + "/") {
            activeDir = pwd
        } else {
            activeDir = wsPath
        }

        // 1. Meaningful agent/tool OSC title (filtered to reject shells, raw paths, and sandbox IDs)
        if let cleanedTitle = Self.cleanSemanticOSCTitle(oscTitle, for: sandbox) {
            if let repoBase = baseProjectName(for: sandbox) {
                if cleanedTitle.lowercased().hasPrefix(repoBase.lowercased()) {
                    return cleanedTitle
                }
                // Keep short titles paired with repo context; long task titles stand alone cleanly
                if cleanedTitle.count <= 16 {
                    return "\(repoBase) · \(cleanedTitle)"
                }
                return cleanedTitle
            }
            return cleanedTitle
        }

        // 2. Cloned project sandbox -> `<repo>[/<subpkg>][ · <branch>]`
        if let repoBase = baseProjectName(for: sandbox) {
            let subpkg = detectSubpackageName(currentDir: activeDir, workspaceRoot: wsPath)
            let branch = readGitBranch(in: activeDir, boundaryDir: wsPath)
            let targetBase: String
            if let subpkg {
                targetBase = "\(repoBase)/\(subpkg)"
            } else {
                targetBase = repoBase
            }
            let desired: String
            if let branch, !Self.boringBranches.contains(branch) {
                desired = "\(targetBase) · \(Self.compactBranch(branch))"
            } else {
                desired = targetBase
            }
            // Preserve existing `#N` disambiguator if base hasn't changed (prevents oscillation)
            if sandbox.name.lowercased() == desired.lowercased()
                || sandbox.name.lowercased().hasPrefix(desired.lowercased() + " #") {
                return nil
            }
            var others = existingNames
            others.remove(sandbox.name)
            return disambiguatedName(base: desired, avoiding: others)
        }

        // 3. Scratch sandbox -> detect cloned/entered top-level project folder + its branch
        var folderName: String? = nil
        var folderPath: String? = nil
        if let pwd = currentPwd, pwd.hasPrefix(wsPath + "/") {
            let rel = String(pwd.dropFirst(wsPath.count + 1))
            if let first = rel.split(separator: "/").first {
                let name = String(first)
                if !name.isEmpty && !name.hasPrefix(".") {
                    folderName = name
                    folderPath = wsPath + "/" + name
                }
            }
        }
        if folderName == nil {
            let fm = FileManager.default
            if let entries = try? fm.contentsOfDirectory(
                at: sandbox.workspaceDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                let dirs = entries.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                if dirs.count == 1 {
                    let name = dirs[0].lastPathComponent
                    if !name.isEmpty && !name.hasPrefix(".") {
                        folderName = name
                        folderPath = dirs[0].path
                    }
                }
            }
        }
        guard let folderName, let folderPath else { return nil }
        let branch = readGitBranch(in: activeDir, boundaryDir: folderPath)
        let desired: String
        if let branch, !Self.boringBranches.contains(branch) {
            desired = "\(folderName) · \(Self.compactBranch(branch))"
        } else {
            desired = folderName
        }
        if sandbox.name.lowercased() == desired.lowercased()
            || sandbox.name.lowercased().hasPrefix(desired.lowercased() + " #") {
            return nil
        }
        var others = existingNames
        others.remove(sandbox.name)
        return disambiguatedName(base: desired, avoiding: others)
    }

    /// Extracts a clean repo name from `sandbox.sourceProjectPath` (stripping template `-<10hex>` suffix if present).
    private func baseProjectName(for sandbox: MacSandboxSession) -> String? {
        guard let src = sandbox.sourceProjectPath, !src.isEmpty else { return nil }
        let raw = URL(fileURLWithPath: src).lastPathComponent
        let cleaned = Self.stripTemplateHashSuffix(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Strips `boo_box`'s internal template hash suffix (`<project>-<10-hex-chars>`) when `sourceProjectPath`
    /// points into `~/boo_box/templates/`.
    static func stripTemplateHashSuffix(_ raw: String) -> String {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count >= 2, let last = parts.last, last.count == 10,
           last.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }) {
            let prefix = parts.dropLast().joined(separator: "-")
            if !prefix.isEmpty { return prefix }
        }
        return raw
    }

    private static func compactBranch(_ branch: String) -> String {
        if branch.count <= 24 { return branch }
        if let slash = branch.lastIndex(of: "/") {
            let tail = String(branch[branch.index(after: slash)...])
            if !tail.isEmpty && tail.count <= 24 { return tail }
        }
        return String(branch.prefix(23)) + "…"
    }

    /// Detects the nearest nested sub-package directory strictly inside `workspaceRoot`
    /// (e.g. `workspace/apps/api/src` -> `"api"` when `apps/api/package.json` exists).
    private func detectSubpackageName(currentDir: String, workspaceRoot: String) -> String? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: workspaceRoot).standardizedFileURL.path
        var cur = URL(fileURLWithPath: currentDir).standardizedFileURL
        guard cur.path != root && cur.path.hasPrefix(root + "/") else { return nil }

        for _ in 0..<8 {
            let path = cur.path
            if path == root || !path.hasPrefix(root + "/") { break }
            for marker in Self.subpackageMarkers {
                if fm.fileExists(atPath: path + "/" + marker) {
                    let name = cur.lastPathComponent
                    if !name.isEmpty && !name.hasPrefix(".") && name != "src" && name != "dist" && name != "build" {
                        return name
                    }
                }
            }
            cur.deleteLastPathComponent()
        }
        return nil
    }

    /// Filters terminal OSC titles to keep genuine agent/task titles while rejecting bare shells,
    /// raw file paths, host prompts, and internal sandbox IDs.
    static func cleanSemanticOSCTitle(_ raw: String?, for sandbox: MacSandboxSession) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        // Strip leading spinner / status glyphs commonly emitted by CLI coding agents
        let leadingTrim = CharacterSet(charactersIn: "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏✳⠐⠒⠂•●◦⏳✓✔✗✖⚡🤖 ")
        while let first = title.unicodeScalars.first, leadingTrim.contains(first) {
            title.unicodeScalars.removeFirst()
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2 else { return nil }

        let lower = title.lowercased()
        if genericShellTitles.contains(lower) { return nil }
        if title.hasPrefix("/") || title.hasPrefix("~/") || title.hasPrefix("workspace/") { return nil }
        if title.contains(sandbox.shortID) || title.contains(sandbox.sessionDir.path) { return nil }
        // Reject `user@host: path` or `host: ~/dir` shell default titles
        if title.contains("@") && title.contains(":") { return nil }
        // Reject bare paths ending in directory segments with slashes (unless short repo/subpkg)
        if title.filter({ $0 == "/" }).count >= 2 && !title.contains(" ") { return nil }
        // Reject noisy command lines that are just `cd ...` or `ls`
        let firstWord = lower.split(separator: " ").first.map(String.init) ?? lower
        if ["cd", "ls", "ll", "pwd", "clear", "exit", "cat", "echo", "zsh", "bash", "sh"].contains(firstWord) {
            return nil
        }
        if title.count > 38 {
            return String(title.prefix(37)) + "…"
        }
        return title
    }
    func workspaceFileCount(for sandbox: MacSandboxSession) -> Int {
        let fm = FileManager.default
        if sandbox.isOverlay {
            if let upperItems = try? fm.contentsOfDirectory(atPath: sandbox.overlayUpperDir.path),
               !upperItems.filter({ $0 != ".DS_Store" }).isEmpty {
                return upperItems.count
            }
            if let src = sandbox.sourceProjectPath, fm.fileExists(atPath: src) {
                return 1
            }
            return 0
        }
        guard let items = try? fm.contentsOfDirectory(atPath: sandbox.workspaceDir.path) else {
            return 0
        }
        return items.filter { $0 != ".DS_Store" }.count
    }

    /// Instant (<0.2 ms) non-blocking deletion: unmounts any CoW overlay first, atomically renames the
    /// session dir to a hidden `.trash-*` path so the UI updates immediately, then deletes asynchronously.
    func deleteSessionDir(_ sandbox: MacSandboxSession) {
        if sandbox.isOverlay || OverlayClient.isPathNFSMounted(sandbox.workspaceDir.path) {
            OverlayClient.shared.unmount(sessionID: sandbox.shortID, mountPoint: sandbox.workspaceDir.path)
        }
        let srcPath = sandbox.sessionDir.path
        let trashName = ".trash-\(sandbox.shortID)-\(UUID().uuidString.prefix(8))"
        let trashURL = sessionsRootURL.appendingPathComponent(trashName, isDirectory: true)
        let targetToDelete: URL
        if rename(srcPath, trashURL.path) == 0 {
            targetToDelete = trashURL
        } else {
            targetToDelete = sandbox.sessionDir
        }
        DispatchQueue.global(qos: .background).async {
            try? FileManager.default.removeItem(at: targetToDelete)
        }
    }

    /// Loads a single persisted sandbox session directory by `shortID` (e.g. `s-1a2b3c4d`) for relaunch restore.
    func loadSession(shortID: String) -> MacSandboxSession? {
        let fm = FileManager.default
        let dir = sessionsRootURL.appendingPathComponent(shortID, isDirectory: true).resolvingSymlinksInPath()
        let metaURL = dir.appendingPathComponent(".session.json")
        let wsURL = dir.appendingPathComponent("workspace", isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? decoder.decode(MacSandboxMetadata.self, from: data),
              fm.fileExists(atPath: wsURL.path) else {
            return nil
        }
        return MacSandboxSession(
            id: meta.id,
            shortID: meta.shortID,
            name: meta.name,
            createdAt: meta.createdAt,
            hasUserCustomName: meta.hasUserCustomName,
            sourceProjectPath: meta.sourceProjectPath,
            overrides: meta.overrides,
            isOverlay: meta.isOverlay,
            sessionDir: dir,
            workspaceDir: wsURL,
            homeDir: dir.appendingPathComponent(".home", isDirectory: true),
            tmpDir: dir.appendingPathComponent(".tmp", isDirectory: true),
            profileURL: dir.appendingPathComponent(".sandbox.sb"),
            metadataURL: metaURL
        )
    }

    func loadSavedSessions(excludingActive activeIDs: Set<UUID> = []) -> [SavedMacSandboxItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var items: [SavedMacSandboxItem] = []
        for dir in entries {
            let resolvedDir = dir.resolvingSymlinksInPath()
            let metaURL = resolvedDir.appendingPathComponent(".session.json")
            let wsURL = resolvedDir.appendingPathComponent("workspace", isDirectory: true)
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(MacSandboxMetadata.self, from: data),
                  fm.fileExists(atPath: wsURL.path) else {
                continue
            }
            if activeIDs.contains(meta.id) { continue }

            let sandbox = MacSandboxSession(
                id: meta.id,
                shortID: meta.shortID,
                name: meta.name,
                createdAt: meta.createdAt,
                hasUserCustomName: meta.hasUserCustomName,
                sourceProjectPath: meta.sourceProjectPath,
                overrides: meta.overrides,
                isOverlay: meta.isOverlay,
                sessionDir: resolvedDir,
                workspaceDir: wsURL,
                homeDir: resolvedDir.appendingPathComponent(".home", isDirectory: true),
                tmpDir: resolvedDir.appendingPathComponent(".tmp", isDirectory: true),
                profileURL: resolvedDir.appendingPathComponent(".sandbox.sb"),
                metadataURL: metaURL
            )
            let count = workspaceFileCount(for: sandbox)
            if count == 0 {
                // Clean up empty abandoned session dirs asynchronously (never stall sidebar refresh)
                deleteSessionDir(sandbox)
            } else {
                items.append(SavedMacSandboxItem(sandbox: sandbox, fileCount: count))
            }
        }

        return items.sorted { $0.sandbox.createdAt > $1.sandbox.createdAt }
    }

    func launchCommand(for sandbox: MacSandboxSession) -> String {
        func quote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // Scrub inherited host environment with `env -i` so zero host secrets leak
        // even when boo_box is launched from a shell with exported tokens.
        var envArgs = launchEnvironment(for: sandbox)
        envArgs["TERM"] = "xterm-ghostty"
        envArgs["TERM_PROGRAM"] = "ghostty"
        envArgs["COLORTERM"] = "truecolor"
        envArgs["LANG"] = ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"
        envArgs["USER"] = NSUserName()
        envArgs["LOGNAME"] = NSUserName()
        envArgs["SHELL"] = "/bin/zsh"

        let assignments = envArgs
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(quote($0.value))" }
            .joined(separator: " ")

        let nicePrefix = sandbox.overrides.cpuPriority.niceValue > 0
            ? "/usr/bin/nice -n \(sandbox.overrides.cpuPriority.niceValue) "
            : ""

        var rlimits: [String] = []
        if let maxCPU = sandbox.overrides.maxCPUSeconds, maxCPU >= 5 {
            rlimits.append("ulimit -Ht \(maxCPU) 2>/dev/null; ulimit -St \(maxCPU) 2>/dev/null")
        }
        if let maxF = sandbox.overrides.maxOpenFiles, maxF >= 128 {
            rlimits.append("ulimit -Hn \(maxF) 2>/dev/null; ulimit -Sn \(maxF) 2>/dev/null")
        }
        if let maxSizeMB = sandbox.overrides.maxFileSizeMB, maxSizeMB >= 1 {
            let blocks = maxSizeMB * 2048
            rlimits.append("ulimit -Hf \(blocks) 2>/dev/null; ulimit -Sf \(blocks) 2>/dev/null")
        }

        let shellCmd: String
        if rlimits.isEmpty {
            shellCmd = "/bin/zsh -i"
        } else {
            let inner = rlimits.joined(separator: "; ") + "; exec /bin/zsh -i"
            shellCmd = "/bin/zsh -c \(quote(inner))"
        }

        return "/usr/bin/env -i \(assignments) \(nicePrefix)/usr/bin/sandbox-exec -f \(quote(sandbox.profileURL.path)) \(shellCmd)"
    }

    func launchEnvironment(for sandbox: MacSandboxSession) -> [String: String] {
        let realHome = realHomeURL.path
        let cfg = BooBoxConfigManager.currentSnapshot().applying(overrides: sandbox.overrides)
        let cacheCfg = cfg.packageCache
        let cacheRoot = cacheCfg.resolvedCacheURL()

        let access = cfg.sandboxAccess
        let persistentTools = access.persistentSandboxTools
        let toolsRoot = access.resolvedToolsURL()
        if persistentTools {
            GlobalEnvManager.shared.ensureLayout(at: toolsRoot)
        }

        var env: [String: String] = [
            "HOME": sandbox.homeDir.path,
            "ZDOTDIR": sandbox.homeDir.path,
            "TMPDIR": sandbox.tmpDir.path,
            "TMPPREFIX": sandbox.tmpDir.appendingPathComponent("zsh").path,
            "XDG_CONFIG_HOME": sandbox.homeDir.appendingPathComponent(".config").path,
            "XDG_DATA_HOME": sandbox.homeDir.appendingPathComponent(".local/share").path,
            "XDG_CACHE_HOME": sandbox.homeDir.appendingPathComponent(".cache").path,
            "SHELL": "/bin/zsh",
            "npm_config_script_shell": "/bin/sh",
            "npm_config_prefix": sandbox.homeDir.appendingPathComponent(".npm-global").path,
            "BUN_INSTALL": sandbox.homeDir.appendingPathComponent(".bun").path,
            "PNPM_HOME": sandbox.homeDir.appendingPathComponent(".local/share/pnpm").path,
            "PYTHONUSERBASE": sandbox.homeDir.appendingPathComponent(".local").path,
            "UV_TOOL_DIR": sandbox.homeDir.appendingPathComponent(".local/share/uv/tools").path,
            "UV_TOOL_BIN_DIR": sandbox.homeDir.appendingPathComponent(".local/bin").path,
            "GOPATH": sandbox.homeDir.appendingPathComponent("go").path,
            "CARGO_INSTALL_ROOT": sandbox.homeDir.appendingPathComponent(".cargo").path,
            "RUSTUP_HOME": "\(realHome)/.rustup",
            "CARGO_HOME": sandbox.homeDir.appendingPathComponent(".cargo").path,
            "BOOBOX_MODE": "mac_sandbox",
            "BOOBOX_SESSION_ID": sandbox.shortID,
            "BOOBOX_WORKSPACE": sandbox.workspaceDir.path,
            "BOOBOX_CLEAR_BANNER": "1",
            // Fast monorepo Git defaults inside sandboxes (no .git/config mutation; disables fsmonitor daemon sockets inside Seatbelt)
            "GIT_CONFIG_COUNT": "4",
            "GIT_CONFIG_KEY_0": "core.preloadIndex",
            "GIT_CONFIG_VALUE_0": "true",
            "GIT_CONFIG_KEY_1": "core.untrackedCache",
            "GIT_CONFIG_VALUE_1": "true",
            "GIT_CONFIG_KEY_2": "feature.manyFiles",
            "GIT_CONFIG_VALUE_2": "true",
            "GIT_CONFIG_KEY_3": "core.fsmonitor",
            "GIT_CONFIG_VALUE_3": "false",
            "PATH": buildSandboxPATH(for: sandbox, config: cfg),
        ]
        if persistentTools {
            for (k, v) in GlobalEnvManager.environmentVariables(at: toolsRoot, realHome: realHome) {
                env[k] = v
            }
        }
        let cltSDK = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
        if FileManager.default.fileExists(atPath: cltSDK) {
            env["SDKROOT"] = cltSDK
            env["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"
        }
        if cacheCfg.enabled {
            if cacheCfg.pnpm {
                env["PNPM_STORE_DIR"] = cacheRoot.appendingPathComponent("pnpm").path
            }
            if cacheCfg.npm {
                env["npm_config_cache"] = cacheRoot.appendingPathComponent("npm").path
            }
            if cacheCfg.bun {
                env["BUN_INSTALL_CACHE_DIR"] = cacheRoot.appendingPathComponent("bun").path
            }
            if cacheCfg.uv {
                env["UV_CACHE_DIR"] = cacheRoot.appendingPathComponent("uv").path
            }
            if cacheCfg.pip {
                env["PIP_CACHE_DIR"] = cacheRoot.appendingPathComponent("pip").path
            }
            if cacheCfg.cargo {
                env["CARGO_HOME"] = cacheRoot.appendingPathComponent("cargo").path
            }
            env["BOOBOX_CACHE_MODE"] = cacheCfg.accessMode.rawValue
        }
        // Opt-in host capabilities (configured in Settings → Sandbox Access)
        if access.allowHostGitConfig {
            let hostGitConfig = "\(realHome)/.gitconfig"
            if FileManager.default.fileExists(atPath: hostGitConfig) {
                env["GIT_CONFIG_GLOBAL"] = hostGitConfig
            }
        }
        if access.allowSSHAgent,
           let sshSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
           !sshSock.isEmpty {
            env["SSH_AUTH_SOCK"] = sshSock
        }
        if access.allowDockerSocket, let dockerSock = resolveHostDockerSocket() {
            env["DOCKER_HOST"] = "unix://\(dockerSock)"
        }
        // Host secret vault & egress proxy (phantom tokens + Base-URL routes; real secrets NEVER enter sandbox)
        let proxyEnv = SecretsVaultManager.shared.sandboxEnvironment(for: sandbox.shortID, overrides: sandbox.overrides).env
        for (k, v) in proxyEnv {
            env[k] = v
        }

        if let resDir = resolveGhosttyResourcesDir() {
            env["GHOSTTY_RESOURCES_DIR"] = resDir
            let terminfoDir = ((resDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("terminfo")
            if FileManager.default.fileExists(atPath: terminfoDir) {
                env["TERMINFO_DIRS"] = "\(terminfoDir):"
            }
        }
        return env
    }

    private func resolveHostDockerSocket() -> String? {
        let realHome = realHomeURL.path
        let candidates = [
            "\(realHome)/.orbstack/run/docker.sock",
            "\(realHome)/.docker/run/docker.sock",
            "/var/run/docker.sock",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        return nil
    }

    // MARK: - Private Setup

    private func materializeSession(
        id: UUID,
        shortID: String,
        name: String,
        createdAt: Date,
        hasUserCustomName: Bool,
        sourceProjectPath: String?,
        sessionDir: URL,
        overrides: SandboxOverrideConfig = .default,
        isOverlay: Bool = false
    ) throws -> MacSandboxSession {
        let fm = FileManager.default
        let cfg = BooBoxConfigManager.currentSnapshot().applying(overrides: overrides)
        let workspaceDir = sessionDir.appendingPathComponent("workspace", isDirectory: true)
        let homeDir = sessionDir.appendingPathComponent(".home", isDirectory: true)
        let tmpDir = sessionDir.appendingPathComponent(".tmp", isDirectory: true)
        let profileURL = sessionDir.appendingPathComponent(".sandbox.sb")
        let metadataURL = sessionDir.appendingPathComponent(".session.json")

        for dir in [
            sessionDir,
            workspaceDir,
            homeDir,
            homeDir.appendingPathComponent(".config", isDirectory: true),
            homeDir.appendingPathComponent(".local/share", isDirectory: true),
            homeDir.appendingPathComponent(".cache", isDirectory: true),
            homeDir.appendingPathComponent(".cargo", isDirectory: true),
            tmpDir,
        ] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if cfg.packageCache.enabled {
            let cacheRoot = cfg.packageCache.resolvedCacheURL()
            for sub in ["pnpm", "npm", "bun", "uv", "pip", "cargo"] {
                try? fm.createDirectory(at: cacheRoot.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
            }
        }

        // Tag workspace with macOS quarantine attribute to block silent Finder app execution (skip on NFS mount)
        if !isOverlay {
            applyQuarantineAttribute(to: workspaceDir.path)
        }

        let sandbox = MacSandboxSession(
            id: id,
            shortID: shortID,
            name: name,
            createdAt: createdAt,
            hasUserCustomName: hasUserCustomName,
            sourceProjectPath: sourceProjectPath,
            overrides: overrides,
            isOverlay: isOverlay,
            sessionDir: sessionDir,
            workspaceDir: workspaceDir,
            homeDir: homeDir,
            tmpDir: tmpDir,
            profileURL: profileURL,
            metadataURL: metadataURL
        )
        // Write fresh Seatbelt SBPL profile + isolated .zshrc + optional first-run setup script
        // Symlink enabled host CLI tool config dirs/files (e.g. ~/.omp, ~/.config/opencode, ~/.claude, ~/.codex)
        // into the session's $HOME so agent CLIs launch with existing auth & settings, while keeping all other
        // host files kernel-denied.
        syncSharedConfigSymlinks(in: homeDir, config: cfg)

        if cfg.secretsNetwork.proxyEnabled {
            _ = SecretsVaultManager.shared.startIfNeeded()
        }
        let sbpl = generateSBPLProfile(for: sandbox, config: cfg)
        try sbpl.write(to: profileURL, atomically: true, encoding: .utf8)

        // Write 0600 env export file sourced & hot-reloaded by .zshrc (keeps secret values off process argv / `ps`).
        writeSandboxEnvFile(for: sandbox, config: cfg)
        let setupScript = cfg.ephemeralSetup.sandboxSetupScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let setupScriptURL = homeDir.appendingPathComponent(".boobox-setup.sh")
        if !setupScript.isEmpty {
            let body = "#!/bin/zsh\nset -e\n\(setupScript)\n"
            try? body.write(to: setupScriptURL, atomically: true, encoding: .utf8)
            chmod(setupScriptURL.path, 0o700)
        } else {
            try? fm.removeItem(at: setupScriptURL)
        }

        let zshenvURL = homeDir.appendingPathComponent(".zshenv")
        try generateSandboxZshenv(for: sandbox).write(to: zshenvURL, atomically: true, encoding: .utf8)
        chmod(zshenvURL.path, 0o444)
        let booboxBinDir = homeDir.appendingPathComponent(".boobox-bin", isDirectory: true)
        try fm.createDirectory(at: booboxBinDir, withIntermediateDirectories: true)
        let mktempShimURL = booboxBinDir.appendingPathComponent("mktemp")
        try Self.mktempShimScript.write(to: mktempShimURL, atomically: true, encoding: .utf8)
        chmod(mktempShimURL.path, 0o555)
        let rmShimURL = booboxBinDir.appendingPathComponent("rm")
        try Self.rmShimScript.write(to: rmShimURL, atomically: true, encoding: .utf8)
        chmod(rmShimURL.path, 0o555)
        let cpShimURL = booboxBinDir.appendingPathComponent("cp")
        try Self.cpShimScript.write(to: cpShimURL, atomically: true, encoding: .utf8)
        chmod(cpShimURL.path, 0o555)
        installCredentialAndCLIShims(in: booboxBinDir)
        let zshrcURL = homeDir.appendingPathComponent(".zshrc")
        try generateSandboxZshrc(for: sandbox, config: cfg).write(to: zshrcURL, atomically: true, encoding: .utf8)
        let meta = MacSandboxMetadata(
            id: id,
            shortID: shortID,
            name: name,
            createdAt: createdAt,
            hasUserCustomName: hasUserCustomName,
            sourceProjectPath: sourceProjectPath,
            overrides: overrides,
            isOverlay: isOverlay
        )
        writeMetadata(meta, to: metadataURL)
        return sandbox
    }

    /// Creates/refreshes `$HOME` symlinks for enabled CLI tool configs and removes stale symlinks
    /// if the user later disables a tool in Settings → Sandbox Access.
    private func syncSharedConfigSymlinks(in homeDir: URL, config cfg: BooBoxConfig) {
        let fm = FileManager.default
        let realHome = realHomeURL.path
        let desired = cfg.sandboxAccess.resolvedSharedConfigMappings(realHome: realHome)
        let desiredLinkPaths = Set(desired.map { homeDir.appendingPathComponent($0.relativePath).path })

        // 1. Remove any previously-managed symlink in $HOME (or $HOME/.config, $HOME/.local/{share,state}) toggled OFF
        let scanRoots = [
            homeDir,
            homeDir.appendingPathComponent(".config", isDirectory: true),
            homeDir.appendingPathComponent(".local/share", isDirectory: true),
            homeDir.appendingPathComponent(".local/state", isDirectory: true),
        ]
        for root in scanRoots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names {
                let candidate = root.appendingPathComponent(name)
                var st = stat()
                guard lstat(candidate.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { continue }
                if let dest = try? fm.destinationOfSymbolicLink(atPath: candidate.path),
                   dest.hasPrefix(realHome + "/"),
                   !desiredLinkPaths.contains(candidate.path) {
                    try? fm.removeItem(at: candidate)
                }
            }
        }

        // 2. Ensure each enabled CLI tool config is symlinked to its host path
        for mapping in desired {
            let linkURL = homeDir.appendingPathComponent(mapping.relativePath)
            let parentURL = linkURL.deletingLastPathComponent()
            try? fm.createDirectory(at: parentURL, withIntermediateDirectories: true)

            var st = stat()
            if lstat(linkURL.path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFLNK {
                    if (try? fm.destinationOfSymbolicLink(atPath: linkURL.path)) == mapping.hostPath {
                        continue
                    }
                    try? fm.removeItem(at: linkURL)
                } else {
                    // Preserve any previous local sandbox-only config before linking host config
                    let backupURL = parentURL.appendingPathComponent("\(linkURL.lastPathComponent).sandbox-local")
                    _ = try? fm.removeItem(at: backupURL)
                    try? fm.moveItem(at: linkURL, to: backupURL)
                }
            }
            try? fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: mapping.hostPath)
        }
    }

    private func writeMetadata(_ meta: MacSandboxMetadata, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meta) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func generateSBPLProfile(for sandbox: MacSandboxSession, config cfg: BooBoxConfig) -> String {
        let realHome = sbplEscape(realHomeURL.path)
        let sessionPath = sbplEscape(sandbox.sessionDir.path)
        let profilePath = sbplEscape(sandbox.profileURL.path)
        let metadataPath = sbplEscape(sandbox.metadataURL.path)
        let zshenvPath = sbplEscape(sandbox.homeDir.appendingPathComponent(".zshenv").path)
        var extraReadPaths: [String] = []
        var extraWritePaths: [String] = []
        var extraMetadataPaths: [String] = []

        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if bundlePath.hasPrefix(realHomeURL.path) {
            extraReadPaths.append(bundlePath)
        }
        if let resDir = resolveGhosttyResourcesDir() {
            let parent = URL(fileURLWithPath: resDir).deletingLastPathComponent().resolvingSymlinksInPath().path
            if parent.hasPrefix(realHomeURL.path) && !extraReadPaths.contains(parent) {
                extraReadPaths.append(parent)
            }
        }

        // Shared package cache path rules
        if cfg.packageCache.enabled {
            let cachePath = cfg.packageCache.resolvedCacheURL().path
            if !extraReadPaths.contains(cachePath) {
                extraReadPaths.append(cachePath)
            }
            if cfg.packageCache.accessMode == .readWrite {
                extraWritePaths.append(cachePath)
            }
            // Allow stat on parent dirs when cache path is nested inside realHome
            var cursor = URL(fileURLWithPath: cachePath).deletingLastPathComponent().path
            while cursor.hasPrefix(realHomeURL.path) && cursor.count > realHomeURL.path.count {
                if !extraMetadataPaths.contains(cursor) {
                    extraMetadataPaths.append(cursor)
                }
                cursor = URL(fileURLWithPath: cursor).deletingLastPathComponent().path
            }
        }

        // User-configured extra read-only paths (Settings → Sandbox Access)
        let access = cfg.sandboxAccess
        let allExtraRead = access.extraReadPaths + cfg.ephemeralSetup.sandboxExtraReadPaths
        var extraReadLiterals: [String] = []
        var extraWriteLiterals: [String] = []

        func addAncestorMetadata(for fullPath: String) {
            var cursor = URL(fileURLWithPath: fullPath).deletingLastPathComponent().path
            while cursor.count > 1 {
                if (cursor.hasPrefix(realHomeURL.path) || cursor.hasPrefix("/private/tmp") || cursor.hasPrefix("/private/var/folders"))
                    && !extraMetadataPaths.contains(cursor) {
                    extraMetadataPaths.append(cursor)
                }
                let next = URL(fileURLWithPath: cursor).deletingLastPathComponent().path
                if next == cursor { break }
                cursor = next
            }
        }

        for rawPath in allExtraRead {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let resolved = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
            if !extraReadPaths.contains(resolved) {
                extraReadPaths.append(resolved)
            }
            addAncestorMetadata(for: resolved)
        }

        if access.allowHostGitConfig {
            let gitCfg = "\(realHomeURL.path)/.gitconfig"
            extraReadLiterals.append(gitCfg)
        }

        if access.allowSSHAgent,
           let sshSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
           !sshSock.isEmpty {
            let resolved = URL(fileURLWithPath: sshSock).resolvingSymlinksInPath().path
            extraReadLiterals.append(resolved)
            extraWriteLiterals.append(resolved)
            addAncestorMetadata(for: resolved)
        }

        if access.allowDockerSocket, let dockerSock = resolveHostDockerSocket() {
            extraReadLiterals.append(dockerSock)
            extraWriteLiterals.append(dockerSock)
            addAncestorMetadata(for: dockerSock)
        }

        // Enabled host CLI tool configs (RW passthrough — tools can edit their own config/auth while all
        // other host files, Desktop, Documents, ~/.ssh, and real repos stay kernel-denied).
        for mapping in access.resolvedSharedConfigMappings(realHome: realHomeURL.path) {
            if mapping.isFile {
                if !extraReadLiterals.contains(mapping.hostPath) {
                    extraReadLiterals.append(mapping.hostPath)
                }
                if !extraWriteLiterals.contains(mapping.hostPath) {
                    extraWriteLiterals.append(mapping.hostPath)
                }
            } else {
                if !extraReadPaths.contains(mapping.hostPath) {
                    extraReadPaths.append(mapping.hostPath)
                }
                if !extraWritePaths.contains(mapping.hostPath) {
                    extraWritePaths.append(mapping.hostPath)
                }
            }
            addAncestorMetadata(for: mapping.hostPath)
        }

        // Persistent sandbox-installed global toolchains (`~/boo_box/tools` RW, isolated from host /opt/homebrew)
        if access.persistentSandboxTools {
            let toolsPath = access.resolvedToolsURL().path
            if !extraReadPaths.contains(toolsPath) {
                extraReadPaths.append(toolsPath)
            }
            if !extraWritePaths.contains(toolsPath) {
                extraWritePaths.append(toolsPath)
            }
            addAncestorMetadata(for: toolsPath)
        }

        let extraMetadataBlock = extraMetadataPaths
            .map { "    (literal \"\(sbplEscape($0))\")" }
            .joined(separator: "\n")
        let extraReadBlock = (
            extraReadPaths.map { "    (subpath \"\(sbplEscape($0))\")" } +
            extraReadLiterals.map { "    (literal \"\(sbplEscape($0))\")" }
        ).joined(separator: "\n")
        let extraWriteBlock = (
            extraWritePaths.map { "    (subpath \"\(sbplEscape($0))\")" } +
            extraWriteLiterals.map { "    (literal \"\(sbplEscape($0))\")" }
        ).joined(separator: "\n")
        let netCfg = cfg.secretsNetwork
        let proxyPort = netCfg.proxyEnabled ? SecretsVaultManager.shared.currentProxyPort : nil
        let networkPolicyBlock: String = {
            if netCfg.egressMode == .offline {
                let proxyAllow = proxyPort.map { port in
                    """
                    (allow network-outbound (remote tcp "localhost:\(port)"))
                    """
                } ?? ""
                return """
                ;; 4. Offline mode: deny all outbound IP traffic and direct DNS (mDNSResponder)
                (deny network-outbound (remote ip))
                (deny network-outbound (remote unix-socket (literal "/var/run/mDNSResponder")))
                \(proxyAllow)
                """
            }
            if netCfg.requiresSeatbeltNetworkLock, let port = proxyPort {
                let dnsBlock = (netCfg.egressMode == .allowlist)
                    ? "(deny network-outbound (remote unix-socket (literal \"/var/run/mDNSResponder\")))"
                    : ""
                let localDevAllow = access.blockLocalNetwork
                    ? "(allow network-outbound (remote tcp \"localhost:\(port)\"))"
                    : """
                    (allow network-outbound
                        (remote ip "localhost:*")
                        (remote ip "127.0.0.1:*")
                        (remote ip "::1:*")
                    )
                    """
                return """
                ;; 4. Proxy-locked egress (\(netCfg.egressMode.rawValue)): deny direct external IP traffic
                (deny network-outbound (remote ip))
                \(dnsBlock)
                \(localDevAllow)
                """
            }
            if access.blockLocalNetwork {
                let proxyAllow = proxyPort.map { port in
                    "(allow network-outbound (remote tcp \"localhost:\(port)\"))"
                } ?? ""
                return """
                ;; 4. Opt-in local network block (prevents reaching host localhost DBs/services, while allowing boobox-proxy)
                (deny network-outbound
                    (remote ip "localhost:*")
                    (remote ip "127.0.0.1:*")
                    (remote ip "::1:*")
                )
                \(proxyAllow)
                """
            }
            return ""
        }()

        let overlayPortBlock: String = {
            let overlayPort = OverlayClient.shared.currentPort
            guard overlayPort > 0 else { return "" }
            return """
            ;; 5. Block direct sandbox TCP access to host boobox-overlay daemon (only macOS kernel NFS client connects)
            (deny network-outbound (remote tcp "localhost:\(overlayPort)"))
            """
        }()
        return """
        (version 1)
        (allow default)

        ;; 1. Default-deny ALL reads AND existence/chdir checks on user data, other users,
        ;;    host /tmp, other apps' /var/folders, and external /Volumes.
        (deny file-read*
            (subpath "/Users")
            (subpath "/private/tmp")
            (subpath "/private/var/folders")
            (subpath "/Volumes")
        )
        (deny file-test-existence
            (subpath "/Users")
            (subpath "/private/tmp")
            (subpath "/private/var/folders")
            (subpath "/Volumes")
        )

        ;; Minimal literal ancestor lstat ONLY so node/pnpm/rustc realpathSync(cwd) succeeds.
        ;; Directory listing (file-read-data) and writes remain hard-denied on all of these.
        (allow file-read-metadata file-test-existence
            (literal "/Users")
            (literal "\(realHome)")
            (literal "\(realHome)/boo_box")
            (literal "\(realHome)/boo_box/sessions")
            (literal "\(sessionPath)")
            (literal "\(realHome)/Library")
            (literal "\(realHome)/Library/Application Support")
            (literal "\(realHome)/Library/Caches")
            (literal "\(realHome)/.local")
            (literal "\(realHome)/.local/share")
            (literal "\(realHome)/.cargo")
            (literal "\(realHome)/.bun")
            (literal "\(realHome)/go")
            (literal "\(realHome)/.deno")
        \(extraMetadataBlock)
        )

        ;; 2. Allow read access ONLY to this session dir + strictly narrowed CLI binary/runtime dirs + configured caches.
        ;;    NEVER exposes ~/.local/share/{opencode,gh,graphite,zero}, ~/.local/state, or ~/.cargo/credentials.toml.
        (allow file-read* file-test-existence
            (subpath "\(sessionPath)/workspace")
            (subpath "\(sessionPath)/.home")
            (subpath "\(sessionPath)/.tmp")
            (subpath "\(realHome)/.cargo/bin")
            (subpath "\(realHome)/.rustup")
            (subpath "\(realHome)/.bun/bin")
            (subpath "\(realHome)/.local/bin")
            (subpath "\(realHome)/.local/share/fnm")
            (subpath "\(realHome)/.local/share/uv")
            (subpath "\(realHome)/go/bin")
            (subpath "\(realHome)/.deno/bin")
            (subpath "\(realHome)/.fnm")
            (subpath "\(realHome)/.nvm")
            (subpath "\(realHome)/.volta")
            (subpath "\(realHome)/.asdf")
            (subpath "\(realHome)/.mise")
            (subpath "\(realHome)/.pyenv")
            (subpath "\(realHome)/.rbenv")
            (subpath "\(realHome)/.npm-global")
            (subpath "\(realHome)/Library/pnpm")
            (subpath "\(realHome)/Library/Application Support/fnm")
        \(extraReadBlock)
        )
        ;; 3. Default-deny ALL filesystem writes everywhere except this session directory, writable caches, and TTYs
        (deny file-write*)
        (allow file-write*
            (subpath "\(sessionPath)/workspace")
            (subpath "\(sessionPath)/.home")
            (subpath "\(sessionPath)/.tmp")
        \(extraWriteBlock)
            (literal "/dev/null")
            (literal "/dev/zero")
            (literal "/dev/tty")
            (literal "/dev/ptmx")
            (literal "/dev/dtracehelper")
            (regex #"^/dev/ttys[0-9]+$")
            (regex #"^/dev/pty.*$")
        )
        ;; Hide and protect boo_box control files from reads, existence probes, and tampering
        (deny file-read* file-test-existence
            (literal "\(profilePath)")
            (literal "\(metadataPath)")
            (literal "\(sessionPath)/.clone-meta.json")
            (subpath "\(sessionPath)/.overlay")
            (subpath "\(realHome)/boo_box/vault")
        )
        (deny file-write*
            (literal "\(profilePath)")
            (literal "\(metadataPath)")
            (literal "\(sessionPath)/.clone-meta.json")
            (literal "\(zshenvPath)")
            (subpath "\(sessionPath)/.home/.boobox-bin")
            (subpath "\(sessionPath)/.overlay")
            (subpath "\(realHome)/boo_box/vault")
        )
        \(networkPolicyBlock)
        \(overlayPortBlock)
        """
    }

    /// Loaded on BOTH interactive and non-interactive (`zsh -c`) shells inside the sandbox
    /// to keep shell navigation (`cd`/`pushd`) inside the session workspace (resolving symlinks).
    private func generateSandboxZshenv(for sandbox: MacSandboxSession) -> String {
        let wsPath = sandbox.workspaceDir.path.replacingOccurrences(of: "'", with: "'\\''")
        return """
        # Auto-generated by boo_box (read-only) — keeps shell cd/pushd within session workspace
        _boobox_guard_dir() {
            local ws='\(wsPath)'
            local resolved="${1:A}"
            if [[ "$resolved" == "$ws" || "$resolved" == "$ws/"* ]]; then
                return 0
            fi
            print -u2 "boo_box: cannot cd outside session workspace ($resolved)"
            return 1
        }

        cd() {
            local args=()
            local target=""
            local parsing_opts=1
            local arg
            for arg in "$@"; do
                if (( parsing_opts )) && [[ "$arg" == "--" ]]; then
                    parsing_opts=0
                    args+=("$arg")
                elif (( parsing_opts )) && [[ "$arg" == -* && "$arg" != "-" ]]; then
                    args+=("$arg")
                else
                    parsing_opts=0
                    target="$arg"
                    args+=("$arg")
                fi
            done
            if [[ -z "$target" ]]; then
                builtin cd '\(wsPath)'
                return $?
            fi
            local dest="$target"
            if [[ "$dest" == "-" ]]; then
                dest="${OLDPWD:-\(wsPath)}"
            elif [[ "$dest" != /* ]]; then
                dest="$PWD/$dest"
            fi
            _boobox_guard_dir "$dest" || return 1
            builtin cd "${args[@]}"
        }

        pushd() {
            if [[ -n "${1:-}" && "$1" != -* && "$1" != +* ]]; then
                local dest="$1"
                [[ "$dest" != /* ]] && dest="$PWD/$dest"
                _boobox_guard_dir "$dest" || return 1
            fi
            builtin pushd "$@"
        }
        """
    }
    /// macOS `/usr/bin/mktemp` (no-arg and `-t` forms) ignores `$TMPDIR` and calls
    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)` (`/var/folders/.../T/`), which Seatbelt denies.
    /// This read-only shim routes default/template-less `mktemp` calls into `$TMPDIR`
    /// (`~/boo_box/sessions/<id>/.tmp`) while preserving explicit paths and keeping `/var/folders` locked.
    private static let mktempShimScript = """
    #!/bin/sh
    has_p=0
    has_t=0
    has_pos=0
    skip_next=0
    after_dd=0
    for arg in "$@"; do
        if [ "$after_dd" -eq 1 ]; then
            has_pos=1
            continue
        fi
        if [ "$skip_next" -eq 1 ]; then
            skip_next=0
            continue
        fi
        case "$arg" in
            --) after_dd=1 ;;
            -p|--tmpdir|--tmpdir=*) has_p=1; [ "$arg" = "-p" ] && skip_next=1 ;;
            -t) has_t=1; skip_next=1 ;;
            -[a-zA-Z]*t) has_t=1; skip_next=1 ;;
            -t*) has_t=1 ;;
            -*) ;;
            *) has_pos=1 ;;
        esac
    done
    if [ "$has_p" -eq 0 ] && [ -n "${TMPDIR:-}" ] && { [ "$has_pos" -eq 0 ] || [ "$has_t" -eq 1 ]; }; then
        exec /usr/bin/mktemp -p "$TMPDIR" "$@"
    fi
    exec /usr/bin/mktemp "$@"
    """

    /// Instant APFS move-aside shim for `rm -rf <dir...>` inside sandboxes.
    ///
    /// Deleting massive directory trees (e.g. monorepo `node_modules` with 300k+ APFS inodes)
    /// serially via `/bin/rm -rf` blocks for 15–30s under XNU's APFS catalog lock. For safe
    /// recursive-force deletes (`-r`/`-R` + `-f`, no `-i`/`-I`/`-v`/`-P`/`-W`), this shim
    /// atomically `mv`s target directories into `$TMPDIR/.rm-trash/` (<1 ms) and reaps them
    /// asynchronously with detached stdio so callers/pipes never block. Opt out with `BOOBOX_SYNC_RM=1`.
    private static let rmShimScript = """
    #!/bin/sh
    if [ "${BOOBOX_SYNC_RM:-0}" = "1" ] || [ -z "${TMPDIR:-}" ] || [ ! -d "${TMPDIR:-}" ]; then
        exec /bin/rm "$@"
    fi
    has_r=0
    has_f=0
    unsupported=0
    after_dd=0
    for arg in "$@"; do
        if [ "$after_dd" -eq 1 ]; then continue; fi
        case "$arg" in
            --) after_dd=1 ;;
            -*)
                chars="${arg#-}"
                [ -z "$chars" ] && continue
                while [ -n "$chars" ]; do
                    c="${chars%"${chars#?}"}"
                    chars="${chars#?}"
                    case "$c" in
                        r|R) has_r=1 ;;
                        f) has_f=1 ;;
                        *) unsupported=1 ;;
                    esac
                done
                ;;
            *) after_dd=1 ;;
        esac
    done
    if [ "$has_r" -eq 0 ] || [ "$has_f" -eq 0 ] || [ "$unsupported" -eq 1 ]; then
        exec /bin/rm "$@"
    fi

    trash_root="${TMPDIR}/.rm-trash"
    /bin/mkdir -p "$trash_root" 2>/dev/null || exec /bin/rm "$@"

    moved_any=0
    batch_dir="${trash_root}/b-$$-$(/bin/date +%s 2>/dev/null || echo 0)"
    idx=0
    fallback_rc=0
    parsing_opts=1

    for arg in "$@"; do
        if [ "$parsing_opts" -eq 1 ]; then
            case "$arg" in
                --) parsing_opts=0; continue ;;
                -*) continue ;;
                *) parsing_opts=0 ;;
            esac
        fi
        # Only move-aside real non-symlink directories (never ., .., /, $HOME, $TMPDIR, or workspace root)
        if [ -d "$arg" ] && [ ! -L "$arg" ]; then
            case "$arg" in
                .|..|./|../|/|"$HOME"|"$HOME/"|"$TMPDIR"|"$TMPDIR/"|"${BOOBOX_WORKSPACE:-}"|"${BOOBOX_WORKSPACE:-}/"|"$trash_root"*)
                    /bin/rm -rf -- "$arg" || fallback_rc=$?
                    continue
                    ;;
            esac
            if [ "$moved_any" -eq 0 ]; then
                /bin/mkdir -p "$batch_dir" 2>/dev/null || { /bin/rm -rf -- "$arg" || fallback_rc=$?; continue; }
            fi
            idx=$((idx + 1))
            if /bin/mv -- "$arg" "${batch_dir}/${idx}" 2>/dev/null; then
                moved_any=1
            else
                /bin/rm -rf -- "$arg" || fallback_rc=$?
            fi
        elif [ -e "$arg" ] || [ -L "$arg" ]; then
            /bin/rm -rf -- "$arg" || fallback_rc=$?
        fi
    done

    if [ "$moved_any" -eq 1 ]; then
        (/bin/rm -rf "$batch_dir" </dev/null >/dev/null 2>&1 &)
    fi
    exit "$fallback_rc"
    """

    /// APFS copy-on-write shim for recursive `cp` (`cp -r` / `-R` / `-a`) inside sandboxes.
    ///
    /// Attempts `/bin/cp -c` (kernel `clonefile(2)`, 0 extra SSD blocks, 10-100x faster on large trees)
    /// when the target does not already exist and flags are CoW-safe; transparently falls back to `/bin/cp`
    /// for non-recursive, cross-volume, interactive/verbose, or existing-target copies. Opt out with `BOOBOX_NO_COW_CP=1`.
    private static let cpShimScript = """
    #!/bin/sh
    if [ "${BOOBOX_NO_COW_CP:-0}" = "1" ]; then
        exec /bin/cp "$@"
    fi
    recursive=0
    unsupported=0
    after_dd=0
    arg_count=0
    last_arg=""
    for arg in "$@"; do
        last_arg="$arg"
        if [ "$after_dd" -eq 1 ]; then
            arg_count=$((arg_count + 1))
            continue
        fi
        case "$arg" in
            --) after_dd=1 ;;
            -*)
                chars="${arg#-}"
                [ -z "$chars" ] && continue
                while [ -n "$chars" ]; do
                    c="${chars%"${chars#?}"}"
                    chars="${chars#?}"
                    case "$c" in
                        r|R|a) recursive=1 ;;
                        p|P|f) ;;
                        *) unsupported=1 ;;
                    esac
                done
                ;;
            *)
                after_dd=1
                arg_count=$((arg_count + 1))
                ;;
        esac
    done
    # Only fast-path exact 2-operand recursive copies into a brand-new destination (zero partial-merge risk)
    if [ "$recursive" -eq 1 ] && [ "$unsupported" -eq 0 ] && [ "$arg_count" -eq 2 ] && [ -n "$last_arg" ] && [ ! -e "$last_arg" ] && [ ! -L "$last_arg" ]; then
        if /bin/cp -c "$@" 2>/dev/null; then
            exit 0
        fi
    fi
    exec /bin/cp "$@"
    """

    /// Zero-Keychain, zero-host-gitconfig POSIX Git credential helper backed by `$GH_TOKEN`
    /// (injected via `0600 ~/.boobox-env.sh` and hot-reloaded on every `preexec`/`precmd`).
    private static let gitCredShimScript = """
    #!/bin/sh
    [ "$1" = "get" ] || exit 0
    [ -f "$HOME/.boobox-env.sh" ] && . "$HOME/.boobox-env.sh"
    [ -n "$GH_TOKEN" ] || exit 0
    printf 'username=x-access-token\\npassword=%s\\n' "$GH_TOKEN"
    """

    /// Hot-reloads `$HOME/.boobox-env.sh` right before invoking real `git` so even pre-existing
    /// shells and already-running coding agents (`claude`/`omp`/`codex`) pick up new GitHub OAuth
    /// credentials immediately with zero restart.
    private static let gitShimScript = """
    #!/bin/sh
    [ -f "$HOME/.boobox-env.sh" ] && . "$HOME/.boobox-env.sh"
    for _cand in /Library/Developer/CommandLineTools/usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git /usr/bin/git; do
        if [ -x "$_cand" ]; then
            exec "$_cand" "$@"
        fi
    done
    exec /usr/bin/git "$@"
    """

    /// Hot-reloads `$HOME/.boobox-env.sh` right before invoking real `gh` so `gh pr`/`gh auth`
    /// immediately pick up newly connected GitHub credentials inside already-open tabs and agents.
    private static let ghShimScript = """
    #!/bin/sh
    [ -f "$HOME/.boobox-env.sh" ] && . "$HOME/.boobox-env.sh"
    if [ -n "$GH_TOKEN" ] && [ -z "$GH_CONFIG_DIR" ]; then
        export GH_CONFIG_DIR="${TMPDIR:-/tmp}/boobox-gh-cfg"
    fi
    for _cand in /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do
        if [ -x "$_cand" ]; then
            exec "$_cand" "$@"
        fi
    done
    echo "boo_box: gh CLI not found on host" >&2
    exit 127
    """

    private func installCredentialAndCLIShims(in booboxBinDir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: booboxBinDir, withIntermediateDirectories: true)
        let shims: [(String, String)] = [
            ("boobox-git-cred", Self.gitCredShimScript),
            ("git", Self.gitShimScript),
            ("gh", Self.ghShimScript),
        ]
        for (name, body) in shims {
            let url = booboxBinDir.appendingPathComponent(name)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o555)
        }
    }

    /// Writes (or refreshes) a sandbox's private `0600 ~/.boobox-env.sh` and `0555` credential/CLI shims.
    /// Called both on session creation/resume and immediately whenever Connections/Env settings change so
    /// already-open shells and running agents hot-reload new or revoked tokens on the very next command.
    func writeSandboxEnvFile(for sandbox: MacSandboxSession, config cfg: BooBoxConfig) {
        let fm = FileManager.default
        let homeDir = sandbox.homeDir
        guard fm.fileExists(atPath: homeDir.path) else { return }

        let booboxBinDir = homeDir.appendingPathComponent(".boobox-bin", isDirectory: true)
        installCredentialAndCLIShims(in: booboxBinDir)
        let gitCredShimURL = booboxBinDir.appendingPathComponent("boobox-git-cred")

        let envFileURL = homeDir.appendingPathComponent(".boobox-env.sh")
        var mergedEnv: [(key: String, value: String)] = ConnectionsManager.shared.resolvedSandboxEnvEntries(
            config: cfg,
            overrides: sandbox.overrides
        )
        let explicitEntries = cfg.ephemeralSetup.injectEnvIntoMacSandbox ? cfg.ephemeralSetup.cleanedEnvVars : []
        for entry in explicitEntries {
            if let idx = mergedEnv.firstIndex(where: { $0.key == entry.key }) {
                mergedEnv[idx] = entry
            } else {
                mergedEnv.append(entry)
            }
        }

        let activeKeys = Set(mergedEnv.map(\.key))
        var lines: [String] = ["# Auto-generated by boo_box (0600) — hot-reloaded by zsh preexec/precmd"]

        for pair in mergedEnv {
            let escaped = pair.value.replacingOccurrences(of: "'", with: "'\\''")
            lines.append("export \(pair.key)='\(escaped)'")
        }

        // Build dynamic GIT_CONFIG_COUNT entries:
        // - When GitHub is connected: wire session-local `boobox-git-cred` helper (clears host osxkeychain first).
        // - For CoW Overlay sessions: set `core.checkStat=minimal` + `core.trustctime=false` so the first `git status`
        //   on large repos (30k–500k files) compares (mtime, size) instead of re-hashing every tracked file on
        //   APFS->NFS inode mismatch (~20x faster cold `git status`).
        var gitConfigPairs: [(String, String)] = []
        if activeKeys.contains("GH_TOKEN") {
            let helperCmd = "!\(gitCredShimURL.path)"
            gitConfigPairs.append(("credential.https://github.com.helper", ""))
            gitConfigPairs.append(("credential.https://github.com.helper", helperCmd))
            gitConfigPairs.append(("credential.https://gist.github.com.helper", ""))
            gitConfigPairs.append(("credential.https://gist.github.com.helper", helperCmd))
        }
        if sandbox.isOverlay {
            gitConfigPairs.append(("core.checkStat", "minimal"))
            gitConfigPairs.append(("core.trustctime", "false"))
        }
        if !gitConfigPairs.isEmpty {
            lines.append("export GIT_CONFIG_COUNT='\(gitConfigPairs.count)'")
            for (idx, pair) in gitConfigPairs.enumerated() {
                let k = pair.0.replacingOccurrences(of: "'", with: "'\\''")
                let v = pair.1.replacingOccurrences(of: "'", with: "'\\''")
                lines.append("export GIT_CONFIG_KEY_\(idx)='\(k)'")
                lines.append("export GIT_CONFIG_VALUE_\(idx)='\(v)'")
            }
        } else {
            lines.append("unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2 GIT_CONFIG_KEY_3 GIT_CONFIG_VALUE_3 GIT_CONFIG_KEY_4 GIT_CONFIG_VALUE_4 GIT_CONFIG_KEY_5 GIT_CONFIG_VALUE_5")
        }
        // Explicitly unset any known connection env vars that are currently disconnected so live shells drop them immediately.
        var managedKeys: [String] = []
        for preset in ConnectionsManager.connectionPresets {
            if !activeKeys.contains(preset.envVar) { managedKeys.append(preset.envVar) }
            for alias in preset.aliasEnvVars where !activeKeys.contains(alias) {
                managedKeys.append(alias)
            }
        }
        if !managedKeys.isEmpty {
            lines.append("unset \(managedKeys.joined(separator: " "))")
        }

        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(to: envFileURL, atomically: true, encoding: .utf8)
        chmod(envFileURL.path, 0o600)
    }

    /// Refreshes `.boobox-env.sh` + `.boobox-bin/boobox-git-cred` for every currently open macOS sandbox.
    func syncLiveEnvFiles(for sandboxes: [MacSandboxSession], config cfg: BooBoxConfig) {
        for sandbox in sandboxes {
            writeSandboxEnvFile(for: sandbox, config: cfg)
        }
    }

    private func generateSandboxZshrc(for sandbox: MacSandboxSession, config cfg: BooBoxConfig) -> String {
        let shortID = sandbox.shortID
        let wsPath = sandbox.workspaceDir.path.replacingOccurrences(of: "'", with: "'\\''")
        let access = cfg.sandboxAccess
        var hintFunctions: [String] = [
            """
            command_not_found_handler() {
                print -u2 "zsh: command not found: $1"
                print -u2 "\\033[33m[boo_box]\\033[0m Sandbox exposes standard Mac toolchains read-only. If '$1' lives in a custom folder under \\$HOME, add it in Settings (⌘,) → Sandbox Access."
                return 127
            }
            """,
        ]
        if !access.allowDockerSocket {
            hintFunctions.append("""
            docker() {
                command docker "$@"
                local rc=$?
                if (( rc != 0 )); then
                    print -u2 "\\033[33m[boo_box]\\033[0m Host Docker/OrbStack socket is blocked by sandbox. To enable it (with risk warning), open Settings (⌘,) → Sandbox Access."
                fi
                return $rc
            }
            """)
        }
        if !access.allowSSHAgent {
            hintFunctions.append("""
            ssh() {
                command ssh "$@"
                local rc=$?
                if (( rc != 0 )); then
                    print -u2 "\\033[33m[boo_box]\\033[0m Host ~/.ssh and ssh-agent are blocked by sandbox. Enable SSH Agent in Settings (⌘,) → Sandbox Access or inject tokens under Ephemeral Setup."
                fi
                return $rc
            }
            """)
        }
        let hintBlock = hintFunctions.joined(separator: "\n")
        return """
        # Auto-generated by boo_box for isolated macOS session \(shortID)
        if [ "${BOOBOX_CLEAR_BANNER:-0}" = "1" ]; then
            unset BOOBOX_CLEAR_BANNER
            printf '\\033[2J\\033[H'
        fi

        export TERM="${TERM:-xterm-ghostty}"
        if [ -n "${GHOSTTY_RESOURCES_DIR:-}" ] && [ -f "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" ]; then
            source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
        fi

        _boobox_ws='\(wsPath)'
        _boobox_precmd() {
            printf '\\e]7;file://boobox%s\\a' "$PWD"
            if [ "$PWD" = "$_boobox_ws" ]; then
                psvar[1]="workspace"
            elif [[ "$PWD" == "$_boobox_ws/"* ]]; then
                psvar[1]="workspace/${PWD#$_boobox_ws/}"
            else
                psvar[1]="${PWD/#$HOME/~}"
            fi
        }
        zmodload -F zsh/stat b:zstat 2>/dev/null || true
        _boobox_env_mtime=0
        _boobox_reload_env() {
            if [ -f "$HOME/.boobox-env.sh" ]; then
                local -a _mt
                zstat -A _mt +mtime "$HOME/.boobox-env.sh" 2>/dev/null || _mt=()
                if [ -n "${_mt[1]}" ] && [ "${_mt[1]}" != "$_boobox_env_mtime" ]; then
                    _boobox_env_mtime="${_mt[1]}"
                    source "$HOME/.boobox-env.sh"
                fi
            fi
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd _boobox_precmd
        add-zsh-hook precmd _boobox_reload_env
        add-zsh-hook preexec _boobox_reload_env
        PROMPT='%F{cyan}boo_box%f %F{blue}%1v%f %# '
        HISTFILE="$HOME/.zsh_history"
        HISTSIZE=5000
        SAVEHIST=5000
        alias ll='ls -la'

        \(hintBlock)

        _boobox_reload_env
        if [ -f "$HOME/.boobox-setup.sh" ] && [ ! -f "$HOME/.boobox-setup-done" ]; then
            echo "\\033[2m[boo_box] Running ephemeral setup script…\\033[0m"
            if /bin/zsh "$HOME/.boobox-setup.sh"; then
                touch "$HOME/.boobox-setup-done"
            else
                echo "\\033[33m[boo_box] Setup script exited with status $?\\033[0m"
            fi
        fi
        """
    }

    private func buildSandboxPATH(for sandbox: MacSandboxSession, config cfg: BooBoxConfig) -> String {
        let realHome = realHomeURL.path
        let sessHome = sandbox.homeDir.path
        let fm = FileManager.default
        var parts: [String] = []

        // 1. Session-local writable bin dirs FIRST, followed by persistent sandbox tools (`~/boo_box/tools`)
        let sessionBins = [
            "\(sessHome)/.boobox-bin",
            "\(sessHome)/.local/bin",
            "\(sessHome)/.npm-global/bin",
            "\(sessHome)/.bun/bin",
            "\(sessHome)/.local/share/pnpm",
            "\(sessHome)/.cargo/bin",
            "\(sessHome)/go/bin",
        ]
        parts.append(contentsOf: sessionBins)

        if cfg.sandboxAccess.persistentSandboxTools {
            let toolsRoot = cfg.sandboxAccess.resolvedToolsURL()
            for b in GlobalEnvManager.binPaths(at: toolsRoot) where !parts.contains(b) {
                parts.append(b)
            }
        }
        // 2. Host user-managed read-only toolchains BEFORE /opt/homebrew/bin (matches host shell precedence
        //    so e.g. ~/.bun/bin/bun 1.4.4 wins over older Homebrew bun 1.4.0)
        let userPreferredBins = [
            "\(realHome)/.local/bin",
            "\(realHome)/.bun/bin",
        ]
        for b in userPreferredBins where fm.fileExists(atPath: b) && !parts.contains(b) {
            parts.append(b)
        }

        // Pick up latest fnm-managed Node version (XDG ~/.local/share/fnm + ~/Library/Application Support/fnm)
        for fnmRoot in [
            "\(realHome)/.local/share/fnm/node-versions",
            "\(realHome)/Library/Application Support/fnm/node-versions",
        ] {
            if let versions = try? fm.contentsOfDirectory(atPath: fnmRoot).sorted(by: >) {
                for v in versions {
                    let bin = "\(fnmRoot)/\(v)/installation/bin"
                    if fm.fileExists(atPath: bin) && !parts.contains(bin) {
                        parts.append(bin)
                        break
                    }
                }
            }
        }

        // Standard nvm fallback if present
        let nvmNodeVersions = "\(realHome)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmNodeVersions).sorted(by: >) {
            for v in versions {
                let bin = "\(nvmNodeVersions)/\(v)/bin"
                if fm.fileExists(atPath: bin) && !parts.contains(bin) {
                    parts.append(bin)
                    break
                }
            }
        }

        // Include user-configured extra read-only binary dirs from Settings → Sandbox Access
        for rawPath in cfg.sandboxAccess.extraReadPaths {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let resolved = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue, !parts.contains(resolved) {
                parts.append(resolved)
            }
        }

        // 3. Remaining host toolchains & Homebrew / system bins
        let candidates = [
            "\(realHome)/.cargo/bin",
            "\(realHome)/go/bin",
            "\(realHome)/.deno/bin",
            "\(realHome)/.volta/bin",
            "\(realHome)/Library/pnpm",
            "\(realHome)/.pyenv/shims",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/Library/Developer/CommandLineTools/usr/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        for c in candidates where !parts.contains(c) {
            parts.append(c)
        }
        return parts.joined(separator: ":")
    }

    private func resolveGhosttyResourcesDir() -> String? {
        if let env = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"], !env.isEmpty {
            return env
        }
        let candidates: [String?] = [
            Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
        ]
        for case let path? in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func applyQuarantineAttribute(to path: String) {
        let value = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));boo_box;"
        _ = value.withCString { ptr in
            setxattr(path, "com.apple.quarantine", ptr, strlen(ptr), 0, 0)
        }
    }

    private func sbplEscape(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
