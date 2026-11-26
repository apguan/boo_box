import Darwin
import Foundation

struct DaemonPaneStatus: Codable, Equatable, Sendable {
    let paneId: String
    let sessionId: String
    let socketPath: String
    let alive: Bool
    let fgBusy: Bool
    let fgName: String?
    let exitCode: Int32?
    let hasClient: Bool
}

/// Host client for `booboxd` (`~/boo_box/run/booboxd.sock`).
/// Spawns and manages detached macOS Sandbox PTY panes so shells and coding agents
/// survive `boo_box.app` quits, crashes, and auto-updates cleanly.
final class DaemonClient: @unchecked Sendable {
    static let shared = DaemonClient()

    let controlSocketPath: String
    private let startLock = NSLock()

    private init() {
        let runDir = BooBoxPaths.rootDirURL.appendingPathComponent("run", isDirectory: true)
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        self.controlSocketPath = runDir.appendingPathComponent("booboxd.sock").path
    }

    func resolveDaemonBinaryURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("booboxd"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/release/booboxd"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/debug/booboxd"),
        ]
        for case let url? in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    func resolveAttachBinaryURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("boobox-attach"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/release/boobox-attach"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/debug/boobox-attach"),
        ]
        for case let url? in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    /// Returns `true` if `booboxd` is already running and responsive on `booboxd.sock`.
    func ping() -> (alive: Bool, livePanes: Int) {
        guard let resp = sendCommand(["op": "ping"]),
              let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
              (obj["ok"] as? Bool) == true else {
            return (false, 0)
        }
        return (true, obj["livePanes"] as? Int ?? 0)
    }

    /// Ensures `booboxd` is running as a detached background daemon.
    @discardableResult
    func ensureRunning() -> Bool {
        if ping().alive { return true }

        startLock.lock()
        defer { startLock.unlock() }
        if ping().alive { return true }

        guard let bin = resolveDaemonBinaryURL() else { return false }
        let proc = Process()
        proc.executableURL = bin
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return false
        }

        // Wait up to 2s for booboxd.sock to become ready
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if ping().alive { return true }
            usleep(25_000)
        }
        return false
    }

    /// Spawns a detached PTY pane inside `booboxd` and returns its per-pane Unix attach socket path.
    func spawnPane(paneId: String, sessionId: String, cwd: String, command: String) -> String? {
        guard ensureRunning() else { return nil }
        guard let resp = sendCommand([
            "op": "spawn",
            "paneId": paneId,
            "sessionId": sessionId,
            "cwd": cwd,
            "command": command,
        ]),
              let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
              (obj["ok"] as? Bool) == true,
              let sock = obj["socketPath"] as? String else {
            return nil
        }
        return sock
    }

    /// Lists all live panes currently hosted by `booboxd` (including foreground busy status).
    func listPanes() -> [DaemonPaneStatus] {
        guard let resp = sendCommand(["op": "list"]) else { return [] }
        struct ListResp: Decodable {
            let ok: Bool
            let panes: [DaemonPaneStatus]
        }
        return (try? JSONDecoder().decode(ListResp.self, from: resp))?.panes ?? []
    }

    func killPane(_ paneId: String) {
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = sendCommand(["op": "kill", "paneId": paneId])
        }
    }

    func killSession(_ sessionId: String) {
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = sendCommand(["op": "kill_session", "sessionId": sessionId])
        }
    }

    func buildAttachCommand(socketPath: String, cwd: String) -> String? {
        guard let attach = resolveAttachBinaryURL() else { return nil }
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return "\(q(attach.path)) \(q(socketPath)) \(q(cwd))"
    }

    private func sendCommand(_ payload: [String: Any]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(controlSocketPath.utf8)
        guard bytes.count < maxLen else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, addrLen) == 0
            }
        }
        guard connected else { return nil }

        var msg = json
        msg.append(0x0A)
        let wrote = msg.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var off = 0
            while off < msg.count {
                let n = Darwin.write(fd, base.advanced(by: off), msg.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard wrote else { return nil }
        shutdown(fd, SHUT_WR)

        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while reply.count < 2 * 1024 * 1024 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            reply.append(buf, count: n)
        }
        return reply.isEmpty ? nil : reply
    }
}
