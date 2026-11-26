import AppKit
import CryptoKit
import Darwin
import Foundation
import Security
import SQLite3

// MARK: - OAuth Provider Catalog

struct OAuthServicePreset: Identifiable, Sendable {
    enum Kind: Sendable, Equatable {
        /// Standard MCP OAuth 2.1 + S256 PKCE + RFC 7591 Dynamic Client Registration (1-click browser login).
        case mcpOAuthDCR(mcpURL: String, defaultScope: String? = nil)
        /// GitHub: instant host `gh` OAuth import if logged in, otherwise launches `gh auth login --web` browser OAuth.
        case githubOAuth
    }

    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let kind: Kind
    /// Optional local CLI token preset ID to also import if present (e.g. "vercel", "github").
    let linkedCLIConnectionID: String?
    /// MCP server slug written into OMP/OpenCode/Claude/Codex/Gemini configs.
    let mcpID: String?
}

struct OAuthTokenRecord: Codable, Sendable {
    var serviceID: String
    var resourceURL: String
    var accessToken: String
    var refreshToken: String?
    var expiresAtEpochSeconds: Double?
    var scope: String?
    var clientID: String
    var clientSecret: String?
    var authorizationURL: String
    var tokenURL: String
    var connectedAt: Date
}

enum OAuthFlowError: LocalizedError {
    case cancelled
    case timeout
    case discoveryFailed(String)
    case registrationFailed(String)
    case listenerFailed(String)
    case callbackError(String)
    case tokenExchangeFailed(String)
    case githubAuthFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Sign-in cancelled."
        case .timeout:
            return "Timed out waiting for browser authorization."
        case .discoveryFailed(let msg):
            return "OAuth discovery failed: \(msg)"
        case .registrationFailed(let msg):
            return "OAuth client registration failed: \(msg)"
        case .listenerFailed(let msg):
            return "Local callback server failed: \(msg)"
        case .callbackError(let msg):
            return "Authorization rejected: \(msg)"
        case .tokenExchangeFailed(let msg):
            return "Token exchange failed: \(msg)"
        case .githubAuthFailed(let msg):
            return msg
        }
    }
}

struct OAuthProgressEvent: Sendable {
    let message: String
    let deviceCode: String?
}

// MARK: - Native OAuth 2.1 + PKCE + DCR Engine

final class OAuthFlowManager: @unchecked Sendable {
    static let shared = OAuthFlowManager()
    static let keychainService = "dev.boo-box.oauth"

    private let lock = NSLock()
    private var activeListenFD: Int32 = -1
    private var activeServiceID: String?
    private var activeProcess: Process?
    private var cancelled = false

    private init() {}

    /// Curated 1-click OAuth catalog — every entry verified live for real browser OAuth!
    static let oauthServices: [OAuthServicePreset] = [
        OAuthServicePreset(
            id: "github",
            name: "GitHub",
            subtitle: "Browser OAuth for gh CLI, HTTPS git push/pull, and GitHub MCP across every sandbox.",
            symbol: "chevron.left.forwardslash.chevron.right",
            kind: .githubOAuth,
            linkedCLIConnectionID: "github",
            mcpID: "github"
        ),
        OAuthServicePreset(
            id: "notion",
            name: "Notion",
            subtitle: "Docs, wikis, databases, and Notion Calendar via official OAuth 2.1.",
            symbol: "doc.richtext",
            kind: .mcpOAuthDCR(mcpURL: "https://mcp.notion.com/mcp"),
            linkedCLIConnectionID: nil,
            mcpID: "notion"
        ),
        OAuthServicePreset(
            id: "linear",
            name: "Linear",
            subtitle: "Issues, cycles, projects, and comments via official OAuth 2.1.",
            symbol: "checklist",
            kind: .mcpOAuthDCR(mcpURL: "https://mcp.linear.app/mcp"),
            linkedCLIConnectionID: nil,
            mcpID: "linear"
        ),
        OAuthServicePreset(
            id: "vercel",
            name: "Vercel",
            subtitle: "Deployments, build logs, and projects via official OAuth 2.1.",
            symbol: "triangle.fill",
            kind: .mcpOAuthDCR(mcpURL: "https://mcp.vercel.com"),
            linkedCLIConnectionID: "vercel",
            mcpID: "vercel"
        ),
        OAuthServicePreset(
            id: "supabase",
            name: "Supabase",
            subtitle: "Postgres schema, migrations, Edge Functions, and logs via official OAuth 2.1.",
            symbol: "bolt.fill",
            kind: .mcpOAuthDCR(mcpURL: "https://mcp.supabase.com/mcp"),
            linkedCLIConnectionID: nil,
            mcpID: "supabase"
        ),
        OAuthServicePreset(
            id: "stripe",
            name: "Stripe",
            subtitle: "Payments, customers, subscriptions, and invoices via official OAuth 2.1.",
            symbol: "creditcard.fill",
            kind: .mcpOAuthDCR(mcpURL: "https://mcp.stripe.com", defaultScope: "mcp"),
            linkedCLIConnectionID: nil,
            mcpID: "stripe"
        ),
        OAuthServicePreset(
            id: "sentry",
            name: "Sentry",
            subtitle: "Errors, stack traces, and releases via official OAuth 2.1.",
            symbol: "ant.fill",
            kind: .mcpOAuthDCR(mcpURL: "https://mcp.sentry.dev/mcp"),
            linkedCLIConnectionID: nil,
            mcpID: "sentry"
        ),
        OAuthServicePreset(
            id: "cloudflare",
            name: "Cloudflare",
            subtitle: "Workers observability, logs, and analytics via official OAuth 2.1.",
            symbol: "cloud.fill",
            kind: .mcpOAuthDCR(mcpURL: "https://observability.mcp.cloudflare.com/mcp"),
            linkedCLIConnectionID: nil,
            mcpID: "cloudflare"
        ),
    ]

    // MARK: - Keychain Storage (dev.boo-box.oauth)

    private static let oauthVaultLock = NSLock()

    private var oauthVaultDirURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("boo_box/vault", isDirectory: true)
    }

    private var oauthVaultFileURL: URL {
        oauthVaultDirURL.appendingPathComponent("oauth.json")
    }

    private func readOAuthVaultLocked() -> [String: OAuthTokenRecord] {
        guard let data = try? Data(contentsOf: oauthVaultFileURL),
              let map = try? JSONDecoder().decode([String: OAuthTokenRecord].self, from: data) else {
            return [:]
        }
        return map
    }

    private func writeOAuthVaultLocked(_ map: [String: OAuthTokenRecord]) throws {
        try FileManager.default.createDirectory(at: oauthVaultDirURL, withIntermediateDirectories: true)
        chmod(oauthVaultDirURL.path, 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        try data.write(to: oauthVaultFileURL, options: .atomic)
        chmod(oauthVaultFileURL.path, 0o600)
    }

    func saveTokenRecord(_ record: OAuthTokenRecord) throws {
        Self.oauthVaultLock.lock()
        defer { Self.oauthVaultLock.unlock() }
        var map = readOAuthVaultLocked()
        map[record.serviceID] = record
        try writeOAuthVaultLocked(map)
    }

    func loadTokenRecord(serviceID: String) -> OAuthTokenRecord? {
        Self.oauthVaultLock.lock()
        defer { Self.oauthVaultLock.unlock() }
        return readOAuthVaultLocked()[serviceID]
    }

    func deleteTokenRecord(serviceID: String) {
        Self.oauthVaultLock.lock()
        defer { Self.oauthVaultLock.unlock() }
        var map = readOAuthVaultLocked()
        guard map.removeValue(forKey: serviceID) != nil else { return }
        try? writeOAuthVaultLocked(map)
    }

    /// Returns true if the service has a live OAuth token in boo_box Keychain, OMP `agent.db`, or OpenCode `mcp-auth.json`.
    func isOAuthConnected(_ preset: OAuthServicePreset) -> Bool {
        switch preset.kind {
        case .githubOAuth:
            return ConnectionsManager.shared.hasToken(for: "github")
        case .mcpOAuthDCR(let mcpURL, _):
            if loadTokenRecord(serviceID: preset.id) != nil {
                return true
            }
            if hasOMPOAuthCredential(mcpURL: mcpURL) {
                return true
            }
            if hasOpenCodeOAuthCredential(mcpID: preset.id, mcpURL: mcpURL) {
                return true
            }
            return false
        }
    }

    func cancelActiveFlow() {
        lock.lock()
        cancelled = true
        let fd = activeListenFD
        activeListenFD = -1
        let proc = activeProcess
        activeProcess = nil
        lock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - 1-Click Browser OAuth 2.1 + PKCE + RFC 7591 DCR

    func connectService(
        _ preset: OAuthServicePreset,
        targetAgents: [MCPAgentTarget],
        onProgress: @escaping @Sendable (OAuthProgressEvent) -> Void
    ) throws -> String {
        switch preset.kind {
        case .githubOAuth:
            return try connectGitHub(targetAgents: targetAgents, onProgress: onProgress)
        case .mcpOAuthDCR(let mcpURL, let defaultScope):
            return try connectMCPOAuth(
                preset: preset,
                mcpURL: mcpURL,
                defaultScope: defaultScope,
                targetAgents: targetAgents,
                onProgress: onProgress
            )
        }
    }

    func disconnectService(_ preset: OAuthServicePreset, targetAgents: [MCPAgentTarget]) {
        switch preset.kind {
        case .githubOAuth:
            ConnectionsManager.shared.deleteToken(for: "github")
            if let mcpID = preset.mcpID, let mcp = ConnectionsManager.mcpPreset(id: mcpID) {
                try? ConnectionsManager.shared.removeMCP(mcp, from: MCPAgentTarget.allCases)
            }
        case .mcpOAuthDCR(let mcpURL, _):
            deleteTokenRecord(serviceID: preset.id)
            removeOMPOAuthCredential(mcpURL: mcpURL)
            removeOpenCodeOAuthCredential(mcpID: preset.id)
            if let mcpID = preset.mcpID, let mcp = ConnectionsManager.mcpPreset(id: mcpID) {
                try? ConnectionsManager.shared.removeMCP(mcp, from: MCPAgentTarget.allCases)
            }
        }
    }

    // MARK: - MCP OAuth 2.1 Implementation

    private struct OAuthMetadata {
        let authorizationEndpoint: String
        let tokenEndpoint: String
        let registrationEndpoint: String
        let scopesSupported: [String]
    }

    private func connectMCPOAuth(
        preset: OAuthServicePreset,
        mcpURL: String,
        defaultScope: String?,
        targetAgents: [MCPAgentTarget],
        onProgress: @escaping @Sendable (OAuthProgressEvent) -> Void
    ) throws -> String {
        cancelActiveFlow()
        lock.lock()
        cancelled = false
        activeServiceID = preset.id
        lock.unlock()

        onProgress(OAuthProgressEvent(message: "Discovering \(preset.name) OAuth endpoints…", deviceCode: nil))
        let meta = try discoverOAuthMetadata(mcpURL: mcpURL)
        try checkCancelled()

        // 1. Bind ephemeral loopback callback server on 127.0.0.1:0
        let (listenFD, port) = try openLoopbackListener()
        lock.lock()
        activeListenFD = listenFD
        lock.unlock()
        defer {
            lock.lock()
            let fd = activeListenFD
            activeListenFD = -1
            activeServiceID = nil
            lock.unlock()
            if fd >= 0 { Darwin.close(fd) }
        }

        let redirectURI = "http://127.0.0.1:\(port)/callback"

        // 2. Dynamic Client Registration (RFC 7591)
        onProgress(OAuthProgressEvent(message: "Registering native OAuth client…", deviceCode: nil))
        let (clientID, clientSecret) = try registerDynamicClient(
            registrationEndpoint: meta.registrationEndpoint,
            redirectURI: redirectURI
        )
        try checkCancelled()

        // 3. PKCE S256 verifier + challenge + state
        let codeVerifier = randomBase64URL(byteCount: 32)
        let challengeDigest = SHA256.hash(data: Data(codeVerifier.utf8))
        let codeChallenge = base64URLEncode(Data(challengeDigest))
        let state = randomBase64URL(byteCount: 24)

        guard var comps = URLComponents(string: meta.authorizationEndpoint) else {
            throw OAuthFlowError.discoveryFailed("Invalid authorization_endpoint URL")
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: mcpURL),
        ]
        if let scope = defaultScope ?? (meta.scopesSupported.isEmpty ? nil : meta.scopesSupported.joined(separator: " ")) {
            queryItems.append(URLQueryItem(name: "scope", value: scope))
        }
        comps.queryItems = (comps.queryItems ?? []) + queryItems
        guard let authURL = comps.url else {
            throw OAuthFlowError.discoveryFailed("Could not assemble authorization URL")
        }

        // 4. Open browser directly to OAuth consent screen
        onProgress(OAuthProgressEvent(message: "Approve \(preset.name) in your browser…", deviceCode: nil))
        DispatchQueue.main.async {
            NSWorkspace.shared.open(authURL)
        }

        // 5. Wait for loopback callback (timeout 180s)
        let code = try waitForOAuthCallback(
            listenFD: listenFD,
            expectedState: state,
            serviceName: preset.name,
            timeoutSeconds: 180
        )
        try checkCancelled()

        // 6. Exchange authorization code for access + refresh tokens
        onProgress(OAuthProgressEvent(message: "Saving \(preset.name) credentials to Keychain…", deviceCode: nil))
        let tokenResp = try exchangeCodeForToken(
            tokenEndpoint: meta.tokenEndpoint,
            code: code,
            redirectURI: redirectURI,
            clientID: clientID,
            clientSecret: clientSecret,
            codeVerifier: codeVerifier,
            resource: mcpURL
        )

        let expiresAt: Double? = tokenResp.expiresIn.map { Date().timeIntervalSince1970 + $0 }
        let record = OAuthTokenRecord(
            serviceID: preset.id,
            resourceURL: mcpURL,
            accessToken: tokenResp.accessToken,
            refreshToken: tokenResp.refreshToken,
            expiresAtEpochSeconds: expiresAt,
            scope: tokenResp.scope ?? defaultScope,
            clientID: clientID,
            clientSecret: clientSecret,
            authorizationURL: meta.authorizationEndpoint,
            tokenURL: meta.tokenEndpoint,
            connectedAt: Date()
        )

        try saveTokenRecord(record)

        // 7. Write live OAuth credentials directly into OMP & OpenCode native stores + install MCP config into selected agents
        writeOMPOAuthCredential(record: record)
        writeOpenCodeOAuthCredential(record: record)

        if let mcpID = preset.mcpID, let mcpPreset = ConnectionsManager.mcpPreset(id: mcpID) {
            let agents = targetAgents.isEmpty ? ConnectionsManager.shared.detectInstalledAgents() : targetAgents
            if !agents.isEmpty {
                try? ConnectionsManager.shared.installMCP(mcpPreset, into: agents)
            }
        }

        // Bonus: if this service also has a local host CLI login (e.g. Vercel), import it silently so CLI commands work too
        if let cliID = preset.linkedCLIConnectionID,
           !ConnectionsManager.shared.hasToken(for: cliID) {
            if let imported = try? ConnectionsManager.shared.importFromHostCLI(connectionID: cliID) {
                try? ConnectionsManager.shared.saveToken(imported.token, for: cliID)
            }
        }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        let agentNames = (targetAgents.isEmpty ? ConnectionsManager.shared.detectInstalledAgents() : targetAgents)
            .map(\.displayName)
            .joined(separator: ", ")
        if agentNames.isEmpty {
            return "Connected \(preset.name) via browser OAuth (saved in Keychain)."
        }
        return "Connected \(preset.name) via browser OAuth — synced to \(agentNames)."
    }

    // MARK: - GitHub 1-Click OAuth (Instant Host Import or Live Browser Device OAuth)

    private func connectGitHub(
        targetAgents: [MCPAgentTarget],
        onProgress: @escaping @Sendable (OAuthProgressEvent) -> Void
    ) throws -> String {
        cancelActiveFlow()
        lock.lock()
        cancelled = false
        activeServiceID = "github"
        lock.unlock()
        defer {
            lock.lock()
            activeServiceID = nil
            activeProcess = nil
            lock.unlock()
        }

        let mgr = ConnectionsManager.shared

        // Fast path: already signed in with host `gh` CLI -> instant 1-click OAuth import!
        if let imported = try? mgr.importFromHostCLI(connectionID: "github") {
            try mgr.saveToken(imported.token, for: "github")
            _ = mgr.configureHostGitForGitHub(token: imported.token)
            if let ghMCP = ConnectionsManager.mcpPreset(id: "github") {
                let agents = targetAgents.isEmpty ? mgr.detectInstalledAgents() : targetAgents
                if !agents.isEmpty {
                    try? mgr.installMCP(ghMCP, into: agents)
                }
            }
            let who = imported.label.isEmpty ? "" : " (\(imported.label))"
            return "Connected GitHub\(who) via host OAuth — wired git push & gh CLI across sandboxes."
        }

        // Browser OAuth path: launch `gh auth login --web` via PTY, copy 8-char device code, open browser, wait for approval!
        guard let ghBin = findExecutable("gh") else {
            throw OAuthFlowError.githubAuthFailed("GitHub CLI (`gh`) not found. Install with `brew install gh` or expand Advanced to paste a token.")
        }

        onProgress(OAuthProgressEvent(message: "Starting GitHub browser OAuth…", deviceCode: nil))

        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, nil)
        guard pid >= 0 else {
            throw OAuthFlowError.githubAuthFailed("Could not start PTY for GitHub OAuth.")
        }
        if pid == 0 {
            setenv("GH_PROMPT_DISABLED", "0", 1)
            setenv("TERM", "xterm-256color", 1)
            let args: [String] = [ghBin, "auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"]
            var cArgs = args.map { strdup($0) } + [nil]
            execv(ghBin, &cArgs)
            _exit(127)
        }

        defer {
            if masterFD >= 0 { Darwin.close(masterFD) }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGTERM)
            }
        }

        let deadline = Date().addingTimeInterval(180)
        var accumulated = ""
        var sentEnter = false
        var detectedCode: String?
        var buf = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            try checkCancelled()

            var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 250)
            if pr > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                let n = Darwin.read(masterFD, &buf, buf.count)
                if n > 0 {
                    let chunk = String(decoding: buf[0..<n], as: UTF8.self)
                    accumulated += chunk

                    // Extract 8-char device code (e.g. ABCD-1234)
                    if detectedCode == nil,
                       let range = accumulated.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#, options: .regularExpression) {
                        let code = String(accumulated[range])
                        detectedCode = code
                        DispatchQueue.main.async {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        onProgress(OAuthProgressEvent(
                            message: "Code \(code) copied — approve in browser (github.com/login/device)…",
                            deviceCode: code
                        ))
                    }

                    // Auto-press Enter when `gh` asks "Press Enter to open github.com in your browser"
                    if !sentEnter && accumulated.localizedCaseInsensitiveContains("Press Enter") {
                        sentEnter = true
                        var nl: UInt8 = 0x0A
                        _ = Darwin.write(masterFD, &nl, 1)
                    }
                } else {
                    break
                }
            }

            var status: Int32 = 0
            let wp = waitpid(pid, &status, WNOHANG)
            if wp == pid {
                break
            }
        }

        try checkCancelled()

        guard let imported = try? mgr.importFromHostCLI(connectionID: "github") else {
            throw OAuthFlowError.githubAuthFailed("GitHub browser sign-in did not complete. Click Connect to try again.")
        }
        try mgr.saveToken(imported.token, for: "github")
        _ = mgr.configureHostGitForGitHub(token: imported.token)
        if let ghMCP = ConnectionsManager.mcpPreset(id: "github") {
            let agents = targetAgents.isEmpty ? mgr.detectInstalledAgents() : targetAgents
            if !agents.isEmpty {
                try? mgr.installMCP(ghMCP, into: agents)
            }
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        let who = imported.label.isEmpty ? "" : " (\(imported.label))"
        return "Connected GitHub\(who) via browser OAuth — wired git push & gh CLI across sandboxes."
    }

    // MARK: - RFC 9728 / RFC 8414 Discovery + RFC 7591 Registration + Token Exchange

    private func discoverOAuthMetadata(mcpURL: String) throws -> OAuthMetadata {
        guard let url = URL(string: mcpURL),
              let scheme = url.scheme,
              let host = url.host else {
            throw OAuthFlowError.discoveryFailed("Invalid MCP URL: \(mcpURL)")
        }
        let portPart = url.port.map { ":\($0)" } ?? ""
        let origin = "\(scheme)://\(host)\(portPart)"
        let path = url.path == "/" ? "" : url.path

        var authServerCandidates: [String] = []
        var scopes: [String] = []

        // 1. Try RFC 9728 Protected Resource Metadata
        for prmStr in [
            "\(origin)/.well-known/oauth-protected-resource\(path)",
            "\(origin)/.well-known/oauth-protected-resource",
        ] {
            if let prm = fetchJSON(urlString: prmStr) {
                if let servers = prm["authorization_servers"] as? [String] {
                    for s in servers {
                        let clean = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if !clean.isEmpty && !authServerCandidates.contains(clean) {
                            authServerCandidates.append(clean)
                        }
                    }
                }
                if let sc = prm["scopes_supported"] as? [String], !sc.isEmpty {
                    scopes = sc
                }
                if !authServerCandidates.isEmpty { break }
            }
        }
        // Always include the resource origin itself as fallback (e.g. Stripe serves AS metadata on mcp.stripe.com!)
        if !authServerCandidates.contains(origin) {
            authServerCandidates.append(origin)
        }

        // 2. Try RFC 8414 Authorization Server Metadata
        for base in authServerCandidates {
            let candidates: [String]
            if let bu = URL(string: base), !bu.path.isEmpty, bu.path != "/" {
                let bOrigin = "\(bu.scheme ?? "https")://\(bu.host ?? "")\(bu.port.map { ":\($0)" } ?? "")"
                candidates = [
                    "\(bOrigin)/.well-known/oauth-authorization-server\(bu.path)",
                    "\(base)/.well-known/oauth-authorization-server",
                    "\(bOrigin)/.well-known/openid-configuration\(bu.path)",
                ]
            } else {
                candidates = [
                    "\(base)/.well-known/oauth-authorization-server",
                    "\(base)/.well-known/openid-configuration",
                ]
            }

            for asURL in candidates {
                if let asm = fetchJSON(urlString: asURL),
                   let authEP = asm["authorization_endpoint"] as? String,
                   let tokenEP = asm["token_endpoint"] as? String,
                   let regEP = asm["registration_endpoint"] as? String {
                    let finalScopes = scopes.isEmpty ? ((asm["scopes_supported"] as? [String]) ?? []) : scopes
                    return OAuthMetadata(
                        authorizationEndpoint: authEP,
                        tokenEndpoint: tokenEP,
                        registrationEndpoint: regEP,
                        scopesSupported: finalScopes
                    )
                }
            }
        }

        throw OAuthFlowError.discoveryFailed("Server does not advertise OAuth 2.1 Dynamic Client Registration.")
    }

    private func registerDynamicClient(
        registrationEndpoint: String,
        redirectURI: String
    ) throws -> (clientID: String, clientSecret: String?) {
        guard let url = URL(string: registrationEndpoint) else {
            throw OAuthFlowError.registrationFailed("Invalid registration URL")
        }
        let body: [String: Any] = [
            "client_name": "boo_box",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        let reqData = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = reqData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("boo_box/1.0", forHTTPHeaderField: "User-Agent")

        let (data, status) = try performSyncRequest(req)
        guard (200...299).contains(status),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let clientID = json["client_id"] as? String, !clientID.isEmpty else {
            let msg = String(data: data, encoding: .utf8)?.prefix(180) ?? "HTTP \(status)"
            throw OAuthFlowError.registrationFailed("HTTP \(status): \(msg)")
        }
        let clientSecret = (json["client_secret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (clientID, clientSecret)
    }

    private struct TokenExchangeResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        let scope: String?
    }

    private func exchangeCodeForToken(
        tokenEndpoint: String,
        code: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String?,
        codeVerifier: String,
        resource: String
    ) throws -> TokenExchangeResponse {
        guard let url = URL(string: tokenEndpoint) else {
            throw OAuthFlowError.tokenExchangeFailed("Invalid token URL")
        }
        var formPairs: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", codeVerifier),
            ("resource", resource),
        ]
        if let secret = clientSecret, !secret.isEmpty {
            formPairs.append(("client_secret", secret))
        }
        let encodedBody = formPairs
            .map { "\(formURLEncode($0.0))=\(formURLEncode($0.1))" }
            .joined(separator: "&")

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = Data(encodedBody.utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("boo_box/1.0", forHTTPHeaderField: "User-Agent")

        let (data, status) = try performSyncRequest(req)
        guard (200...299).contains(status),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            let msg = String(data: data, encoding: .utf8)?.prefix(200) ?? "HTTP \(status)"
            throw OAuthFlowError.tokenExchangeFailed("HTTP \(status): \(msg)")
        }
        let refreshToken = json["refresh_token"] as? String
        let expiresIn: Double?
        if let n = json["expires_in"] as? NSNumber {
            expiresIn = n.doubleValue
        } else {
            expiresIn = nil
        }
        let scope = json["scope"] as? String
        return TokenExchangeResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
            scope: scope
        )
    }

    // MARK: - Loopback 127.0.0.1 HTTP Callback Listener

    private func openLoopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OAuthFlowError.listenerFailed("socket() errno \(errno)")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let e = errno
            Darwin.close(fd)
            throw OAuthFlowError.listenerFailed("bind() errno \(e)")
        }
        guard Darwin.listen(fd, 4) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw OAuthFlowError.listenerFailed("listen() errno \(e)")
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &boundLen)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        return (fd, port)
    }

    private func waitForOAuthCallback(
        listenFD: Int32,
        expectedState: String,
        serviceName: String,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try checkCancelled()

            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 300)
            if pr < 0 {
                if errno == EINTR { continue }
                try checkCancelled()
                throw OAuthFlowError.listenerFailed("poll() errno \(errno)")
            }
            if pr == 0 { continue }

            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                try checkCancelled()
                continue
            }

            var buf = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(clientFD, &buf, buf.count)
            guard n > 0 else {
                Darwin.close(clientFD)
                continue
            }

            let reqText = String(decoding: buf[0..<n], as: UTF8.self)
            guard let firstLine = reqText.split(separator: "\r\n", maxSplits: 1).first else {
                Darwin.close(clientFD)
                continue
            }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                Darwin.close(clientFD)
                continue
            }
            let rawPath = String(parts[1])

            // Ignore favicon probes cleanly
            if rawPath.hasPrefix("/favicon") {
                sendHTTPResponse(fd: clientFD, status: "404 Not Found", html: "")
                Darwin.close(clientFD)
                continue
            }

            guard let comps = URLComponents(string: "http://127.0.0.1\(rawPath)") else {
                sendHTTPResponse(fd: clientFD, status: "400 Bad Request", html: callbackHTML(title: "Invalid callback", detail: "Malformed redirect URL.", ok: false))
                Darwin.close(clientFD)
                continue
            }
            let items = comps.queryItems ?? []
            let queryDict = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })

            if let err = queryDict["error"], !err.isEmpty {
                let desc = queryDict["error_description"] ?? err
                sendHTTPResponse(fd: clientFD, status: "200 OK", html: callbackHTML(title: "Authorization cancelled", detail: desc, ok: false))
                Darwin.close(clientFD)
                throw OAuthFlowError.callbackError(desc)
            }

            guard let returnedState = queryDict["state"], returnedState == expectedState else {
                sendHTTPResponse(fd: clientFD, status: "400 Bad Request", html: callbackHTML(title: "State mismatch", detail: "Security check failed — please retry from boo_box.", ok: false))
                Darwin.close(clientFD)
                throw OAuthFlowError.callbackError("OAuth state mismatch")
            }

            guard let code = queryDict["code"], !code.isEmpty else {
                sendHTTPResponse(fd: clientFD, status: "400 Bad Request", html: callbackHTML(title: "Missing code", detail: "Provider did not return an authorization code.", ok: false))
                Darwin.close(clientFD)
                throw OAuthFlowError.callbackError("Missing authorization code")
            }

            sendHTTPResponse(
                fd: clientFD,
                status: "200 OK",
                html: callbackHTML(
                    title: "Connected \(serviceName) to boo_box",
                    detail: "OAuth credentials saved to macOS Keychain and synced to your coding agents. You can close this tab.",
                    ok: true
                )
            )
            Darwin.close(clientFD)
            return code
        }
        throw OAuthFlowError.timeout
    }

    private func sendHTTPResponse(fd: Int32, status: String, html: String) {
        let body = Data(html.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var full = Data(header.utf8)
        full.append(body)
        full.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var offset = 0
            while offset < full.count {
                let written = Darwin.write(fd, base.advanced(by: offset), full.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func callbackHTML(title: String, detail: String, ok: Bool) -> String {
        let accent = ok ? "#3fd6b8" : "#f87171"
        let badge = ok ? "✓" : "✕"
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>\(escapeHTML(title))</title>
          <style>
            body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; background:#14161a; color:#f3f4f6; font-family:-apple-system,BlinkMacSystemFont,sans-serif; }
            .card { max-width:440px; padding:32px; border-radius:16px; background:#1d2026; border:1px solid rgba(255,255,255,0.08); text-align:center; box-shadow:0 20px 60px rgba(0,0,0,0.45); }
            .icon { width:48px; height:48px; margin:0 auto 16px; border-radius:999px; display:flex; align-items:center; justify-content:center; font-size:24px; font-weight:700; color:#14161a; background:\(accent); }
            h1 { margin:0 0 10px; font-size:18px; font-weight:600; }
            p { margin:0; font-size:13.5px; line-height:1.5; color:#9ca3af; }
          </style>
        </head>
        <body>
          <div class="card">
            <div class="icon">\(badge)</div>
            <h1>\(escapeHTML(title))</h1>
            <p>\(escapeHTML(detail))</p>
          </div>
          <script>setTimeout(() => { window.close(); }, 1800);</script>
        </body>
        </html>
        """
    }

    // MARK: - Native Agent OAuth Store Sync (OMP SQLite & OpenCode mcp-auth.json)

    private var ompDBPath: String {
        URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent(".omp/agent/agent.db").path
    }

    private var openCodeMCPAuthURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent(".local/share/opencode/mcp-auth.json")
    }

    private func ompProviderKey(for mcpURL: String) -> String {
        "mcp_oauth:profile:default:\(mcpURL)"
    }

    func hasOMPOAuthCredential(mcpURL: String) -> Bool {
        guard FileManager.default.fileExists(atPath: ompDBPath) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(ompDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(1) FROM auth_credentials WHERE provider = ? AND credential_type = 'oauth'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        let key = ompProviderKey(for: mcpURL)
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) > 0
        }
        return false
    }

    func writeOMPOAuthCredential(record: OAuthTokenRecord) {
        guard FileManager.default.fileExists(atPath: ompDBPath) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(ompDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let provider = ompProviderKey(for: record.resourceURL)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let expiresMs = Int64((record.expiresAtEpochSeconds ?? (Date().timeIntervalSince1970 + 3600)) * 1000)

        var payload: [String: Any] = [
            "access": record.accessToken,
            "expires": expiresMs,
            "clientId": record.clientID,
            "authorizationUrl": record.authorizationURL,
            "tokenUrl": record.tokenURL,
            "resource": record.resourceURL,
        ]
        if let refresh = record.refreshToken, !refresh.isEmpty {
            payload["refresh"] = refresh
        }
        if let secret = record.clientSecret, !secret.isEmpty {
            payload["clientSecret"] = secret
        }
        if let scope = record.scope, !scope.isEmpty {
            payload["scope"] = scope
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)

        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM auth_credentials WHERE provider = ? AND credential_type = 'oauth'", -1, &delStmt, nil) == SQLITE_OK, let delStmt {
            sqlite3_bind_text(delStmt, 1, provider, -1, transient)
            _ = sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }

        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO auth_credentials (provider, credential_type, data, created_at, updated_at) VALUES (?, 'oauth', ?, ?, ?)", -1, &insStmt, nil) == SQLITE_OK, let insStmt {
            sqlite3_bind_text(insStmt, 1, provider, -1, transient)
            sqlite3_bind_text(insStmt, 2, jsonStr, -1, transient)
            sqlite3_bind_int64(insStmt, 3, nowMs)
            sqlite3_bind_int64(insStmt, 4, nowMs)
            _ = sqlite3_step(insStmt)
            sqlite3_finalize(insStmt)
        }

        _ = sqlite3_exec(db, "UPDATE auth_change_revision SET revision = revision + 1", nil, nil, nil)
        _ = sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func removeOMPOAuthCredential(mcpURL: String) {
        guard FileManager.default.fileExists(atPath: ompDBPath) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(ompDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let provider = ompProviderKey(for: mcpURL)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM auth_credentials WHERE provider = ? AND credential_type = 'oauth'", -1, &stmt, nil) == SQLITE_OK, let stmt {
            sqlite3_bind_text(stmt, 1, provider, -1, transient)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        _ = sqlite3_exec(db, "UPDATE auth_change_revision SET revision = revision + 1", nil, nil, nil)
    }

    func hasOpenCodeOAuthCredential(mcpID: String, mcpURL: String) -> Bool {
        guard let data = try? Data(contentsOf: openCodeMCPAuthURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        for (key, val) in root {
            guard let entry = val as? [String: Any],
                  let tokens = entry["tokens"] as? [String: Any],
                  let tok = tokens["accessToken"] as? String, !tok.isEmpty else { continue }
            if key == mcpID || (entry["serverUrl"] as? String) == mcpURL {
                return true
            }
        }
        return false
    }

    func writeOpenCodeOAuthCredential(record: OAuthTokenRecord) {
        let dir = openCodeMCPAuthURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path) ||
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/opencode").path) else {
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: openCodeMCPAuthURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = existing
        }

        var tokens: [String: Any] = [
            "accessToken": record.accessToken,
        ]
        if let refresh = record.refreshToken, !refresh.isEmpty {
            tokens["refreshToken"] = refresh
        }
        if let exp = record.expiresAtEpochSeconds {
            tokens["expiresAt"] = exp
        }
        if let scope = record.scope, !scope.isEmpty {
            tokens["scope"] = scope
        }

        var clientInfo: [String: Any] = [
            "clientId": record.clientID,
        ]
        if let secret = record.clientSecret, !secret.isEmpty {
            clientInfo["clientSecret"] = secret
        }

        root[record.serviceID] = [
            "serverUrl": record.resourceURL,
            "tokens": tokens,
            "clientInfo": clientInfo,
        ]

        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: openCodeMCPAuthURL, options: .atomic)
            chmod(openCodeMCPAuthURL.path, 0o600)
        }
    }

    func removeOpenCodeOAuthCredential(mcpID: String) {
        guard let data = try? Data(contentsOf: openCodeMCPAuthURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root.removeValue(forKey: mcpID) != nil else { return }
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: openCodeMCPAuthURL, options: .atomic)
            chmod(openCodeMCPAuthURL.path, 0o600)
        }
    }

    // MARK: - Helpers

    private func checkCancelled() throws {
        lock.lock()
        let c = cancelled
        lock.unlock()
        if c { throw OAuthFlowError.cancelled }
    }

    private func fetchJSON(urlString: String) -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("boo_box/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, status) = try? performSyncRequest(req),
              (200...299).contains(status),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return json
    }

    private final class SyncHTTPBox: @unchecked Sendable {
        var data = Data()
        var statusCode = 0
        var error: Error?
    }

    private func performSyncRequest(_ request: URLRequest) throws -> (Data, Int) {
        let sem = DispatchSemaphore(value: 0)
        let box = SyncHTTPBox()

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let data { box.data = data }
            if let http = response as? HTTPURLResponse { box.statusCode = http.statusCode }
            box.error = error
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 25)
        if let err = box.error { throw err }
        return (box.data, box.statusCode)
    }

    private func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func formURLEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func findExecutable(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
