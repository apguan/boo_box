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
}

struct SessionPolicy: Sendable {
    let sessionId: String
    let egressMode: String?
    let extraAllowedDomains: [String]
    let allowedSecretEnvVars: Set<String>?
}
struct ProxyAuditEvent: Codable, Sendable {
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
        let ev = ProxyAuditEvent(
            timestamp: Date().timeIntervalSince1970,
            sessionId: sessionId,
            method: method,
            host: host,
            decision: decision,
            reason: reason
        )
        lock.lock()
        events.append(ev)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lock.unlock()
    }

    func recentEvents() -> [ProxyAuditEvent] {
        lock.lock()
        let copy = events
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

private func readHTTPRequest(fd: Int32) -> (method: String, target: String, headers: [(String, String)], body: Data)? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    let headerSep = Data("\r\n\r\n".utf8)
    var headerEndRange: Range<Data.Index>? = nil

    while buffer.count < 256 * 1024 {
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

    var body = Data(buffer[sep.upperBound...])
    if contentLength > 0 {
        while body.count < contentLength {
            let toRead = min(chunk.count, contentLength - body.count)
            let n = Darwin.read(fd, &chunk, toRead)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            body.append(chunk, count: n)
        }
        if body.count > contentLength {
            body = body.prefix(contentLength)
        }
    } else if isChunked {
        body = readAndDecodeChunkedBody(fd: fd, initial: body)
    }

    return (method, target, headers, body)
}

private func readAndDecodeChunkedBody(fd: Int32, initial: Data) -> Data {
    var raw = initial
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 8192)
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
        if size == 0 { break }
        while raw.count < size + 2 {
            if !fillMore() { return out }
        }
        out.append(raw.prefix(size))
        raw.removeFirst(min(raw.count, size + 2))
    }
    return out
}

// MARK: - Streaming Upstream Bridge (Supports SSE / Chunked LLM Streams)

private final class StreamingUpstreamBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let clientFD: Int32
    private let scrubPairs: [(real: String, phantom: String)]
    private let doneSemaphore = DispatchSemaphore(value: 0)
    private var sentHeaders = false
    private var useChunked = true
    private var writeFailed = false

    init(clientFD: Int32, scrubPairs: [(real: String, phantom: String)]) {
        self.clientFD = clientFD
        self.scrubPairs = scrubPairs
    }

    func execute(_ request: URLRequest) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:] // Never recurse through system HTTP_PROXY
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 1800

        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        doneSemaphore.wait()
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
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
            for pair in scrubPairs where !pair.real.isEmpty {
                if val.contains(pair.real) {
                    val = val.replacingOccurrences(of: pair.real, with: pair.phantom)
                }
            }
            head += "\(name): \(val)\r\n"
        }
        // Always stream chunked back to client so SSE works with zero buffering and clean Content-Encoding decode
        useChunked = true
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        sentHeaders = true
        if !writeAll(fd: clientFD, data: Data(head.utf8)) {
            writeFailed = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !writeFailed, !data.isEmpty else { return }
        var payload = data
        if !scrubPairs.isEmpty, var text = String(data: data, encoding: .utf8) {
            var changed = false
            for pair in scrubPairs where !pair.real.isEmpty {
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
        var frame = Data(prefix.utf8)
        frame.append(payload)
        frame.append(contentsOf: [0x0D, 0x0A])
        if !writeAll(fd: clientFD, data: frame) {
            writeFailed = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !sentHeaders {
            let msg = error?.localizedDescription ?? "Upstream connection failed"
            sendHTTPError(fd: clientFD, status: 502, title: "Bad Gateway", reasonHeader: "upstream-error", body: "boo_box proxy: \(msg)\n")
        } else if useChunked && !writeFailed {
            _ = writeAll(fd: clientFD, data: Data("0\r\n\r\n".utf8))
        }
        doneSemaphore.signal()
    }
}

// MARK: - TCP Tunnel for HTTPS CONNECT

private func openUpstreamTCP(host: String, port: Int) -> Int32 {
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
            if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                return fd
            }
            close(fd)
        }
        cur = info.pointee.ai_next
    }
    return -1
}

private func relayBidirectional(clientFD: Int32, upstreamFD: Int32) {
    let group = DispatchGroup()
    let relayQueue = DispatchQueue.global(qos: .userInitiated)

    @Sendable func pump(from src: Int32, to dst: Int32) {
        var buf = [UInt8](repeating: 0, count: 32768)
        while true {
            let n = Darwin.read(src, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            var off = 0
            while off < n {
                let w = Darwin.write(dst, &buf[off], n - off)
                if w < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if w == 0 { return }
                off += w
            }
        }
        shutdown(dst, SHUT_WR)
    }

    group.enter()
    relayQueue.async {
        pump(from: clientFD, to: upstreamFD)
        group.leave()
    }
    group.enter()
    relayQueue.async {
        pump(from: upstreamFD, to: clientFD)
        group.leave()
    }
    group.wait()
}

// MARK: - Core Request Handler

private func handleProxyClient(clientFD: Int32, state: ProxyState) {
    defer { close(clientFD) }
    guard let req = readHTTPRequest(fd: clientFD) else { return }

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
            return
        }
        if snap.egressMode == "offline" {
            state.record(sessionId: sessionId, method: "CONNECT", host: normHost, decision: "blocked", reason: "Offline mode")
            sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "offline", body: "boo_box proxy: sandbox network is Offline\n")
            return
        }
        if snap.egressMode == "allowlist" && !hostMatches(normHost, patterns: snap.allowedDomains) {
            state.record(sessionId: sessionId, method: "CONNECT", host: normHost, decision: "blocked", reason: "Host not in Dev Allowlist")
            sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "domain-blocked", body: "boo_box proxy: host '\(normHost)' is not in Dev Allowlist\n")
            return
        }

        let upFD = openUpstreamTCP(host: host, port: port)
        guard upFD >= 0 else {
            sendHTTPError(fd: clientFD, status: 502, title: "Bad Gateway", reasonHeader: "connect-failed", body: "boo_box proxy: failed to connect to \(host):\(port)\n")
            return
        }
        defer { close(upFD) }
        state.record(sessionId: sessionId, method: "CONNECT", host: normHost, decision: "allowed", reason: snap.egressMode)
        guard writeAll(fd: clientFD, data: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else { return }
        relayBidirectional(clientFD: clientFD, upstreamFD: upFD)
        return
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
            return
        }
        targetHostPort = String(hostSeg)
        let norm = normalizeHost(targetHostPort)
        // `/upstream-http/` is permitted ONLY for loopback test endpoints; all remote hosts use HTTPS
        if isLocalHTTP && norm != "127.0.0.1" && norm != "localhost" {
            sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "https-required", body: "boo_box proxy: /upstream-http/ is restricted to localhost\n")
            return
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
        return
    }
    let normHost = normalizeHost(targetHostPort)

    if isBlockedMetadataHost(normHost) {
        state.record(sessionId: sessionId, method: req.method, host: normHost, decision: "blocked", reason: "Cloud metadata IP blocked")
        sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "metadata-blocked", body: "boo_box proxy: metadata endpoint blocked\n")
        return
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
                return
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
        return
    }
    if snap.egressMode == "allowlist" && !hostMatches(normHost, patterns: snap.allowedDomains) {
        state.record(sessionId: sessionId, method: req.method, host: normHost, decision: "blocked", reason: "Host not in Dev Allowlist")
        sendHTTPError(fd: clientFD, status: 403, title: "Forbidden", reasonHeader: "domain-blocked", body: "boo_box proxy: host '\(normHost)' is not in Dev Allowlist\n")
        return
    }

    guard let upstreamURL = URL(string: "\(upstreamScheme)://\(targetHostPort)\(mutatedPath)") else {
        sendHTTPError(fd: clientFD, status: 400, title: "Bad Request", reasonHeader: "invalid-url", body: "boo_box proxy: invalid upstream URL\n")
        return
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

    let bridge = StreamingUpstreamBridge(clientFD: clientFD, scrubPairs: scrubPairs)
    bridge.execute(urlReq)
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
            case "events":
                let evs = state.recentEvents()
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
            default:
                _ = writeAll(fd: clientFD, data: Data("{\"ok\":false,\"error\":\"unknown_op\"}\n".utf8))
            }
        }
    }
}

// MARK: - Entry Point

signal(SIGPIPE, SIG_IGN)

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
