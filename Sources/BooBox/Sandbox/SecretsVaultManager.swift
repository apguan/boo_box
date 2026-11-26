import Darwin
import Foundation
import Security

struct ProxyAuditEventItem: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(seq ?? 0)-\(timestamp)-\(sessionId)-\(host)-\(decision)" }
    let seq: UInt64?
    let timestamp: Double
    let sessionId: String
    let method: String
    let host: String
    let decision: String
    let reason: String

    var formattedTime: String {
        let d = Date(timeIntervalSince1970: timestamp)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

/// Manages host-only secret storage (macOS Keychain + optional 1Password `op://`) and the
/// `boobox-proxy` sidecar process.
///
/// Real secret bytes live ONLY in macOS Keychain / 1Password / `boobox-proxy` host memory.
/// Sandboxes receive worthless `bbx_ph_...` phantom tokens + proxy URLs.
final class SecretsVaultManager: @unchecked Sendable {
    static let shared = SecretsVaultManager()

    private static let keychainService = "dev.boo-box.secrets"

    private let stateLock = NSLock()
    private var process: Process?
    private var adoptedExternalProxy = false
    private var boundPort: UInt16 = 0
    private var phantomTokensBySecretID: [UUID: String] = [:]
    private var sessionProxyTokens: [String: String] = [:]
    private var onePasswordCache: [String: String] = [:]
    private let controlSocketPath: String

    private init() {
        let realHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let runDir = "\(realHome)/boo_box/run"
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        chmod(runDir, 0o700)
        self.controlSocketPath = "\(runDir)/proxy-ctl.sock"
    }

    var currentProxyPort: UInt16? {
        stateLock.lock()
        let p = boundPort
        let alive = (process?.isRunning == true) || adoptedExternalProxy
        stateLock.unlock()
        return (alive && p > 0) ? p : nil
    }
    var isRunning: Bool {
        currentProxyPort != nil
    }

    var isOnePasswordAvailable: Bool {
        resolveOnePasswordBinary() != nil
    }

    // MARK: - Keychain Vault Operations (Host-Only)

    func saveKeychainSecret(_ value: String, for secretID: UUID) throws {
        let account = secretID.uuidString
        guard let data = value.data(using: .utf8) else {
            throw MacSandboxError.cloneFailed("Invalid UTF-8 secret value")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MacSandboxError.cloneFailed("Keychain save failed (OSStatus \(addStatus))")
            }
        } else if status != errSecSuccess {
            throw MacSandboxError.cloneFailed("Keychain update failed (OSStatus \(status))")
        }
    }

    func readKeychainSecret(for secretID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: secretID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasKeychainSecret(for secretID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: secretID.uuidString,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func deleteKeychainSecret(for secretID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: secretID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func resolveOnePasswordBinary() -> String? {
        for p in ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func resolveOnePasswordValue(_ ref: String) -> String? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("op://") else { return nil }

        stateLock.lock()
        if let cached = onePasswordCache[trimmed] {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        guard let opBin = resolveOnePasswordBinary() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: opBin)
        proc.arguments = ["read", "--no-newline", trimmed]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let val = String(data: data, encoding: .utf8), !val.isEmpty else {
                return nil
            }
            stateLock.lock()
            onePasswordCache[trimmed] = val
            stateLock.unlock()
            return val
        } catch {
            return nil
        }
    }

    func clearOnePasswordCache() {
        stateLock.lock()
        onePasswordCache.removeAll()
        stateLock.unlock()
    }

    // MARK: - Sidecar Lifecycle (`boobox-proxy`)

    private func resolveProxyBinaryURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("boobox-proxy"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/release/boobox-proxy"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/debug/boobox-proxy"),
        ]
        for case let url? in candidates {
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    @discardableResult
    func startIfNeeded() -> UInt16? {
        let cfg = BooBoxConfigManager.currentSnapshot().secretsNetwork
        guard cfg.proxyEnabled else {
            stop()
            return nil
        }
        if let existing = currentProxyPort {
            return existing
        }

        // Re-adopt an already-running `boobox-proxy` (kept alive for detached `booboxd` panes across restarts/updates)
        if let adoptedPort = pingExistingProxy() {
            stateLock.lock()
            self.adoptedExternalProxy = true
            self.boundPort = adoptedPort
            stateLock.unlock()
            syncPolicyToProxy(blocking: true)
            return adoptedPort
        }

        guard let binURL = resolveProxyBinaryURL() else {
            return nil
        }
        let proc = Process()
        proc.executableURL = binURL
        proc.arguments = ["--control-socket", controlSocketPath, "--port", "0"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return nil
        }

        // Read the first line (`BOOBOX_PROXY_PORT=<port>`) with a short bounded wait
        let readFD = outPipe.fileHandleForReading.fileDescriptor
        var lineData = Data()
        var byte: UInt8 = 0
        let deadline = CFAbsoluteTimeGetCurrent() + 2.0
        var fds = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
        while CFAbsoluteTimeGetCurrent() < deadline && lineData.count < 128 {
            let ready = poll(&fds, 1, 100)
            if ready > 0 {
                let n = Darwin.read(readFD, &byte, 1)
                if n <= 0 { break }
                if byte == 0x0A { break }
                lineData.append(byte)
            } else if !proc.isRunning {
                break
            }
        }

        guard let line = String(data: lineData, encoding: .utf8),
              line.hasPrefix("BOOBOX_PROXY_PORT="),
              let port = UInt16(line.dropFirst("BOOBOX_PROXY_PORT=".count).trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else {
            proc.terminate()
            return nil
        }

        // Drain stdout in background so child never blocks on pipe buffer
        DispatchQueue.global(qos: .background).async {
            _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        }

        stateLock.lock()
        self.process?.terminate()
        self.process = proc
        self.adoptedExternalProxy = false
        self.boundPort = port
        stateLock.unlock()

        syncPolicyToProxy(blocking: true)
        return port
    }

    private func pingExistingProxy() -> UInt16? {
        guard let req = try? JSONSerialization.data(withJSONObject: ["op": "ping"]),
              let resp = sendControlCommand(req),
              let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
              (obj["ok"] as? Bool) == true,
              let portNum = obj["port"] as? Int,
              portNum > 0 && portNum <= Int(UInt16.max) else {
            return nil
        }
        return UInt16(portNum)
    }

    func stop() {
        stateLock.lock()
        let proc = self.process
        let wasAdopted = self.adoptedExternalProxy
        self.process = nil
        self.adoptedExternalProxy = false
        self.boundPort = 0
        stateLock.unlock()

        if let proc, proc.isRunning {
            proc.terminate()
        } else if wasAdopted, let req = try? JSONSerialization.data(withJSONObject: ["op": "shutdown"]) {
            _ = sendControlCommand(req)
        }
        unlink(controlSocketPath)
    }

    // MARK: - Policy & Secret Sync to Sidecar

    private func phantomToken(for secretID: UUID) -> String {
        stateLock.lock()
        if let existing = phantomTokensBySecretID[secretID] {
            stateLock.unlock()
            return existing
        }
        let token = "bbx_ph_" + Self.randomHex(bytes: 16)
        phantomTokensBySecretID[secretID] = token
        stateLock.unlock()
        return token
    }

    private func sessionProxyToken(for sessionShortID: String) -> String {
        stateLock.lock()
        if let existing = sessionProxyTokens[sessionShortID] {
            stateLock.unlock()
            return existing
        }
        let tok = Self.randomHex(bytes: 12)
        sessionProxyTokens[sessionShortID] = tok
        stateLock.unlock()
        return tok
    }

    private static func randomHex(bytes count: Int) -> String {
        var raw = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &raw)
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    func syncPolicyToProxy(blocking: Bool = false) {
        let cfg = BooBoxConfigManager.currentSnapshot().secretsNetwork
        if !cfg.proxyEnabled {
            stop()
            return
        }
        let work: @Sendable () -> Void = { [self] in
            if currentProxyPort == nil {
                _ = startIfNeeded()
                return
            }

            var secretSpecs: [[String: Any]] = []
            for entry in cfg.secrets where entry.enabled {
                let envName = entry.envVar.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !envName.isEmpty, !entry.allowedHosts.isEmpty else { continue }
                let realVal: String?
                switch entry.source {
                case .keychain:
                    realVal = readKeychainSecret(for: entry.id)
                case .onePassword:
                    realVal = resolveOnePasswordValue(entry.onePasswordRef)
                }
                guard let realVal, !realVal.isEmpty else { continue }
                let phantom = phantomToken(for: entry.id)
                secretSpecs.append([
                    "envVar": envName,
                    "phantomToken": phantom,
                    "realValue": realVal,
                    "allowedHosts": entry.allowedHosts,
                ])
            }

            let payload: [String: Any] = [
                "op": "configure",
                "egressMode": cfg.egressMode.rawValue,
                "allowedDomains": cfg.effectiveAllowlistDomains,
                "secrets": secretSpecs,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                _ = sendControlCommand(data)
            }
        }

        if blocking {
            work()
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    /// Pushes per-session network/secret overrides to `boobox-proxy` immediately (works on live sessions!).
    func updateSessionPolicy(
        for sessionShortID: String,
        overrides: SandboxOverrideConfig,
        blocking: Bool = false
    ) {
        let globalCfg = BooBoxConfigManager.currentSnapshot()
        guard globalCfg.secretsNetwork.proxyEnabled, startIfNeeded() != nil else { return }
        let pTok = sessionProxyToken(for: sessionShortID)
        var payload: [String: Any] = [
            "op": "register_session",
            "sessionId": sessionShortID,
            "proxyToken": pTok,
        ]
        if let mode = overrides.egressMode {
            payload["egressMode"] = mode.rawValue
        }
        if !overrides.extraAllowedDomains.isEmpty {
            payload["extraAllowedDomains"] = overrides.extraAllowedDomains
        }
        switch overrides.secretAccessMode {
        case .inheritGlobal:
            break
        case .none:
            payload["allowedSecretEnvVars"] = [String]()
        case .custom:
            let idSet = Set(overrides.allowedSecretIDs)
            let envNames = globalCfg.secretsNetwork.secrets
                .filter { $0.enabled && idSet.contains($0.id) }
                .map { $0.envVar.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            payload["allowedSecretEnvVars"] = envNames
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        if blocking {
            _ = sendControlCommand(data)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                _ = sendControlCommand(data)
            }
        }
    }

    /// Computes sandbox-safe environment variables (`HTTP_PROXY`, `HTTPS_PROXY`, phantom tokens,
    /// and Base-URL proxy endpoints) respecting per-sandbox overrides. Real secret values NEVER enter sandboxes.
    func sandboxEnvironment(
        for sessionShortID: String,
        overrides: SandboxOverrideConfig = .default
    ) -> (env: [String: String], proxyPort: UInt16?) {
        let effectiveCfg = BooBoxConfigManager.currentSnapshot().applying(overrides: overrides)
        let cfg = effectiveCfg.secretsNetwork
        guard cfg.proxyEnabled else { return ([:], nil) }
        guard let port = startIfNeeded() else { return ([:], nil) }

        updateSessionPolicy(for: sessionShortID, overrides: overrides, blocking: true)

        let pTok = sessionProxyToken(for: sessionShortID)
        var env: [String: String] = [:]
        let activeSecrets = cfg.secrets.filter { entry in
            guard entry.enabled, !entry.envVar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            switch entry.source {
            case .keychain: return hasKeychainSecret(for: entry.id)
            case .onePassword: return entry.onePasswordRef.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("op://")
            }
        }

        let proxyURL = "http://\(sessionShortID):\(pTok)@127.0.0.1:\(port)"
        if cfg.egressMode != .full || cfg.strictProxyRouting || !activeSecrets.isEmpty {
            env["HTTP_PROXY"] = proxyURL
            env["http_proxy"] = proxyURL
            env["HTTPS_PROXY"] = proxyURL
            env["https_proxy"] = proxyURL
            env["NO_PROXY"] = "localhost,127.0.0.1,::1"
            env["no_proxy"] = "localhost,127.0.0.1,::1"
            env["BOOBOX_EGRESS_MODE"] = cfg.egressMode.rawValue
        }

        for entry in activeSecrets {
            let envName = entry.envVar.trimmingCharacters(in: .whitespacesAndNewlines)
            env[envName] = phantomToken(for: entry.id)

            let baseVar = entry.baseURLVar.trimmingCharacters(in: .whitespacesAndNewlines)
            if !baseVar.isEmpty, let primaryHost = entry.primaryHost {
                let rawPrefix = entry.baseURLPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanPrefix = rawPrefix.isEmpty ? "" : (rawPrefix.hasPrefix("/") ? rawPrefix : "/\(rawPrefix)")
                let routePrefix = (primaryHost == "127.0.0.1" || primaryHost == "localhost") ? "upstream-http" : "upstream"
                env[baseVar] = "http://127.0.0.1:\(port)/s/\(sessionShortID)/\(routePrefix)/\(primaryHost)\(cleanPrefix)"
            }
        }

        return (env, port)
    }
    func unregisterSession(_ sessionShortID: String) {
        stateLock.lock()
        sessionProxyTokens.removeValue(forKey: sessionShortID)
        stateLock.unlock()
        guard currentProxyPort != nil else { return }
        if let data = try? JSONSerialization.data(withJSONObject: ["op": "unregister_session", "sessionId": sessionShortID]) {
            DispatchQueue.global(qos: .utility).async { [self] in
                _ = sendControlCommand(data)
            }
        }
    }

    // MARK: - Live Audit Events

    func fetchAuditEvents(completion: @escaping @MainActor @Sendable ([ProxyAuditEventItem]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard currentProxyPort != nil,
                  let req = try? JSONSerialization.data(withJSONObject: ["op": "events"]),
                  let resp = sendControlCommand(req),
                  let parsed = try? JSONDecoder().decode([ProxyAuditEventItem].self, from: resp) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            DispatchQueue.main.async { completion(parsed.reversed()) }
        }
    }

    func fetchAuditEventsSince(_ sinceSeq: UInt64, completion: @escaping @MainActor @Sendable ([ProxyAuditEventItem]) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard currentProxyPort != nil,
                  let req = try? JSONSerialization.data(withJSONObject: ["op": "events_since", "sinceSeq": sinceSeq]),
                  let resp = sendControlCommand(req),
                  let parsed = try? JSONDecoder().decode([ProxyAuditEventItem].self, from: resp) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            DispatchQueue.main.async { completion(parsed) }
        }
    }

    func clearAuditEvents(completion: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if currentProxyPort != nil,
               let req = try? JSONSerialization.data(withJSONObject: ["op": "clear_events"]) {
                _ = sendControlCommand(req)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Control Unix Socket Client

    private func sendControlCommand(_ json: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

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
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, addrLen) == 0
            }
        }
        guard ok else { return nil }

        var msg = json
        if msg.last != 0x0A { msg.append(0x0A) }
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
            if n <= 0 { break }
            reply.append(buf, count: n)
        }
        return reply
    }
}
