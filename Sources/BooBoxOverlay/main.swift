import CryptoKit
import Darwin
import Foundation
import Security

// ============================================================================
// boobox-overlay — O(1) Copy-on-Write Userspace Overlay Filesystem for macOS
// ============================================================================
// Speaks RFC 1057 SunRPC + MOUNTv3 + RFC 1813 NFSv3 over 127.0.0.1 TCP so macOS
// mounts any directory (even 10M+ files or an entire partition) via unprivileged
// `/sbin/mount_nfs` in ~20 ms — zero sudo, zero kexts, zero FUSE-T, zero certs.
//
// Security invariants:
//   1. Lower layer is NEVER opened for writing (O_RDONLY | O_NOFOLLOW only).
//   2. Every path component validated (no "..", "/", or NUL); strict prefix check.
//   3. One-shot 128-bit cryptographic export path invalidated immediately after MNT.
//   4. 128-bit cryptographic random filehandles (SecRandomCopyBytes) — unguessable.
//   5. Seatbelt denies sandbox TCP access to the daemon's localhost port so only
//      the macOS kernel NFS client ever talks to boobox-overlay.
//   6. When excludeEnv=true, host .env / .env.* (except template allowlist) are
//      hidden from lower LOOKUP & READDIR while allowing sandbox-local .env in upper.

// MARK: - Constants & Wire Enums

private let PROG_NFS: UInt32 = 100003
private let VERS_NFS3: UInt32 = 3
private let PROG_MOUNT: UInt32 = 100005
private let VERS_MOUNT3: UInt32 = 3

private let MAX_RPC_FRAGMENT: Int = 2 * 1024 * 1024 // 2 MiB hard cap
private let MAX_IO_BYTES: UInt32 = 1048576          // 1 MiB rsize/wsize

// NFS3 status codes (RFC 1813 §2.6)
private let NFS3_OK: UInt32 = 0
private let NFS3ERR_PERM: UInt32 = 1
private let NFS3ERR_NOENT: UInt32 = 2
private let NFS3ERR_IO: UInt32 = 5
private let NFS3ERR_ACCES: UInt32 = 13
private let NFS3ERR_EXIST: UInt32 = 17
private let NFS3ERR_XDEV: UInt32 = 18
private let NFS3ERR_NOTDIR: UInt32 = 20
private let NFS3ERR_ISDIR: UInt32 = 21
private let NFS3ERR_INVAL: UInt32 = 22
private let NFS3ERR_FBIG: UInt32 = 27
private let NFS3ERR_NOSPC: UInt32 = 28
private let NFS3ERR_NAMETOOLONG: UInt32 = 63
private let NFS3ERR_NOTEMPTY: UInt32 = 66
private let NFS3ERR_STALE: UInt32 = 70
private let NFS3ERR_NOTSUPP: UInt32 = 10004

// NFS3 file types
private let NF3REG: UInt32 = 1
private let NF3DIR: UInt32 = 2
private let NF3BLK: UInt32 = 3
private let NF3CHR: UInt32 = 4
private let NF3LNK: UInt32 = 5
private let NF3SOCK: UInt32 = 6
private let NF3FIFO: UInt32 = 7

private let envTemplateAllowlist: Set<String> = [
    ".env.example", ".env.sample", ".env.template", ".env.dist",
]

private func isHiddenEnvFilename(_ name: String) -> Bool {
    let lower = name.lowercased()
    return (lower == ".env" || lower.hasPrefix(".env.")) && !envTemplateAllowlist.contains(lower)
}

private func isSafeSingleComponent(_ name: String) -> Bool {
    guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255 else { return false }
    for b in name.utf8 {
        if b == 0 || b == UInt8(ascii: "/") { return false }
    }
    return true
}

private func nfsStatus(fromErrno e: Int32) -> UInt32 {
    switch e {
    case 0: return NFS3_OK
    case EPERM: return NFS3ERR_PERM
    case ENOENT: return NFS3ERR_NOENT
    case EACCES: return NFS3ERR_ACCES
    case EEXIST: return NFS3ERR_EXIST
    case EXDEV: return NFS3ERR_XDEV
    case ENOTDIR: return NFS3ERR_NOTDIR
    case EISDIR: return NFS3ERR_ISDIR
    case EINVAL: return NFS3ERR_INVAL
    case EFBIG: return NFS3ERR_FBIG
    case ENOSPC: return NFS3ERR_NOSPC
    case ENAMETOOLONG: return NFS3ERR_NAMETOOLONG
    case ENOTEMPTY: return NFS3ERR_NOTEMPTY
    default: return NFS3ERR_IO
    }
}

private func randomBytes(_ count: Int) -> Data {
    var buf = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &buf)
    return Data(buf)
}

private func randomHex(_ byteCount: Int) -> String {
    randomBytes(byteCount).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Bounds-Checked XDR Reader & Writer

private struct XDRReader {
    let data: Data
    var offset: Int = 0

    var remaining: Int { data.count - offset }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    mutating func readUInt64() -> UInt64? {
        guard let hi = readUInt32(), let lo = readUInt32() else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }

    mutating func readFixedOpaque(_ length: Int) -> Data? {
        let padded = (length + 3) & ~3
        guard length >= 0, offset + padded <= data.count else { return nil }
        let slice = data.subdata(in: offset..<(offset + length))
        offset += padded
        return slice
    }

    mutating func readOpaque(maxLength: Int = MAX_RPC_FRAGMENT) -> Data? {
        guard let len32 = readUInt32() else { return nil }
        let len = Int(len32)
        guard len >= 0, len <= maxLength else { return nil }
        return readFixedOpaque(len)
    }

    mutating func readString(maxLength: Int = 4096) -> String? {
        guard let raw = readOpaque(maxLength: maxLength) else { return nil }
        return String(data: raw, encoding: .utf8)
    }

    mutating func skipAuth() -> Bool {
        guard readUInt32() != nil else { return false }
        guard readOpaque(maxLength: 400) != nil else { return false }
        return true
    }
}

private struct XDRWriter {
    var data = Data()

    init(capacity: Int = 256) {
        data.reserveCapacity(capacity)
    }

    mutating func writeUInt32(_ v: UInt32) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func writeUInt64(_ v: UInt64) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func writeBool(_ v: Bool) {
        writeUInt32(v ? 1 : 0)
    }

    mutating func writeFixedBytes(_ bytes: Data) {
        data.append(bytes)
        let rem = bytes.count & 3
        if rem != 0 {
            let pad = 4 - rem
            for _ in 0..<pad { data.append(0) }
        }
    }

    mutating func writeOpaque(_ bytes: Data) {
        writeUInt32(UInt32(bytes.count))
        writeFixedBytes(bytes)
    }

    mutating func writeString(_ s: String) {
        writeOpaque(Data(s.utf8))
    }

    mutating func writeFattr3(_ attr: NFSAttr) {
        writeUInt32(attr.type)
        writeUInt32(attr.mode)
        writeUInt32(attr.nlink)
        writeUInt32(attr.uid)
        writeUInt32(attr.gid)
        writeUInt64(attr.size)
        writeUInt64(attr.used)
        writeUInt32(0) // rdev.specdata1
        writeUInt32(0) // rdev.specdata2
        writeUInt64(attr.fsid)
        writeUInt64(attr.fileid)
        writeUInt32(attr.atimeSec)
        writeUInt32(attr.atimeNsec)
        writeUInt32(attr.mtimeSec)
        writeUInt32(attr.mtimeNsec)
        writeUInt32(attr.ctimeSec)
        writeUInt32(attr.ctimeNsec)
    }

    mutating func writePostOpAttr(_ attr: NFSAttr?) {
        if let attr {
            writeBool(true)
            writeFattr3(attr)
        } else {
            writeBool(false)
        }
    }

    mutating func writeWccData(pre: NFSAttr?, post: NFSAttr?) {
        if let pre {
            writeBool(true)
            writeUInt64(pre.size)
            writeUInt32(pre.mtimeSec)
            writeUInt32(pre.mtimeNsec)
            writeUInt32(pre.ctimeSec)
            writeUInt32(pre.ctimeNsec)
        } else {
            writeBool(false)
        }
        writePostOpAttr(post)
    }
}

private struct NFSAttr {
    let type: UInt32
    let mode: UInt32
    let nlink: UInt32
    let uid: UInt32
    let gid: UInt32
    let size: UInt64
    let used: UInt64
    let fsid: UInt64
    let fileid: UInt64
    let atimeSec: UInt32
    let atimeNsec: UInt32
    let mtimeSec: UInt32
    let mtimeNsec: UInt32
    let ctimeSec: UInt32
    let ctimeNsec: UInt32

    static func fromStat(_ st: stat, fsid: UInt64, fileid: UInt64) -> NFSAttr {
        let ftype: UInt32
        switch st.st_mode & S_IFMT {
        case S_IFREG: ftype = NF3REG
        case S_IFDIR: ftype = NF3DIR
        case S_IFLNK: ftype = NF3LNK
        case S_IFBLK: ftype = NF3BLK
        case S_IFCHR: ftype = NF3CHR
        case S_IFSOCK: ftype = NF3SOCK
        case S_IFIFO: ftype = NF3FIFO
        default: ftype = NF3REG
        }
        let mode = UInt32(st.st_mode & 0o7777)
        let size = UInt64(max(0, st.st_size))
        let used = UInt64(max(0, st.st_blocks)) * 512
        return NFSAttr(
            type: ftype,
            mode: mode,
            nlink: max(1, UInt32(st.st_nlink)),
            uid: st.st_uid,
            gid: st.st_gid,
            size: size,
            used: used,
            fsid: fsid,
            fileid: fileid,
            atimeSec: UInt32(max(0, st.st_atimespec.tv_sec)),
            atimeNsec: UInt32(max(0, st.st_atimespec.tv_nsec)),
            mtimeSec: UInt32(max(0, st.st_mtimespec.tv_sec)),
            mtimeNsec: UInt32(max(0, st.st_mtimespec.tv_nsec)),
            ctimeSec: UInt32(max(0, st.st_ctimespec.tv_sec)),
            ctimeNsec: UInt32(max(0, st.st_ctimespec.tv_nsec))
        )
    }
}

// MARK: - Persisted Whiteouts & Opaque Directories

private struct WhiteoutState: Codable {
    var version: Int = 1
    var whiteouts: [String] = []
    var opaqueDirs: [String] = []
}

// MARK: - Per-Session Copy-on-Write Overlay Export

private final class OverlayExport {
    let sessionID: String
    let slotID: UInt16
    let fsid: UInt64
    let lowerRoot: String
    let upperRoot: String
    let whiteoutFile: String
    let mountPoint: String
    let excludeEnv: Bool

    let lock = NSLock()
    /// One-shot 128-bit export path token; cleared immediately after successful MOUNTv3 MNT.
    var pendingMountToken: String?

    /// Relative paths hidden from lower (deleted or renamed away).
    private var whiteouts: Set<String> = []
    /// Relative directory paths whose lower contents are completely masked (e.g. rm -rf dir && mkdir dir).
    private var opaqueDirs: Set<String> = []
    /// Ancestor directory paths that actually have entries inside `upperRoot` (empty on fresh sessions -> skips 100% of redundant `lstatUpper` calls!).
    private var upperTouchedDirs: Set<String> = []

    /// Fast in-memory cryptographic handle generator (1 CSPRNG seed at mount -> 0 syscalls per file!).
    private let handleKey: SymmetricKey
    private var nextHandleSeq: UInt64 = 1

    /// Bi-directional 16-byte cryptographic filehandle <-> relative path table ("" = root).
    private var handleToPath: [Data: String] = [:]
    private var pathToHandle: [String: Data] = [:]
    let rootHandle: Data

    /// O(1) paginated READDIR / READDIRPLUS cache invalidated on mutation or lower mtime change.
    private struct CachedDirListing {
        let version: UInt64
        let lowerMtimeSec: Int
        let lowerMtimeNsec: Int
        let entries: [String]
    }
    private var dirCacheVersion: UInt64 = 1
    private var dirListCache: [String: CachedDirListing] = [:]

    init(
        sessionID: String,
        slotID: UInt16,
        fsid: UInt64,
        lowerRoot: String,
        upperRoot: String,
        whiteoutFile: String,
        mountPoint: String,
        excludeEnv: Bool
    ) {
        self.sessionID = sessionID
        self.slotID = slotID
        self.fsid = fsid
        self.lowerRoot = URL(fileURLWithPath: lowerRoot).resolvingSymlinksInPath().path
        self.upperRoot = URL(fileURLWithPath: upperRoot).resolvingSymlinksInPath().path
        self.whiteoutFile = whiteoutFile
        self.mountPoint = mountPoint
        self.excludeEnv = excludeEnv
        self.pendingMountToken = "/\(sessionID)-\(randomHex(16))"
        self.handleKey = SymmetricKey(data: randomBytes(32))

        var seq: UInt64 = 0
        let mac = HMAC<SHA256>.authenticationCode(for: withUnsafeBytes(of: &seq) { Data($0) }, using: self.handleKey)
        var rh = Data(capacity: 16)
        rh.append(UInt8((slotID >> 8) & 0xFF))
        rh.append(UInt8(slotID & 0xFF))
        rh.append(contentsOf: mac.prefix(14))
        self.rootHandle = rh
        self.handleToPath[rh] = ""
        self.pathToHandle[""] = rh

        loadWhiteoutsLocked()
        scanExistingUpperLocked()
    }

    /// Indexes any pre-existing files/dirs in `upperRoot` when resuming a persisted session (<1 ms).
    private func scanExistingUpperLocked() {
        guard let en = FileManager.default.enumerator(atPath: upperRoot) else { return }
        while let rel = en.nextObject() as? String {
            markUpperMutatedLocked(rel)
        }
    }

    func markUpperMutatedLocked(_ rel: String) {
        dirCacheVersion &+= 1
        upperTouchedDirs.insert("")
        var cur = rel
        while !cur.isEmpty {
            upperTouchedDirs.insert(cur)
            guard let idx = cur.lastIndex(of: "/") else { break }
            cur = String(cur[..<idx])
        }
    }

    func bumpDirCacheLocked() {
        dirCacheVersion &+= 1
    }

    // MARK: Whiteouts & Opaque Persistence

    private func loadWhiteoutsLocked() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: whiteoutFile)),
              let state = try? JSONDecoder().decode(WhiteoutState.self, from: data) else {
            return
        }
        whiteouts = Set(state.whiteouts)
        opaqueDirs = Set(state.opaqueDirs)
    }

    private func saveWhiteoutsLocked() {
        dirCacheVersion &+= 1
        let state = WhiteoutState(
            version: 1,
            whiteouts: whiteouts.sorted(),
            opaqueDirs: opaqueDirs.sorted()
        )
        let url = URL(fileURLWithPath: whiteoutFile)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Handle & Path Helpers (must hold lock)

    func handleForPathLocked(_ rel: String) -> Data {
        if let existing = pathToHandle[rel] {
            return existing
        }
        var seq = nextHandleSeq
        nextHandleSeq &+= 1
        let mac = HMAC<SHA256>.authenticationCode(for: withUnsafeBytes(of: &seq) { Data($0) }, using: handleKey)
        var h = Data(capacity: 16)
        h.append(UInt8((slotID >> 8) & 0xFF))
        h.append(UInt8(slotID & 0xFF))
        h.append(contentsOf: mac.prefix(14))
        handleToPath[h] = rel
        pathToHandle[rel] = h
        return h
    }

    func pathForHandleLocked(_ handle: Data) -> String? {
        handleToPath[handle]
    }
    func fileID(for handle: Data) -> UInt64 {
        guard handle.count >= 8 else { return 1 }
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(handle[i])
        }
        return v == 0 ? 1 : v
    }

    func joinRel(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : "\(parent)/\(name)"
    }

    func parentRel(_ rel: String) -> String {
        guard let idx = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<idx])
    }

    func fullUpper(_ rel: String) -> String {
        rel.isEmpty ? upperRoot : "\(upperRoot)/\(rel)"
    }

    func fullLower(_ rel: String) -> String {
        rel.isEmpty ? lowerRoot : "\(lowerRoot)/\(rel)"
    }

    private func isContained(_ candidate: String, inside root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }

    /// True if `rel` or any of its ancestor directories is whiteout-deleted OR masked by an opaque ancestor.
    func isMaskedInLowerLocked(_ rel: String) -> Bool {
        if rel.isEmpty { return false }
        if !whiteouts.isEmpty || !opaqueDirs.isEmpty {
            if whiteouts.contains(rel) { return true }
            var cur = rel
            while let idx = cur.lastIndex(of: "/") {
                cur = String(cur[..<idx])
                if whiteouts.contains(cur) || opaqueDirs.contains(cur) {
                    return true
                }
            }
        }
        if excludeEnv {
            let last = rel.lastIndex(of: "/").map { String(rel[rel.index(after: $0)...]) } ?? rel
            if isHiddenEnvFilename(last) { return true }
        }
        return false
    }

    func lstatUpperLocked(_ rel: String) -> stat? {
        if upperTouchedDirs.isEmpty { return nil }
        if !rel.isEmpty {
            let parent = parentRel(rel)
            if !upperTouchedDirs.contains(parent) { return nil }
        }
        let p = fullUpper(rel)
        guard isContained(p, inside: upperRoot) else { return nil }
        var st = stat()
        guard lstat(p, &st) == 0 else { return nil }
        return st
    }
    func lstatLowerLocked(_ rel: String) -> stat? {
        if isMaskedInLowerLocked(rel) { return nil }
        let p = fullLower(rel)
        guard isContained(p, inside: lowerRoot) else { return nil }
        var st = stat()
        guard lstat(p, &st) == 0 else { return nil }
        return st
    }

    enum ResolvedLayer {
        case upper(path: String, st: stat)
        case lower(path: String, st: stat)
    }

    func resolveLocked(_ rel: String) -> ResolvedLayer? {
        if let st = lstatUpperLocked(rel) {
            return .upper(path: fullUpper(rel), st: st)
        }
        if let st = lstatLowerLocked(rel) {
            return .lower(path: fullLower(rel), st: st)
        }
        return nil
    }

    func attrLocked(for rel: String) -> NFSAttr? {
        guard let layer = resolveLocked(rel) else { return nil }
        let h = handleForPathLocked(rel)
        let fid = fileID(for: h)
        switch layer {
        case .upper(_, let st): return NFSAttr.fromStat(st, fsid: fsid, fileid: fid)
        case .lower(_, let st): return NFSAttr.fromStat(st, fsid: fsid, fileid: fid)
        }
    }

    // MARK: Copy-on-Write Materialization (strictly lower RO -> upper RW)

    /// Ensures every ancestor directory of `rel` exists in `upperRoot`.
    func ensureUpperParentsLocked(for rel: String) throws {
        let parent = parentRel(rel)
        guard !parent.isEmpty else { return }
        try ensureUpperDirLocked(parent)
    }

    /// Ensures directory `rel` exists in `upperRoot` (preserving permissions from lower if present).
    func ensureUpperDirLocked(_ rel: String) throws {
        guard !rel.isEmpty else { return }
        if let st = lstatUpperLocked(rel) {
            if (st.st_mode & S_IFMT) == S_IFDIR { return }
            throw POSIXError(.ENOTDIR)
        }
        try ensureUpperParentsLocked(for: rel)
        let upPath = fullUpper(rel)
        let mode: mode_t
        if let lst = lstatLowerLocked(rel), (lst.st_mode & S_IFMT) == S_IFDIR {
            mode = (lst.st_mode & 0o7777) | 0o700
        } else {
            mode = 0o755
        }
        if mkdir(upPath, mode) != 0 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        markUpperMutatedLocked(rel)
    }

    /// Copies a file, symlink, or directory from `lower` into `upper` without ever opening `lower` for write.
    func copyUpLocked(_ rel: String) throws -> String {
        if let _ = lstatUpperLocked(rel) {
            return fullUpper(rel)
        }
        guard let lst = lstatLowerLocked(rel) else {
            throw POSIXError(.ENOENT)
        }
        let lowPath = fullLower(rel)
        let upPath = fullUpper(rel)
        try ensureUpperParentsLocked(for: rel)
        markUpperMutatedLocked(rel)
        let ftype = lst.st_mode & S_IFMT
        if ftype == S_IFDIR {
            try ensureUpperDirLocked(rel)
            return upPath
        } else if ftype == S_IFLNK {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(lowPath, &buf, Int(PATH_MAX))
            guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if symlink(target, upPath) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return upPath
        } else if ftype == S_IFREG {
            // Fast path: APFS clonefile(2) with CLONE_NOFOLLOW (0 extra SSD blocks, ~0.05 ms!)
            if clonefile(lowPath, upPath, UInt32(CLONE_NOFOLLOW)) == 0 {
                // Ensure owner-writable if the file was read-only and is being modified? Preserve exact mode; caller handles SETATTR/WRITE.
                return upPath
            }
            // Fallback: O_RDONLY | O_NOFOLLOW stream copy (handles cross-volume mounts cleanly)
            let rfd = Darwin.open(lowPath, O_RDONLY | O_NOFOLLOW)
            guard rfd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(rfd) }

            let mode = lst.st_mode & 0o7777
            let wfd = Darwin.open(upPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
            guard wfd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(wfd) }

            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(rfd, &chunk, chunk.count)
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    let e = errno
                    unlink(upPath)
                    throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
                }
                var written = 0
                while written < n {
                    let w = chunk.withUnsafeBytes { ptr in
                        Darwin.write(wfd, ptr.baseAddress!.advanced(by: written), n - written)
                    }
                    if w < 0 {
                        if errno == EINTR { continue }
                        let e = errno
                        unlink(upPath)
                        throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
                    }
                    written += w
                }
            }
            var times = [lst.st_atimespec, lst.st_mtimespec]
            futimens(wfd, &times)
            return upPath
        } else {
            throw POSIXError(.EOPNOTSUPP)
        }
    }

    /// Recursively materializes an entire merged directory subtree into `dstRel` inside `upper` (used for directory RENAME).
    func materializeMergedTreeLocked(from srcRel: String, to dstRel: String) throws {
        guard let layer = resolveLocked(srcRel) else { throw POSIXError(.ENOENT) }
        let st: stat
        switch layer {
        case .upper(_, let s): st = s
        case .lower(_, let s): st = s
        }
        let ftype = st.st_mode & S_IFMT
        if ftype != S_IFDIR {
            // Single file/symlink copy to dstRel in upper
            try ensureUpperParentsLocked(for: dstRel)
            let srcPath: String
            switch layer {
            case .upper(let p, _): srcPath = p
            case .lower(let p, _): srcPath = p
            }
            let dstPath = fullUpper(dstRel)
            _ = unlink(dstPath)
            if ftype == S_IFLNK {
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(srcPath, &buf, Int(PATH_MAX))
                guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if symlink(target, dstPath) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else if clonefile(srcPath, dstPath, UInt32(CLONE_NOFOLLOW)) != 0 {
                // Fallback copy
                let rfd = Darwin.open(srcPath, O_RDONLY | O_NOFOLLOW)
                guard rfd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { Darwin.close(rfd) }
                let wfd = Darwin.open(dstPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, st.st_mode & 0o7777)
                guard wfd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { Darwin.close(wfd) }
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = Darwin.read(rfd, &buf, buf.count)
                    if n <= 0 { break }
                    _ = buf.withUnsafeBytes { Darwin.write(wfd, $0.baseAddress!, n) }
                }
            }
            return
        }

        // Directory: create dstRel in upper and recursively copy all visible merged children
        try ensureUpperParentsLocked(for: dstRel)
        let dstPath = fullUpper(dstRel)
        if mkdir(dstPath, (st.st_mode & 0o7777) | 0o700) != 0 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let entries = mergedDirEntriesLocked(relDir: srcRel)
        for name in entries {
            try materializeMergedTreeLocked(from: joinRel(srcRel, name), to: joinRel(dstRel, name))
        }
    }

    /// Returns sorted visible entry names in merged directory `relDir`.
    func mergedDirEntriesLocked(relDir: String) -> [String] {
        // Check O(1) directory listing cache first (critical for paginated READDIRPLUS on large dirs!)
        let lowDir = fullLower(relDir)
        var lowSt = stat()
        let hasLow = isContained(lowDir, inside: lowerRoot) && (lstat(lowDir, &lowSt) == 0)
        let lowSec = hasLow ? lowSt.st_mtimespec.tv_sec : -1
        let lowNsec = hasLow ? lowSt.st_mtimespec.tv_nsec : -1
        if let cached = dirListCache[relDir],
           cached.version == dirCacheVersion,
           cached.lowerMtimeSec == lowSec,
           cached.lowerMtimeNsec == lowNsec {
            return cached.entries
        }

        var names = Set<String>()

        // 1. Upper entries (skip opendir completely when upper has never touched this dir!)
        if upperTouchedDirs.contains(relDir) {
            let upDir = fullUpper(relDir)
            if isContained(upDir, inside: upperRoot), let dp = opendir(upDir) {
                defer { closedir(dp) }
                while let ent = readdir(dp) {
                    let name = withUnsafePointer(to: ent.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) {
                            String(cString: $0)
                        }
                    }
                    if name == "." || name == ".." { continue }
                    names.insert(name)
                }
            }
        }

        // 2. Lower entries (unless directory is opaque or whiteout-masked)
        let lowerBlocked = !relDir.isEmpty && (opaqueDirs.contains(relDir) || isMaskedInLowerLocked(relDir))
        if !lowerBlocked && hasLow, let dp = opendir(lowDir) {
            defer { closedir(dp) }
            while let ent = readdir(dp) {
                let name = withUnsafePointer(to: ent.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                if excludeEnv && isHiddenEnvFilename(name) { continue }
                if !whiteouts.isEmpty && whiteouts.contains(joinRel(relDir, name)) { continue }
                names.insert(name)
            }
        }

        let sorted = names.sorted()
        if dirListCache.count > 4096 {
            dirListCache.removeAll(keepingCapacity: true)
        }
        dirListCache[relDir] = CachedDirListing(
            version: dirCacheVersion,
            lowerMtimeSec: lowSec,
            lowerMtimeNsec: lowNsec,
            entries: sorted
        )
        return sorted
    }
    func markWhiteoutLocked(_ rel: String) {
        guard !rel.isEmpty else { return }
        whiteouts.insert(rel)
        opaqueDirs.remove(rel)
        // Drop any nested opaque/whiteout records under rel to keep state compact
        let prefix = rel + "/"
        whiteouts = whiteouts.filter { !$0.hasPrefix(prefix) }
        opaqueDirs = opaqueDirs.filter { !$0.hasPrefix(prefix) }
        saveWhiteoutsLocked()
    }

    func clearWhiteoutLocked(_ rel: String, markOpaqueIfLowerDirExists: Bool) {
        let changed1 = whiteouts.remove(rel) != nil
        var changed2 = false
        if markOpaqueIfLowerDirExists {
            let lowPath = fullLower(rel)
            var st = stat()
            if lstat(lowPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR {
                opaqueDirs.insert(rel)
                changed2 = true
            }
        }
        if changed1 || changed2 {
            saveWhiteoutsLocked()
        }
    }

    func renameHandlesLocked(from oldRel: String, to newRel: String) {
        let oldPrefix = oldRel + "/"
        var updates: [(Data, String)] = []
        for (h, p) in handleToPath {
            if p == oldRel {
                updates.append((h, newRel))
            } else if p.hasPrefix(oldPrefix) {
                let suffix = String(p.dropFirst(oldPrefix.count))
                updates.append((h, "\(newRel)/\(suffix)"))
            }
        }
        // Evict any handles previously pointing to overwritten dst
        let newPrefix = newRel + "/"
        var toEvict: [Data] = []
        for (h, p) in handleToPath where p == newRel || p.hasPrefix(newPrefix) {
            if !updates.contains(where: { $0.0 == h }) {
                toEvict.append(h)
            }
        }
        for h in toEvict {
            if let p = handleToPath.removeValue(forKey: h) {
                pathToHandle.removeValue(forKey: p)
            }
        }
        for (h, newPath) in updates {
            if let oldP = handleToPath[h] {
                pathToHandle.removeValue(forKey: oldP)
            }
            handleToPath[h] = newPath
            pathToHandle[newPath] = h
        }
    }

    func removeUpperTreeLocked(_ path: String) {
        guard isContained(path, inside: upperRoot), path != upperRoot else { return }
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            if let dp = opendir(path) {
                var children: [String] = []
                while let ent = readdir(dp) {
                    let name = withUnsafePointer(to: ent.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) {
                            String(cString: $0)
                        }
                    }
                    if name == "." || name == ".." { continue }
                    children.append(name)
                }
                closedir(dp)
                for c in children {
                    removeUpperTreeLocked(path + "/" + c)
                }
            }
            _ = rmdir(path)
        } else {
            _ = unlink(path)
        }
    }

    func statsSummary() -> (upperFiles: Int, whiteouts: Int) {
        lock.lock()
        let wh = whiteouts.count + opaqueDirs.count
        lock.unlock()
        var cnt = 0
        if let en = FileManager.default.enumerator(atPath: upperRoot) {
            while en.nextObject() != nil { cnt += 1 }
        }
        return (cnt, wh)
    }
}

// MARK: - Overlay Server & RPC Dispatcher

private final class OverlayDaemon: @unchecked Sendable {
    let port: UInt16
    let tcpFD: Int32
    let writeVerifier: Data = randomBytes(8)

    private let registryLock = NSLock()
    private var exportsBySession: [String: OverlayExport] = [:]
    private var exportsBySlot: [UInt16: OverlayExport] = [:]
    private var nextSlotID: UInt16 = 1
    private var nextFSID: UInt64 = 100
    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bres = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bres == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &blen)
            }
        }
        self.tcpFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    func startAcceptingNFS() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let cfd = Darwin.accept(tcpFD, nil, nil)
                if cfd < 0 {
                    if errno == EINTR { continue }
                    usleep(10_000)
                    continue
                }
                var one: Int32 = 1
                setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global(qos: .userInitiated).async {
                    self.serveTCPConnection(cfd)
                }
            }
        }
    }

    // MARK: Export Registry (Mount / Unmount)

    func mountSession(
        sessionID: String,
        lowerDir: String,
        upperDir: String,
        whiteoutFile: String,
        mountPoint: String,
        excludeEnv: Bool
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: upperDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        let canonicalMnt = URL(fileURLWithPath: mountPoint).resolvingSymlinksInPath().path

        // Check if already registered and mounted
        registryLock.lock()
        if let existing = exportsBySession[sessionID], isPathNFSMounted(existing.mountPoint) {
            registryLock.unlock()
            return
        }
        registryLock.unlock()

        // If a stale mount is sitting on mountPoint from a prior daemon, unmount it cleanly first
        if isPathNFSMounted(canonicalMnt) {
            _ = runProcess("/sbin/umount", ["-f", canonicalMnt])
        }

        registryLock.lock()
        nextFSID += 1
        let fsid = nextFSID
        var slot = nextSlotID
        nextSlotID = (nextSlotID == UInt16.max) ? 1 : (nextSlotID + 1)
        while exportsBySlot[slot] != nil {
            slot = (slot == UInt16.max) ? 1 : (slot + 1)
        }
        let exp = OverlayExport(
            sessionID: sessionID,
            slotID: slot,
            fsid: fsid,
            lowerRoot: lowerDir,
            upperRoot: upperDir,
            whiteoutFile: whiteoutFile,
            mountPoint: canonicalMnt,
            excludeEnv: excludeEnv
        )
        exportsBySession[sessionID] = exp
        exportsBySlot[slot] = exp
        let token = exp.pendingMountToken!
        registryLock.unlock()

        let opts = "vers=3,tcp,nolocks,noacl,rsize=\(MAX_IO_BYTES),wsize=\(MAX_IO_BYTES),acregmin=5,acregmax=30,acdirmin=5,acdirmax=30,port=\(port),mountport=\(port)"
        let (rc, stderr) = runProcess("/sbin/mount_nfs", ["-o", opts, "127.0.0.1:\(token)", canonicalMnt])

        // Always invalidate one-shot mount token immediately after mount_nfs finishes
        exp.lock.lock()
        exp.pendingMountToken = nil
        exp.lock.unlock()

        guard rc == 0 else {
            registryLock.lock()
            exportsBySession.removeValue(forKey: sessionID)
            exportsBySlot.removeValue(forKey: slot)
            registryLock.unlock()
            throw NSError(
                domain: "BooBoxOverlay",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "mount_nfs failed (exit \(rc)): \(stderr)"]
            )
        }
    }

    func unmountSession(sessionID: String) {
        registryLock.lock()
        let exp = exportsBySession[sessionID]
        registryLock.unlock()

        guard let exp else { return }
        let mnt = exp.mountPoint
        // Unmount BEFORE removing export so the kernel flushes cleanly with zero ESTALE!
        var unmounted = false
        for attempt in 0..<4 {
            let (rc, _) = runProcess("/sbin/umount", [mnt])
            if rc == 0 {
                unmounted = true
                break
            }
            if attempt >= 1 {
                let (rc2, _) = runProcess("/sbin/umount", ["-f", mnt])
                if rc2 == 0 {
                    unmounted = true
                    break
                }
            }
            usleep(80_000)
        }
        if !unmounted {
            _ = runProcess("/usr/sbin/diskutil", ["unmount", "force", mnt])
        }

        registryLock.lock()
        if exportsBySession[sessionID] === exp {
            exportsBySession.removeValue(forKey: sessionID)
            exportsBySlot.removeValue(forKey: exp.slotID)
        }
        registryLock.unlock()
    }

    func listMountedSessions() -> [[String: Any]] {
        registryLock.lock()
        let all = Array(exportsBySession.values)
        registryLock.unlock()
        return all.map { exp in
            [
                "sessionId": exp.sessionID,
                "lowerDir": exp.lowerRoot,
                "mountPoint": exp.mountPoint,
                "mounted": isPathNFSMounted(exp.mountPoint),
            ]
        }
    }

    /// O(1) direct export lookup via 2-byte slot prefix + 128-bit handle table verification.
    private func resolveExportAndPath(handle: Data) -> (OverlayExport, String)? {
        guard handle.count == 16 else { return nil }
        let slot = (UInt16(handle[0]) << 8) | UInt16(handle[1])
        registryLock.lock()
        let exp = exportsBySlot[slot]
        registryLock.unlock()
        guard let exp else { return nil }
        exp.lock.lock()
        let p = exp.pathForHandleLocked(handle)
        exp.lock.unlock()
        if let p { return (exp, p) }
        return nil
    }
    private func claimExportByMountToken(_ token: String) -> OverlayExport? {
        registryLock.lock()
        let exports = Array(exportsBySession.values)
        registryLock.unlock()
        for exp in exports {
            exp.lock.lock()
            let matches = (exp.pendingMountToken == token)
            if matches {
                exp.pendingMountToken = nil
            }
            exp.lock.unlock()
            if matches { return exp }
        }
        return nil
    }

    // MARK: SunRPC TCP Framing (RFC 5531 Record Marking)

    private func readExact(fd: Int32, count: Int) -> Data? {
        var out = Data(count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: got), count - got)
            }
            if n == 0 { return nil }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            got += n
        }
        return out
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return true }
            while sent < data.count {
                let n = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }

    private func serveTCPConnection(_ fd: Int32) {
        let writeLock = NSLock()
        let inflight = DispatchGroup()
        defer {
            inflight.wait()
            Darwin.close(fd)
        }
        while true {
            var message = Data()
            var isLast = false
            while !isLast {
                guard let header = readExact(fd: fd, count: 4) else { return }
                let word = (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) | (UInt32(header[2]) << 8) | UInt32(header[3])
                isLast = (word & 0x8000_0000) != 0
                let fragLen = Int(word & 0x7FFF_FFFF)
                if fragLen == 0 { continue }
                guard message.count + fragLen <= MAX_RPC_FRAGMENT else { return }
                guard let frag = readExact(fd: fd, count: fragLen) else { return }
                message.append(frag)
            }
            let rpcBytes = message
            inflight.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { inflight.leave() }
                guard let reply = self.dispatchRPC(rpcBytes) else { return }
                var frame = Data(capacity: 4 + reply.count)
                var rm = (UInt32(0x8000_0000) | UInt32(reply.count)).bigEndian
                withUnsafeBytes(of: &rm) { frame.append(contentsOf: $0) }
                frame.append(reply)
                writeLock.lock()
                _ = self.writeAll(fd: fd, data: frame)
                writeLock.unlock()
            }
        }
    }

    private func makeAcceptedReplyHeader(xid: UInt32, acceptStat: UInt32 = 0) -> XDRWriter {
        var w = XDRWriter(capacity: 256)
        w.writeUInt32(xid)
        w.writeUInt32(1)          // REPLY
        w.writeUInt32(0)          // MSG_ACCEPTED
        w.writeUInt32(0)          // AUTH_NULL
        w.writeUInt32(0)          // verifier len 0
        w.writeUInt32(acceptStat) // SUCCESS = 0
        return w
    }

    private func dispatchRPC(_ msg: Data) -> Data? {
        var r = XDRReader(data: msg)
        guard let xid = r.readUInt32(),
              let mtype = r.readUInt32(), mtype == 0, // CALL
              let rpcver = r.readUInt32(), rpcver == 2,
              let prog = r.readUInt32(),
              let vers = r.readUInt32(),
              let proc = r.readUInt32(),
              r.skipAuth(), // cred
              r.skipAuth()  // verf
        else {
            return nil
        }

        if prog == PROG_MOUNT && vers == VERS_MOUNT3 {
            return handleMount3(xid: xid, proc: proc, r: &r)
        }
        if prog == PROG_NFS && vers == VERS_NFS3 {
            return handleNFS3(xid: xid, proc: proc, r: &r)
        }
        let w = makeAcceptedReplyHeader(xid: xid, acceptStat: 1) // PROG_UNAVAIL
        return w.data
    }

    // MARK: MOUNTv3 Procedures

    private func handleMount3(xid: UInt32, proc: UInt32, r: inout XDRReader) -> Data {
        var w = makeAcceptedReplyHeader(xid: xid)
        switch proc {
        case 0: // NULL
            return w.data
        case 1: // MNT
            guard let dirpath = r.readString() else {
                w.writeUInt32(NFS3ERR_INVAL)
                return w.data
            }
            guard let exp = claimExportByMountToken(dirpath) else {
                w.writeUInt32(NFS3ERR_ACCES)
                return w.data
            }
            w.writeUInt32(NFS3_OK)
            w.writeOpaque(exp.rootHandle)
            w.writeUInt32(1) // 1 auth flavor
            w.writeUInt32(0) // AUTH_NULL
            return w.data
        case 3, 4: // UMNT / UMNTALL
            return w.data
        default:
            return makeAcceptedReplyHeader(xid: xid, acceptStat: 3).data // PROC_UNAVAIL
        }
    }

    // MARK: NFSv3 Procedures (RFC 1813)

    private func handleNFS3(xid: UInt32, proc: UInt32, r: inout XDRReader) -> Data {
        var w = makeAcceptedReplyHeader(xid: xid)
        switch proc {
        case 0: // NULL
            return w.data

        case 1: // GETATTR
            guard let fh = r.readOpaque(maxLength: 64),
                  let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                return w.data
            }
            exp.lock.lock()
            let attr = exp.attrLocked(for: rel)
            exp.lock.unlock()
            guard let attr else {
                w.writeUInt32(NFS3ERR_NOENT)
                return w.data
            }
            w.writeUInt32(NFS3_OK)
            w.writeFattr3(attr)
            return w.data

        case 2: // SETATTR
            guard let fh = r.readOpaque(maxLength: 64),
                  let sattr = readSattr3(&r),
                  let hasGuard = r.readUInt32() else {
                w.writeUInt32(NFS3ERR_INVAL)
                return w.data
            }
            if hasGuard != 0 {
                _ = r.readUInt32(); _ = r.readUInt32() // guard ctime
            }
            guard let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            let pre = exp.attrLocked(for: rel)
            do {
                let upPath = try exp.copyUpLocked(rel)
                applySattr3(sattr, to: upPath)
                let post = exp.attrLocked(for: rel)
                w.writeUInt32(NFS3_OK)
                w.writeWccData(pre: pre, post: post)
            } catch let err as POSIXError {
                w.writeUInt32(nfsStatus(fromErrno: err.code.rawValue))
                w.writeWccData(pre: pre, post: exp.attrLocked(for: rel))
            } catch {
                w.writeUInt32(NFS3ERR_IO)
                w.writeWccData(pre: pre, post: exp.attrLocked(for: rel))
            }
            return w.data

        case 3: // LOOKUP
            guard let dirFH = r.readOpaque(maxLength: 64),
                  let name = r.readString() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writePostOpAttr(nil)
                return w.data
            }
            guard let (exp, dirRel) = resolveExportAndPath(handle: dirFH) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writePostOpAttr(nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            let dirAttr = exp.attrLocked(for: dirRel)

            let targetRel: String
            if name == "." {
                targetRel = dirRel
            } else if name == ".." {
                targetRel = exp.parentRel(dirRel)
            } else if isSafeSingleComponent(name) {
                targetRel = exp.joinRel(dirRel, name)
            } else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writePostOpAttr(dirAttr)
                return w.data
            }

            guard let objAttr = exp.attrLocked(for: targetRel) else {
                w.writeUInt32(NFS3ERR_NOENT)
                w.writePostOpAttr(dirAttr)
                return w.data
            }
            let objFH = exp.handleForPathLocked(targetRel)
            w.writeUInt32(NFS3_OK)
            w.writeOpaque(objFH)
            w.writePostOpAttr(objAttr)
            w.writePostOpAttr(dirAttr)
            return w.data

        case 4: // ACCESS
            guard let fh = r.readOpaque(maxLength: 64),
                  let requested = r.readUInt32() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writePostOpAttr(nil)
                return w.data
            }
            guard let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writePostOpAttr(nil)
                return w.data
            }
            exp.lock.lock()
            let attr = exp.attrLocked(for: rel)
            exp.lock.unlock()
            guard let attr else {
                w.writeUInt32(NFS3ERR_NOENT)
                w.writePostOpAttr(nil)
                return w.data
            }
            var granted: UInt32 = 0
            if (attr.mode & 0o444) != 0 { granted |= 0x01 | 0x02 } // READ | LOOKUP
            if (attr.mode & 0o222) != 0 { granted |= 0x04 | 0x08 | 0x10 } // MODIFY | EXTEND | DELETE
            if (attr.mode & 0o111) != 0 { granted |= 0x20 } // EXECUTE
            if attr.type == NF3DIR { granted |= 0x3f }
            w.writeUInt32(NFS3_OK)
            w.writePostOpAttr(attr)
            w.writeUInt32(requested & granted)
            return w.data

        case 5: // READLINK
            guard let fh = r.readOpaque(maxLength: 64),
                  let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writePostOpAttr(nil)
                return w.data
            }
            exp.lock.lock()
            let resolved = exp.resolveLocked(rel)
            let attr = exp.attrLocked(for: rel)
            exp.lock.unlock()
            guard let resolved else {
                w.writeUInt32(NFS3ERR_NOENT)
                w.writePostOpAttr(attr)
                return w.data
            }
            let path: String
            switch resolved {
            case .upper(let p, _): path = p
            case .lower(let p, _): path = p
            }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(path, &buf, Int(PATH_MAX))
            guard n >= 0 else {
                w.writeUInt32(nfsStatus(fromErrno: errno))
                w.writePostOpAttr(attr)
                return w.data
            }
            let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            w.writeUInt32(NFS3_OK)
            w.writePostOpAttr(attr)
            w.writeString(target)
            return w.data

        case 6: // READ
            guard let fh = r.readOpaque(maxLength: 64),
                  let offset = r.readUInt64(),
                  let reqCount = r.readUInt32() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writePostOpAttr(nil)
                return w.data
            }
            guard let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writePostOpAttr(nil)
                return w.data
            }
            exp.lock.lock()
            let resolved = exp.resolveLocked(rel)
            let attr = exp.attrLocked(for: rel)
            exp.lock.unlock()
            guard let resolved, let attr else {
                w.writeUInt32(NFS3ERR_NOENT)
                w.writePostOpAttr(nil)
                return w.data
            }
            let path: String
            switch resolved {
            case .upper(let p, _): path = p
            case .lower(let p, _): path = p
            }
            let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else {
                w.writeUInt32(nfsStatus(fromErrno: errno))
                w.writePostOpAttr(attr)
                return w.data
            }
            defer { Darwin.close(fd) }

            let count = Int(min(reqCount, MAX_IO_BYTES))
            var buf = Data(count: count)
            let n = buf.withUnsafeMutableBytes { ptr in
                pread(fd, ptr.baseAddress!, count, off_t(offset))
            }
            guard n >= 0 else {
                w.writeUInt32(nfsStatus(fromErrno: errno))
                w.writePostOpAttr(attr)
                return w.data
            }
            buf.count = n
            let eof = (offset + UInt64(n)) >= attr.size
            w.writeUInt32(NFS3_OK)
            w.writePostOpAttr(attr)
            w.writeUInt32(UInt32(n))
            w.writeBool(eof)
            w.writeOpaque(buf)
            return w.data

        case 7: // WRITE
            guard let fh = r.readOpaque(maxLength: 64),
                  let offset = r.readUInt64(),
                  let _ = r.readUInt32(), // count
                  let stable = r.readUInt32(),
                  let payload = r.readOpaque(maxLength: Int(MAX_IO_BYTES)) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            guard let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            let pre = exp.attrLocked(for: rel)
            let upPath: String
            do {
                upPath = try exp.copyUpLocked(rel)
            } catch let err as POSIXError {
                let post = exp.attrLocked(for: rel)
                exp.lock.unlock()
                w.writeUInt32(nfsStatus(fromErrno: err.code.rawValue))
                w.writeWccData(pre: pre, post: post)
                return w.data
            } catch {
                let post = exp.attrLocked(for: rel)
                exp.lock.unlock()
                w.writeUInt32(NFS3ERR_IO)
                w.writeWccData(pre: pre, post: post)
                return w.data
            }
            exp.lock.unlock()

            var savedReadOnlyMode: mode_t? = nil
            var fd = Darwin.open(upPath, O_WRONLY | O_NOFOLLOW)
            if fd < 0 && errno == EACCES {
                // POSIX allows writing to a newly created 0444 file (e.g. Git loose objects) via an open fd,
                // whereas stateless NFSv3 WRITE re-opens the path -> temporarily grant owner-write and restore!
                var st = stat()
                if lstat(upPath, &st) == 0 {
                    let origMode = st.st_mode & 0o7777
                    if chmod(upPath, origMode | 0o200) == 0 {
                        savedReadOnlyMode = origMode
                        fd = Darwin.open(upPath, O_WRONLY | O_NOFOLLOW)
                    }
                }
            }
            guard fd >= 0 else {
                let e = errno
                if let orig = savedReadOnlyMode { _ = chmod(upPath, orig) }
                exp.lock.lock()
                let post = exp.attrLocked(for: rel)
                exp.lock.unlock()
                w.writeUInt32(nfsStatus(fromErrno: e))
                w.writeWccData(pre: pre, post: post)
                return w.data
            }
            defer {
                Darwin.close(fd)
                if let orig = savedReadOnlyMode { _ = chmod(upPath, orig) }
            }
            let written = payload.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress, !payload.isEmpty else { return 0 }
                return pwrite(fd, base, payload.count, off_t(offset))
            }
            guard written >= 0 else {
                let e = errno
                exp.lock.lock()
                let post = exp.attrLocked(for: rel)
                exp.lock.unlock()
                w.writeUInt32(nfsStatus(fromErrno: e))
                w.writeWccData(pre: pre, post: post)
                return w.data
            }
            if stable != 0 {
                _ = fsync(fd)
            }
            exp.lock.lock()
            let post = exp.attrLocked(for: rel)
            exp.lock.unlock()
            w.writeUInt32(NFS3_OK)
            w.writeWccData(pre: pre, post: post)
            w.writeUInt32(UInt32(written))
            w.writeUInt32(stable == 0 ? 0 : 2) // UNSTABLE or FILE_SYNC
            w.writeFixedBytes(writeVerifier)
            return w.data

        case 8: // CREATE
            guard let dirFH = r.readOpaque(maxLength: 64),
                  let name = r.readString(),
                  let modeEnum = r.readUInt32() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            var sattr: Sattr3? = nil
            if modeEnum == 0 || modeEnum == 1 { // UNCHECKED / GUARDED
                sattr = readSattr3(&r)
            } else { // EXCLUSIVE: 8-byte createverf
                _ = r.readFixedOpaque(8)
            }
            guard let (exp, dirRel) = resolveExportAndPath(handle: dirFH) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            let preDir = exp.attrLocked(for: dirRel)
            guard isSafeSingleComponent(name) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let childRel = exp.joinRel(dirRel, name)
            if (modeEnum == 1 || modeEnum == 2) && exp.resolveLocked(childRel) != nil {
                w.writeUInt32(NFS3ERR_EXIST)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            do {
                try exp.ensureUpperDirLocked(dirRel)
                exp.clearWhiteoutLocked(childRel, markOpaqueIfLowerDirExists: false)
                let upPath = exp.fullUpper(childRel)
                let fmode = mode_t(sattr?.mode ?? 0o644)
                let flags: Int32 = (modeEnum == 0) ? (O_WRONLY | O_CREAT | O_NOFOLLOW) : (O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW)
                let fd = Darwin.open(upPath, flags, fmode)
                guard fd >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                Darwin.close(fd)
                exp.markUpperMutatedLocked(childRel)
                if let sattr { applySattr3(sattr, to: upPath) }
                let objFH = exp.handleForPathLocked(childRel)
                let objAttr = exp.attrLocked(for: childRel)
                let postDir = exp.attrLocked(for: dirRel)
                w.writeUInt32(NFS3_OK)
                w.writeBool(true)
                w.writeOpaque(objFH)
                w.writePostOpAttr(objAttr)
                w.writeWccData(pre: preDir, post: postDir)
            } catch let err as POSIXError {
                w.writeUInt32(nfsStatus(fromErrno: err.code.rawValue))
                w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            } catch {
                w.writeUInt32(NFS3ERR_IO)
                w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            }
            return w.data

        case 9: // MKDIR
            guard let dirFH = r.readOpaque(maxLength: 64),
                  let name = r.readString(),
                  let sattr = readSattr3(&r) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            guard let (exp, dirRel) = resolveExportAndPath(handle: dirFH) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            let preDir = exp.attrLocked(for: dirRel)
            guard isSafeSingleComponent(name) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let childRel = exp.joinRel(dirRel, name)
            if exp.resolveLocked(childRel) != nil {
                w.writeUInt32(NFS3ERR_EXIST)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            do {
                try exp.ensureUpperDirLocked(dirRel)
                // If lower had a directory here that was previously deleted, mark opaque so old lower files don't reappear!
                exp.clearWhiteoutLocked(childRel, markOpaqueIfLowerDirExists: true)
                let upPath = exp.fullUpper(childRel)
                let dmode = mode_t(sattr.mode ?? 0o755)
                if mkdir(upPath, dmode) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                exp.markUpperMutatedLocked(childRel)
                let objFH = exp.handleForPathLocked(childRel)
                let objAttr = exp.attrLocked(for: childRel)
                let postDir = exp.attrLocked(for: dirRel)
                w.writeUInt32(NFS3_OK)
                w.writeBool(true)
                w.writeOpaque(objFH)
                w.writePostOpAttr(objAttr)
                w.writeWccData(pre: preDir, post: postDir)
            } catch let err as POSIXError {
                w.writeUInt32(nfsStatus(fromErrno: err.code.rawValue))
                w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            } catch {
                w.writeUInt32(NFS3ERR_IO)
                w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            }
            return w.data

        case 10: // SYMLINK
            guard let dirFH = r.readOpaque(maxLength: 64),
                  let name = r.readString(),
                  let _ = readSattr3(&r),
                  let target = r.readString(maxLength: Int(PATH_MAX)) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            guard let (exp, dirRel) = resolveExportAndPath(handle: dirFH) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            let preDir = exp.attrLocked(for: dirRel)
            guard isSafeSingleComponent(name) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let childRel = exp.joinRel(dirRel, name)
            if exp.resolveLocked(childRel) != nil {
                w.writeUInt32(NFS3ERR_EXIST)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            do {
                try exp.ensureUpperDirLocked(dirRel)
                exp.clearWhiteoutLocked(childRel, markOpaqueIfLowerDirExists: false)
                let upPath = exp.fullUpper(childRel)
                if symlink(target, upPath) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                exp.markUpperMutatedLocked(childRel)
                let objFH = exp.handleForPathLocked(childRel)
                let objAttr = exp.attrLocked(for: childRel)
                let postDir = exp.attrLocked(for: dirRel)
                w.writeUInt32(NFS3_OK)
                w.writeBool(true)
                w.writeOpaque(objFH)
                w.writePostOpAttr(objAttr)
                w.writeWccData(pre: preDir, post: postDir)
            } catch let err as POSIXError {
                w.writeUInt32(nfsStatus(fromErrno: err.code.rawValue))
                w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            } catch {
                w.writeUInt32(NFS3ERR_IO)
                w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            }
            return w.data

        case 12: // REMOVE
            guard let dirFH = r.readOpaque(maxLength: 64),
                  let name = r.readString() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            guard let (exp, dirRel) = resolveExportAndPath(handle: dirFH) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            let preDir = exp.attrLocked(for: dirRel)
            guard isSafeSingleComponent(name) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let childRel = exp.joinRel(dirRel, name)
            guard let layer = exp.resolveLocked(childRel) else {
                w.writeUInt32(NFS3ERR_NOENT)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let st: stat
            switch layer {
            case .upper(_, let s): st = s
            case .lower(_, let s): st = s
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                w.writeUInt32(NFS3ERR_ISDIR)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let upPath = exp.fullUpper(childRel)
            if exp.lstatUpperLocked(childRel) != nil {
                if unlink(upPath) != 0 {
                    w.writeUInt32(nfsStatus(fromErrno: errno))
                    w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
                    return w.data
                }
                exp.bumpDirCacheLocked()
            }
            if exp.lstatLowerLocked(childRel) != nil {
                exp.markWhiteoutLocked(childRel)
            }
            w.writeUInt32(NFS3_OK)
            w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            return w.data

        case 13: // RMDIR
            guard let dirFH = r.readOpaque(maxLength: 64),
                  let name = r.readString() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            guard let (exp, dirRel) = resolveExportAndPath(handle: dirFH) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            let preDir = exp.attrLocked(for: dirRel)
            guard isSafeSingleComponent(name) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let childRel = exp.joinRel(dirRel, name)
            guard let layer = exp.resolveLocked(childRel) else {
                w.writeUInt32(NFS3ERR_NOENT)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let st: stat
            switch layer {
            case .upper(_, let s): st = s
            case .lower(_, let s): st = s
            }
            if (st.st_mode & S_IFMT) != S_IFDIR {
                w.writeUInt32(NFS3ERR_NOTDIR)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            if !exp.mergedDirEntriesLocked(relDir: childRel).isEmpty {
                w.writeUInt32(NFS3ERR_NOTEMPTY)
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let upPath = exp.fullUpper(childRel)
            if exp.lstatUpperLocked(childRel) != nil {
                exp.removeUpperTreeLocked(upPath)
                exp.bumpDirCacheLocked()
            }
            if exp.lstatLowerLocked(childRel) != nil {
                exp.markWhiteoutLocked(childRel)
            }
            w.writeUInt32(NFS3_OK)
            w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            return w.data

        case 14: // RENAME
            guard let fromDirFH = r.readOpaque(maxLength: 64),
                  let fromName = r.readString(),
                  let toDirFH = r.readOpaque(maxLength: 64),
                  let toName = r.readString() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: nil, post: nil)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            guard let (exp, fromDirRel) = resolveExportAndPath(handle: fromDirFH),
                  let (exp2, toDirRel) = resolveExportAndPath(handle: toDirFH),
                  exp === exp2 else {
                w.writeUInt32(NFS3ERR_XDEV)
                w.writeWccData(pre: nil, post: nil)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            let preFrom = exp.attrLocked(for: fromDirRel)
            let preTo = exp.attrLocked(for: toDirRel)
            guard isSafeSingleComponent(fromName), isSafeSingleComponent(toName) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: preFrom, post: preFrom)
                w.writeWccData(pre: preTo, post: preTo)
                return w.data
            }
            let srcRel = exp.joinRel(fromDirRel, fromName)
            let dstRel = exp.joinRel(toDirRel, toName)
            if srcRel == dstRel {
                w.writeUInt32(NFS3_OK)
                w.writeWccData(pre: preFrom, post: preFrom)
                w.writeWccData(pre: preTo, post: preTo)
                return w.data
            }
            guard let srcLayer = exp.resolveLocked(srcRel) else {
                w.writeUInt32(NFS3ERR_NOENT)
                w.writeWccData(pre: preFrom, post: preFrom)
                w.writeWccData(pre: preTo, post: preTo)
                return w.data
            }
            let srcSt: stat
            switch srcLayer {
            case .upper(_, let s): srcSt = s
            case .lower(_, let s): srcSt = s
            }
            let srcIsDir = (srcSt.st_mode & S_IFMT) == S_IFDIR

            do {
                try exp.ensureUpperDirLocked(toDirRel)
                // If dst exists and is a non-empty dir, fail ENOTEMPTY
                if let dstLayer = exp.resolveLocked(dstRel) {
                    let dstSt: stat
                    switch dstLayer {
                    case .upper(_, let s): dstSt = s
                    case .lower(_, let s): dstSt = s
                    }
                    let dstIsDir = (dstSt.st_mode & S_IFMT) == S_IFDIR
                    if srcIsDir != dstIsDir {
                        throw POSIXError(dstIsDir ? .EISDIR : .ENOTDIR)
                    }
                    if dstIsDir && !exp.mergedDirEntriesLocked(relDir: dstRel).isEmpty {
                        throw POSIXError(.ENOTEMPTY)
                    }
                    exp.removeUpperTreeLocked(exp.fullUpper(dstRel))
                }

                let dstInLower = (exp.lstatLowerLocked(dstRel) != nil)
                let srcInLower = (exp.lstatLowerLocked(srcRel) != nil)
                let srcUpperExists = (exp.lstatUpperLocked(srcRel) != nil)

                if srcIsDir {
                    if !srcInLower && srcUpperExists {
                        // Pure upper dir -> fast atomic rename(2)!
                        exp.clearWhiteoutLocked(dstRel, markOpaqueIfLowerDirExists: dstInLower)
                        if rename(exp.fullUpper(srcRel), exp.fullUpper(dstRel)) != 0 {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    } else {
                        // Merged/lower dir -> materialize merged tree into upper/dstRel, mark dst opaque, whiteout src
                        exp.clearWhiteoutLocked(dstRel, markOpaqueIfLowerDirExists: true)
                        try exp.materializeMergedTreeLocked(from: srcRel, to: dstRel)
                        if srcUpperExists {
                            exp.removeUpperTreeLocked(exp.fullUpper(srcRel))
                        }
                        if srcInLower {
                            exp.markWhiteoutLocked(srcRel)
                        }
                    }
                } else {
                    let upSrc = try exp.copyUpLocked(srcRel)
                    exp.clearWhiteoutLocked(dstRel, markOpaqueIfLowerDirExists: false)
                    if rename(upSrc, exp.fullUpper(dstRel)) != 0 {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if srcInLower {
                        exp.markWhiteoutLocked(srcRel)
                    }
                }

                exp.markUpperMutatedLocked(dstRel)
                exp.renameHandlesLocked(from: srcRel, to: dstRel)
                w.writeUInt32(NFS3_OK)
                w.writeWccData(pre: preFrom, post: exp.attrLocked(for: fromDirRel))
                w.writeWccData(pre: preTo, post: exp.attrLocked(for: toDirRel))
            } catch let err as POSIXError {
                w.writeUInt32(nfsStatus(fromErrno: err.code.rawValue))
                w.writeWccData(pre: preFrom, post: exp.attrLocked(for: fromDirRel))
                w.writeWccData(pre: preTo, post: exp.attrLocked(for: toDirRel))
            } catch {
                w.writeUInt32(NFS3ERR_IO)
                w.writeWccData(pre: preFrom, post: exp.attrLocked(for: fromDirRel))
                w.writeWccData(pre: preTo, post: exp.attrLocked(for: toDirRel))
            }
            return w.data

        case 15: // LINK (hardlink — used by git lockfiles / object commits!)
            guard let targetFH = r.readOpaque(maxLength: 64),
                  let dirFH = r.readOpaque(maxLength: 64),
                  let name = r.readString() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writePostOpAttr(nil)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            guard let (exp, targetRel) = resolveExportAndPath(handle: targetFH),
                  let (exp2, dirRel) = resolveExportAndPath(handle: dirFH),
                  exp === exp2 else {
                w.writeUInt32(NFS3ERR_XDEV)
                w.writePostOpAttr(nil)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            let preDir = exp.attrLocked(for: dirRel)
            guard isSafeSingleComponent(name) else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writePostOpAttr(exp.attrLocked(for: targetRel))
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            let linkRel = exp.joinRel(dirRel, name)
            if exp.resolveLocked(linkRel) != nil {
                w.writeUInt32(NFS3ERR_EXIST)
                w.writePostOpAttr(exp.attrLocked(for: targetRel))
                w.writeWccData(pre: preDir, post: preDir)
                return w.data
            }
            do {
                let upTarget = try exp.copyUpLocked(targetRel)
                try exp.ensureUpperDirLocked(dirRel)
                exp.clearWhiteoutLocked(linkRel, markOpaqueIfLowerDirExists: false)
                if link(upTarget, exp.fullUpper(linkRel)) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                exp.markUpperMutatedLocked(linkRel)
                w.writeUInt32(NFS3_OK)
                w.writePostOpAttr(exp.attrLocked(for: targetRel))
                w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            } catch let err as POSIXError {
                w.writeUInt32(nfsStatus(fromErrno: err.code.rawValue))
                w.writePostOpAttr(exp.attrLocked(for: targetRel))
                w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            } catch {
                w.writeUInt32(NFS3ERR_IO)
                w.writePostOpAttr(exp.attrLocked(for: targetRel))
                w.writeWccData(pre: preDir, post: exp.attrLocked(for: dirRel))
            }
            return w.data

        case 16: // READDIR
            guard let dirFH = r.readOpaque(maxLength: 64),
                  let cookie = r.readUInt64(),
                  let _ = r.readFixedOpaque(8), // cookieverf
                  let maxCount = r.readUInt32() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writePostOpAttr(nil)
                return w.data
            }
            guard let (exp, dirRel) = resolveExportAndPath(handle: dirFH) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writePostOpAttr(nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            guard let dirAttr = exp.attrLocked(for: dirRel) else {
                w.writeUInt32(NFS3ERR_NOENT)
                w.writePostOpAttr(nil)
                return w.data
            }
            let entries = [".", ".."] + exp.mergedDirEntriesLocked(relDir: dirRel)
            let startIdx = Int(cookie)
            let budget = max(512, Int(min(maxCount, MAX_IO_BYTES)) - 160)

            w.writeUInt32(NFS3_OK)
            w.writePostOpAttr(dirAttr)
            w.writeFixedBytes(Data(repeating: 0, count: 8)) // cookieverf

            var writtenBytes = 0
            var idx = startIdx
            while idx < entries.count {
                let name = entries[idx]
                let childRel: String
                if name == "." { childRel = dirRel }
                else if name == ".." { childRel = exp.parentRel(dirRel) }
                else { childRel = exp.joinRel(dirRel, name) }
                let fh = exp.handleForPathLocked(childRel)
                let est = 24 + ((name.utf8.count + 3) & ~3)
                if writtenBytes > 0 && writtenBytes + est > budget { break }
                w.writeBool(true) // value follows
                w.writeUInt64(exp.fileID(for: fh))
                w.writeString(name)
                w.writeUInt64(UInt64(idx + 1)) // next cookie
                writtenBytes += est
                idx += 1
            }
            w.writeBool(false) // end of list
            w.writeBool(idx >= entries.count) // eof
            return w.data

        case 17: // READDIRPLUS
            guard let dirFH = r.readOpaque(maxLength: 64),
                  let cookie = r.readUInt64(),
                  let _ = r.readFixedOpaque(8), // cookieverf
                  let _ = r.readUInt32(),       // dircount
                  let maxCount = r.readUInt32() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writePostOpAttr(nil)
                return w.data
            }
            guard let (exp, dirRel) = resolveExportAndPath(handle: dirFH) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writePostOpAttr(nil)
                return w.data
            }
            exp.lock.lock()
            defer { exp.lock.unlock() }
            guard let dirAttr = exp.attrLocked(for: dirRel) else {
                w.writeUInt32(NFS3ERR_NOENT)
                w.writePostOpAttr(nil)
                return w.data
            }
            let entries = [".", ".."] + exp.mergedDirEntriesLocked(relDir: dirRel)
            let startIdx = Int(cookie)
            let budget = max(1024, Int(min(maxCount, MAX_IO_BYTES)) - 256)

            w.writeUInt32(NFS3_OK)
            w.writePostOpAttr(dirAttr)
            w.writeFixedBytes(Data(repeating: 0, count: 8))

            var writtenBytes = 0
            var idx = startIdx
            while idx < entries.count {
                let name = entries[idx]
                let childRel: String
                if name == "." { childRel = dirRel }
                else if name == ".." { childRel = exp.parentRel(dirRel) }
                else { childRel = exp.joinRel(dirRel, name) }
                let fh = exp.handleForPathLocked(childRel)
                let attr = exp.attrLocked(for: childRel)
                let est = 160 + ((name.utf8.count + 3) & ~3)
                if writtenBytes > 0 && writtenBytes + est > budget { break }
                w.writeBool(true)
                w.writeUInt64(exp.fileID(for: fh))
                w.writeString(name)
                w.writeUInt64(UInt64(idx + 1))
                w.writePostOpAttr(attr)
                w.writeBool(true) // handle follows
                w.writeOpaque(fh)
                writtenBytes += est
                idx += 1
            }
            w.writeBool(false)
            w.writeBool(idx >= entries.count)
            return w.data

        case 18: // FSSTAT
            guard let fh = r.readOpaque(maxLength: 64),
                  let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writePostOpAttr(nil)
                return w.data
            }
            exp.lock.lock()
            let attr = exp.attrLocked(for: rel)
            let upRoot = exp.upperRoot
            exp.lock.unlock()
            var vfs = statvfs()
            let tbytes: UInt64
            let fbytes: UInt64
            let abytes: UInt64
            if statvfs(upRoot, &vfs) == 0 {
                let fr = UInt64(vfs.f_frsize > 0 ? vfs.f_frsize : 4096)
                tbytes = UInt64(vfs.f_blocks) * fr
                fbytes = UInt64(vfs.f_bfree) * fr
                abytes = UInt64(vfs.f_bavail) * fr
            } else {
                tbytes = 1 << 40; fbytes = 1 << 39; abytes = 1 << 39
            }
            w.writeUInt32(NFS3_OK)
            w.writePostOpAttr(attr)
            w.writeUInt64(tbytes)
            w.writeUInt64(fbytes)
            w.writeUInt64(abytes)
            w.writeUInt64(1 << 24) // tfiles
            w.writeUInt64(1 << 23) // ffiles
            w.writeUInt64(1 << 23) // afiles
            w.writeUInt32(0)       // invarsec
            return w.data

        case 19: // FSINFO
            guard let fh = r.readOpaque(maxLength: 64),
                  let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writePostOpAttr(nil)
                return w.data
            }
            exp.lock.lock()
            let attr = exp.attrLocked(for: rel)
            exp.lock.unlock()
            w.writeUInt32(NFS3_OK)
            w.writePostOpAttr(attr)
            w.writeUInt32(MAX_IO_BYTES) // rtmax
            w.writeUInt32(65536)        // rtpref
            w.writeUInt32(4096)         // rtmult
            w.writeUInt32(MAX_IO_BYTES) // wtmax
            w.writeUInt32(65536)        // wtpref
            w.writeUInt32(4096)         // wtmult
            w.writeUInt32(65536)        // dtpref
            w.writeUInt64(1 << 50)      // maxfilesize
            w.writeUInt32(0)            // time_delta.sec
            w.writeUInt32(1)            // time_delta.nsec
            w.writeUInt32(0x1b)         // FSF3_LINK|SYMLINK|HOMOGENEOUS|CANSETTIME
            return w.data

        case 20: // PATHCONF
            guard let fh = r.readOpaque(maxLength: 64),
                  let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writePostOpAttr(nil)
                return w.data
            }
            exp.lock.lock()
            let attr = exp.attrLocked(for: rel)
            exp.lock.unlock()
            w.writeUInt32(NFS3_OK)
            w.writePostOpAttr(attr)
            w.writeUInt32(32767) // linkmax
            w.writeUInt32(255)   // name_max
            w.writeBool(true)    // no_trunc
            w.writeBool(true)    // chown_restricted
            w.writeBool(false)   // case_insensitive
            w.writeBool(true)    // case_preserving
            return w.data

        case 21: // COMMIT
            guard let fh = r.readOpaque(maxLength: 64),
                  let _ = r.readUInt64(),
                  let _ = r.readUInt32() else {
                w.writeUInt32(NFS3ERR_INVAL)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            guard let (exp, rel) = resolveExportAndPath(handle: fh) else {
                w.writeUInt32(NFS3ERR_STALE)
                w.writeWccData(pre: nil, post: nil)
                return w.data
            }
            exp.lock.lock()
            let pre = exp.attrLocked(for: rel)
            let up = exp.lstatUpperLocked(rel) != nil ? exp.fullUpper(rel) : nil
            exp.lock.unlock()
            if let up {
                let fd = Darwin.open(up, O_RDONLY | O_NOFOLLOW)
                if fd >= 0 {
                    _ = fsync(fd)
                    Darwin.close(fd)
                }
            }
            exp.lock.lock()
            let post = exp.attrLocked(for: rel)
            exp.lock.unlock()
            w.writeUInt32(NFS3_OK)
            w.writeWccData(pre: pre, post: post)
            w.writeFixedBytes(writeVerifier)
            return w.data

        default:
            return makeAcceptedReplyHeader(xid: xid, acceptStat: 3).data
        }
    }

    // MARK: SATTR3 Parsing & Application

    private struct Sattr3 {
        var mode: UInt32?
        var size: UInt64?
        var atime: timespec?
        var mtime: timespec?
    }

    private func readSattr3(_ r: inout XDRReader) -> Sattr3? {
        var out = Sattr3()
        guard let setMode = r.readUInt32() else { return nil }
        if setMode != 0 { out.mode = r.readUInt32() }

        guard let setUID = r.readUInt32() else { return nil }
        if setUID != 0 { _ = r.readUInt32() }

        guard let setGID = r.readUInt32() else { return nil }
        if setGID != 0 { _ = r.readUInt32() }

        guard let setSize = r.readUInt32() else { return nil }
        if setSize != 0 { out.size = r.readUInt64() }

        guard let atimeHow = r.readUInt32() else { return nil }
        if atimeHow == 1 { // SET_TO_SERVER_TIME
            var tv = timeval()
            gettimeofday(&tv, nil)
            out.atime = timespec(tv_sec: tv.tv_sec, tv_nsec: Int(tv.tv_usec) * 1000)
        } else if atimeHow == 2 { // SET_TO_CLIENT_TIME
            if let sec = r.readUInt32(), let nsec = r.readUInt32() {
                out.atime = timespec(tv_sec: Int(sec), tv_nsec: Int(nsec))
            }
        }

        guard let mtimeHow = r.readUInt32() else { return nil }
        if mtimeHow == 1 {
            var tv = timeval()
            gettimeofday(&tv, nil)
            out.mtime = timespec(tv_sec: tv.tv_sec, tv_nsec: Int(tv.tv_usec) * 1000)
        } else if mtimeHow == 2 {
            if let sec = r.readUInt32(), let nsec = r.readUInt32() {
                out.mtime = timespec(tv_sec: Int(sec), tv_nsec: Int(nsec))
            }
        }
        return out
    }

    private func applySattr3(_ sattr: Sattr3, to path: String) {
        if let mode = sattr.mode {
            _ = chmod(path, mode_t(mode & 0o7777))
        }
        if let size = sattr.size {
            _ = truncate(path, off_t(size))
        }
        if sattr.atime != nil || sattr.mtime != nil {
            var st = stat()
            if lstat(path, &st) == 0 {
                let at = sattr.atime ?? st.st_atimespec
                let mt = sattr.mtime ?? st.st_mtimespec
                var times = [at, mt]
                let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
                if fd >= 0 {
                    _ = futimens(fd, &times)
                    Darwin.close(fd)
                }
            }
        }
    }
}

// MARK: - Helpers (Process & Mount Detection)

private func runProcess(_ executable: String, _ arguments: [String]) -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = arguments
    let errPipe = Pipe()
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = errPipe
    do {
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, errStr)
    } catch {
        return (-1, error.localizedDescription)
    }
}

private func isPathNFSMounted(_ path: String) -> Bool {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    var st = statfs()
    guard statfs(resolved, &st) == 0 else { return false }
    let fsType = withUnsafePointer(to: &st.f_fstypename) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
    }
    let mntOn = withUnsafePointer(to: &st.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return fsType == "nfs" && mntOn == resolved
}

// MARK: - Control Unix Domain Socket Server (`~/boo_box/run/overlay.sock`)

private func writeJSONLine(fd: Int32, obj: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    data.append(0x0A)
    data.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        var off = 0
        while off < data.count {
            let n = Darwin.write(fd, base.advanced(by: off), data.count - off)
            if n <= 0 { break }
            off += n
        }
    }
}

private func handleControlClient(fd: Int32, daemon: OverlayDaemon) {
    defer { Darwin.close(fd) }
    var reqData = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while reqData.count < 65536 {
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { break }
        reqData.append(contentsOf: buf[0..<n])
        if buf[0..<n].contains(0x0A) { break }
    }
    guard let json = (try? JSONSerialization.jsonObject(with: reqData)) as? [String: Any],
          let op = json["op"] as? String else {
        writeJSONLine(fd: fd, obj: ["ok": false, "error": "invalid_json"])
        return
    }

    switch op {
    case "ping":
        writeJSONLine(fd: fd, obj: [
            "ok": true,
            "port": Int(daemon.port),
            "pid": Int(getpid()),
            "mounts": daemon.listMountedSessions().count,
        ])

    case "list":
        writeJSONLine(fd: fd, obj: [
            "ok": true,
            "port": Int(daemon.port),
            "mounts": daemon.listMountedSessions(),
        ])

    case "mount":
        guard let sessionID = json["sessionId"] as? String, !sessionID.isEmpty,
              let lowerDir = json["lowerDir"] as? String, !lowerDir.isEmpty,
              let upperDir = json["upperDir"] as? String, !upperDir.isEmpty,
              let whiteoutFile = json["whiteoutFile"] as? String, !whiteoutFile.isEmpty,
              let mountPoint = json["mountPoint"] as? String, !mountPoint.isEmpty else {
            writeJSONLine(fd: fd, obj: ["ok": false, "error": "missing_fields"])
            return
        }
        let excludeEnv = (json["excludeEnv"] as? Bool) ?? true
        do {
            try daemon.mountSession(
                sessionID: sessionID,
                lowerDir: lowerDir,
                upperDir: upperDir,
                whiteoutFile: whiteoutFile,
                mountPoint: mountPoint,
                excludeEnv: excludeEnv
            )
            writeJSONLine(fd: fd, obj: [
                "ok": true,
                "port": Int(daemon.port),
                "mountPoint": mountPoint,
            ])
        } catch {
            writeJSONLine(fd: fd, obj: ["ok": false, "error": error.localizedDescription])
        }

    case "unmount":
        guard let sessionID = json["sessionId"] as? String, !sessionID.isEmpty else {
            writeJSONLine(fd: fd, obj: ["ok": false, "error": "missing_sessionId"])
            return
        }
        daemon.unmountSession(sessionID: sessionID)
        writeJSONLine(fd: fd, obj: ["ok": true])

    default:
        writeJSONLine(fd: fd, obj: ["ok": false, "error": "unknown_op"])
    }
}

// MARK: - Main Entrypoint

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
_ = setsid()

let runDir = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
    .appendingPathComponent("boo_box/run", isDirectory: true)
try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

var customControlSock: String? = nil
let cliArgs = Array(CommandLine.arguments.dropFirst())
if let idx = cliArgs.firstIndex(of: "--control-socket"), idx + 1 < cliArgs.count {
    customControlSock = cliArgs[idx + 1]
}
let controlSockPath = customControlSock ?? runDir.appendingPathComponent("overlay.sock").path
let pidFilePath = runDir.appendingPathComponent("overlay.pid").path
private let daemon: OverlayDaemon
do {
    daemon = try OverlayDaemon()
} catch {
    fputs("boobox-overlay: failed to bind NFSv3 listener: \(error)\n", stderr)
    exit(1)
}
daemon.startAcceptingNFS()

// Bind Unix domain control socket (0600)
unlink(controlSockPath)
let ctlFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
guard ctlFD >= 0 else {
    fputs("boobox-overlay: socket(AF_UNIX) failed\n", stderr)
    exit(1)
}
var sun = sockaddr_un()
sun.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(controlSockPath.utf8CString)
withUnsafeMutablePointer(to: &sun.sun_path) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
        for i in 0..<min(pathBytes.count, 103) {
            dst[i] = pathBytes[i]
        }
    }
}
let bindRC = withUnsafePointer(to: &sun) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(ctlFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindRC == 0, Darwin.listen(ctlFD, 32) == 0 else {
    fputs("boobox-overlay: failed to bind \(controlSockPath) (errno \(errno))\n", stderr)
    exit(1)
}
chmod(controlSockPath, 0o600)
try? "\(getpid())\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)

// Print ready line for callers inspecting stdout
fputs("BOOBOX_OVERLAY_READY port=\(daemon.port) pid=\(getpid())\n", stdout)
fflush(stdout)

while true {
    let clientFD = Darwin.accept(ctlFD, nil, nil)
    if clientFD < 0 {
        if errno == EINTR { continue }
        usleep(10_000)
        continue
    }
    DispatchQueue.global(qos: .userInitiated).async {
        handleControlClient(fd: clientFD, daemon: daemon)
    }
}
