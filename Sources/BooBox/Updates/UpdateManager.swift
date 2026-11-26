import AppKit
import Combine
import Foundation

struct AvailableUpdate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case releaseAsset(downloadURL: URL, assetName: String, releaseNotes: String)
        case releasePageOnly(releaseNotes: String)
        case gitCommit(sha: String, message: String, localRepoPath: String?)
    }

    let version: String
    let htmlURL: URL
    let publishedAt: String?
    let kind: Kind

    var canAutoInstall: Bool {
        switch kind {
        case .releaseAsset:
            return true
        case .gitCommit(_, _, let repo):
            return repo != nil
        case .releasePageOnly:
            return false
        }
    }

    var installButtonTitle: String {
        switch kind {
        case .releaseAsset:
            return "Install & Restart"
        case .gitCommit(_, _, let repo):
            return repo != nil ? "Pull, Rebuild & Restart" : "View Commit"
        case .releasePageOnly:
            return "Open Release"
        }
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(AvailableUpdate)
    case downloading(progress: Double, version: String)
    case installing(message: String)
    case error(String)
}

/// Checks `apguan/boo_box` on GitHub for new releases (with fallback to `main` commit tracking)
/// and performs verified atomic `.app` self-updates or clean local-checkout rebuilds.
/// Respects `GeneralConfig.autoUpdateEnabled` — when toggled OFF, performs zero background network checks.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var state: UpdateState = .idle
    @Published var dismissedVersion: String?

    let repoSlug: String
    let currentVersion: String
    let currentCommit: String

    private var periodicTimer: Timer?
    private var launchCheckWorkItem: DispatchWorkItem?
    private var configCancellable: AnyCancellable?
    private var isChecking = false
    private let checkIntervalSeconds: TimeInterval = 6 * 60 * 60 // 6 hours

    private init() {
        let info = Bundle.main.infoDictionary
        self.repoSlug = (info?["BooBoxGitRepo"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "apguan/boo_box"
        self.currentVersion = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "0.2.0"
        self.currentCommit = (info?["BooBoxGitCommit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? ""

        self.configCancellable = BooBoxConfigManager.shared.$config
            .map { $0.general.autoUpdateEnabled }
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.scheduleAutomaticChecks(triggerSoon: false)
                } else {
                    self.stopAutomaticChecks()
                }
            }
    }

    var shouldShowBanner: Bool {
        guard case .available(let update) = state else { return false }
        return dismissedVersion != update.version
    }

    var repoURL: URL {
        URL(string: "https://github.com/\(repoSlug)")!
    }

    func dismissBanner(for version: String) {
        dismissedVersion = version
    }

    func startIfEnabled() {
        guard BooBoxConfigManager.shared.config.general.autoUpdateEnabled else {
            stopAutomaticChecks()
            return
        }
        scheduleAutomaticChecks(triggerSoon: true)
    }

    func stopAutomaticChecks() {
        launchCheckWorkItem?.cancel()
        launchCheckWorkItem = nil
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    private func scheduleAutomaticChecks(triggerSoon: Bool) {
        stopAutomaticChecks()
        if triggerSoon {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self,
                          BooBoxConfigManager.shared.config.general.autoUpdateEnabled else { return }
                    self.checkForUpdates(userInitiated: false)
                }
            }
            launchCheckWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
        }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      BooBoxConfigManager.shared.config.general.autoUpdateEnabled else { return }
                self.checkForUpdates(userInitiated: false)
            }
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        guard !isChecking else { return }
        if !userInitiated && !BooBoxConfigManager.shared.config.general.autoUpdateEnabled {
            return
        }
        isChecking = true
        if userInitiated {
            dismissedVersion = nil
        }
        state = .checking

        let slug = repoSlug
        let localVer = currentVersion
        let localCommit = currentCommit
        let autoDownload = BooBoxConfigManager.shared.config.general.autoDownloadUpdates

        Task.detached(priority: .utility) { [weak self] in
            let outcome = await Self.fetchLatestUpdate(
                repoSlug: slug,
                currentVersion: localVer,
                currentCommit: localCommit
            )
            await MainActor.run {
                guard let self else { return }
                self.isChecking = false
                switch outcome {
                case .success(let maybeUpdate):
                    if let update = maybeUpdate {
                        self.state = .available(update)
                        if autoDownload && !userInitiated, case .releaseAsset = update.kind {
                            self.installAvailableUpdate()
                        }
                    } else {
                        self.state = .upToDate(checkedAt: Date())
                    }
                case .failure(let err):
                    if userInitiated {
                        self.state = .error(err.localizedDescription)
                    } else {
                        // Silent on background network/offline failures so offline sandboxes stay quiet
                        self.state = .idle
                    }
                }
            }
        }
    }

    func installAvailableUpdate() {
        guard case .available(let update) = state else { return }
        switch update.kind {
        case .releaseAsset(let downloadURL, _, _):
            installReleaseAsset(update: update, downloadURL: downloadURL)
        case .gitCommit(_, _, let localRepoPath):
            if let repoPath = localRepoPath {
                installFromLocalGitCheckout(update: update, repoPath: repoPath)
            } else {
                NSWorkspace.shared.open(update.htmlURL)
            }
        case .releasePageOnly:
            NSWorkspace.shared.open(update.htmlURL)
        }
    }

    // MARK: - GitHub API Query (Releases Primary, `main` Commit Fallback)

    private struct GHRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let body: String?
        let published_at: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    private struct GHCommit: Decodable {
        struct CommitDetail: Decodable {
            struct Committer: Decodable {
                let date: String?
            }
            let message: String
            let committer: Committer?
        }
        let sha: String
        let html_url: String
        let commit: CommitDetail
    }

    private nonisolated static func githubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    private nonisolated static func githubRequest(url: URL, userAgentVersion: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("boo_box/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    private nonisolated static func fetchLatestUpdate(
        repoSlug: String,
        currentVersion: String,
        currentCommit: String
    ) async -> Result<AvailableUpdate?, Error> {
        let session = githubSession()
        defer { session.invalidateAndCancel() }

        // 1. Check GitHub Releases first
        if let relURL = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest") {
            do {
                let (data, resp) = try await session.data(for: githubRequest(url: relURL, userAgentVersion: currentVersion))
                if let http = resp as? HTTPURLResponse {
                    if http.statusCode == 200 {
                        let rel = try JSONDecoder().decode(GHRelease.self, from: data)
                        if rel.draft != true && rel.prerelease != true {
                            let remoteVer = normalizeVersion(rel.tag_name)
                            if isVersion(remoteVer, newerThan: normalizeVersion(currentVersion)),
                               let pageURL = URL(string: rel.html_url) {
                                let notes = (rel.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                if let zipAsset = pickMacZipAsset(from: rel.assets ?? []),
                                   let dlURL = URL(string: zipAsset.browser_download_url) {
                                    return .success(AvailableUpdate(
                                        version: "v\(remoteVer)",
                                        htmlURL: pageURL,
                                        publishedAt: rel.published_at,
                                        kind: .releaseAsset(downloadURL: dlURL, assetName: zipAsset.name, releaseNotes: notes)
                                    ))
                                }
                                return .success(AvailableUpdate(
                                    version: "v\(remoteVer)",
                                    htmlURL: pageURL,
                                    publishedAt: rel.published_at,
                                    kind: .releasePageOnly(releaseNotes: notes)
                                ))
                            }
                            return .success(nil)
                        }
                    } else if http.statusCode != 404 {
                        return .failure(NSError(
                            domain: "BooBox.Updates",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "GitHub API returned HTTP \(http.statusCode)"]
                        ))
                    }
                }
            } catch {
                return .failure(error)
            }
        }

        // 2. No GitHub Release published yet -> fall back to `main` branch commit comparison
        guard let commitURL = URL(string: "https://api.github.com/repos/\(repoSlug)/commits/main") else {
            return .success(nil)
        }
        do {
            let (data, resp) = try await session.data(for: githubRequest(url: commitURL, userAgentVersion: currentVersion))
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                return .failure(NSError(
                    domain: "BooBox.Updates",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub commit check failed (HTTP \(code))"]
                ))
            }
            let latest = try JSONDecoder().decode(GHCommit.self, from: data)
            let shortRemote = String(latest.sha.prefix(7)).lowercased()
            let shortLocal = String(currentCommit.prefix(7)).lowercased()

            guard !shortLocal.isEmpty, shortRemote != shortLocal else {
                return .success(nil)
            }

            let localRepo = resolveLocalRepoPath()
            // If we have the local git repo and remote SHA is already an ancestor of local HEAD
            // (i.e. local build is ahead of origin/main), report up-to-date!
            if let repo = localRepo, gitIsAncestor(sha: latest.sha, in: repo) {
                return .success(nil)
            }

            let firstLine = latest.commit.message
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? "New commit on main"
            guard let pageURL = URL(string: latest.html_url) else {
                return .success(nil)
            }
            return .success(AvailableUpdate(
                version: "main @ \(shortRemote)",
                htmlURL: pageURL,
                publishedAt: latest.commit.committer?.date,
                kind: .gitCommit(sha: shortRemote, message: firstLine, localRepoPath: localRepo)
            ))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func pickMacZipAsset(from assets: [GHRelease.Asset]) -> GHRelease.Asset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        if let arm = zips.first(where: { $0.name.lowercased().contains("arm64") || $0.name.lowercased().contains("macos") }) {
            return arm
        }
        return zips.first { $0.name.lowercased().contains("boo_box") || $0.name.lowercased().contains("boobox") } ?? zips.first
    }

    nonisolated static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        if let dash = s.firstIndex(of: "-") {
            s = String(s[..<dash])
        }
        return s
    }

    nonisolated static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    private nonisolated static func resolveLocalRepoPath() -> String? {
        let fm = FileManager.default
        let recorded = NSHomeDirectory() + "/boo_box/.repo-path"
        var candidates: [String] = []
        if let text = try? String(contentsOfFile: recorded, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { candidates.append(trimmed) }
        }
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path
        candidates.append(bundleParent)

        for dir in candidates {
            if fm.fileExists(atPath: dir + "/.git") && fm.isExecutableFile(atPath: dir + "/scripts/bundle-app.sh") {
                return dir
            }
        }
        return nil
    }

    private nonisolated static func gitIsAncestor(sha: String, in repoPath: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["--no-optional-locks", "-C", repoPath, "merge-base", "--is-ancestor", sha, "HEAD"]
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

    // MARK: - Verified Atomic `.zip` Release Self-Update

    private func installReleaseAsset(update: AvailableUpdate, downloadURL: URL) {
        let targetAppURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard targetAppURL.pathExtension == "app" else {
            state = .error("Cannot self-update outside a .app bundle. Open GitHub to download manually.")
            return
        }
        let parentDir = targetAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            state = .error("App folder \(parentDir.path) is not writable. Move boo_box.app to /Applications or update manually.")
            return
        }

        state = .downloading(progress: 0.0, version: update.version)
        let versionLabel = update.version

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let updatesRoot = URL(fileURLWithPath: NSHomeDirectory() + "/boo_box/updates", isDirectory: true)
                let fm = FileManager.default
                try fm.createDirectory(at: updatesRoot, withIntermediateDirectories: true)

                let safeTag = versionLabel.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
                let zipURL = updatesRoot.appendingPathComponent("boo_box-\(safeTag).zip")
                let stageDir = updatesRoot.appendingPathComponent("stage-\(safeTag)-\(UUID().uuidString.prefix(6))", isDirectory: true)
                try? fm.removeItem(at: zipURL)
                try? fm.removeItem(at: stageDir)

                let session = Self.githubSession()
                defer { session.invalidateAndCancel() }
                let (bytes, resp) = try await session.bytes(from: downloadURL)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw NSError(domain: "BooBox.Updates", code: -10, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
                }
                let expected = max(resp.expectedContentLength, 1)
                fm.createFile(atPath: zipURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: zipURL)
                var received: Int64 = 0
                var chunk = Data()
                chunk.reserveCapacity(65536)
                var lastReported: Double = -1

                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 65536 {
                        try handle.write(contentsOf: chunk)
                        received += Int64(chunk.count)
                        chunk.removeAll(keepingCapacity: true)
                        let pct = min(0.99, Double(received) / Double(expected))
                        if pct - lastReported >= 0.03 {
                            lastReported = pct
                            await MainActor.run {
                                self?.state = .downloading(progress: pct, version: versionLabel)
                            }
                        }
                    }
                }
                if !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()

                await MainActor.run {
                    self?.state = .installing(message: "Verifying \(versionLabel)…")
                }

                try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
                try Self.runProcess("/usr/bin/ditto", ["-xk", zipURL.path, stageDir.path])

                guard let extractedApp = Self.findAppBundle(in: stageDir) else {
                    throw NSError(domain: "BooBox.Updates", code: -11, userInfo: [NSLocalizedDescriptionKey: "Release archive did not contain boo_box.app"])
                }

                // Verify bundle ID & codesign integrity before replacing running app
                let plistURL = extractedApp.appendingPathComponent("Contents/Info.plist")
                guard let plistData = try? Data(contentsOf: plistURL),
                      let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                      (plist["CFBundleIdentifier"] as? String) == "dev.boo-box.app" else {
                    throw NSError(domain: "BooBox.Updates", code: -12, userInfo: [NSLocalizedDescriptionKey: "Bundle identifier mismatch in downloaded update"])
                }
                try Self.runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", extractedApp.path])

                await MainActor.run {
                    self?.state = .installing(message: "Swapping app & restarting…")
                }

                let pid = ProcessInfo.processInfo.processIdentifier
                try Self.launchAtomicSwapScript(
                    parentPID: pid,
                    stagedAppPath: extractedApp.path,
                    targetAppPath: targetAppURL.path,
                    cleanupPaths: [zipURL.path, stageDir.path]
                )

                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self?.state = .error("Update failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Local Git Checkout Rebuild Update (When Tracking `main` Commits)

    private func installFromLocalGitCheckout(update: AvailableUpdate, repoPath: String) {
        state = .installing(message: "Checking local git repo…")
        let targetAppURL = Bundle.main.bundleURL.resolvingSymlinksInPath()

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let dirtyOut = try Self.runProcessOutput("/usr/bin/git", ["--no-optional-locks", "-C", repoPath, "status", "--porcelain"])
                if !dirtyOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw NSError(
                        domain: "BooBox.Updates",
                        code: -20,
                        userInfo: [NSLocalizedDescriptionKey: "Local repo at \(repoPath) has uncommitted changes. Commit or stash them before auto-updating from main."]
                    )
                }

                await MainActor.run {
                    self?.state = .installing(message: "Pulling \(update.version) & building release…")
                }

                try Self.runProcess("/usr/bin/git", ["-C", repoPath, "pull", "--ff-only", "origin", "main"])
                try Self.runProcess("/bin/bash", [repoPath + "/scripts/bundle-app.sh", "release"])

                let builtApp = repoPath + "/build/boo_box.app"
                let pid = ProcessInfo.processInfo.processIdentifier
                let relaunchPath = FileManager.default.fileExists(atPath: builtApp) ? builtApp : targetAppURL.path

                let helper = """
                #!/bin/sh
                PID=\(pid)
                i=0
                while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 100 ]; do
                    sleep 0.1
                    i=$((i + 1))
                done
                /usr/bin/open -n "\(relaunchPath)"
                """
                let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("boobox-relaunch-\(UUID().uuidString.prefix(8)).sh")
                try helper.write(to: scriptURL, atomically: true, encoding: .utf8)
                chmod(scriptURL.path, 0o700)

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                proc.arguments = ["-c", "\"\(scriptURL.path)\" >/dev/null 2>&1 &"]
                try proc.run()

                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self?.state = .error(error.localizedDescription)
                }
            }
        }
    }

    private nonisolated static func findAppBundle(in root: URL) -> URL? {
        let fm = FileManager.default
        if let direct = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if let app = direct.first(where: { $0.pathExtension == "app" }) {
                return app
            }
            for sub in direct {
                if let nested = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil),
                   let app = nested.first(where: { $0.pathExtension == "app" }) {
                    return app
                }
            }
        }
        return nil
    }

    private nonisolated static func launchAtomicSwapScript(
        parentPID: Int32,
        stagedAppPath: String,
        targetAppPath: String,
        cleanupPaths: [String]
    ) throws {
        func shQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let backupPath = targetAppPath + ".update-bak"
        let cleanupCmds = cleanupPaths.map { "rm -rf \(shQuote($0))" }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        PID=\(parentPID)
        TARGET=\(shQuote(targetAppPath))
        STAGED=\(shQuote(stagedAppPath))
        BACKUP=\(shQuote(backupPath))

        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 100 ]; do
            sleep 0.1
            i=$((i + 1))
        done

        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP"; then
            if mv "$STAGED" "$TARGET"; then
                rm -rf "$BACKUP"
                if [ -x "$TARGET/Contents/Resources/bin/boo" ]; then
                    mkdir -p "$HOME/.local/bin"
                    cp "$TARGET/Contents/Resources/bin/boo" "$HOME/.local/bin/boo"
                    chmod +x "$HOME/.local/bin/boo"
                fi
                mkdir -p "$HOME/boo_box"
                printf '%s\\n' "$TARGET" > "$HOME/boo_box/.app-path"
            else
                mv "$BACKUP" "$TARGET"
            fi
        fi
        \(cleanupCmds)
        /usr/bin/open -n "$TARGET"
        rm -f "$0"
        """
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boobox-swap-\(UUID().uuidString.prefix(8)).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        chmod(scriptURL.path, 0o700)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "\"\(scriptURL.path)\" </dev/null >/dev/null 2>&1 &"]
        try proc.run()
    }

    private nonisolated static func runProcess(_ path: String, _ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "BooBox.Updates",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "\(path) exited \(proc.terminationStatus)" : msg]
            )
        }
    }

    private nonisolated static func runProcessOutput(_ path: String, _ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
