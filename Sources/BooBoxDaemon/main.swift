import Darwin
import Foundation

// booboxd: Persistent detached PTY broker daemon for boo_box macOS Sandbox sessions.
//
// Keeps sandboxed Seatbelt shells & coding agents alive across boo_box.app quits, crashes,
// and auto-updates, speaking the exact framed Unix socket protocol consumed by `boobox-attach`:
//   Handshake line: "COLS=<u16> ROWS=<u16> TERM=<str> CWD=<str>\n"
//   Framed messages: [type: u8][len: u32 BE][payload]
//     0x01 DATA   - raw terminal bytes
//     0x02 RESIZE - [rows: u16 BE][cols: u16 BE]
//     0x03 EXIT   - [exit_code: u8]

private let MSG_DATA: UInt8 = 0x01
private let MSG_RESIZE: UInt8 = 0x02
private let MSG_EXIT: UInt8 = 0x03

private let RING_BUFFER_CAPACITY = 131_072 // 128 KiB scrollback replay per pane

private func setCloseOnExec(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFD, 0)
    if flags >= 0 {
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }
}

private func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
    var written = 0
    while written < count {
        let n = Darwin.write(fd, ptr.advanced(by: written), count - written)
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        if n == 0 { return false }
        written += n
    }
    return true
}

private func readAll(_ fd: Int32, _ ptr: UnsafeMutableRawPointer, _ count: Int) -> Int {
    var total = 0
    while total < count {
        let n = Darwin.read(fd, ptr.advanced(by: total), count - total)
        if n < 0 {
            if errno == EINTR { continue }
            return -1
        }
        if n == 0 { return total == 0 ? 0 : -1 }
        total += n
    }
    return total
}

private func sendFrame(_ fd: Int32, type: UInt8, bytes: UnsafeRawPointer?, count: Int) -> Bool {
    let len = UInt32(count)
    let header: [UInt8] = [
        type,
        UInt8((len >> 24) & 0xFF),
        UInt8((len >> 16) & 0xFF),
        UInt8((len >> 8) & 0xFF),
        UInt8(len & 0xFF),
    ]
    guard header.withUnsafeBytes({ writeAll(fd, $0.baseAddress!, 5) }) else { return false }
    if count > 0, let bytes {
        return writeAll(fd, bytes, count)
    }
    return true
}

private func writeJSONLine(_ fd: Int32, _ data: Data) {
    var out = data
    if out.last != 0x0A { out.append(0x0A) }
    out.withUnsafeBytes { raw in
        if let base = raw.baseAddress {
            _ = writeAll(fd, base, out.count)
        }
    }
}

private func createUnixListener(at path: String, mode: mode_t = 0o600) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    setCloseOnExec(fd)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < maxLen else { close(fd); return -1 }
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
    guard bound, listen(fd, 16) == 0 else { close(fd); return -1 }
    chmod(path, mode)
    return fd
}

private func isExistingDaemonAlive(controlSocket: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    let bytes = Array(controlSocket.utf8)
    guard bytes.count < maxLen else { return false }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, addrLen) == 0
        }
    }
    guard ok else { return false }
    let ping = Data("{\"op\":\"ping\"}\n".utf8)
    writeJSONLine(fd, ping)
    var buf = [UInt8](repeating: 0, count: 256)
    let n = Darwin.read(fd, &buf, buf.count)
    return n > 0 && String(decoding: buf[0..<n], as: UTF8.self).contains("\"ok\":true")
}

private func processName(for pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: 128)
    let len = proc_name(pid, &buf, UInt32(buf.count))
    guard len > 0 else { return nil }
    let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
    let name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}

// MARK: - Managed PTY Pane

private struct PaneStatusInfo: Codable, Sendable {
    let paneId: String
    let sessionId: String
    let socketPath: String
    let alive: Bool
    let fgBusy: Bool
    let fgName: String?
    let exitCode: Int32?
    let hasClient: Bool
}

private final class ManagedPane: @unchecked Sendable {
    let paneId: String
    let sessionId: String
    let socketPath: String
    let childPID: pid_t

    private let stateLock = NSLock()
    private let clientWriteLock = NSLock()
    private var masterFD: Int32
    private var listenFD: Int32 = -1
    private var activeClientFD: Int32 = -1
    private var ringBuffer = Data()
    private var alive = true
    private var exitCode: Int32? = nil
    private var stopped = false

    var onFinalCleanup: (() -> Void)?

    init?(paneId: String, sessionId: String, socketPath: String, cwd: String, command: String) {
        self.paneId = paneId
        self.sessionId = sessionId
        self.socketPath = socketPath

        // Prepare pure-C strings BEFORE forkpty() so the child branch calls ONLY async-signal-safe syscalls.
        let shPath = strdup("/bin/sh")
        let dashC = strdup("-c")
        // Prefix with `exec ` so /bin/sh replaces itself directly with the target command;
        // the shell/sandbox inherits childPID as its process group leader for exact tcgetpgrp() busy detection.
        let execCmd = command.hasPrefix("exec ") ? command : "exec " + command
        let cCmd = strdup(execCmd)
        let cCwd = strdup(cwd)
        defer {
            if let shPath { free(shPath) }
            if let dashC { free(dashC) }
            if let cCmd { free(cCmd) }
            if let cCwd { free(cCwd) }
        }
        guard let shPath, let dashC, let cCmd, let cCwd else { return nil }

        var ws = winsize(ws_row: 36, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        var mfd: Int32 = -1
        let pid = forkpty(&mfd, nil, nil, &ws)
        if pid < 0 {
            return nil
        }
        if pid == 0 {
            // Child process: async-signal-safe syscalls ONLY!
            _ = chdir(cCwd)
            var argv: [UnsafeMutablePointer<CChar>?] = [shPath, dashC, cCmd, nil]
            execv(shPath, &argv)
            _exit(127)
        }

        // Parent (daemon)
        setCloseOnExec(mfd)
        self.masterFD = mfd
        self.childPID = pid

        let lfd = createUnixListener(at: socketPath, mode: 0o600)
        guard lfd >= 0 else {
            _ = Darwin.kill(-pid, SIGHUP)
            close(mfd)
            return nil
        }
        self.listenFD = lfd
        self.ringBuffer.reserveCapacity(RING_BUFFER_CAPACITY)
    }

    func start() {
        // 1. Continuous PTY master reader: buffers scrollback + forwards to attached client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runMasterReadLoop()
        }
        // 2. Per-pane attach socket accept loop (`boobox-attach` connects here)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runAttachAcceptLoop()
        }
    }

    func statusInfo() -> PaneStatusInfo {
        stateLock.lock()
        let mfd = masterFD
        let isAlive = alive
        let code = exitCode
        let hasClient = activeClientFD >= 0
        stateLock.unlock()

        var fgBusy = false
        var fgName: String? = nil
        if isAlive && mfd >= 0 {
            let fgPgrp = tcgetpgrp(mfd)
            if fgPgrp > 0 && fgPgrp != childPID {
                fgBusy = true
                fgName = processName(for: fgPgrp)
            }
        }
        return PaneStatusInfo(
            paneId: paneId,
            sessionId: sessionId,
            socketPath: socketPath,
            alive: isAlive,
            fgBusy: fgBusy,
            fgName: fgName,
            exitCode: code,
            hasClient: hasClient
        )
    }

    func killPane() {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let lfd = listenFD
        listenFD = -1
        let cfd = activeClientFD
        activeClientFD = -1
        let mfd = masterFD
        masterFD = -1
        alive = false
        stateLock.unlock()

        if lfd >= 0 { close(lfd) }
        unlink(socketPath)
        if cfd >= 0 {
            shutdown(cfd, SHUT_RDWR)
            close(cfd)
        }
        if mfd >= 0 { close(mfd) }

        // Terminate the entire process group cleanly
        _ = Darwin.kill(-childPID, SIGHUP)
        _ = Darwin.kill(childPID, SIGHUP)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) { [childPID] in
            var st: Int32 = 0
            if waitpid(childPID, &st, WNOHANG) == 0 {
                _ = Darwin.kill(-childPID, SIGTERM)
                _ = Darwin.kill(childPID, SIGTERM)
            }
        }
        onFinalCleanup?()
    }

    private func runMasterReadLoop() {
        var buf = [UInt8](repeating: 0, count: 32768)
        while true {
            stateLock.lock()
            let mfd = masterFD
            stateLock.unlock()
            guard mfd >= 0 else { break }

            let n = Darwin.read(mfd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }

            // Append to scrollback ring buffer & forward to attached client if any
            clientWriteLock.lock()
            stateLock.lock()
            if ringBuffer.count + n > RING_BUFFER_CAPACITY {
                let overflow = (ringBuffer.count + n) - RING_BUFFER_CAPACITY
                if overflow >= ringBuffer.count {
                    ringBuffer.removeAll(keepingCapacity: true)
                } else {
                    ringBuffer.removeFirst(overflow)
                }
            }
            if n > RING_BUFFER_CAPACITY {
                ringBuffer.append(contentsOf: buf[(n - RING_BUFFER_CAPACITY)..<n])
            } else {
                ringBuffer.append(contentsOf: buf[0..<n])
            }
            let cfd = activeClientFD
            stateLock.unlock()

            if cfd >= 0 {
                let sent = buf.withUnsafeBytes { raw in
                    sendFrame(cfd, type: MSG_DATA, bytes: raw.baseAddress, count: n)
                }
                if !sent {
                    detachClient(cfd)
                }
            }
            clientWriteLock.unlock()
        }

        // Reap exited child process
        var rawStatus: Int32 = 0
        var finalCode: Int32 = 0
        if waitpid(childPID, &rawStatus, 0) > 0 {
            if (rawStatus & 0x7F) == 0 {
                finalCode = (rawStatus >> 8) & 0xFF
            } else {
                finalCode = 128 + (rawStatus & 0x7F)
            }
        }

        clientWriteLock.lock()
        stateLock.lock()
        alive = false
        exitCode = finalCode
        let mfd = masterFD
        masterFD = -1
        let cfd = activeClientFD
        activeClientFD = -1
        let lfd = listenFD
        listenFD = -1
        let wasStopped = stopped
        stopped = true
        stateLock.unlock()

        if cfd >= 0 {
            var codeByte = UInt8(truncatingIfNeeded: finalCode)
            _ = withUnsafeBytes(of: &codeByte) { raw in
                sendFrame(cfd, type: MSG_EXIT, bytes: raw.baseAddress, count: 1)
            }
            shutdown(cfd, SHUT_RDWR)
            close(cfd)
        }
        clientWriteLock.unlock()

        if mfd >= 0 { close(mfd) }
        if lfd >= 0 { close(lfd) }
        unlink(socketPath)
        if !wasStopped {
            onFinalCleanup?()
        }
    }

    private func runAttachAcceptLoop() {
        while true {
            stateLock.lock()
            let lfd = listenFD
            stateLock.unlock()
            guard lfd >= 0 else { break }

            let cfd = accept(lfd, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                break
            }
            setCloseOnExec(cfd)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleAttachClient(cfd)
            }
        }
    }

    private func detachClient(_ fd: Int32) {
        stateLock.lock()
        if activeClientFD == fd {
            activeClientFD = -1
        }
        stateLock.unlock()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func handleAttachClient(_ cfd: Int32) {
        // 1. Read handshake line ("COLS=120 ROWS=36 TERM=xterm-ghostty CWD=...\n")
        var lineBytes: [UInt8] = []
        var ch: UInt8 = 0
        while lineBytes.count < 1024 {
            let n = Darwin.read(cfd, &ch, 1)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                close(cfd)
                return
            }
            if ch == 0x0A { break }
            lineBytes.append(ch)
        }
        let handshake = String(decoding: lineBytes, as: UTF8.self)
        var cols: UInt16 = 120
        var rows: UInt16 = 36
        for tok in handshake.split(separator: " ") {
            if tok.hasPrefix("COLS="), let v = UInt16(tok.dropFirst(5)), v > 0 { cols = v }
            if tok.hasPrefix("ROWS="), let v = UInt16(tok.dropFirst(5)), v > 0 { rows = v }
        }

        // 2. Apply initial window size, swap in as active client, and replay buffered scrollback atomically
        clientWriteLock.lock()
        stateLock.lock()
        let prevClient = activeClientFD
        let mfd = masterFD
        let isAlive = alive
        let code = exitCode ?? 0
        let replay = ringBuffer
        if isAlive {
            activeClientFD = cfd
        }
        stateLock.unlock()

        if prevClient >= 0 && prevClient != cfd {
            shutdown(prevClient, SHUT_RDWR)
            close(prevClient)
        }

        if isAlive && mfd >= 0 {
            var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(mfd, TIOCSWINSZ, &ws)
        }

        var replayOK = true
        if !replay.isEmpty {
            replay.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    var off = 0
                    while off < replay.count {
                        let chunk = min(16384, replay.count - off)
                        if !sendFrame(cfd, type: MSG_DATA, bytes: base.advanced(by: off), count: chunk) {
                            replayOK = false
                            break
                        }
                        off += chunk
                    }
                }
            }
        }
        if !isAlive {
            var codeByte = UInt8(truncatingIfNeeded: code)
            _ = withUnsafeBytes(of: &codeByte) { raw in
                sendFrame(cfd, type: MSG_EXIT, bytes: raw.baseAddress, count: 1)
            }
            clientWriteLock.unlock()
            close(cfd)
            return
        }
        clientWriteLock.unlock()

        guard replayOK else {
            detachClient(cfd)
            return
        }

        // 3. Read framed client -> PTY master input & resize messages
        var hdr = [UInt8](repeating: 0, count: 5)
        var payloadBuf = [UInt8](repeating: 0, count: 16384)
        while true {
            let hn = hdr.withUnsafeMutableBytes { readAll(cfd, $0.baseAddress!, 5) }
            if hn <= 0 { break }
            let type = hdr[0]
            let payloadLen = Int(
                (UInt32(hdr[1]) << 24) |
                (UInt32(hdr[2]) << 16) |
                (UInt32(hdr[3]) << 8) |
                UInt32(hdr[4])
            )

            if type == MSG_DATA {
                var remaining = payloadLen
                var writeOK = true
                while remaining > 0 {
                    let chunk = min(remaining, payloadBuf.count)
                    let rn = payloadBuf.withUnsafeMutableBytes { readAll(cfd, $0.baseAddress!, chunk) }
                    if rn <= 0 { writeOK = false; break }
                    stateLock.lock()
                    let curMaster = masterFD
                    stateLock.unlock()
                    if curMaster < 0 { writeOK = false; break }
                    let ok = payloadBuf.withUnsafeBytes { raw in
                        writeAll(curMaster, raw.baseAddress!, chunk)
                    }
                    if !ok { writeOK = false; break }
                    remaining -= chunk
                }
                if !writeOK { break }
            } else if type == MSG_RESIZE && payloadLen == 4 {
                var rbuf = [UInt8](repeating: 0, count: 4)
                let rn = rbuf.withUnsafeMutableBytes { readAll(cfd, $0.baseAddress!, 4) }
                if rn <= 0 { break }
                let newRows = (UInt16(rbuf[0]) << 8) | UInt16(rbuf[1])
                let newCols = (UInt16(rbuf[2]) << 8) | UInt16(rbuf[3])
                if newRows > 0 && newCols > 0 {
                    stateLock.lock()
                    let curMaster = masterFD
                    stateLock.unlock()
                    if curMaster >= 0 {
                        var ws = winsize(ws_row: newRows, ws_col: newCols, ws_xpixel: 0, ws_ypixel: 0)
                        _ = ioctl(curMaster, TIOCSWINSZ, &ws)
                    }
                }
            } else {
                // Skip unknown frame payload cleanly
                var remaining = payloadLen
                var ok = true
                while remaining > 0 {
                    let chunk = min(remaining, payloadBuf.count)
                    if payloadBuf.withUnsafeMutableBytes({ readAll(cfd, $0.baseAddress!, chunk) }) <= 0 {
                        ok = false
                        break
                    }
                    remaining -= chunk
                }
                if !ok { break }
            }
        }

        // Client disconnected (e.g. boo_box.app quit/update) -> detach WITHOUT killing the PTY child!
        detachClient(cfd)
    }
}

// MARK: - Daemon Registry & Control Server

private struct ControlRequest: Decodable {
    let op: String
    let paneId: String?
    let sessionId: String?
    let cwd: String?
    let command: String?
}

private final class DaemonState: @unchecked Sendable {
    let panesDir: String
    private let lock = NSLock()
    private var panes: [String: ManagedPane] = [:]
    private var lastActivity = Date()

    init(panesDir: String) {
        self.panesDir = panesDir
    }

    func touch() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    func idleSecondsWithNoPanes() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard panes.isEmpty else { return nil }
        return Date().timeIntervalSince(lastActivity)
    }

    func liveCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return panes.count
    }

    func spawnPane(paneId: String, sessionId: String, cwd: String, command: String) -> (socketPath: String, pid: pid_t)? {
        touch()
        lock.lock()
        if let existing = panes[paneId] {
            let info = existing.statusInfo()
            lock.unlock()
            if info.alive {
                return (existing.socketPath, existing.childPID)
            }
        } else {
            lock.unlock()
        }

        let safeID = paneId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safeID.isEmpty else { return nil }
        let sockPath = panesDir + "/\(safeID).sock"

        guard let pane = ManagedPane(
            paneId: paneId,
            sessionId: sessionId,
            socketPath: sockPath,
            cwd: cwd,
            command: command
        ) else {
            return nil
        }

        pane.onFinalCleanup = { [weak self] in
            self?.removePane(paneId: paneId)
        }

        lock.lock()
        panes[paneId] = pane
        lastActivity = Date()
        lock.unlock()

        pane.start()
        return (sockPath, pane.childPID)
    }

    func removePane(paneId: String) {
        lock.lock()
        panes.removeValue(forKey: paneId)
        lastActivity = Date()
        lock.unlock()
    }

    func killPane(paneId: String) {
        touch()
        lock.lock()
        let pane = panes.removeValue(forKey: paneId)
        lock.unlock()
        pane?.killPane()
    }

    func killSession(sessionId: String) {
        touch()
        lock.lock()
        let targets = panes.values.filter { $0.sessionId == sessionId }
        for p in targets {
            panes.removeValue(forKey: p.paneId)
        }
        lock.unlock()
        for p in targets {
            p.killPane()
        }
    }

    func listPanes() -> [PaneStatusInfo] {
        touch()
        lock.lock()
        let snapshot = Array(panes.values)
        lock.unlock()
        return snapshot.map { $0.statusInfo() }
    }

    func killAll() {
        lock.lock()
        let all = Array(panes.values)
        panes.removeAll()
        lock.unlock()
        for p in all {
            p.killPane()
        }
    }
}

// MARK: - Entry Point

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
_ = setsid()

let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
let runDir = home + "/boo_box/run"
let panesDir = runDir + "/panes"
let controlSocketPath = runDir + "/booboxd.sock"
let pidFilePath = runDir + "/booboxd.pid"

let fm = FileManager.default
try? fm.createDirectory(atPath: panesDir, withIntermediateDirectories: true)
chmod(runDir, 0o700)
chmod(panesDir, 0o700)

// Single-instance check: exit cleanly if an active booboxd already serves booboxd.sock
if isExistingDaemonAlive(controlSocket: controlSocketPath) {
    exit(0)
}

// Clean stale pane sockets left behind from a prior crash
if let stale = try? fm.contentsOfDirectory(atPath: panesDir) {
    for item in stale where item.hasSuffix(".sock") {
        unlink(panesDir + "/" + item)
    }
}

let controlFD = createUnixListener(at: controlSocketPath, mode: 0o600)
guard controlFD >= 0 else {
    fputs("booboxd: failed to bind \(controlSocketPath) (errno \(errno))\n", stderr)
    exit(1)
}
try? "\(getpid())\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)

private let state = DaemonState(panesDir: panesDir)

// Idle reaper: exit cleanly after 15 minutes with zero live panes so booboxd never lingers unused
DispatchQueue.global(qos: .background).async {
    while true {
        sleep(60)
        if let idle = state.idleSecondsWithNoPanes(), idle > 900 {
            unlink(controlSocketPath)
            unlink(pidFilePath)
            exit(0)
        }
    }
}

// Accept control requests
while true {
    let clientFD = accept(controlFD, nil, nil)
    if clientFD < 0 {
        if errno == EINTR { continue }
        break
    }
    setCloseOnExec(clientFD)

    var data = Data()
    var buf = [UInt8](repeating: 0, count: 8192)
    while data.count < 512 * 1024 {
        let n = Darwin.read(clientFD, &buf, buf.count)
        if n < 0 {
            if errno == EINTR { continue }
            break
        }
        if n == 0 { break }
        data.append(buf, count: n)
        if buf[0..<n].contains(0x0A) { break }
    }

    guard let req = try? JSONDecoder().decode(ControlRequest.self, from: data) else {
        writeJSONLine(clientFD, Data("{\"ok\":false,\"error\":\"invalid_json\"}".utf8))
        close(clientFD)
        continue
    }

    switch req.op {
    case "ping":
        state.touch()
        let resp = "{\"ok\":true,\"pid\":\(getpid()),\"livePanes\":\(state.liveCount())}"
        writeJSONLine(clientFD, Data(resp.utf8))

    case "spawn":
        if let paneId = req.paneId, let sessionId = req.sessionId,
           let cwd = req.cwd, let cmd = req.command,
           let spawned = state.spawnPane(paneId: paneId, sessionId: sessionId, cwd: cwd, command: cmd) {
            let payload: [String: Any] = [
                "ok": true,
                "paneId": paneId,
                "socketPath": spawned.socketPath,
                "pid": spawned.pid,
            ]
            if let encoded = try? JSONSerialization.data(withJSONObject: payload) {
                writeJSONLine(clientFD, encoded)
            }
        } else {
            writeJSONLine(clientFD, Data("{\"ok\":false,\"error\":\"spawn_failed\"}".utf8))
        }

    case "list":
        let panes = state.listPanes()
        struct ListResp: Encodable {
            let ok: Bool
            let panes: [PaneStatusInfo]
        }
        if let encoded = try? JSONEncoder().encode(ListResp(ok: true, panes: panes)) {
            writeJSONLine(clientFD, encoded)
        } else {
            writeJSONLine(clientFD, Data("{\"ok\":true,\"panes\":[]}".utf8))
        }

    case "kill":
        if let paneId = req.paneId {
            state.killPane(paneId: paneId)
        }
        writeJSONLine(clientFD, Data("{\"ok\":true}".utf8))

    case "kill_session":
        if let sid = req.sessionId {
            state.killSession(sessionId: sid)
        }
        writeJSONLine(clientFD, Data("{\"ok\":true}".utf8))

    case "shutdown":
        writeJSONLine(clientFD, Data("{\"ok\":true}".utf8))
        close(clientFD)
        state.killAll()
        unlink(controlSocketPath)
        unlink(pidFilePath)
        exit(0)

    default:
        writeJSONLine(clientFD, Data("{\"ok\":false,\"error\":\"unknown_op\"}".utf8))
    }

    close(clientFD)
}
