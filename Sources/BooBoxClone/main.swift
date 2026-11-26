import Darwin
import Foundation

/// High-speed parallel APFS copy-on-write project cloner + warm-pool delta sync (`boobox-clone`).
///
/// Usage:
///   boobox-clone <srcDir> <dstDir>
///     [--no-env]
///     [--include-ignored]
///     [--quiet]
///     [--write-meta <metaFile>]
///     [--warm-pop <warmDir> --warm-meta <warmMetaFile>]
///     [--delta-in-place <metaFile>]
///     [--preserve-source-dir <canonicalSourceDir>]
///
/// Cold run (Git repo): uses `git ls-files --cached --others --exclude-standard`
/// + shallow `.env*` / `.worktreeinclude` discovery + 8-thread native `clonefile(2)`
/// with zero extra SSD blocks, and writes a sidecar fingerprint (`--write-meta`).
///
/// Repeat run (`--warm-pop`): atomically claims a pre-warmed APFS clone via `rename(2)` (<1 ms)
/// and applies an exact Git + `.env*` delta sync (~20-500 ms even on 70k-file monorepos).

private let heavyDirNames: Set<String> = [
    "node_modules", ".next", ".turbo", ".wrangler", ".cache",
    ".venv", "venv", "target", ".build", "__pycache__", ".svelte-kit", ".nuxt",
    ".parcel-cache", ".vite", ".angular", ".nx", ".gradle",
    ".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox", ".logs",
]

private let envTemplateAllowlist: Set<String> = [
    ".env.example", ".env.sample", ".env.template", ".env.dist",
]

private struct CloneMeta: Codable, Equatable {
    let version: Int
    let sourceDir: String
    let headCommit: String
    let gitStatSig: String
    let dirtyFiles: [String]
    let envFiles: [String: String]
    let excludeEnv: Bool
    let includeIgnored: Bool
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

nonisolated(unsafe) private var cloneCancelled: sig_atomic_t = 0
private func handleCloneCancelSignal(_: Int32) {
    cloneCancelled = 1
}
signal(SIGINT, handleCloneCancelSignal)
signal(SIGTERM, handleCloneCancelSignal)
private func isSecretEnvFile(_ filename: String) -> Bool {
    let lower = filename.lowercased()
    return (lower == ".env" || lower.hasPrefix(".env.")) && !envTemplateAllowlist.contains(lower)
}

private func statSignature(of path: String) -> String? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return "\(st.st_mode):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_size)"
}

private func runGit(_ arguments: [String], in dir: String, stdinData: Data? = nil) -> (Int32, Data) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["--no-optional-locks", "-C", dir] + arguments
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice

    var inPipe: Pipe?
    if stdinData != nil {
        let pipe = Pipe()
        proc.standardInput = pipe
        inPipe = pipe
    }

    do {
        try proc.run()
    } catch {
        return (-1, Data())
    }

    if let stdinData, let inPipe {
        DispatchQueue.global(qos: .userInitiated).async {
            inPipe.fileHandleForWriting.write(stdinData)
            try? inPipe.fileHandleForWriting.close()
        }
    }

    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, data)
}

private func splitNulUTF8(_ data: Data) -> [String] {
    var results: [String] = []
    results.reserveCapacity(128)
    data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        let count = raw.count
        var start = 0
        for i in 0..<count {
            if base[i] == 0 {
                if i > start {
                    let slice = UnsafeBufferPointer(start: base.advanced(by: start), count: i - start)
                    results.append(String(decoding: slice, as: UTF8.self))
                }
                start = i + 1
            }
        }
    }
    return results
}

private func runGitLsFiles(in srcDir: String) -> [String]? {
    let (status, data) = runGit(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: srcDir)
    guard status == 0 else { return nil }
    return splitNulUTF8(data)
}

private func gitHeadCommit(in srcDir: String) -> String {
    // Fast path: resolve `.git/HEAD` (+ loose ref) directly in Swift (~0.05 ms, zero subprocess fork)
    let gitDir = srcDir + "/.git"
    var st = stat()
    if lstat(gitDir, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR,
       let headRaw = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) {
        let head = headRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref:") {
            let refRel = head.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            if !refRel.isEmpty,
               let refRaw = try? String(contentsOfFile: gitDir + "/" + refRel, encoding: .utf8) {
                let sha = refRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                if sha.count == 40 {
                    return sha
                }
            }
        } else if head.count == 40 {
            return head
        }
    }
    let (status, data) = runGit(["rev-parse", "--verify", "HEAD"], in: srcDir)
    guard status == 0 else { return "" }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Parses `git status --porcelain=v1 -z --no-renames` into sorted unique relative paths.
/// Trailing `/` is preserved on untracked directories so delta-sync knows to mirror the folder.
private func gitStatusDirtyPaths(in srcDir: String) -> [String]? {
    let (status, data) = runGit(["status", "--porcelain=v1", "-z", "--no-renames"], in: srcDir)
    guard status == 0 else { return nil }

    let tokens = splitNulUTF8(data)
    var paths = Set<String>()
    var idx = 0
    while idx < tokens.count {
        let entry = tokens[idx]
        idx += 1
        guard entry.count >= 4 else { continue }
        let statusChars = entry.prefix(2)
        let path = String(entry.dropFirst(3))
        if !path.isEmpty {
            paths.insert(path)
        }
        // Defensively consume the second NUL-delimited path if git ever reports R or C
        if statusChars.contains("R") || statusChars.contains("C") {
            if idx < tokens.count {
                let orig = tokens[idx]
                idx += 1
                if !orig.isEmpty {
                    paths.insert(orig)
                }
            }
        }
    }
    return paths.sorted()
}

private func gitCommittedDiffPaths(in srcDir: String, from oldHead: String, to newHead: String) -> [String]? {
    if oldHead == newHead { return [] }
    guard !oldHead.isEmpty, !newHead.isEmpty else { return nil }
    let (status, data) = runGit(["diff", "--name-only", "-z", oldHead, newHead], in: srcDir)
    guard status == 0 else { return nil }
    return splitNulUTF8(data)
}

private func gitCheckIgnored(paths: [String], in srcDir: String) -> Set<String> {
    guard !paths.isEmpty else { return [] }
    var payload = Data()
    for p in paths {
        payload.append(contentsOf: p.utf8)
        payload.append(0)
    }
    let (status, data) = runGit(["check-ignore", "-z", "--stdin"], in: srcDir, stdinData: payload)
    // git check-ignore exits 0 if at least one path is ignored, 1 if none are ignored
    guard status == 0 else { return [] }
    return Set(splitNulUTF8(data))
}

/// Fast stat signature of `.git` metadata so we only re-clone `.git` when branch/HEAD/index/refs actually changed.
private func computeGitStatSignature(in srcDir: String) -> String {
    let gitPath = srcDir + "/.git"
    var st = stat()
    guard lstat(gitPath, &st) == 0 else { return "" }
    if (st.st_mode & S_IFMT) != S_IFDIR {
        let content = (try? String(contentsOfFile: gitPath, encoding: .utf8)) ?? ""
        return "file:\(statSignature(of: gitPath) ?? ""):\(content)"
    }

    var parts: [String] = []
    let headPath = gitPath + "/HEAD"
    let headContent = ((try? String(contentsOfFile: headPath, encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    parts.append("H=\(headContent)")

    var watchFiles = [
        headPath,
        gitPath + "/index",
        gitPath + "/packed-refs",
        gitPath + "/MERGE_HEAD",
        gitPath + "/REBASE_HEAD",
        gitPath + "/CHERRY_PICK_HEAD",
        gitPath + "/config",
        gitPath + "/info/exclude",
        gitPath + "/logs/HEAD",
    ]
    if headContent.hasPrefix("ref:") {
        let refRel = headContent.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        if !refRel.isEmpty {
            watchFiles.append(gitPath + "/" + refRel)
        }
    }

    for f in watchFiles {
        if let sig = statSignature(of: f) {
            parts.append(sig)
        } else {
            parts.append("-")
        }
    }
    return parts.joined(separator: "|")
}

/// Fast `d_type`-aware `opendir`/`readdir` helper — avoids `lstat()` on regular non-dot files.
private func listDirEntries(at absDir: String) -> [(name: String, dType: UInt8)] {
    guard let dir = opendir(absDir) else { return [] }
    defer { closedir(dir) }
    var entries: [(String, UInt8)] = []
    entries.reserveCapacity(32)
    while let ptr = readdir(dir) {
        let dType = ptr.pointee.d_type
        let nameLen = Int(ptr.pointee.d_namlen)
        let name: String = withUnsafePointer(to: &ptr.pointee.d_name) { namePtr in
            namePtr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { buf in
                String(decoding: UnsafeBufferPointer(start: buf, count: nameLen), as: UTF8.self)
            }
        }
        if name == "." || name == ".." { continue }
        entries.append((name, dType))
    }
    return entries
}

/// Discovers `.worktreeinclude` paths AND all non-heavy dotfiles / dotfolders
/// (e.g. `.env*`, `.opencode/`, `.zed/`, `.claude/`, `.omp/`, `.vscode/`, `.ori/`, `.codegraph`, `.dev.vars`)
/// using zero-stat `readdir` (`d_type`) so devex matches the real repo with ~15ms scan overhead.
private func discoverExtraLocalFilesWithSig(in srcDir: String, excludeEnv: Bool) -> [String: String] {
    var found: [String: String] = [:]

    func recordFileOrLink(rel: String, abs: String, baseName: String) {
        if excludeEnv && isSecretEnvFile(baseName) { return }
        var st = stat()
        guard lstat(abs, &st) == 0 else { return }
        let ftype = st.st_mode & S_IFMT
        if ftype == S_IFREG || ftype == S_IFLNK {
            found[rel] = "\(st.st_mode):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_size)"
        }
    }

    func walkDotDir(relDir: String, remainingBudget: inout Int) {
        guard remainingBudget > 0 else { return }
        let absDir = srcDir + "/" + relDir
        for (name, dType) in listDirEntries(at: absDir) {
            if name == ".git" || name == ".DS_Store" || heavyDirNames.contains(name) { continue }
            let rel = relDir + "/" + name
            let abs = srcDir + "/" + rel
            if dType == UInt8(DT_DIR) {
                walkDotDir(relDir: rel, remainingBudget: &remainingBudget)
            } else if dType == UInt8(DT_REG) || dType == UInt8(DT_LNK) {
                guard remainingBudget > 0 else { return }
                remainingBudget -= 1
                recordFileOrLink(rel: rel, abs: abs, baseName: name)
            } else if dType == UInt8(DT_UNKNOWN) {
                var st = stat()
                guard lstat(abs, &st) == 0 else { continue }
                let ftype = st.st_mode & S_IFMT
                if ftype == S_IFDIR {
                    walkDotDir(relDir: rel, remainingBudget: &remainingBudget)
                } else if ftype == S_IFREG || ftype == S_IFLNK {
                    guard remainingBudget > 0 else { return }
                    remainingBudget -= 1
                    if !(excludeEnv && isSecretEnvFile(name)) {
                        found[rel] = "\(st.st_mode):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_size)"
                    }
                }
            }
        }
    }

    // 1. Honor `.worktreeinclude` entries if present
    let wtiPath = srcDir + "/.worktreeinclude"
    if let content = try? String(contentsOfFile: wtiPath, encoding: .utf8) {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let name = (line as NSString).lastPathComponent
            let full = srcDir + "/" + line
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let ftype = st.st_mode & S_IFMT
            if ftype == S_IFDIR {
                var budget = 1500
                walkDotDir(relDir: line, remainingBudget: &budget)
            } else {
                recordFileOrLink(rel: line, abs: full, baseName: name)
            }
        }
    }

    // 2. Scan root & nested (depth <= 2) dotfiles/dotfolders using zero-stat `d_type`
    func scan(relDir: String, depth: Int) {
        let absDir = relDir.isEmpty ? srcDir : (srcDir + "/" + relDir)
        for (name, dType) in listDirEntries(at: absDir) {
            if name == ".git" || name == ".DS_Store" || heavyDirNames.contains(name) { continue }
            let isDot = name.hasPrefix(".")
            let rel = relDir.isEmpty ? name : (relDir + "/" + name)

            if !isDot {
                // Zero lstat() calls on non-dot files! Only recurse into non-dot subdirs up to depth 2
                if depth < 2 {
                    if dType == UInt8(DT_DIR) {
                        scan(relDir: rel, depth: depth + 1)
                    } else if dType == UInt8(DT_UNKNOWN) {
                        var st = stat()
                        if lstat(srcDir + "/" + rel, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR {
                            scan(relDir: rel, depth: depth + 1)
                        }
                    }
                }
                continue
            }

            let abs = srcDir + "/" + rel
            if dType == UInt8(DT_DIR) {
                if depth <= 1 {
                    var budget = 1500
                    walkDotDir(relDir: rel, remainingBudget: &budget)
                }
            } else if dType == UInt8(DT_REG) || dType == UInt8(DT_LNK) {
                recordFileOrLink(rel: rel, abs: abs, baseName: name)
            } else if dType == UInt8(DT_UNKNOWN) {
                var st = stat()
                guard lstat(abs, &st) == 0 else { continue }
                let ftype = st.st_mode & S_IFMT
                if ftype == S_IFDIR {
                    if depth <= 1 {
                        var budget = 1500
                        walkDotDir(relDir: rel, remainingBudget: &budget)
                    }
                } else if ftype == S_IFREG || ftype == S_IFLNK {
                    if !(excludeEnv && isSecretEnvFile(name)) {
                        found[rel] = "\(st.st_mode):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_size)"
                    }
                }
            }
        }
    }
    scan(relDir: "", depth: 0)

    return found
}

/// Walks a directory subtree, returning relative file paths (skipping heavy dirs & `.git`).
private func walkDirectoryFiles(in srcDir: String, excludeEnv: Bool, skipHeavy: Bool) -> [String] {
    let fm = FileManager.default
    var files: [String] = []
    files.reserveCapacity(4096)

    func walk(relDir: String) {
        let absDir = relDir.isEmpty ? srcDir : (srcDir + "/" + relDir)
        guard let names = try? fm.contentsOfDirectory(atPath: absDir) else { return }
        for name in names {
            if name == ".DS_Store" { continue }
            let rel = relDir.isEmpty ? name : (relDir + "/" + name)
            let abs = srcDir + "/" + rel
            var st = stat()
            guard lstat(abs, &st) == 0 else { continue }
            let ftype = st.st_mode & S_IFMT
            if ftype == S_IFDIR {
                if skipHeavy && heavyDirNames.contains(name) { continue }
                if name == ".git" { continue }
                walk(relDir: rel)
            } else if ftype == S_IFREG || ftype == S_IFLNK {
                if excludeEnv && isSecretEnvFile(name) { continue }
                files.append(rel)
            }
        }
    }
    walk(relDir: "")
    return files
}

private func mkdirP(_ path: String) {
    var st = stat()
    if lstat(path, &st) == 0 { return }
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func cloneSinglePath(src: String, dst: String) {
    if clonefile(src, dst, 0) == 0 {
        return
    }
    let err = errno
    if err == EEXIST {
        var dstSt = stat()
        if lstat(dst, &dstSt) == 0 && (dstSt.st_mode & S_IFMT) == S_IFDIR {
            try? FileManager.default.removeItem(atPath: dst)
        } else {
            unlink(dst)
        }
        if clonefile(src, dst, 0) == 0 { return }
    }
    if err == EXDEV || err == ENOTSUP {
        try? FileManager.default.copyItem(atPath: src, toPath: dst)
    }
}

/// Moves a directory/path into `trashRoot/.trash-<uuid>` in ~0.05 ms and deletes it asynchronously
/// so callers never block waiting for `rm -rf` on large `.git` directories.
private func moveToTrashAsync(_ path: String, trashRoot: String) {
    var st = stat()
    guard lstat(path, &st) == 0 else { return }
    mkdirP(trashRoot)
    let trashDest = trashRoot + "/.trash-" + UUID().uuidString.prefix(12)
    if rename(path, trashDest) == 0 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/rm")
        proc.arguments = ["-rf", trashDest]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    } else {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func removeDstPath(_ dstPath: String, rootDst: String, trashRoot: String) {
    var st = stat()
    guard lstat(dstPath, &st) == 0 else { return }
    if (st.st_mode & S_IFMT) == S_IFDIR {
        moveToTrashAsync(dstPath, trashRoot: trashRoot)
    } else {
        unlink(dstPath)
    }
    // Prune now-empty parent directories up to (but never including) rootDst
    var parent = (dstPath as NSString).deletingLastPathComponent
    while parent.count > rootDst.count && parent.hasPrefix(rootDst + "/") {
        if rmdir(parent) != 0 { break }
        parent = (parent as NSString).deletingLastPathComponent
    }
}

private func syncSingleRelativePath(
    _ rawRel: String,
    srcDir: String,
    dstDir: String,
    excludeEnv: Bool,
    newlyIgnored: Set<String>,
    trashRoot: String
) {
    let cleanRel = rawRel.hasSuffix("/") ? String(rawRel.dropLast()) : rawRel
    guard !cleanRel.isEmpty, cleanRel != ".", cleanRel != "..",
          !cleanRel.hasPrefix("/"), !cleanRel.contains("/../") else {
        return
    }
    let srcPath = srcDir + "/" + cleanRel
    let dstPath = dstDir + "/" + cleanRel

    var srcSt = stat()
    if lstat(srcPath, &srcSt) != 0 || newlyIgnored.contains(cleanRel) || newlyIgnored.contains(rawRel) {
        removeDstPath(dstPath, rootDst: dstDir, trashRoot: trashRoot)
        return
    }

    let baseName = (cleanRel as NSString).lastPathComponent
    if excludeEnv && isSecretEnvFile(baseName) {
        removeDstPath(dstPath, rootDst: dstDir, trashRoot: trashRoot)
        return
    }

    let ftype = srcSt.st_mode & S_IFMT
    if ftype == S_IFREG || ftype == S_IFLNK {
        let parent = (dstPath as NSString).deletingLastPathComponent
        mkdirP(parent)
        var dstSt = stat()
        if lstat(dstPath, &dstSt) == 0 {
            if (dstSt.st_mode & S_IFMT) == S_IFDIR {
                moveToTrashAsync(dstPath, trashRoot: trashRoot)
            } else {
                unlink(dstPath)
            }
        }
        cloneSinglePath(src: srcPath, dst: dstPath)
    } else if ftype == S_IFDIR {
        // Untracked folder (e.g. `?? newdir/`) — mirror cleanly while skipping heavy/secret files
        removeDstPath(dstPath, rootDst: dstDir, trashRoot: trashRoot)
        mkdirP(dstPath)
        let subFiles = walkDirectoryFiles(in: srcPath, excludeEnv: excludeEnv, skipHeavy: true)
        var subParents = Set<String>()
        for sf in subFiles {
            if let slashIdx = sf.lastIndex(of: "/") {
                subParents.insert(String(sf[..<slashIdx]))
            }
        }
        for sp in subParents.sorted(by: { $0.count < $1.count }) {
            mkdirP(dstPath + "/" + sp)
        }
        for sf in subFiles {
            cloneSinglePath(src: srcPath + "/" + sf, dst: dstPath + "/" + sf)
        }
        // Preserve nested submodule `.git` if present
        var subGitSt = stat()
        if lstat(srcPath + "/.git", &subGitSt) == 0 {
            cloneSinglePath(src: srcPath + "/.git", dst: dstPath + "/.git")
        }
    }
}

private func readMeta(at path: String) -> CloneMeta? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(CloneMeta.self, from: data)
}

private func writeMeta(_ meta: CloneMeta, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(meta) {
        try? data.write(to: url, options: .atomic)
    }
}

/// Strips secret `.env*` files from an already-cloned directory tree using zero-stat `d_type` traversal,
/// skipping `.git` and `heavyDirNames` (`node_modules`, `.next`, `target`, etc.) so huge dependency trees
/// are never walked in userspace.
private func stripSecretEnvFiles(in dir: String) {
    for (name, dType) in listDirEntries(at: dir) {
        if name == ".git" || heavyDirNames.contains(name) { continue }
        let path = dir + "/" + name
        if dType == UInt8(DT_DIR) {
            stripSecretEnvFiles(in: path)
        } else if dType == UInt8(DT_REG) || dType == UInt8(DT_LNK) {
            if isSecretEnvFile(name) {
                unlink(path)
            }
        } else if dType == UInt8(DT_UNKNOWN) {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let ftype = st.st_mode & S_IFMT
            if ftype == S_IFDIR {
                stripSecretEnvFiles(in: path)
            } else if (ftype == S_IFREG || ftype == S_IFLNK) && isSecretEnvFile(name) {
                unlink(path)
            }
        }
    }
}

/// Clones an entire directory/file via native APFS `clonefile(2)` in a single kernel call even when
/// `excludeEnv` is true (stripping any `.env*` files in `dst` afterward while skipping `heavyDirNames`),
/// falling back to recursive entry-by-entry cloning only if a subtree contains unsupported nodes (e.g. sockets/FIFOs).
private func cloneSubtreeAPFS(src: String, dst: String, excludeEnv: Bool) {
    let baseName = (src as NSString).lastPathComponent
    let isHeavyOrGit = (baseName == ".git") || heavyDirNames.contains(baseName)
    var clonedWhole = false
    if clonefile(src, dst, 0) == 0 {
        clonedWhole = true
    } else if errno == EEXIST {
        var dstSt = stat()
        if lstat(dst, &dstSt) == 0 && (dstSt.st_mode & S_IFMT) == S_IFDIR {
            try? FileManager.default.removeItem(atPath: dst)
        } else {
            unlink(dst)
        }
        if clonefile(src, dst, 0) == 0 {
            clonedWhole = true
        }
    }
    if clonedWhole {
        if excludeEnv && !isHeavyOrGit {
            var dstSt = stat()
            if lstat(dst, &dstSt) == 0 && (dstSt.st_mode & S_IFMT) == S_IFDIR {
                stripSecretEnvFiles(in: dst)
            }
        }
        return
    }

    var st = stat()
    guard lstat(src, &st) == 0 else { return }
    let ftype = st.st_mode & S_IFMT
    if ftype == S_IFREG || ftype == S_IFLNK {
        if excludeEnv && isSecretEnvFile(baseName) { return }
        cloneSinglePath(src: src, dst: dst)
    } else if ftype == S_IFDIR {
        mkdirP(dst)
        for (name, dType) in listDirEntries(at: src) {
            if name == ".DS_Store" { continue }
            if excludeEnv && isSecretEnvFile(name) { continue }
            if dType == UInt8(DT_SOCK) || dType == UInt8(DT_FIFO) || dType == UInt8(DT_BLK) || dType == UInt8(DT_CHR) {
                continue
            }
            cloneSubtreeAPFS(src: src + "/" + name, dst: dst + "/" + name, excludeEnv: excludeEnv)
        }
    }
}

private let dependencyLockFiles: Set<String> = [
    "bun.lock", "bun.lockb", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
]

/// Applies an exact Git + dotfile + lockfile delta from `srcDir` onto an existing cloned tree at `dstDir`
/// whose baseline state is described by `oldMeta`.
/// Returns `(syncedCount, updatedMeta)` on success, or `nil` if a full clone is required.
private func applyDeltaSync(
    from srcDir: String,
    into dstDir: String,
    oldMeta: CloneMeta,
    excludeEnv: Bool,
    includeIgnored: Bool,
    trashRoot: String,
    preserveSourceDir: String?
) -> (Int, CloneMeta)? {
    let group = DispatchGroup()
    let headBox = ResultBox("")
    let dirtyBox = ResultBox<[String]?>(nil)
    let envBox = ResultBox<[String: String]>([:])
    let gitSigBox = ResultBox("")

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        headBox.value = gitHeadCommit(in: srcDir)
        dirtyBox.value = gitStatusDirtyPaths(in: srcDir)
        group.leave()
    }

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        envBox.value = discoverExtraLocalFilesWithSig(in: srcDir, excludeEnv: excludeEnv)
        gitSigBox.value = computeGitStatSignature(in: srcDir)
        group.leave()
    }

    group.wait()

    let newHead = headBox.value
    let newEnvFiles = envBox.value
    let newGitSig = gitSigBox.value
    guard let currentDirty = dirtyBox.value else { return nil }

    // 1. Committed changes if HEAD moved
    let committedDiff: [String]
    if oldMeta.headCommit != newHead {
        guard let diff = gitCommittedDiffPaths(in: srcDir, from: oldMeta.headCommit, to: newHead) else {
            return nil
        }
        committedDiff = diff
    } else {
        committedDiff = []
    }

    // 2. Env / .worktreeinclude files that were added, removed, or modified
    var changedEnvPaths = Set<String>()
    for (k, v) in newEnvFiles where oldMeta.envFiles[k] != v {
        changedEnvPaths.insert(k)
    }
    for k in oldMeta.envFiles.keys where newEnvFiles[k] == nil {
        changedEnvPaths.insert(k)
    }

    let currentDirtySet = Set(currentDirty)
    let committedDiffSet = Set(committedDiff)

    // 3. Detect files that were dirty/untracked at T0 and newly added to .gitignore at T1
    var wasDirtyNowClean: [String] = []
    for oldPath in oldMeta.dirtyFiles {
        if !currentDirtySet.contains(oldPath) && !committedDiffSet.contains(oldPath) && newEnvFiles[oldPath] == nil {
            let clean = oldPath.hasSuffix("/") ? String(oldPath.dropLast()) : oldPath
            var st = stat()
            if lstat(srcDir + "/" + clean, &st) == 0 {
                wasDirtyNowClean.append(clean)
            }
        }
    }
    let newlyIgnored = gitCheckIgnored(paths: wasDirtyNowClean, in: srcDir)

    // 4. Exact union of every path that can possibly differ between dstDir and srcDir
    var dirtyUnion = Set<String>()
    dirtyUnion.formUnion(oldMeta.dirtyFiles)
    dirtyUnion.formUnion(currentDirty)
    dirtyUnion.formUnion(committedDiff)
    dirtyUnion.formUnion(changedEnvPaths)

    let syncList = Array(dirtyUnion)
    if syncList.count <= 16 {
        for rel in syncList {
            syncSingleRelativePath(
                rel,
                srcDir: srcDir,
                dstDir: dstDir,
                excludeEnv: excludeEnv,
                newlyIgnored: newlyIgnored,
                trashRoot: trashRoot
            )
        }
    } else {
        let workerCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let chunkSize = max(1, (syncList.count + workerCount - 1) / workerCount)
        // Pre-create parent directories sequentially to avoid mkdir races across threads
        var parents = Set<String>()
        for rel in syncList {
            let clean = rel.hasSuffix("/") ? String(rel.dropLast()) : rel
            if let slashIdx = clean.lastIndex(of: "/") {
                parents.insert(String(clean[..<slashIdx]))
            }
        }
        for p in parents.sorted(by: { $0.count < $1.count }) {
            mkdirP(dstDir + "/" + p)
        }
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            let start = worker * chunkSize
            let end = min(start + chunkSize, syncList.count)
            guard start < end else { return }
            for i in start..<end {
                syncSingleRelativePath(
                    syncList[i],
                    srcDir: srcDir,
                    dstDir: dstDir,
                    excludeEnv: excludeEnv,
                    newlyIgnored: newlyIgnored,
                    trashRoot: trashRoot
                )
            }
        }
    }

    // 5. Refresh `.git` only when its stat signature changed (0 ms when unchanged!)
    var gitChanged = false
    if newGitSig != oldMeta.gitStatSig {
        gitChanged = true
        moveToTrashAsync(dstDir + "/.git", trashRoot: trashRoot)
        cloneSinglePath(src: srcDir + "/.git", dst: dstDir + "/.git")
    }

    // 6. In full-clone mode (`includeIgnored == true`), if a root JS/Bun lockfile changed since
    //    the warm clone was built, refresh `node_modules` via APFS clonefile so deps stay exact.
    var depsRefreshed = false
    if includeIgnored && dirtyUnion.contains(where: { dependencyLockFiles.contains($0) }) {
        let srcNM = srcDir + "/node_modules"
        var nmSt = stat()
        if lstat(srcNM, &nmSt) == 0 {
            depsRefreshed = true
            moveToTrashAsync(dstDir + "/node_modules", trashRoot: trashRoot)
            cloneSubtreeAPFS(src: srcNM, dst: dstDir + "/node_modules", excludeEnv: false)
        }
    }

    let updatedMeta = CloneMeta(
        version: 1,
        sourceDir: preserveSourceDir ?? srcDir,
        headCommit: newHead,
        gitStatSig: newGitSig,
        dirtyFiles: currentDirty,
        envFiles: newEnvFiles,
        excludeEnv: excludeEnv,
        includeIgnored: includeIgnored
    )
    return (syncList.count + (gitChanged ? 1 : 0) + (depsRefreshed ? 1 : 0), updatedMeta)
}

private func printErr(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
var positional: [String] = []
private func sendIPCMessage(socketPath: String, payload: Data) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < maxLen else { return false }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, addrLen) == 0
        }
    }
    guard connected else { return false }

    var msg = payload
    if msg.last != 0x0A { msg.append(0x0A) }
    let written = msg.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        var off = 0
        while off < msg.count {
            let n = Darwin.write(fd, base.advanced(by: off), msg.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
    guard written else { return false }
    shutdown(fd, SHUT_WR)

    var reply = [UInt8](repeating: 0, count: 16)
    let n = Darwin.read(fd, &reply, reply.count)
    return n >= 2 && reply[0] == UInt8(ascii: "O") && reply[1] == UInt8(ascii: "K")
}

private func readGeneralCloneConfig(at path: String) -> (excludeEnv: Bool, skipHeavy: Bool) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let general = root["general"] as? [String: Any] else {
        return (false, false)
    }
    let exEnv = (general["excludeEnvFilesWhenCloning"] as? Bool) ?? false
    let skipHeavy = (general["skipHeavyDirsWhenCloning"] as? Bool) ?? false
    return (exEnv, skipHeavy)
}

// Fast IPC-only send mode: `boobox-clone --ipc-send <sockPath> <jsonPayload>`
if args.count == 3 && args[0] == "--ipc-send" {
    let ok = sendIPCMessage(socketPath: args[1], payload: Data(args[2].utf8))
    exit(ok ? 0 : 1)
}

var excludeEnv = false
var explicitNoEnv = false
var includeIgnored = false
var explicitCloneMode: Bool? = nil // true = full, false = slim
var configPath: String? = nil
var quiet = false
var writeMetaPath: String? = nil
var warmPopDir: String? = nil
var warmMetaPath: String? = nil
var deltaInPlaceMetaPath: String? = nil
var preserveSourceDir: String? = nil
var notifySocketPath: String? = nil
var notifyID: String? = nil
var notifyName: String? = nil
var notifyTemplate: String? = nil

var argIdx = 0
while argIdx < args.count {
    let arg = args[argIdx]
    switch arg {
    case "--no-env":
        excludeEnv = true
        explicitNoEnv = true
    case "--include-ignored", "--full":
        includeIgnored = true
        explicitCloneMode = true
    case "--slim":
        includeIgnored = false
        explicitCloneMode = false
    case "--use-config":
        guard argIdx + 1 < args.count else {
            printErr("boobox-clone: --use-config requires a path")
            exit(2)
        }
        argIdx += 1
        configPath = args[argIdx]
    case "--notify-socket":
        guard argIdx + 1 < args.count else {
            printErr("boobox-clone: --notify-socket requires a path")
            exit(2)
        }
        argIdx += 1
        notifySocketPath = args[argIdx]
    case "--notify-id":
        guard argIdx + 1 < args.count else { exit(2) }
        argIdx += 1
        notifyID = args[argIdx]
    case "--notify-name":
        guard argIdx + 1 < args.count else { exit(2) }
        argIdx += 1
        notifyName = args[argIdx]
    case "--notify-template":
        guard argIdx + 1 < args.count else { exit(2) }
        argIdx += 1
        notifyTemplate = args[argIdx]
    case "--quiet", "-q":
        quiet = true
    case "--write-meta":
        guard argIdx + 1 < args.count else {
            printErr("boobox-clone: --write-meta requires a path")
            exit(2)
        }
        argIdx += 1
        writeMetaPath = args[argIdx]
    case "--warm-pop":
        guard argIdx + 1 < args.count else {
            printErr("boobox-clone: --warm-pop requires a directory path")
            exit(2)
        }
        argIdx += 1
        warmPopDir = args[argIdx]
    case "--warm-meta":
        guard argIdx + 1 < args.count else {
            printErr("boobox-clone: --warm-meta requires a file path")
            exit(2)
        }
        argIdx += 1
        warmMetaPath = args[argIdx]
    case "--delta-in-place":
        guard argIdx + 1 < args.count else {
            printErr("boobox-clone: --delta-in-place requires a meta file path")
            exit(2)
        }
        argIdx += 1
        deltaInPlaceMetaPath = args[argIdx]
    case "--preserve-source-dir":
        guard argIdx + 1 < args.count else {
            printErr("boobox-clone: --preserve-source-dir requires a path")
            exit(2)
        }
        argIdx += 1
        preserveSourceDir = args[argIdx]
    default:
        positional.append(arg)
    }
    argIdx += 1
}

if let cfgPath = configPath {
    let cfg = readGeneralCloneConfig(at: cfgPath)
    if !explicitNoEnv && cfg.excludeEnv {
        excludeEnv = true
    }
    if explicitCloneMode == nil {
        includeIgnored = !cfg.skipHeavy
    }
}

@MainActor
private func finishAndNotifyIfRequested() -> Never {
    if let sock = notifySocketPath, let id = notifyID, let tmpl = notifyTemplate {
        let obj: [String: Any] = [
            "op": "ready",
            "id": id,
            "name": notifyName ?? (tmpl as NSString).lastPathComponent,
            "template": tmpl,
            "noEnv": excludeEnv,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            if sendIPCMessage(socketPath: sock, payload: data) {
                exit(0)
            }
            // Cloned cleanly, but live app socket not listening -> caller falls back to `open -a`
            exit(10)
        }
    }
    exit(0)
}

guard positional.count == 2 else {
    printErr("Usage: boobox-clone <srcDir> <dstDir> [--no-env] [--include-ignored|--full|--slim] [--use-config <path>] [--quiet] [--write-meta <file>] [--warm-pop <dir> --warm-meta <file>] [--delta-in-place <metaFile>]")
    exit(2)
}
let startTime = CFAbsoluteTimeGetCurrent()
let srcDir = URL(fileURLWithPath: positional[0]).resolvingSymlinksInPath().path
let dstDir = URL(fileURLWithPath: positional[1]).path
let templatesRoot = NSHomeDirectory() + "/boo_box/templates"

var srcStat = stat()
guard lstat(srcDir, &srcStat) == 0, (srcStat.st_mode & S_IFMT) == S_IFDIR else {
    printErr("boobox-clone: source is not a directory: \(srcDir)")
    exit(1)
}

var gitStat = stat()
let hasGitDir = lstat(srcDir + "/.git", &gitStat) == 0

// MARK: Mode 1 — In-place Delta Sync (used to refresh ~/boo_box/templates/<proj> in ~0.9s)
if let deltaMetaPath = deltaInPlaceMetaPath {
    guard hasGitDir,
          let oldMeta = readMeta(at: deltaMetaPath),
          oldMeta.version == 1,
          oldMeta.excludeEnv == excludeEnv,
          oldMeta.includeIgnored == includeIgnored else {
        exit(3)
    }
    var dstSt = stat()
    guard lstat(dstDir, &dstSt) == 0, (dstSt.st_mode & S_IFMT) == S_IFDIR else {
        exit(3)
    }
    if let (syncedCount, updatedMeta) = applyDeltaSync(
        from: srcDir,
        into: dstDir,
        oldMeta: oldMeta,
        excludeEnv: excludeEnv,
        includeIgnored: includeIgnored,
        trashRoot: templatesRoot,
        preserveSourceDir: preserveSourceDir ?? oldMeta.sourceDir
    ) {
        if let writeMetaPath {
            writeMeta(updatedMeta, to: writeMetaPath)
        }
        if !quiet {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            print(String(format: "Delta-synced %d changes in %.2fs", syncedCount, elapsed))
        }
        exit(0)
    }
    exit(3)
}

// MARK: Mode 2 — Lock-Free Atomic Warm-Pool Pop + Git Delta Sync (~0.9s even with full node_modules!)
if let warmDir = warmPopDir, let warmMetaFile = warmMetaPath, hasGitDir {
    if let warmMeta = readMeta(at: warmMetaFile),
       warmMeta.version == 1,
       warmMeta.sourceDir == srcDir,
       warmMeta.excludeEnv == excludeEnv,
       warmMeta.includeIgnored == includeIgnored {
        let dstParent = (dstDir as NSString).deletingLastPathComponent
        mkdirP(dstParent)
        var dstSt = stat()
        if lstat(dstDir, &dstSt) == 0 {
            _ = rmdir(dstDir)
        }

        // POSIX-atomic claim on the same APFS volume: only ONE winner if `boo .` and `⌘T` race!
        if rename(warmDir, dstDir) == 0 {
            unlink(warmMetaFile)
            if let (syncedCount, updatedMeta) = applyDeltaSync(
                from: srcDir,
                into: dstDir,
                oldMeta: warmMeta,
                excludeEnv: excludeEnv,
                includeIgnored: includeIgnored,
                trashRoot: templatesRoot,
                preserveSourceDir: preserveSourceDir
            ) {
                if let writeMetaPath {
                    writeMeta(updatedMeta, to: writeMetaPath)
                }
                if !quiet {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let label = syncedCount == 1 ? "change" : "changes"
                    print(String(format: "Popped warm clone + synced %d %@ in %.2fs", syncedCount, label, elapsed))
                }
                finishAndNotifyIfRequested()
            } else {
                moveToTrashAsync(dstDir, trashRoot: templatesRoot)
            }
        }
    }
}

// MARK: Mode 3 — APFS Copy-On-Write Cold Clone (full subtree clonefile(2) by default, or slim Git-aware clone)
let fm = FileManager.default
try? fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)

let metaGroup = DispatchGroup()
let capturedHeadBox = ResultBox("")
let capturedDirtyBox = ResultBox<[String]?>(nil)
let capturedGitSigBox = ResultBox("")
let capturedEnvBox = ResultBox<[String: String]>([:])
let shouldCaptureMeta = (writeMetaPath != nil) && hasGitDir

let capturedExcludeEnv = excludeEnv
if shouldCaptureMeta {
    metaGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        capturedHeadBox.value = gitHeadCommit(in: srcDir)
        capturedDirtyBox.value = gitStatusDirtyPaths(in: srcDir)
        capturedGitSigBox.value = computeGitStatSignature(in: srcDir)
        capturedEnvBox.value = discoverExtraLocalFilesWithSig(in: srcDir, excludeEnv: capturedExcludeEnv)
        metaGroup.leave()
    }
}

if includeIgnored {
    // Full zero-copy APFS clone: brings over ALL files (node_modules, build caches, dotfiles, .git)
    // using direct kernel directory clonefile(2) per top-level entry (0 extra SSD data bytes!).
    let topEntries = listDirEntries(at: srcDir).filter { name, dType in
        if name == ".DS_Store" { return false }
        if excludeEnv && isSecretEnvFile(name) { return false }
        if dType == UInt8(DT_SOCK) || dType == UInt8(DT_FIFO) || dType == UInt8(DT_BLK) || dType == UInt8(DT_CHR) {
            return false
        }
        return true
    }
    let immutableSrc = srcDir
    let immutableDst = dstDir
    let immutableExcludeEnv = excludeEnv
    DispatchQueue.concurrentPerform(iterations: topEntries.count) { idx in
        if cloneCancelled != 0 { return }
        let name = topEntries[idx].name
        cloneSubtreeAPFS(src: immutableSrc + "/" + name, dst: immutableDst + "/" + name, excludeEnv: immutableExcludeEnv)
    }
    if cloneCancelled != 0 {
        exit(130)
    }
    if shouldCaptureMeta, let writeMetaPath {
        metaGroup.wait()
        if let dirty = capturedDirtyBox.value {
            let meta = CloneMeta(
                version: 1,
                sourceDir: preserveSourceDir ?? srcDir,
                headCommit: capturedHeadBox.value,
                gitStatSig: capturedGitSigBox.value,
                dirtyFiles: dirty,
                envFiles: capturedEnvBox.value,
                excludeEnv: excludeEnv,
                includeIgnored: true
            )
            writeMeta(meta, to: writeMetaPath)
        }
    }
    if !quiet {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print(String(format: "Cloned full workspace (%d top-level entries, 0 extra SSD bytes) in %.2fs", topEntries.count, elapsed))
    }
} else {
    // Slim Git-aware clone (when `--slim` / `skipHeavyDirsWhenCloning = true`)
    var fileList: [String]
    var envFilesMap: [String: String] = [:]
    if hasGitDir, let tracked = runGitLsFiles(in: srcDir) {
        envFilesMap = discoverExtraLocalFilesWithSig(in: srcDir, excludeEnv: excludeEnv)
        var set = Set(tracked)
        for extra in envFilesMap.keys {
            set.insert(extra)
        }
        if excludeEnv {
            fileList = set.filter { !isSecretEnvFile(($0 as NSString).lastPathComponent) }
        } else {
            fileList = Array(set)
        }
    } else {
        fileList = walkDirectoryFiles(in: srcDir, excludeEnv: excludeEnv, skipHeavy: true)
    }

    var parentDirs = Set<String>()
    parentDirs.reserveCapacity(max(64, fileList.count / 4))
    for rel in fileList {
        if let slashIdx = rel.lastIndex(of: "/") {
            parentDirs.insert(String(rel[..<slashIdx]))
        }
    }
    for relDir in parentDirs.sorted(by: { $0.count < $1.count }) {
        mkdirP(dstDir + "/" + relDir)
    }

    let workerCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
    let chunkSize = max(1, (fileList.count + workerCount - 1) / workerCount)
    let totalTasks = workerCount + (hasGitDir ? 1 : 0)

    let immutableFiles = fileList
    let immutableSrc = srcDir
    let immutableDst = dstDir

    DispatchQueue.concurrentPerform(iterations: totalTasks) { taskIdx in
        if cloneCancelled != 0 { return }
        if hasGitDir && taskIdx == workerCount {
            cloneSinglePath(src: immutableSrc + "/.git", dst: immutableDst + "/.git")
            return
        }
        let start = taskIdx * chunkSize
        let end = min(start + chunkSize, immutableFiles.count)
        guard start < end else { return }
        for i in start..<end {
            if cloneCancelled != 0 { return }
            let rel = immutableFiles[i]
            cloneSinglePath(src: immutableSrc + "/" + rel, dst: immutableDst + "/" + rel)
        }
    }
    if cloneCancelled != 0 {
        exit(130)
    }
    if shouldCaptureMeta, let writeMetaPath {
        metaGroup.wait()
        if let dirty = capturedDirtyBox.value {
            let meta = CloneMeta(
                version: 1,
                sourceDir: preserveSourceDir ?? srcDir,
                headCommit: capturedHeadBox.value,
                gitStatSig: capturedGitSigBox.value,
                dirtyFiles: dirty,
                envFiles: envFilesMap,
                excludeEnv: excludeEnv,
                includeIgnored: false
            )
            writeMeta(meta, to: writeMetaPath)
        }
    }

    if !quiet {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let suffix = hasGitDir ? " (+ .git)" : ""
        print(String(format: "Cloned %d files%@ in %.2fs", immutableFiles.count, suffix, elapsed))
    }
}
finishAndNotifyIfRequested()
