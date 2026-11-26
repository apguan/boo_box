import Darwin
import Foundation

// boobox-proxy — Host-side secret-injecting & egress-filtering proxy sidecar for boo_box.
//
// Security properties:
// - Real secret values are pushed over a chmod-0600 host Unix domain socket and kept strictly in memory.
// - Sandboxes receive worthless per-session phantom tokens (`bbx_ph_...`).
// - Base-URL reverse-proxy requests (`/upstream/<host>/...`) substitute `bbx_ph_...` -> real secret
//   ONLY when `<host>` matches that secret's `allowedHosts`. Any attempt to send a phantom token
//   to an unauthorized host is hard-blocked (`403 Forbidden`) and recorded as `leak_blocked`.
// - Forward HTTP and HTTPS (`CONNECT`) requests enforce `offline` | `allowlist` | `full` egress
//   policy and emit real-time audit events queryable by `boo_box.app`.

// MARK: - Protocol Models

struct ProxySecretSpec: Codable, Sendable {
    let envVar: String
    let phantomToken: String
    let realValue: String
    let allowedHosts: [String]
}

struct ProxyConfigPayload: Codable, Sendable {
    let op: String
    let egressMode: String?                 // "full" | "allowlist" | "offline"
    let allowedDomains: [String]?
    let secrets: [ProxySecretSpec]?
    let sessionId: String?
    let proxyToken: String?
    let extraAllowedDomains: [String]?      // per-session additional domains
    let allowedSecretEnvVars: [String]?     // nil = inherit all; [] = 0 secrets; [...] = subset
    let sinceSeq: UInt64?
}

struct SessionPolicy: Sendable {
    let sessionId: String
    let egressMode: String?
    let extraAllowedDomains: [String]
    let allowedSecretEnvVars: Set<String>?
}
struct ProxyAuditEvent: Codable, Sendable {
    let seq: UInt64
    let timestamp: Double
    let sessionId: String
    let method: String
    let host: String
    let decision: String            // "allowed" | "blocked" | "secret_injected" | "leak_blocked"
    let reason: String
}

// MARK: - Thread-Safe Policy & Audit Store

final class ProxyState: @unchecked Sendable {
    private let lock = NSLock()
    private var egressMode: String = "full"
    private var allowedDomains: [String] = []
    private var secrets: [ProxySecretSpec] = []
    private var sessionTokens: [String: String] = [:]       // proxyToken -> sessionId
    private var sessionPolicies: [String: SessionPolicy] = [:] // sessionId -> policy
    private var events: [ProxyAuditEvent] = []
    private var nextSeq: UInt64 = 1
    private let maxEvents = 250
    func updateConfig(egressMode: String?, allowedDomains: [String]?, secrets: [ProxySecretSpec]?) {
        lock.lock()
        if let m = egressMode { self.egressMode = m }
        if let d = allowedDomains { self.allowedDomains = d.map { $0.lowercased() } }
        if let s = secrets { self.secrets = s }
        lock.unlock()
    }

    func registerSession(
        sessionId: String,
        proxyToken: String,
        egressMode: String?,
        extraAllowedDomains: [String]?,
        allowedSecretEnvVars: [String]?
    ) {
        lock.lock()
        sessionTokens[proxyToken] = sessionId
        sessionPolicies[sessionId] = SessionPolicy(
            sessionId: sessionId,
            egressMode: egressMode,
            extraAllowedDomains: (extraAllowedDomains ?? []).map { $0.lowercased() },
            allowedSecretEnvVars: allowedSecretEnvVars.map { Set($0) }
        )
        lock.unlock()
    }

    func unregisterSession(sessionId: String) {
        lock.lock()
        sessionTokens = sessionTokens.filter { $0.value != sessionId }
        sessionPolicies.removeValue(forKey: sessionId)
        lock.unlock()
    }

    func resolveSession(fromProxyAuthHeader value: String?) -> String {
        guard let value else { return "global" }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: String(parts[1])),
              let creds = String(data: decoded, encoding: .utf8) else {
            return "global"
        }
        let pair = creds.split(separator: ":", maxSplits: 1)
        if pair.count == 2 {
            let tok = String(pair[1])
            lock.lock()
            let mapped = sessionTokens[tok]
            lock.unlock()
            if let mapped { return mapped }
            return String(pair[0])
        }
        return "global"
    }

    func effectiveSnapshot(for sessionId: String) -> (
        egressMode: String,
        allowedDomains: [String],
        secrets: [ProxySecretSpec],
        allowedSecretEnvVars: Set<String>?
    ) {
        lock.lock()
        let pol = sessionPolicies[sessionId]
        let mode = pol?.egressMode ?? egressMode
        let domains = pol.map { allowedDomains + $0.extraAllowedDomains } ?? allowedDomains
        let copySecrets = secrets
        let allowedEnvVars = pol?.allowedSecretEnvVars
        lock.unlock()
        return (mode, domains, copySecrets, allowedEnvVars)
    }
    func record(sessionId: String, method: String, host: String, decision: String, reason: String) {
        lock.lock()
        let seq = nextSeq
        nextSeq += 1
        let ev = ProxyAuditEvent(
            seq: seq,
            timestamp: Date().timeIntervalSince1970,
            sessionId: sessionId,
            method: method,
            host: host,
            decision: decision,
            reason: reason
        )
        events.append(ev)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lock.unlock()
    }

    func recentEvents(sinceSeq: UInt64 = 0) -> [ProxyAuditEvent] {
        lock.lock()
        let copy = sinceSeq > 0 ? events.filter { $0.seq > sinceSeq } : events
        lock.unlock()
        return copy
    }

    func clearEvents() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}

// MARK: - Host & Secret Matching

private func normalizeHost(_ raw: String) -> String {
    var h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if h.hasPrefix("[") {
        if let end = h.firstIndex(of: "]") {
            h = String(h[h.index(after: h.startIndex)..<end])
        }
    } else if let colon = h.firstIndex(of: ":") {
        h = String(h[..<colon])
    }
    while h.hasSuffix(".") { h.removeLast() }
    return h
}

private func hostMatches(_ host: String, patterns: [String]) -> Bool {
    let target = normalizeHost(host)
    guard !target.isEmpty else { return false }
    for rawPat in patterns {
        let pat = normalizeHost(rawPat)
        guard !pat.isEmpty else { continue }
        if pat == target { return true }
        if pat.hasPrefix("*.") {
            let suffix = String(pat.dropFirst(1)) // ".example.com"
            let apex = String(pat.dropFirst(2))   // "example.com"
            if target == apex || target.hasSuffix(suffix) {
                return true
            }
        }
    }
    return false
}

private func isBlockedMetadataHost(_ host: String) -> Bool {
    let h = normalizeHost(host)
    return h == "169.254.169.254" || h == "metadata.google.internal"
}

private func splitHostPort(_ authority: String, defaultPort: Int) -> (host: String, port: Int) {
    let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
        let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        let after = trimmed[trimmed.index(after: close)...]
        if after.hasPrefix(":"), let p = Int(after.dropFirst()) {
            return (host, p)
        }
        return (host, defaultPort)
    }
    if let colon = trimmed.lastIndex(of: ":"), let p = Int(trimmed[trimmed.index(after: colon)...]) {
        return (String(trimmed[..<colon]), p)
    }
    return (trimmed, defaultPort)
}

// MARK: - Socket I/O Helpers

private func writeAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }
        var off = 0
        while off < data.count {
            let n = Darwin.write(fd, base.advanced(by: off), data.count - off)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            off += n
        }
        return true
    }
}

private func sendHTTPError(fd: Int32, status: Int, title: String, reasonHeader: String, body: String) {
    let bodyData = Data(body.utf8)
    let resp = """
    HTTP/1.1 \(status) \(title)\r
    Content-Type: text/plain; charset=utf-8\r
    Content-Length: \(bodyData.count)\r
    X-BooBox-Proxy: \(reasonHeader)\r
    Connection: close\r
    \r
    \(body)
    """
    _ = writeAll(fd: fd, data: Data(resp.utf8))
}

private func setSocketNoDelay(_ fd: Int32) {
    var one: Int32 = 1
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
}

private func setSocketNonBlocking(_ fd: Int32, enabled: Bool) {
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0 else { return }
    _ = fcntl(fd, F_SETFL, enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
}

private func waitReadable(fd: Int32, timeoutMs: Int32) -> Bool {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        let rc = Darwin.poll(&pfd, 1, timeoutMs)
        if rc < 0 {
            if errno == EINTR { continue }
            return false
        }
        return rc > 0 && (pfd.revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0
    }
}

private func readHTTPRequest(
    fd: Int32,
    leftover: inout Data,
    idleTimeoutMs: Int32 = 30_000
) -> (method: String, target: String, version: String, headers: [(String, String)], body: Data)? {
    var buffer = leftover
    leftover.removeAll(keepingCapacity: true)
    var chunk = [UInt8](repeating: 0, count: 16384)
    let headerSep = Data("\r\n\r\n".utf8)
    var headerEndRange: Range<Data.Index>? = buffer.range(of: headerSep)

    while headerEndRange == nil && buffer.count < 256 * 1024 {
        if buffer.isEmpty && !waitReadable(fd: fd, timeoutMs: idleTimeoutMs) {
            return nil
        }
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if n == 0 { break }
        buffer.append(chunk, count: n)
        if let r = buffer.range(of: headerSep) {
            headerEndRange = r
            break
        }
    }

    guard let sep = headerEndRange else { return nil }
    let headerData = buffer[..<sep.lowerBound]
    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let reqParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard reqParts.count >= 2 else { return nil }

    let method = String(reqParts[0]).uppercased()
    let target = String(reqParts[1])
    let version = reqParts.count >= 3 ? String(reqParts[2]).uppercased() : "HTTP/1.1"
    var headers: [(String, String)] = []
    var contentLength = 0
    var isChunked = false

    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        headers.append((name, val))
        let lower = name.lowercased()
        if lower == "content-length", let len = Int(val), len > 0 {
            contentLength = min(len, 32 * 1024 * 1024)
        } else if lower == "transfer-encoding", val.lowercased().contains("chunked") {
            isChunked = true
        }
    }

    var bodyBuf = Data(buffer[sep.upperBound...])
    let body: Data
    if contentLength > 0 {
        while bodyBuf.count < contentLength {
            let toRead = min(chunk.count, contentLength - bodyBuf.count)
            let n = Darwin.read(fd, &chunk, toRead)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            bodyBuf.append(chunk, count: n)
        }
        if bodyBuf.count > contentLength {
            body = Data(bodyBuf.prefix(contentLength))
            leftover = Data(bodyBuf.dropFirst(contentLength))
        } else {
            body = bodyBuf
        }
    } else if isChunked {
        body = readAndDecodeChunkedBody(fd: fd, buffer: &bodyBuf)
        leftover = bodyBuf
    } else {
        body = Data()
        leftover = bodyBuf
    }

    return (method, target, version, headers, body)
}

private func readAndDecodeChunkedBody(fd: Int32, buffer raw: inout Data) -> Data {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 16384)
    let crlf = Data("\r\n".utf8)

    func fillMore() -> Bool {
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            raw.append(buf, count: n)
            return true
        }
    }

    while out.count < 32 * 1024 * 1024 {
        while raw.range(of: crlf) == nil {
            if !fillMore() { return out }
        }
        guard let lineRange = raw.range(of: crlf) else { break }
        let sizeStr = String(data: raw[..<lineRange.lowerBound], encoding: .utf8)?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        raw.removeSubrange(..<lineRange.upperBound)
        guard let size = Int(sizeStr, radix: 16) else { break }
        if size == 0 {
            // Drain optional trailing headers + final CRLF so keep-alive framing stays aligned
            while true {
                while raw.range(of: crlf) == nil {
                    if !fillMore() { return out }
                }
                guard let endRange = raw.range(of: crlf) else { return out }
                let isEmptyTrailer = (endRange.lowerBound == raw.startIndex)
                raw.removeSubrange(..<endRange.upperBound)
                if isEmptyTrailer { break }
            }
            break
        }
        while raw.count < size + 2 {
            if !fillMore() { return out }
        }
        out.append(raw.prefix(size))
        raw.removeFirst(min(raw.count, size + 2))
    }
    return out
}
// MARK: - Streaming Upstream Bridge (Supports SSE / Chunked LLM Streams)

/// Process-wide pooled URLSession so upstream LLM API requests reuse HTTP/2+HTTP/3 connections
/// and TLS 1.3 sessions instead of paying a cold TCP+TLS handshake on every turn.
private final class UpstreamSessionPool: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class TaskState: @unchecked Sendable {
        let clientFD: Int32
        let scrubPairs: [(real: String, phantom: String)]
        let keepAlive: Bool
        let doneSemaphore = DispatchSemaphore(value: 0)
        var sentHeaders = false
        var writeFailed = false
        var canReuseClient = false

        init(clientFD: Int32, scrubPairs: [(real: String, phantom: String)], keepAlive: Bool) {
            self.clientFD = clientFD
            self.scrubPairs = scrubPairs
            self.keepAlive = keepAlive
        }
    }

    static let shared = UpstreamSessionPool()

    private let lock = NSLock()
    private var tasks: [Int: TaskState] = [:]
    private var session: URLSession!

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:] // Never recurse through system HTTP_PROXY
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpMaximumConnectionsPerHost = 16
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 1800
        let queue = OperationQueue()
        queue.name = "dev.boo-box.proxy-upstream"
        queue.qualityOfService = .userInitiated
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }

    /// Executes `request` on the shared pooled session, streaming chunked response bytes back to `clientFD`.
    /// Returns `true` if `clientFD` remains cleanly framed for HTTP/1.1 keep-alive reuse.
    func execute(
        _ request: URLRequest,
        clientFD: Int32,
        scrubPairs: [(real: String, phantom: String)],
        keepAlive: Bool
    ) -> Bool {
        let state = TaskState(clientFD: clientFD, scrubPairs: scrubPairs, keepAlive: keepAlive)
        let task = session.dataTask(with: request)
        lock.lock()
        tasks[task.taskIdentifier] = state
        lock.unlock()
        task.resume()
        state.doneSemaphore.wait()
        return state.canReuseClient
    }

    private func state(for taskID: Int) -> TaskState? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[taskID]
    }

    private func removeState(for taskID: Int) -> TaskState? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.removeValue(forKey: taskID)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let st = state(for: dataTask.taskIdentifier),
              let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        var head = "HTTP/1.1 \(http.statusCode) \(reason)\r\n"
        let hopByHop: Set<String> = [
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "te", "trailer", "transfer-encoding", "upgrade", "content-encoding", "content-length",
        ]
        for (k, v) in http.allHeaderFields {
            let name = "\(k)"
            if hopByHop.contains(name.lowercased()) { continue }
            var val = "\(v)"
            for pair in st.scrubPairs where !pair.real.isEmpty {
                if val.contains(pair.real) {
                    val = val.replacingOccurrences(of: pair.real, with: pair.phantom)
                }
            }
            head += "\(name): \(val)\r\n"
        }
        let connHeader = st.keepAlive ? "keep-alive" : "close"
        head += "Transfer-Encoding: chunked\r\nConnection: \(connHeader)\r\n\r\n"
        st.sentHeaders = true
        if !writeAll(fd: st.clientFD, data: Data(head.utf8)) {
            st.writeFailed = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let st = state(for: dataTask.taskIdentifier), !st.writeFailed, !data.isEmpty else { return }
        var payload = data
        if !st.scrubPairs.isEmpty, var text = String(data: data, encoding: .utf8) {
            var changed = false
            for pair in st.scrubPairs where !pair.real.isEmpty {
                if text.contains(pair.real) {
                    text = text.replacingOccurrences(of: pair.real, with: pair.phantom)
                    changed = true
                }
            }
            if changed {
                payload = Data(text.utf8)
            }
        }
        let prefix = String(format: "%x\r\n", payload.count)
        var frame = Data(capacity: prefix.utf8.count + payload.count + 2)
        frame.append(contentsOf: prefix.utf8)
        frame.append(payload)
        frame.append(contentsOf: [0x0D, 0x0A])
        if !writeAll(fd: st.clientFD, data: frame) {
            st.writeFailed = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let st = removeState(for: task.taskIdentifier) else { return }
        if !st.sentHeaders {
            let msg = error?.localizedDescription ?? "Upstream connection failed"
            sendHTTPError(fd: st.clientFD, status: 502, title: "Bad Gateway", reasonHeader: "upstream-error", body: "boo_box proxy: \(msg)\n")
            st.canReuseClient = false
        } else if !st.writeFailed {
            let ok = writeAll(fd: st.clientFD, data: Data("0\r\n\r\n".utf8))
            st.canReuseClient = ok && st.keepAlive && (error == nil)
        } else {
            st.canReuseClient = false
        }
        st.doneSemaphore.signal()
    }
}

// MARK: - TCP Tunnel for HTTPS CONNECT (Non-Blocking Timeout + Single-Thread poll(2) Relay)

private func openUpstreamTCP(host: String, port: Int, timeoutMs: Int32 = 5_000) -> Int32 {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    hints.ai_family = AF_UNSPEC
    var res: UnsafeMutablePointer<addrinfo>? = nil
    let rc = getaddrinfo(host, String(port), &hints, &res)
    guard rc == 0, let first = res else { return -1 }
    defer { freeaddrinfo(first) }

    var cur: UnsafeMutablePointer<addrinfo>? = first
    while let info = cur {
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd >= 0 {
            setSocketNoDelay(fd)
            setSocketNonBlocking(fd, enabled: true)
            let c = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if c == 0 {
                return fd
            }
            if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let prc = Darwin.poll(&pfd, 1, timeoutMs)
                if prc > 0 {
                    var soErr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 && soErr == 0 {
                        return fd
                    }
                }
            }
            close(fd)
        }
        cur = info.pointee.ai_next
    }
    return -1
}

/// Single-thread bidirectional `poll(2)` relay for HTTPS CONNECT tunnels.
/// Avoids spawning 2 extra GCD threads per open socket, eliminating thread-pool starvation under heavy load.
private func relayBidirectional(clientFD: Int32, upstreamFD: Int32, initialClientBytes: Data = Data()) {
    setSocketNoDelay(clientFD)
    setSocketNoDelay(upstreamFD)
    setSocketNonBlocking(clientFD, enabled: true)
    setSocketNonBlocking(upstreamFD, enabled: true)

    let maxBuf = 65536
    var c2u = [UInt8](initialClientBytes)
    var c2uOff = 0
    var u2c: [UInt8] = []
    var u2cOff = 0
    var scratch = [UInt8](repeating: 0, count: 32768)

    var clientEOF = false
    var upstreamEOF = false
    var sentUpEOF = false
    var sentClientEOF = false

    while true {
        if c2uOff == c2u.count { c2u.removeAll(keepingCapacity: true); c2uOff = 0 }
        if u2cOff == u2c.count { u2c.removeAll(keepingCapacity: true); u2cOff = 0 }

        if clientEOF && c2u.isEmpty && !sentUpEOF {
            shutdown(upstreamFD, SHUT_WR)
            sentUpEOF = true
        }
        if upstreamEOF && u2c.isEmpty && !sentClientEOF {
            shutdown(clientFD, SHUT_WR)
            sentClientEOF = true
        }
        if sentUpEOF && sentClientEOF { break }

        var cEvents: Int16 = 0
        if !clientEOF && (c2u.count - c2uOff) < maxBuf { cEvents |= Int16(POLLIN) }
        if !u2c.isEmpty && !sentClientEOF { cEvents |= Int16(POLLOUT) }

        var uEvents: Int16 = 0
        if !upstreamEOF && (u2c.count - u2cOff) < maxBuf { uEvents |= Int16(POLLIN) }
        if !c2u.isEmpty && !sentUpEOF { uEvents |= Int16(POLLOUT) }

        if cEvents == 0 && uEvents == 0 { break }

        var pfds = [
            pollfd(fd: clientFD, events: cEvents, revents: 0),
            pollfd(fd: upstreamFD, events: uEvents, revents: 0),
        ]
        let rc = Darwin.poll(&pfds, 2, 60_000)
        if rc < 0 {
            if errno == EINTR { continue }
            break
        }
        if rc == 0 { continue }

        // 1. Read client -> c2u
        if (pfds[0].revents & Int16(POLLIN | POLLHUP)) != 0 && !clientEOF {
            while (c2u.count - c2uOff) < maxBuf {
                let n = Darwin.read(clientFD, &scratch, min(scratch.count, maxBuf - (c2u.count - c2uOff)))
                if n > 0 {
                    c2u.append(contentsOf: scratch[0..<n])
                } else if n == 0 {
                    clientEOF = true
                    break
                } else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    clientEOF = true
                    break
                }
            }
        }
        if (pfds[0].revents & Int16(POLLERR | POLLNVAL)) != 0 {
            clientEOF = true
            u2c.removeAll(keepingCapacity: false)
            u2cOff = 0
            sentClientEOF = true
        }

        // 2. Read upstream -> u2c
        if (pfds[1].revents & Int16(POLLIN | POLLHUP)) != 0 && !upstreamEOF {
            while (u2c.count - u2cOff) < maxBuf {
                let n = Darwin.read(upstreamFD, &scratch, min(scratch.count, maxBuf - (u2c.count - u2cOff)))
                if n > 0 {
                    u2c.append(contentsOf: scratch[0..<n])
                } else if n == 0 {
                    upstreamEOF = true
                    break
                } else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    upstreamEOF = true
                    break
                }
            }
        }
        if (pfds[1].revents & Int16(POLLERR | POLLNVAL)) != 0 {
            upstreamEOF = true
            c2u.removeAll(keepingCapacity: false)
            c2uOff = 0
            sentUpEOF = true
        }

        // 3. Flush c2u -> upstream
        while c2uOff < c2u.count {
            let w = c2u.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(upstreamFD, base.advanced(by: c2uOff), c2u.count - c2uOff)
            }
            if w > 0 {
                c2uOff += w
            } else if w < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                c2u.removeAll(keepingCapacity: false)
                c2uOff = 0
                sentUpEOF = true
                clientEOF = true
                break
            } else {
                break
            }
        }

        // 4. Flush u2c -> client
        while u2cOff < u2c.count {
            let w = u2c.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(clientFD, base.advanced(by: u2cOff), u2c.count - u2cOff)
            }
            if w > 0 {
                u2cOff += w
            } else if w < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                u2c.removeAll(keepingCapacity: false)
                u2cOff = 0
                sentClientEOF = true
                upstreamEOF = true
                break
            } else {
                break
            }
        }
    }
}

// MARK: - Core Request Handler (Supports HTTP/1.1 Keep-Alive on Client Loopback Socket)

private func handleProxyClient(clientFD: Int32, state: ProxyState) {
    defer { close(clientFD) }
    setSocketNoDelay(clientFD)
    var leftover = Data()

    while let req = readHTTPRequest(fd: clientFD, leftover: &leftover, idleTimeoutMs: 30_000) {
        let shouldContinue = handleSingleProxyRequest(req: req, clientFD: clientFD, state: state, leftover: &leftover)
        if !shouldContinue { break }
    }
}

private func handleSingleProxyRequest(
    req: (method: String, target: String, version: String, headers: [(String, String)], body: Data),
    clientFD: Int32,
    state: ProxyState,
    leftover: inout Data
) -> Bool {
    let proxyAuth = req.headers.first { $0.0.lowercased() == "proxy-authorization" }?.1
    var sessionId = state.resolveSession(fromProxyAuthHeader: proxyAuth)

    // Optional `/s/<sessionId>/upstream/...` prefix lets Base-URL requests identify their exact session
    var effectiveTarget = req.target
    if effectiveTarget.hasPrefix("/s/") {
        let afterPrefix = effectiveTarget.dropFirst(3)
        if let slash = afterPrefix.firstIndex(of: "/") {
            let sid = String(afterPrefix[..<slash])
            if !sid.isEmpty {
                sessionId = sid
                effectiveTarget = String(afterPrefix[slash...])
            }
        }
    }

    let snap = state.effectiveSnapshot(for: sessionId)

    // 1. HTTPS CONNECT Tunnel
    if req.method == "CONNECT" {
        let (host, port) = splitHostPort(effectiveTarget, defaultPort: 443)
        let normHost = normalizeHost(host)

        if isBlockedMetadataHost(normHost) {
            state.record(sessionId: sessionId, method: "CONNECT", host: normHost, decision: "blocked", reason: "Cloud metadata IP blocked")
            sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "metadata-blocked", body: "boo_box proxy: metadata endpoint blocked\n")
            return false
        }
        if snap.egressMode == "offline" {
            state.record(sessionId: sessionId, method: "CONNECT", host: normHost, decision: "blocked", reason: "Offline mode")
            sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "offline", body: "boo_box proxy: sandbox network is Offline\n")
            return false
        }
        if snap.egressMode == "allowlist" && !hostMatches(normHost, patterns: snap.allowedDomains) {
            state.record(sessionId: sessionId, method: "CONNECT", host: normHost, decision: "blocked", reason: "Host not in Dev Allowlist")
            sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "domain-blocked", body: "boo_box proxy: host '\(normHost)' is not in Dev Allowlist\n")
            return false
        }

        let upFD = openUpstreamTCP(host: host, port: port)
        guard upFD >= 0 else {
            sendHTTPError(fd: clientFD, status: 502, title: "Bad Gateway", reasonHeader: "connect-failed", body: "boo_box proxy: failed to connect to \(host):\(port)\n")
            return false
        }
        defer { close(upFD) }
        state.record(sessionId: sessionId, method: "CONNECT", host: normHost, decision: "allowed", reason: snap.egressMode)
        guard writeAll(fd: clientFD, data: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else { return false }
        relayBidirectional(clientFD: clientFD, upstreamFD: upFD, initialClientBytes: leftover)
        leftover.removeAll(keepingCapacity: false)
        return false
    }

    // 2. Determine target upstream URL (either Base-URL reverse proxy or forward plaintext HTTP)
    let upstreamScheme: String
    let targetHostPort: String
    let targetPath: String

    if effectiveTarget.hasPrefix("/upstream/") || effectiveTarget.hasPrefix("/upstream-http/") {
        let isLocalHTTP = effectiveTarget.hasPrefix("/upstream-http/")
        let prefix = isLocalHTTP ? "/upstream-http/" : "/upstream/"
        let rest = String(effectiveTarget.dropFirst(prefix.count))
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let hostSeg = parts.first, !hostSeg.isEmpty else {
            sendHTTPError(fd: clientFD, status: 400, title: "Bad Request", reasonHeader: "bad-upstream", body: "boo_box proxy: missing upstream host\n")
            return false
        }
        targetHostPort = String(hostSeg)
        let norm = normalizeHost(targetHostPort)
        // `/upstream-http/` is permitted ONLY for loopback test endpoints; all remote hosts use HTTPS
        if isLocalHTTP && norm != "127.0.0.1" && norm != "localhost" {
            sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "https-required", body: "boo_box proxy: /upstream-http/ is restricted to localhost\n")
            return false
        }
        upstreamScheme = isLocalHTTP ? "http" : "https"
        targetPath = parts.count > 1 ? "/" + String(parts[1]) : "/"
    } else if effectiveTarget.lowercased().hasPrefix("http://") || effectiveTarget.lowercased().hasPrefix("https://"),
              let comps = URLComponents(string: effectiveTarget),
              let host = comps.host {
        upstreamScheme = (comps.scheme ?? "http").lowercased()
        if let port = comps.port {
            targetHostPort = "\(host):\(port)"
        } else {
            targetHostPort = host
        }
        var p = comps.percentEncodedPath
        if p.isEmpty { p = "/" }
        if let q = comps.percentEncodedQuery { p += "?\(q)" }
        targetPath = p
    } else {
        sendHTTPError(fd: clientFD, status: 400, title: "Bad Request", reasonHeader: "unsupported-target", body: "boo_box proxy: expected absolute URL or /upstream/<host>/...\n")
        return false
    }
    let normHost = normalizeHost(targetHostPort)

    if isBlockedMetadataHost(normHost) {
        state.record(sessionId: sessionId, method: req.method, host: normHost, decision: "blocked", reason: "Cloud metadata IP blocked")
        sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "metadata-blocked", body: "boo_box proxy: metadata endpoint blocked\n")
        return false
    }

    // 3. Active phantom-token leak detection + host-bound secret substitution
    var mutatedHeaders = req.headers
    var mutatedPath = targetPath
    var mutatedBody = req.body
    var injectedNames: [String] = []
    var scrubPairs: [(real: String, phantom: String)] = []

    for secret in snap.secrets where !secret.phantomToken.isEmpty {
        let tok = secret.phantomToken
        let inPath = mutatedPath.contains(tok)
        let inHeaders = mutatedHeaders.contains { $0.1.contains(tok) }
        let bodyText = String(data: mutatedBody, encoding: .utf8)
        let inBody = bodyText?.contains(tok) ?? false

        if inPath || inHeaders || inBody {
            let sessionPermitted = (snap.allowedSecretEnvVars == nil) || snap.allowedSecretEnvVars!.contains(secret.envVar)
            guard sessionPermitted && hostMatches(normHost, patterns: secret.allowedHosts) else {
                let reason = sessionPermitted
                    ? "Blocked \(secret.envVar) phantom token sent to unauthorized host \(normHost)"
                    : "Blocked \(secret.envVar) phantom token used by unauthorized session \(sessionId)"
                state.record(
                    sessionId: sessionId,
                    method: req.method,
                    host: normHost,
                    decision: "leak_blocked",
                    reason: reason
                )
                sendHTTPError(
                    fd: clientFD,
                    status: 403,
                    title: "Forbidden",
                    reasonHeader: "secret-exfiltration-blocked",
                    body: "boo_box proxy: BLOCKED \(reason)\n"
                )
                return false
            }
            if inPath {
                mutatedPath = mutatedPath.replacingOccurrences(of: tok, with: secret.realValue)
            }
            if inHeaders {
                mutatedHeaders = mutatedHeaders.map { (k, v) in
                    (k, v.replacingOccurrences(of: tok, with: secret.realValue))
                }
            }
            if inBody, let txt = bodyText {
                mutatedBody = Data(txt.replacingOccurrences(of: tok, with: secret.realValue).utf8)
            }
            injectedNames.append(secret.envVar)
            scrubPairs.append((real: secret.realValue, phantom: tok))
        }
    }

    // 4. Enforce egress mode (after leak check so leak attempts are ALWAYS flagged even in offline mode!)
    if snap.egressMode == "offline" {
        state.record(sessionId: sessionId, method: req.method, host: normHost, decision: "blocked", reason: "Offline mode")
        sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "offline", body: "boo_box proxy: sandbox network is Offline\n")
        return false
    }
    if snap.egressMode == "allowlist" && !hostMatches(normHost, patterns: snap.allowedDomains) {
        state.record(sessionId: sessionId, method: req.method, host: normHost, decision: "blocked", reason: "Host not in Dev Allowlist")
        sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "domain-blocked", body: "boo_box proxy: host '\(normHost)' is not in Dev Allowlist\n")
        return false
    }

    guard let upstreamURL = URL(string: "\(upstreamScheme)://\(targetHostPort)\(mutatedPath)") else {
        sendHTTPError(fd: clientFD, status: 400, title: "Bad Request", reasonHeader: "invalid-url", body: "boo_box proxy: invalid upstream URL\n")
        return false
    }

    var urlReq = URLRequest(url: upstreamURL)
    urlReq.httpMethod = req.method
    let skipReqHeaders: Set<String> = [
        "host", "proxy-connection", "proxy-authorization", "connection",
        "transfer-encoding", "content-length", "keep-alive",
    ]
    for (k, v) in mutatedHeaders {
        if skipReqHeaders.contains(k.lowercased()) { continue }
        urlReq.addValue(v, forHTTPHeaderField: k)
    }
    if !mutatedBody.isEmpty {
        urlReq.httpBody = mutatedBody
    }

    if !injectedNames.isEmpty {
        state.record(
            sessionId: sessionId,
            method: req.method,
            host: normHost,
            decision: "secret_injected",
            reason: "Injected \(injectedNames.joined(separator: ", "))"
        )
    } else {
        state.record(sessionId: sessionId, method: req.method, host: normHost, decision: "allowed", reason: snap.egressMode)
    }

    let connVal = req.headers.first {
        let k = $0.0.lowercased()
        return k == "connection" || k == "proxy-connection"
    }?.1.lowercased() ?? ""
    let wantsKeepAlive: Bool
    if req.version == "HTTP/1.0" {
        wantsKeepAlive = connVal.contains("keep-alive")
    } else {
        wantsKeepAlive = !connVal.contains("close")
    }

    return UpstreamSessionPool.shared.execute(
        urlReq,
        clientFD: clientFD,
        scrubPairs: scrubPairs,
        keepAlive: wantsKeepAlive
    )
}

// MARK: - Host Control Unix Socket (`0600`)

private func startControlServer(socketPath: String, boundPort: UInt16, state: ProxyState) {
    let dir = (socketPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    chmod(dir, 0o700)
    unlink(socketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < maxLen else { close(fd); return }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, addrLen) == 0
        }
    }
    guard bound, listen(fd, 16) == 0 else { close(fd); return }
    chmod(socketPath, 0o600)

    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            defer { close(clientFD) }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 8192)
            while data.count < 2 * 1024 * 1024 {
                let n = Darwin.read(clientFD, &buf, buf.count)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if n == 0 { break }
                data.append(buf, count: n)
                if buf[0..<n].contains(0x0A) { break }
            }

            guard let cmd = try? JSONDecoder().decode(ProxyConfigPayload.self, from: data) else {
                _ = writeAll(fd: clientFD, data: Data("{\"ok\":false,\"error\":\"invalid_json\"}\n".utf8))
                continue
            }

            switch cmd.op {
            case "configure":
                state.updateConfig(egressMode: cmd.egressMode, allowedDomains: cmd.allowedDomains, secrets: cmd.secrets)
                _ = writeAll(fd: clientFD, data: Data("{\"ok\":true}\n".utf8))
            case "register_session":
                if let sid = cmd.sessionId, let tok = cmd.proxyToken {
                    state.registerSession(
                        sessionId: sid,
                        proxyToken: tok,
                        egressMode: cmd.egressMode,
                        extraAllowedDomains: cmd.extraAllowedDomains,
                        allowedSecretEnvVars: cmd.allowedSecretEnvVars
                    )
                }
                _ = writeAll(fd: clientFD, data: Data("{\"ok\":true}\n".utf8))
            case "unregister_session":
                if let sid = cmd.sessionId {
                    state.unregisterSession(sessionId: sid)
                }
                _ = writeAll(fd: clientFD, data: Data("{\"ok\":true}\n".utf8))
            case "events", "events_since":
                let evs = state.recentEvents(sinceSeq: cmd.sinceSeq ?? 0)
                if let encoded = try? JSONEncoder().encode(evs) {
                    var out = encoded
                    out.append(0x0A)
                    _ = writeAll(fd: clientFD, data: out)
                } else {
                    _ = writeAll(fd: clientFD, data: Data("[]\n".utf8))
                }
            case "clear_events":
                state.clearEvents()
                _ = writeAll(fd: clientFD, data: Data("{\"ok\":true}\n".utf8))
            case "ping":
                _ = writeAll(fd: clientFD, data: Data("{\"ok\":true,\"port\":\(boundPort)}\n".utf8))
            case "shutdown":
                _ = writeAll(fd: clientFD, data: Data("{\"ok\":true}\n".utf8))
                close(clientFD)
                unlink(socketPath)
                exit(0)
            default:
                _ = writeAll(fd: clientFD, data: Data("{\"ok\":false,\"error\":\"unknown_op\"}\n".utf8))
            }
        }
    }
}

// MARK: - Entry Point

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
_ = setsid()

let cliArgs = Array(CommandLine.arguments.dropFirst())
var controlSocketPath = NSHomeDirectory() + "/boo_box/run/proxy-ctl.sock"
var requestedPort: UInt16 = 0

var idx = 0
while idx < cliArgs.count {
    switch cliArgs[idx] {
    case "--control-socket":
        if idx + 1 < cliArgs.count {
            idx += 1
            controlSocketPath = cliArgs[idx]
        }
    case "--port":
        if idx + 1 < cliArgs.count, let p = UInt16(cliArgs[idx + 1]) {
            idx += 1
            requestedPort = p
        }
    default:
        break
    }
    idx += 1
}

let listenFD = socket(AF_INET, SOCK_STREAM, 0)
guard listenFD >= 0 else {
    fputs("boobox-proxy: socket() failed\n", stderr)
    exit(1)
}
var yes: Int32 = 1
setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

var bindAddr = sockaddr_in()
bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
bindAddr.sin_family = sa_family_t(AF_INET)
bindAddr.sin_port = requestedPort.bigEndian
bindAddr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

let bindOK = withUnsafePointer(to: &bindAddr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
    }
}
guard bindOK, listen(listenFD, 128) == 0 else {
    fputs("boobox-proxy: bind/listen on 127.0.0.1:\(requestedPort) failed (errno \(errno))\n", stderr)
    exit(1)
}

var actualAddr = sockaddr_in()
var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &actualAddr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        getsockname(listenFD, sa, &actualLen)
    }
}
let boundPort = UInt16(bigEndian: actualAddr.sin_port)

let state = ProxyState()
startControlServer(socketPath: controlSocketPath, boundPort: boundPort, state: state)

// Announce bound port immediately for parent boo_box.app
print("BOOBOX_PROXY_PORT=\(boundPort)")
fflush(stdout)

let clientQueue = DispatchQueue(label: "dev.boo-box.proxy-clients", qos: .userInitiated, attributes: .concurrent)
while true {
    let clientFD = accept(listenFD, nil, nil)
    if clientFD < 0 {
        if errno == EINTR { continue }
        break
    }
    clientQueue.async {
        handleProxyClient(clientFD: clientFD, state: state)
    }
}
