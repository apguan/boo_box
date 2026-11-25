import Foundation

struct GlobalEnvDirectory: Identifiable, Codable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let displayPath: String
    let binaries: [String]
}

struct GlobalEnvInventory: Codable, Equatable, Sendable {
    let envRoot: String
    let displayRoot: String
    let directories: [GlobalEnvDirectory]

    var totalBinaries: Int {
        directories.reduce(0) { $0 + $1.binaries.count }
    }

    static let empty = GlobalEnvInventory(envRoot: "", displayRoot: "~/boo_box/env", directories: [])
}

/// Manages boo_box's shared global sandbox environment (`~/boo_box/env`).
///
/// Design:
/// - Any install script (`curl | sh`, `npm i -g`, `bun add -g`, `uv tool install`, `go install`,
///   `cargo install`, tarballs, etc.) runs inside a Seatbelt sandbox with `HOME=~/boo_box/env`.
/// - Every directory under `~/boo_box/env` containing executables is automatically discovered,
///   listed by directory path, and prepended to `PATH` across all sandbox sessions.
final class GlobalEnvManager: @unchecked Sendable {
    static let shared = GlobalEnvManager()

    private init() {}

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedBins: (root: String, sig: String, paths: [String])?

    static func invalidateBinPathCache() {
        cacheLock.lock()
        cachedBins = nil
        cacheLock.unlock()
    }

    private static func fastDirectorySignature(at envRoot: URL) -> String {
        let e = envRoot.path
        var sigParts: [String] = []
        func statToken(_ p: String) -> String {
            var st = stat()
            guard lstat(p, &st) == 0 else { return "-" }
            return "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
        sigParts.append(statToken(e))
        if let top = try? FileManager.default.contentsOfDirectory(atPath: e) {
            for name in top.sorted() where !skipDirNames.contains(name) {
                let child = "\(e)/\(name)"
                sigParts.append("\(name):\(statToken(child))")
                let binSub = "\(child)/bin"
                let binTok = statToken(binSub)
                if binTok != "-" {
                    sigParts.append("\(name)/bin:\(binTok)")
                }
            }
        }
        return sigParts.joined(separator: "|")
    }
    private static let skipDirNames: Set<String> = [
        "node_modules", ".git", ".tmp", ".cache", "cache", "state", ".boobox-bin",
        "__pycache__", "site-packages", "include", "man", "doc", "docs",
        "test", "tests", "pkg", "src", "share", "lib", "libexec",
    ]

    /// Fast native scan returning all executable bin directories under `envRoot` (plus standard roots)
    /// so newly-installed toolchains appear on sandbox `PATH` automatically without hardcoding tools.
    static func binPaths(at envRoot: URL) -> [String] {
        let e = envRoot.path
        let sig = fastDirectorySignature(at: envRoot)
        cacheLock.lock()
        if let cached = cachedBins, cached.root == e, cached.sig == sig {
            let out = cached.paths
            cacheLock.unlock()
            return out
        }
        cacheLock.unlock()

        var result: [String] = []
        var seen = Set<String>()

        func add(_ p: String) {
            if !seen.contains(p) {
                seen.insert(p)
                result.append(p)
            }
        }
        // Dynamically discover any bin/shims or depth<=2 executable folders inside envRoot
        let fm = FileManager.default
        func walk(_ dir: URL, depth: Int) {
            guard depth <= 4 else { return }
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { return }

            let name = dir.lastPathComponent
            let isBinDir = (name == "bin" || name == "shims" || name == "pnpm") && dir.path != e
            let isToolDir = (depth == 1 || depth == 2) && dir.path != e && !name.hasPrefix(".tmp")
            var hasExec = false
            var subdirs: [URL] = []

            for item in items {
                let itemName = item.lastPathComponent
                let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDir = vals?.isDirectory == true
                let isLink = vals?.isSymbolicLink == true
                if isDir && !isLink {
                    if !skipDirNames.contains(itemName) {
                        subdirs.append(item)
                    }
                } else if (isBinDir || isToolDir) && !itemName.hasPrefix(".") && itemName != "boo" {
                    if !hasExec && fm.isExecutableFile(atPath: item.path) {
                        hasExec = true
                    }
                }
            }
            if hasExec {
                add(dir.path)
            }
            for sub in subdirs {
                walk(sub, depth: depth + 1)
            }
        }

        walk(envRoot, depth: 0)

        // Always include standard default bin roots so tools installed mid-session resolve immediately
        for standard in [
            "\(e)/bin",
            "\(e)/.local/bin",
            "\(e)/.npm-global/bin",
            "\(e)/.bun/bin",
            "\(e)/.local/share/pnpm",
            "\(e)/.cargo/bin",
            "\(e)/go/bin",
            "\(e)/.deno/bin",
        ] {
            add(standard)
        }
        cacheLock.lock()
        cachedBins = (root: e, sig: sig, paths: result)
        cacheLock.unlock()
        return result
    }

    /// Environment variables routing global installs from inside any sandbox directly into `~/boo_box/env`.
    static func environmentVariables(at envRoot: URL, realHome: String) -> [String: String] {
        let e = envRoot.path
        let fm = FileManager.default
        var env: [String: String] = [
            "BOOBOX_ENV": e,
            "BOOBOX_TOOLS_DIR": e,
            "PREFIX": e,
            "npm_config_prefix": "\(e)/.npm-global",
            "BUN_INSTALL": "\(e)/.bun",
            "PNPM_HOME": "\(e)/.local/share/pnpm",
            "PYTHONUSERBASE": "\(e)/.local",
            "UV_TOOL_DIR": "\(e)/.local/share/uv/tools",
            "UV_TOOL_BIN_DIR": "\(e)/.local/bin",
            "UV_PYTHON_INSTALL_DIR": "\(e)/.local/share/uv/python",
            "UV_PYTHON_BIN_DIR": "\(e)/.local/bin",
            "GOPATH": "\(e)/go",
            "CARGO_INSTALL_ROOT": "\(e)/.cargo",
            "DENO_INSTALL": "\(e)/.deno",
        ]
        if fm.fileExists(atPath: "\(e)/.rustup") {
            env["RUSTUP_HOME"] = "\(e)/.rustup"
        } else {
            env["RUSTUP_HOME"] = "\(realHome)/.rustup"
        }
        if fm.fileExists(atPath: "\(e)/goroot/bin/go") {
            env["GOROOT"] = "\(e)/goroot"
        }
        return env
    }

    func resolveHelperURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/boobox-env"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("scripts/boobox-env"),
        ]
        for case let url? in candidates {
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    func ensureLayout(at envRoot: URL) {
        let fm = FileManager.default
        for sub in [
            "bin", ".local/bin", ".npm-global/bin", ".bun/bin",
            ".local/share/pnpm", ".cargo/bin", "go/bin", ".config", ".cache", ".tmp",
        ] {
            try? fm.createDirectory(at: envRoot.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        if let helper = resolveHelperURL() {
            let linkURL = envRoot.appendingPathComponent("bin/boo")
            let existing = try? fm.destinationOfSymbolicLink(atPath: linkURL.path)
            if existing != helper.path {
                try? fm.removeItem(at: linkURL)
                try? fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: helper.path)
            }
        }
    }

    func fetchInventory(at envRoot: URL, completion: @escaping @MainActor @Sendable (GlobalEnvInventory) -> Void) {
        ensureLayout(at: envRoot)
        guard let helper = resolveHelperURL() else {
            DispatchQueue.main.async { completion(.empty) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = helper
            proc.arguments = ["tools", "--json"]
            var env = ProcessInfo.processInfo.environment
            env["BOOBOX_ENV"] = envRoot.path
            proc.environment = env
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0,
                   let parsed = try? JSONDecoder().decode(GlobalEnvInventory.self, from: data) {
                    DispatchQueue.main.async { completion(parsed) }
                    return
                }
            } catch {}
            DispatchQueue.main.async { completion(.empty) }
        }
    }

    /// Runs an arbitrary install script inside a Seatbelt sandbox targeting `envRoot` (`HOME=envRoot`),
    /// returning combined stdout/stderr output.
    func runInstallScript(
        _ rawScript: String,
        at envRoot: URL,
        completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
    ) {
        let script = rawScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(MacSandboxError.cloneFailed("Enter an install script to run")))
            }
            return
        }
        runHelper(args: ["env", "run", script], at: envRoot, completion: completion)
    }

    func removeDirectory(
        _ dirPath: String,
        at envRoot: URL,
        completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
    ) {
        runHelper(args: ["env", "rm", dirPath], at: envRoot, completion: completion)
    }

    func reset(
        at envRoot: URL,
        completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
    ) {
        runHelper(args: ["env", "reset"], at: envRoot, completion: completion)
    }

    private func runHelper(
        args: [String],
        at envRoot: URL,
        completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
    ) {
        ensureLayout(at: envRoot)
        guard let helper = resolveHelperURL() else {
            DispatchQueue.main.async {
                completion(.failure(MacSandboxError.cloneFailed("boobox-env helper not found")))
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = helper
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["BOOBOX_ENV"] = envRoot.path
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                Self.invalidateBinPathCache()
                let outStr = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let errStr = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = [outStr, errStr].filter { !$0.isEmpty }.joined(separator: "\n")
                if proc.terminationStatus == 0 {
                    DispatchQueue.main.async {
                        completion(.success(combined.isEmpty ? "Completed cleanly" : combined))
                    }
                } else {
                    let msg = combined.isEmpty ? "Script exited with status \(proc.terminationStatus)" : combined
                    DispatchQueue.main.async {
                        completion(.failure(MacSandboxError.cloneFailed(msg)))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}
