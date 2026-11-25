import Darwin
import Foundation

// boobox-attach: Tiny PTY-to-Unix-socket bridge spawned by libghostty
// (`ghostty_surface_config_s.command`) for every sandboxed microVM pane.
//
// Wire protocol matches guest/sbox-init.c:
//   Handshake line: "COLS=<u16> ROWS=<u16> TERM=<str> CWD=<str>\n"
//   Framed messages: [type: u8][len: u32 BE][payload]
//     0x01 DATA   - raw terminal bytes
//     0x02 RESIZE - [rows: u16 BE][cols: u16 BE]
//     0x03 EXIT   - [exit_code: u8]

private let MSG_DATA: UInt8 = 0x01
private let MSG_RESIZE: UInt8 = 0x02
private let MSG_EXIT: UInt8 = 0x03

// Self-pipe for async-signal-safe SIGWINCH delivery into poll()
nonisolated(unsafe) private var winchWriteFD: Int32 = -1

private func handleSigWinch(_ sig: Int32) {
    var b: UInt8 = 1
    if winchWriteFD >= 0 {
        _ = Darwin.write(winchWriteFD, &b, 1)
    }
}

private func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let n = Darwin.write(fd, ptr.advanced(by: offset), count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += n
    }
    return true
}

private func readAll(_ fd: Int32, _ ptr: UnsafeMutableRawPointer, _ count: Int) -> Int {
    var offset = 0
    while offset < count {
        let n = Darwin.read(fd, ptr.advanced(by: offset), count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            return -1
        }
        if n == 0 { return 0 }
        offset += n
    }
    return offset
}

private func sendFrame(_ fd: Int32, type: UInt8, payload: UnsafeRawPointer?, count: Int) -> Bool {
    var hdr = [UInt8](repeating: 0, count: 5)
    hdr[0] = type
    var beLen = UInt32(count).bigEndian
    withUnsafeBytes(of: &beLen) { bytes in
        hdr[1] = bytes[0]
        hdr[2] = bytes[1]
        hdr[3] = bytes[2]
        hdr[4] = bytes[3]
    }
    guard hdr.withUnsafeBytes({ writeAll(fd, $0.baseAddress!, 5) }) else { return false }
    if count > 0, let payload {
        return writeAll(fd, payload, count)
    }
    return true
}

private func currentWindowSize() -> (rows: UInt16, cols: UInt16) {
    var ws = winsize()
    if ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
        return (ws.ws_row, ws.ws_col)
    }
    return (24, 80)
}

private func sendResize(_ sockFD: Int32) -> Bool {
    let (rows, cols) = currentWindowSize()
    var buf = [UInt8](repeating: 0, count: 4)
    var beRows = rows.bigEndian
    var beCols = cols.bigEndian
    withUnsafeBytes(of: &beRows) { b in
        buf[0] = b[0]
        buf[1] = b[1]
    }
    withUnsafeBytes(of: &beCols) { b in
        buf[2] = b[0]
        buf[3] = b[1]
    }
    return buf.withUnsafeBytes { sendFrame(sockFD, type: MSG_RESIZE, payload: $0.baseAddress!, count: 4) }
}

private func connectUnixSocket(path: String, timeoutSec: Double = 10.0) -> Int32 {
    let deadline = Date().addingTimeInterval(timeoutSec)
    while true {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxLen else {
            close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, byte) in utf8.enumerated() {
                raw[i] = byte
            }
            raw[utf8.count] = 0
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        if res == 0 {
            return fd
        }
        close(fd)
        if Date() >= deadline {
            return -1
        }
        usleep(25_000)
    }
}

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: boobox-attach <socket_path> [cwd]\n", stderr)
    exit(2)
}

let sockPath = CommandLine.arguments[1]
let cwd = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "/root"
let term = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-ghostty"

// Connect to the host VM multiplexer socket
let sockFD = connectUnixSocket(path: sockPath)
guard sockFD >= 0 else {
    let msg = "\r\n\u{1B}[31m[boo_box] Failed to connect to sandbox VM.\u{1B}[0m\r\n"
    _ = msg.withCString { Darwin.write(STDOUT_FILENO, $0, strlen($0)) }
    exit(1)
}

// Configure local PTY in raw mode and restore on exit
var origTermios = termios()
let isTTY = isatty(STDIN_FILENO) != 0
if isTTY, tcgetattr(STDIN_FILENO, &origTermios) == 0 {
    var raw = origTermios
    cfmakeraw(&raw)
    _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}
defer {
    if isTTY {
        var restore = origTermios
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &restore)
    }
    close(sockFD)
}

// Setup SIGWINCH self-pipe
var winchPipe: [Int32] = [-1, -1]
if pipe(&winchPipe) == 0 {
    _ = fcntl(winchPipe[0], F_SETFL, O_NONBLOCK)
    _ = fcntl(winchPipe[1], F_SETFL, O_NONBLOCK)
    winchWriteFD = winchPipe[1]
    signal(SIGWINCH, handleSigWinch)
}
signal(SIGPIPE, SIG_IGN)

// Send handshake
let (initRows, initCols) = currentWindowSize()
let safeTerm = term.replacingOccurrences(of: " ", with: "_")
let safeCwd = cwd.replacingOccurrences(of: " ", with: "_")
let handshake = "COLS=\(initCols) ROWS=\(initRows) TERM=\(safeTerm) CWD=\(safeCwd)\n"
guard handshake.withCString({ writeAll(sockFD, $0, strlen($0)) }) else {
    exit(1)
}

var pfds: [pollfd] = [
    pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
    pollfd(fd: sockFD, events: Int16(POLLIN), revents: 0),
    pollfd(fd: winchPipe[0], events: Int16(POLLIN), revents: 0),
]

var ioBuf = [UInt8](repeating: 0, count: 16384)
var exitCode: Int32 = 0
var running = true
var clearedLoginBanner = !isTTY
while running {
    let rc = poll(&pfds, nfds_t(pfds.count), -1)
    if rc < 0 {
        if errno == EINTR { continue }
        break
    }

    // 1. SIGWINCH -> send resize frame
    if pfds[2].revents & Int16(POLLIN) != 0 {
        var drain = [UInt8](repeating: 0, count: 64)
        while Darwin.read(winchPipe[0], &drain, drain.count) > 0 {}
        if !sendResize(sockFD) {
            running = false
            break
        }
    }

    // 2. Local stdin -> guest VM (stop polling stdin on EOF without cutting guest stdout)
    if pfds[0].fd >= 0 && pfds[0].revents & Int16(POLLIN) != 0 {
        let n = Darwin.read(STDIN_FILENO, &ioBuf, ioBuf.count)
        if n > 0 {
            let ok = ioBuf.withUnsafeBytes { sendFrame(sockFD, type: MSG_DATA, payload: $0.baseAddress!, count: n) }
            if !ok {
                running = false
                break
            }
        } else {
            pfds[0].fd = -1
            pfds[0].events = 0
        }
    }
    if pfds[0].fd >= 0 && pfds[0].revents & Int16(POLLHUP | POLLERR) != 0 {
        pfds[0].fd = -1
        pfds[0].events = 0
    }
    // 3. Guest VM -> local stdout
    if pfds[1].revents & Int16(POLLIN) != 0 {
        var hdr = [UInt8](repeating: 0, count: 5)
        let hn = hdr.withUnsafeMutableBytes { readAll(sockFD, $0.baseAddress!, 5) }
        if hn <= 0 {
            running = false
            break
        }
        let type = hdr[0]
        let payloadLen = Int(
            (UInt32(hdr[1]) << 24) |
            (UInt32(hdr[2]) << 16) |
            (UInt32(hdr[3]) << 8) |
            UInt32(hdr[4])
        )

        if type == MSG_DATA {
            if !clearedLoginBanner {
                clearedLoginBanner = true
                let clr = "\u{1B}[2J\u{1B}[H"
                _ = clr.withCString { writeAll(STDOUT_FILENO, $0, strlen($0)) }
            }
            var remaining = payloadLen
            while remaining > 0 {
                let chunk = min(remaining, ioBuf.count)
                let rn = ioBuf.withUnsafeMutableBytes { readAll(sockFD, $0.baseAddress!, chunk) }
                if rn <= 0 {
                    running = false
                    break
                }
                if !ioBuf.withUnsafeBytes({ writeAll(STDOUT_FILENO, $0.baseAddress!, chunk) }) {
                    running = false
                    break
                }
                remaining -= chunk
            }
        } else if type == MSG_EXIT {
            if payloadLen >= 1 {
                var code: UInt8 = 0
                _ = withUnsafeMutableBytes(of: &code) { readAll(sockFD, $0.baseAddress!, 1) }
                exitCode = Int32(code)
            }
            running = false
            break
        } else {
            var remaining = payloadLen
            while remaining > 0 {
                let chunk = min(remaining, ioBuf.count)
                if ioBuf.withUnsafeMutableBytes({ readAll(sockFD, $0.baseAddress!, chunk) }) <= 0 {
                    running = false
                    break
                }
                remaining -= chunk
            }
        }
    }
    if pfds[1].revents & Int16(POLLHUP | POLLERR) != 0 {
        running = false
        break
    }
}

exit(exitCode)
