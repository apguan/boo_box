import Darwin
import Foundation

/// Host-side client for the persistent `boobox-overlay` NFSv3 Copy-on-Write daemon (`~/boo_box/run/overlay.sock`).
///
/// Mirrors `DaemonClient` and `SecretsVaultManager`: launches `boobox-overlay` detached so active
/// session overlay mounts survive `boo_box.app` quits, restarts, and auto-updates seamlessly.
final class OverlayClient: @unchecked Sendable {
    static let shared = OverlayClient()

    private let lock = NSLock()
    private var cachedPort: UInt16 = 0

    let controlSocketPath: String

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        self.controlSocketPath = home.appendingPathComponent("boo_box/run/overlay.sock").path
    }

    var currentPort: UInt16 {
        lock.lock()
        let p = cachedPort
        lock.unlock()
        if p > 0 { return p }
        if let reply = sendControl(["op": "ping"]),
           reply["ok"] as? Bool == true,
           let port = reply["port"] as? Int, port > 0, port <= 65535 {
            lock.lock()
            cachedPort = UInt16(port)
            lock.unlock()
            return UInt16(port)
        }
        return 0
    }

    /// Ensures the detached `boobox-overlay` host daemon is running and returns its loopback TCP port.
    @discardableResult
    func ensureDaemonRunning() throws -> UInt16 {
        if let reply = sendControl(["op": "ping"]),
           reply["ok"] as? Bool == true,
           let port = reply["port"] as? Int, port > 0, port <= 65535 {
            lock.lock()
            cachedPort = UInt16(port)
            lock.unlock()
            return UInt16(port)
        }

        guard let binURL = resolveOverlayBinaryURL() else {
            throw MacSandboxError.cloneFailed("boobox-overlay helper binary not found in app bundle.")
        }

        let proc = Process()
        proc.executableURL = binURL
        proc.arguments = []
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        // Wait up to 4 seconds for overlay.sock to accept ping
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            if let reply = sendControl(["op": "ping"]),
               reply["ok"] as? Bool == true,
               let port = reply["port"] as? Int, port > 0, port <= 65535 {
                lock.lock()
                cachedPort = UInt16(port)
                lock.unlock()
                return UInt16(port)
            }
            usleep(40_000)
        }
        throw MacSandboxError.cloneFailed("Timed out waiting for boobox-overlay daemon to start.")
    }

    /// Mounts `lowerDir` read-only under a Copy-on-Write overlay at `mountPoint` (~20 ms, O(1) for any size).
    /// Returns the daemon's localhost TCP port so Seatbelt can block sandbox access to it.
    @discardableResult
    func mount(
        sessionID: String,
        lowerDir: String,
        upperDir: String,
        whiteoutFile: String,
        mountPoint: String,
        excludeEnv: Bool
    ) throws -> UInt16 {
        let port = try ensureDaemonRunning()
        guard let reply = sendControl([
            "op": "mount",
            "sessionId": sessionID,
            "lowerDir": lowerDir,
            "upperDir": upperDir,
            "whiteoutFile": whiteoutFile,
            "mountPoint": mountPoint,
            "excludeEnv": excludeEnv,
        ], timeoutSeconds: 15) else {
            throw MacSandboxError.cloneFailed("No response from boobox-overlay while mounting \(sessionID).")
        }
        guard reply["ok"] as? Bool == true else {
            let err = (reply["error"] as? String) ?? "unknown mount error"
            throw MacSandboxError.cloneFailed(err)
        }
        if let p = reply["port"] as? Int, p > 0, p <= 65535 {
            lock.lock()
            cachedPort = UInt16(p)
            lock.unlock()
            return UInt16(p)
        }
        return port
    }

    /// Cleanly unmounts an overlay session (and falls back to direct `umount` if daemon isn't running).
    func unmount(sessionID: String, mountPoint: String) {
        _ = sendControl(["op": "unmount", "sessionId": sessionID], timeoutSeconds: 8)
        if Self.isPathNFSMounted(mountPoint) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/umount")
            p.arguments = ["-f", mountPoint]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    static func isPathNFSMounted(_ path: String) -> Bool {
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

    private func resolveOverlayBinaryURL() -> URL? {
        let fm = FileManager.default
        if let execURL = Bundle.main.executableURL {
            let candidate = execURL.deletingLastPathComponent().appendingPathComponent("boobox-overlay")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        if let appPath = try? String(contentsOf: home.appendingPathComponent("boo_box/.app-path"), encoding: .utf8) {
            let trimmed = appPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let candidate = URL(fileURLWithPath: trimmed).appendingPathComponent("Contents/MacOS/boobox-overlay")
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    private func sendControl(_ payload: [String: Any], timeoutSeconds: Int = 5) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: controlSocketPath) else { return nil }
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        data.append(0x0A)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var sun = sockaddr_un()
        sun.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(controlSocketPath.utf8CString)
        withUnsafeMutablePointer(to: &sun.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for i in 0..<min(bytes.count, 103) { dst[i] = bytes[i] }
            }
        }
        let crc = withUnsafePointer(to: &sun) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard crc == 0 else { return nil }

        let wrote = data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            var off = 0
            while off < data.count {
                let n = Darwin.write(fd, base.advanced(by: off), data.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard wrote else { return nil }

        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while resp.count < 65536 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            resp.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }
        return (try? JSONSerialization.jsonObject(with: resp)) as? [String: Any]
    }
}
