import AppKit
import Foundation
import Security

// MARK: - Curated 1-Click Catalog Definitions

struct ConnectionPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let envVar: String
    let aliasEnvVars: [String]
    let tokenURL: String
    let placeholder: String
    let supportsHostImport: Bool
    let hostImportHint: String?
}

enum MCPTransport: Sendable {
    case remoteHTTP(url: String, authHeaderEnvVar: String? = nil)
    case stdio(command: String, args: [String], envVar: String? = nil)

    var badgeLabel: String {
        switch self {
        case .remoteHTTP(_, nil): return "OAuth HTTP"
        case .remoteHTTP(_, _?): return "HTTP + Token"
        case .stdio: return "Local Stdio"
        }
    }
}

struct MCPPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let transport: MCPTransport
    let linkedConnectionID: String?
    let docsURL: String
}

enum MCPAgentTarget: String, CaseIterable, Identifiable, Sendable {
    case omp = "omp"
    case opencode = "opencode"
    case claude = "claude"
    case codex = "codex"
    case gemini = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .omp: return "OMP"
        case .opencode: return "OpenCode"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        }
    }

    func configFileURL(realHome: String) -> URL {
        switch self {
        case .omp: return URL(fileURLWithPath: "\(realHome)/.omp/agent/mcp.json")
        case .opencode: return URL(fileURLWithPath: "\(realHome)/.config/opencode/opencode.json")
        case .claude: return URL(fileURLWithPath: "\(realHome)/.claude.json")
        case .codex: return URL(fileURLWithPath: "\(realHome)/.codex/config.toml")
        case .gemini: return URL(fileURLWithPath: "\(realHome)/.gemini/settings.json")
        }
    }

    var binaryName: String {
        switch self {
        case .omp: return "omp"
        case .opencode: return "opencode"
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        }
    }
}

// MARK: - Connections & Multi-Agent MCP Manager

/// Unified Keychain-backed account token manager (`dev.boo-box.connections`, zero plaintext in `config.json`)
/// plus 1-click host CLI auto-import and non-destructive multi-agent MCP server synchronization.
final class ConnectionsManager: @unchecked Sendable {
    static let shared = ConnectionsManager()

    static let keychainService = "dev.boo-box.connections"

    let realHome: String

    private init() {
        self.realHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    }

    // MARK: - Curated Built-In Catalogs

    static let connectionPresets: [ConnectionPreset] = [
        ConnectionPreset(
            id: "github",
            name: "GitHub",
            subtitle: "Enables gh CLI, HTTPS git push/pull, and GitHub MCP across every sandbox.",
            symbol: "chevron.left.forwardslash.chevron.right",
            envVar: "GH_TOKEN",
            aliasEnvVars: ["GITHUB_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN"],
            tokenURL: "https://github.com/settings/personal-access-tokens/new",
            placeholder: "github_pat_…",
            supportsHostImport: true,
            hostImportHint: "Import from host gh CLI and wire ~/.gitconfig"
        ),
        ConnectionPreset(
            id: "cloudflare",
            name: "Cloudflare / Wrangler",
            subtitle: "Workers, Pages, R2, D1, and Wrangler deployments.",
            symbol: "cloud.fill",
            envVar: "CLOUDFLARE_API_TOKEN",
            aliasEnvVars: [],
            tokenURL: "https://dash.cloudflare.com/profile/api-tokens",
            placeholder: "Cloudflare API Token…",
            supportsHostImport: false,
            hostImportHint: nil
        ),
        ConnectionPreset(
            id: "vercel",
            name: "Vercel",
            subtitle: "Deployments, env pull, and Vercel CLI.",
            symbol: "triangle.fill",
            envVar: "VERCEL_TOKEN",
            aliasEnvVars: [],
            tokenURL: "https://vercel.com/account/tokens",
            placeholder: "Vercel Token…",
            supportsHostImport: true,
            hostImportHint: "Import from local Vercel CLI login"
        ),
        ConnectionPreset(
            id: "supabase",
            name: "Supabase",
            subtitle: "Migrations, Edge Functions, and Supabase CLI.",
            symbol: "bolt.fill",
            envVar: "SUPABASE_ACCESS_TOKEN",
            aliasEnvVars: [],
            tokenURL: "https://supabase.com/dashboard/account/tokens",
            placeholder: "sbp_…",
            supportsHostImport: false,
            hostImportHint: nil
        ),
        ConnectionPreset(
            id: "linear",
            name: "Linear",
            subtitle: "Issues, projects, and Linear CLI / API.",
            symbol: "checklist",
            envVar: "LINEAR_API_KEY",
            aliasEnvVars: [],
            tokenURL: "https://linear.app/settings/api",
            placeholder: "lin_api_…",
            supportsHostImport: false,
            hostImportHint: nil
        ),
        ConnectionPreset(
            id: "stripe",
            name: "Stripe",
            subtitle: "Restricted API key for Stripe CLI, test fixtures, and billing scripts.",
            symbol: "creditcard.fill",
            envVar: "STRIPE_API_KEY",
            aliasEnvVars: [],
            tokenURL: "https://dashboard.stripe.com/apikeys",
            placeholder: "rk_test_… or sk_test_…",
            supportsHostImport: false,
            hostImportHint: nil
        ),
        ConnectionPreset(
            id: "sentry",
            name: "Sentry",
            subtitle: "Issue lookup, releases, and sourcemaps.",
            symbol: "ant.fill",
            envVar: "SENTRY_AUTH_TOKEN",
            aliasEnvVars: [],
            tokenURL: "https://sentry.io/settings/account/api/auth-tokens/",
            placeholder: "sntrys_…",
            supportsHostImport: false,
            hostImportHint: nil
        ),
        ConnectionPreset(
            id: "slack",
            name: "Slack",
            subtitle: "Bot/User token for Slack CLI scripts.",
            symbol: "bubble.left.and.bubble.right.fill",
            envVar: "SLACK_BOT_TOKEN",
            aliasEnvVars: [],
            tokenURL: "https://api.slack.com/apps",
            placeholder: "xoxb-…",
            supportsHostImport: false,
            hostImportHint: nil
        ),
        ConnectionPreset(
            id: "npm",
            name: "npm Registry",
            subtitle: "Private npm and GitHub Packages auth.",
            symbol: "shippingbox.fill",
            envVar: "NPM_TOKEN",
            aliasEnvVars: [],
            tokenURL: "https://www.npmjs.com/settings/~/tokens",
            placeholder: "npm_…",
            supportsHostImport: true,
            hostImportHint: "Import _authToken from ~/.npmrc"
        ),
        ConnectionPreset(
            id: "fly",
            name: "Fly.io",
            subtitle: "Deployments and flyctl commands.",
            symbol: "paperplane.fill",
            envVar: "FLY_API_TOKEN",
            aliasEnvVars: [],
            tokenURL: "https://fly.io/user/personal_access_tokens",
            placeholder: "FlyV1 …",
            supportsHostImport: true,
            hostImportHint: "Import from ~/.fly/config.yml"
        ),
        ConnectionPreset(
            id: "exa",
            name: "Exa Search",
            subtitle: "Neural web & code search API.",
            symbol: "sparkle.magnifyingglass",
            envVar: "EXA_API_KEY",
            aliasEnvVars: [],
            tokenURL: "https://dashboard.exa.ai/api-keys",
            placeholder: "Exa API Key…",
            supportsHostImport: false,
            hostImportHint: nil
        ),
        ConnectionPreset(
            id: "context7",
            name: "Context7",
            subtitle: "Up-to-date library docs MCP.",
            symbol: "books.vertical.fill",
            envVar: "CONTEXT7_API_KEY",
            aliasEnvVars: [],
            tokenURL: "https://context7.com/dashboard",
            placeholder: "ctx7sk-…",
            supportsHostImport: false,
            hostImportHint: nil
        ),
        ConnectionPreset(
            id: "firecrawl",
            name: "Firecrawl",
            subtitle: "Web scraping & markdown extraction.",
            symbol: "flame.fill",
            envVar: "FIRECRAWL_API_KEY",
            aliasEnvVars: [],
            tokenURL: "https://www.firecrawl.dev/app/api-keys",
            placeholder: "fc-…",
            supportsHostImport: false,
            hostImportHint: nil
        ),
    ]

    static let mcpPresets: [MCPPreset] = [
        MCPPreset(
            id: "notion",
            name: "Notion",
            subtitle: "Docs, wikis, databases, and Notion Calendar via official OAuth MCP.",
            symbol: "doc.richtext",
            transport: .remoteHTTP(url: "https://mcp.notion.com/mcp"),
            linkedConnectionID: nil,
            docsURL: "https://developers.notion.com/docs/mcp"
        ),
        MCPPreset(
            id: "linear",
            name: "Linear",
            subtitle: "Issues, cycles, projects, and comments via official Linear OAuth MCP.",
            symbol: "checklist",
            transport: .remoteHTTP(url: "https://mcp.linear.app/mcp"),
            linkedConnectionID: "linear",
            docsURL: "https://linear.app/docs/mcp"
        ),
        MCPPreset(
            id: "slack",
            name: "Slack",
            subtitle: "Search channels, threads, and send messages via official Slack OAuth MCP.",
            symbol: "bubble.left.and.bubble.right.fill",
            transport: .remoteHTTP(url: "https://mcp.slack.com/mcp"),
            linkedConnectionID: "slack",
            docsURL: "https://docs.slack.dev"
        ),
        MCPPreset(
            id: "figma",
            name: "Figma",
            subtitle: "Inspect frames, design tokens, and components via official Figma OAuth MCP.",
            symbol: "paintpalette.fill",
            transport: .remoteHTTP(url: "https://mcp.figma.com/mcp"),
            linkedConnectionID: nil,
            docsURL: "https://help.figma.com"
        ),
        MCPPreset(
            id: "sentry",
            name: "Sentry",
            subtitle: "Query stack traces, issues, and releases via official Sentry OAuth MCP.",
            symbol: "ant.fill",
            transport: .remoteHTTP(url: "https://mcp.sentry.dev/mcp"),
            linkedConnectionID: "sentry",
            docsURL: "https://docs.sentry.io/product/sentry-mcp/"
        ),
        MCPPreset(
            id: "cloudflare",
            name: "Cloudflare",
            subtitle: "Workers observability, logs, and analytics via Cloudflare OAuth MCP.",
            symbol: "cloud.fill",
            transport: .remoteHTTP(url: "https://observability.mcp.cloudflare.com/mcp"),
            linkedConnectionID: "cloudflare",
            docsURL: "https://developers.cloudflare.com/agents/model-context-protocol/"
        ),
        MCPPreset(
            id: "cloudflare-docs",
            name: "Cloudflare Docs",
            subtitle: "Search Workers, Pages, D1, and R2 documentation (no login required).",
            symbol: "book.closed.fill",
            transport: .remoteHTTP(url: "https://docs.mcp.cloudflare.com/mcp"),
            linkedConnectionID: nil,
            docsURL: "https://developers.cloudflare.com/agents/model-context-protocol/"
        ),
        MCPPreset(
            id: "supabase",
            name: "Supabase",
            subtitle: "Inspect schemas, run queries, and manage projects via Supabase OAuth MCP.",
            symbol: "bolt.fill",
            transport: .remoteHTTP(url: "https://mcp.supabase.com/mcp"),
            linkedConnectionID: "supabase",
            docsURL: "https://supabase.com/docs/guides/getting-started/mcp"
        ),
        MCPPreset(
            id: "vercel",
            name: "Vercel",
            subtitle: "Inspect deployments, build logs, and domains via Vercel OAuth MCP.",
            symbol: "triangle.fill",
            transport: .remoteHTTP(url: "https://mcp.vercel.com"),
            linkedConnectionID: "vercel",
            docsURL: "https://vercel.com/docs/mcp"
        ),
        MCPPreset(
            id: "stripe",
            name: "Stripe",
            subtitle: "Docs, customers, prices, and test payments via Stripe OAuth MCP.",
            symbol: "creditcard.fill",
            transport: .remoteHTTP(url: "https://mcp.stripe.com"),
            linkedConnectionID: "stripe",
            docsURL: "https://docs.stripe.com/mcp"
        ),
        MCPPreset(
            id: "context7",
            name: "Context7",
            subtitle: "Live version-matched docs & code examples for any library/framework.",
            symbol: "books.vertical.fill",
            transport: .remoteHTTP(url: "https://mcp.context7.com/mcp"),
            linkedConnectionID: "context7",
            docsURL: "https://context7.com"
        ),
        MCPPreset(
            id: "openrouter",
            name: "OpenRouter",
            subtitle: "Model catalog, routing, and usage insights via OpenRouter OAuth MCP.",
            symbol: "network",
            transport: .remoteHTTP(url: "https://mcp.openrouter.ai/mcp"),
            linkedConnectionID: nil,
            docsURL: "https://openrouter.ai/docs"
        ),
        MCPPreset(
            id: "github",
            name: "GitHub MCP",
            subtitle: "Repos, PRs, issues, code search, and Actions (uses connected GitHub token).",
            symbol: "chevron.left.forwardslash.chevron.right",
            transport: .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], envVar: "GITHUB_PERSONAL_ACCESS_TOKEN"),
            linkedConnectionID: "github",
            docsURL: "https://github.com/github/github-mcp-server"
        ),
        MCPPreset(
            id: "playwright",
            name: "Playwright",
            subtitle: "Headless browser automation, screenshots, and DOM inspection.",
            symbol: "safari.fill",
            transport: .stdio(command: "npx", args: ["-y", "@playwright/mcp@latest"]),
            linkedConnectionID: nil,
            docsURL: "https://github.com/microsoft/playwright-mcp"
        ),
        MCPPreset(
            id: "exa",
            name: "Exa Search",
            subtitle: "Fast semantic web and developer search MCP.",
            symbol: "sparkle.magnifyingglass",
            transport: .remoteHTTP(url: "https://mcp.exa.ai/mcp"),
            linkedConnectionID: "exa",
            docsURL: "https://exa.ai"
        ),
        MCPPreset(
            id: "sequential-thinking",
            name: "Sequential Thinking",
            subtitle: "Structured multi-step reasoning tool (runs locally via npx, zero API key).",
            symbol: "brain.head.profile",
            transport: .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-sequential-thinking"]),
            linkedConnectionID: nil,
            docsURL: "https://github.com/modelcontextprotocol/servers"
        ),
    ]

    static func preset(for id: String) -> ConnectionPreset? {
        connectionPresets.first { $0.id == id }
    }

    static func connectionPreset(id: String) -> ConnectionPreset? {
        connectionPresets.first { $0.id == id }
    }

    static func mcpPreset(id: String) -> MCPPreset? {
        mcpPresets.first { $0.id == id }
    }

    // MARK: - Host-Only Vault Token Storage (~/boo_box/vault/connections.json, 0700/0600, Seatbelt-denied)
    // Stored outside config.json and outside legacy login Keychain so ad-hoc signed rebuilds/auto-updates
    // and `boo setup-github` CLI never hang on macOS SecurityAgent Keychain ACL prompts.

    private static let vaultLock = NSLock()

    private var vaultDirURL: URL {
        BooBoxPaths.rootDirURL.appendingPathComponent("vault", isDirectory: true)
    }

    private var vaultFileURL: URL {
        vaultDirURL.appendingPathComponent("connections.json")
    }

    private func readVaultMapLocked() -> [String: String] {
        guard let data = try? Data(contentsOf: vaultFileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private func writeVaultMapLocked(_ map: [String: String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: vaultDirURL, withIntermediateDirectories: true)
        chmod(vaultDirURL.path, 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        try data.write(to: vaultFileURL, options: .atomic)
        chmod(vaultFileURL.path, 0o600)
    }

    func saveToken(_ value: String, for connectionID: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "BooBox.Connections", code: -1, userInfo: [NSLocalizedDescriptionKey: "Token cannot be empty."])
        }
        Self.vaultLock.lock()
        defer { Self.vaultLock.unlock() }
        var map = readVaultMapLocked()
        map[connectionID] = trimmed
        try writeVaultMapLocked(map)
    }

    func readToken(for connectionID: String) -> String? {
        Self.vaultLock.lock()
        defer { Self.vaultLock.unlock() }
        let s = readVaultMapLocked()[connectionID]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    func hasToken(for connectionID: String) -> Bool {
        readToken(for: connectionID) != nil
    }

    func deleteToken(for connectionID: String) {
        Self.vaultLock.lock()
        defer { Self.vaultLock.unlock() }
        var map = readVaultMapLocked()
        guard map.removeValue(forKey: connectionID) != nil else { return }
        try? writeVaultMapLocked(map)
    }
    /// Resolves enabled Keychain-backed connection tokens for injection into a sandbox's `0600` `.boobox-env.sh`.
    /// Respects per-sandbox `secretAccessMode == .none` (withholds all tokens in untrusted/zero-secret tabs).
    func resolvedSandboxEnvEntries(config cfg: BooBoxConfig, overrides: SandboxOverrideConfig) -> [(key: String, value: String)] {
        guard overrides.secretAccessMode != .none else { return [] }
        var out: [(key: String, value: String)] = []
        var seen = Set<String>()
        for acct in cfg.connections.accounts where acct.enabled {
            guard let tok = readToken(for: acct.id), !tok.isEmpty else { continue }
            let primary = acct.envVar.trimmingCharacters(in: .whitespacesAndNewlines)
            if !primary.isEmpty && !seen.contains(primary) {
                seen.insert(primary)
                out.append((key: primary, value: tok))
            }
            if let preset = Self.preset(for: acct.id) {
                for alias in preset.aliasEnvVars where !alias.isEmpty && !seen.contains(alias) {
                    seen.insert(alias)
                    out.append((key: alias, value: tok))
                }
            }
        }
        return out
    }

    // MARK: - 1-Click Host CLI Auto-Import & GitHub Setup

    /// Imports an existing host CLI credential directly into macOS Keychain (`dev.boo-box.connections`).
    /// Returns `(token, label)` on success.
    func importFromHostCLI(connectionID: String) throws -> (token: String, label: String) {
        switch connectionID {
        case "github":
            return try importGitHubFromHost()
        case "vercel":
            return try importVercelFromHost()
        case "npm":
            return try importNPMFromHost()
        case "fly":
            return try importFlyFromHost()
        default:
            throw NSError(domain: "BooBox.Connections", code: -2, userInfo: [NSLocalizedDescriptionKey: "Host auto-import is not available for \(connectionID). Paste a token instead."])
        }
    }

    /// Ensures host `~/.gitconfig` has `user.name`, `user.email`, and `gh auth setup-git` wired so
    /// HTTPS `git push` / `git pull` automatically authenticate with `GH_TOKEN` inside every sandbox.
    func configureHostGitForGitHub(token: String) -> String? {
        let ghBin = resolveBinary("gh")
        var loginLabel: String? = nil

        var ghUserJSON: [String: Any]? = nil
        if let ghBin,
           let out = runCapture(ghBin, ["api", "user"], extraEnv: ["GH_TOKEN": token]),
           let data = out.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ghUserJSON = obj
            loginLabel = obj["login"] as? String
        }

        let curName = runCapture("/usr/bin/git", ["config", "--global", "--get", "user.name"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if curName.isEmpty {
            let inferred = (ghUserJSON?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? loginLabel
                ?? NSFullUserName()
            if !inferred.isEmpty {
                _ = runCapture("/usr/bin/git", ["config", "--global", "user.name", inferred])
            }
        }

        let curEmail = runCapture("/usr/bin/git", ["config", "--global", "--get", "user.email"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if curEmail.isEmpty {
            if let email = ghUserJSON?["email"] as? String, !email.isEmpty {
                _ = runCapture("/usr/bin/git", ["config", "--global", "user.email", email])
            } else if let uid = ghUserJSON?["id"] as? Int, let login = loginLabel, !login.isEmpty {
                _ = runCapture("/usr/bin/git", ["config", "--global", "user.email", "\(uid)+\(login)@users.noreply.github.com"])
            }
        }

        // Wire host ~/.gitconfig with a sandbox-aware GitHub credential helper:
        // - Inside any boo_box sandbox (even already-open shells without GH_TOKEN in env), delegates to
        //   `$HOME/.boobox-bin/boobox-git-cred` which live-sources `$HOME/.boobox-env.sh`.
        // - On the real host Mac, falls back to `gh auth git-credential` identically to `gh auth setup-git`.
        let helperFallback = ghBin.map { "exec \($0) auth git-credential \"$@\"" } ?? "exit 0"
        let helperCmd = "!/bin/sh -c 'if [ -x \"$HOME/.boobox-bin/boobox-git-cred\" ]; then exec \"$HOME/.boobox-bin/boobox-git-cred\" \"$@\"; else \(helperFallback); fi' --"
        for host in ["https://github.com", "https://gist.github.com"] {
            let key = "credential.\(host).helper"
            _ = runCapture("/usr/bin/git", ["config", "--global", "--unset-all", key])
            _ = runCapture("/usr/bin/git", ["config", "--global", "--add", key, ""])
            _ = runCapture("/usr/bin/git", ["config", "--global", "--add", key, helperCmd])
        }
        return loginLabel
    }

    private func importGitHubFromHost() throws -> (token: String, label: String) {
        guard let ghBin = resolveBinary("gh") else {
            throw NSError(domain: "BooBox.Connections", code: -3, userInfo: [NSLocalizedDescriptionKey: "GitHub CLI (`gh`) not found. Install via `brew install gh` or paste a fine-grained PAT."])
        }
        guard let tok = runCapture(ghBin, ["auth", "token"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tok.isEmpty else {
            throw NSError(domain: "BooBox.Connections", code: -4, userInfo: [NSLocalizedDescriptionKey: "Host `gh` CLI is not signed in. Run `gh auth login` on your Mac or paste a fine-grained PAT."])
        }
        let login = configureHostGitForGitHub(token: tok)
        return (tok, login ?? "Host gh CLI")
    }

    private func importVercelFromHost() throws -> (token: String, label: String) {
        let candidates = [
            "\(realHome)/Library/Application Support/com.vercel.cli/auth.json",
            "\(realHome)/.local/share/com.vercel.cli/auth.json",
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tok = obj["token"] as? String, !tok.isEmpty {
                return (tok, "Imported from Vercel CLI")
            }
        }
        throw NSError(domain: "BooBox.Connections", code: -5, userInfo: [NSLocalizedDescriptionKey: "No local Vercel CLI auth.json found. Run `vercel login` on your Mac or paste a token."])
    }

    private func importNPMFromHost() throws -> (token: String, label: String) {
        let path = "\(realHome)/.npmrc"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw NSError(domain: "BooBox.Connections", code: -6, userInfo: [NSLocalizedDescriptionKey: "No ~/.npmrc found. Paste an npm token instead."])
        }
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            if let range = trimmed.range(of: "_authToken=") {
                let tok = String(trimmed[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
                if !tok.isEmpty && !tok.hasPrefix("${") {
                    return (tok, "Imported from ~/.npmrc")
                }
            }
        }
        throw NSError(domain: "BooBox.Connections", code: -7, userInfo: [NSLocalizedDescriptionKey: "No literal `_authToken` found in ~/.npmrc. Paste an npm token instead."])
    }

    private func importFlyFromHost() throws -> (token: String, label: String) {
        let path = "\(realHome)/.fly/config.yml"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw NSError(domain: "BooBox.Connections", code: -8, userInfo: [NSLocalizedDescriptionKey: "No ~/.fly/config.yml found. Run `fly auth login` or paste a token."])
        }
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("access_token:") {
                let tok = String(trimmed.dropFirst("access_token:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
                if !tok.isEmpty {
                    return (tok, "Imported from flyctl")
                }
            }
        }
        throw NSError(domain: "BooBox.Connections", code: -9, userInfo: [NSLocalizedDescriptionKey: "No access_token found in ~/.fly/config.yml."])
    }

    // MARK: - Multi-Agent MCP Detection & 1-Click Install / Remove

    func detectInstalledAgents() -> [MCPAgentTarget] {
        let fm = FileManager.default
        return MCPAgentTarget.allCases.filter { agent in
            if fm.fileExists(atPath: agent.configFileURL(realHome: realHome).path) {
                return true
            }
            if resolveBinary(agent.binaryName) != nil {
                return true
            }
            return false
        }
    }

    func agentsWithMCPInstalled(_ mcpID: String) -> Set<MCPAgentTarget> {
        var result = Set<MCPAgentTarget>()
        for agent in MCPAgentTarget.allCases {
            if isMCPInstalled(mcpID, in: agent) {
                result.insert(agent)
            }
        }
        return result
    }

    func isMCPInstalled(_ mcpID: String, in agent: MCPAgentTarget) -> Bool {
        let url = agent.configFileURL(realHome: realHome)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        switch agent {
        case .omp, .claude, .gemini:
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any],
                  let entry = servers[mcpID] as? [String: Any] else {
                return false
            }
            if let enabled = entry["enabled"] as? Bool, !enabled {
                return false
            }
            return true

        case .opencode:
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mcp = root["mcp"] as? [String: Any],
                  let entry = mcp[mcpID] as? [String: Any] else {
                return false
            }
            if let enabled = entry["enabled"] as? Bool, !enabled {
                return false
            }
            return true

        case .codex:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains("[mcp_servers.\(mcpID)]") || text.contains("[mcp_servers.\"\(mcpID)\"]")
        }
    }

    /// Installs `preset` non-destructively into all specified `agents` (preserving every existing setting & OAuth state).
    func installMCP(_ preset: MCPPreset, into agents: [MCPAgentTarget]) throws {
        let targets = agents.isEmpty ? detectInstalledAgents() : agents
        let finalTargets = targets.isEmpty ? [.omp] : targets
        for agent in finalTargets {
            try writeMCP(preset, to: agent)
        }
    }

    /// Removes `preset` cleanly from all specified `agents` without touching unrelated entries.
    func removeMCP(_ preset: MCPPreset, from agents: [MCPAgentTarget]) throws {
        let targets = agents.isEmpty ? MCPAgentTarget.allCases : agents
        for agent in targets {
            try deleteMCP(preset.id, from: agent)
        }
    }

    private func writeMCP(_ preset: MCPPreset, to agent: MCPAgentTarget) throws {
        let url = agent.configFileURL(realHome: realHome)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch agent {
        case .omp, .claude, .gemini:
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = existing
            }
            var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
            var entry = (servers[preset.id] as? [String: Any]) ?? [:]
            switch preset.transport {
            case .remoteHTTP(let endpoint, _):
                if agent == .gemini {
                    entry["httpUrl"] = endpoint
                } else {
                    entry["type"] = "http"
                    entry["url"] = endpoint
                }
            case .stdio(let cmd, let args, _):
                if agent != .gemini {
                    entry["type"] = "stdio"
                }
                entry["command"] = cmd
                entry["args"] = args
            }
            // Re-enable cleanly if previously disabled (e.g. OMP's `"enabled": false`)
            if entry["enabled"] != nil {
                entry["enabled"] = true
            }
            servers[preset.id] = entry
            root["mcpServers"] = servers
            try writeJSONAtomically(root, to: url)

        case .opencode:
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = existing
            }
            var mcp = (root["mcp"] as? [String: Any]) ?? [:]
            var entry = (mcp[preset.id] as? [String: Any]) ?? [:]
            switch preset.transport {
            case .remoteHTTP(let endpoint, _):
                entry["type"] = "remote"
                entry["url"] = endpoint
                entry["enabled"] = true
            case .stdio(let cmd, let args, _):
                entry["type"] = "local"
                entry["command"] = [cmd] + args
                entry["enabled"] = true
            }
            mcp[preset.id] = entry
            root["mcp"] = mcp
            try writeJSONAtomically(root, to: url)

        case .codex:
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text = removeTOMLSection(named: "mcp_servers.\(preset.id)", from: text)
            text = removeTOMLSection(named: "mcp_servers.\"\(preset.id)\"", from: text)
            let header = preset.id.contains("-") ? "[mcp_servers.\"\(preset.id)\"]" : "[mcp_servers.\(preset.id)]"
            var block = "\n\(header)\n"
            switch preset.transport {
            case .remoteHTTP(let endpoint, _):
                block += "url = \"\(endpoint)\"\n"
            case .stdio(let cmd, let args, _):
                let quotedArgs = args.map { "\"\($0)\"" }.joined(separator: ", ")
                block += "command = \"\(cmd)\"\nargs = [\(quotedArgs)]\n"
            }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += block
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func deleteMCP(_ mcpID: String, from agent: MCPAgentTarget) throws {
        let url = agent.configFileURL(realHome: realHome)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        switch agent {
        case .omp, .claude, .gemini:
            guard let data = try? Data(contentsOf: url),
                  var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var servers = root["mcpServers"] as? [String: Any],
                  servers[mcpID] != nil else { return }
            servers.removeValue(forKey: mcpID)
            root["mcpServers"] = servers
            try writeJSONAtomically(root, to: url)

        case .opencode:
            guard let data = try? Data(contentsOf: url),
                  var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var mcp = root["mcp"] as? [String: Any],
                  mcp[mcpID] != nil else { return }
            mcp.removeValue(forKey: mcpID)
            root["mcp"] = mcp
            try writeJSONAtomically(root, to: url)

        case .codex:
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let updated = removeTOMLSection(
                named: "mcp_servers.\"\(mcpID)\"",
                from: removeTOMLSection(named: "mcp_servers.\(mcpID)", from: text)
            )
            if updated != text {
                text = updated
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func writeJSONAtomically(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        var out = data
        out.append(0x0A)
        try out.write(to: url, options: .atomic)
    }

    private func removeTOMLSection(named sectionName: String, from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let targetHeader = "[\(sectionName)]"
        var out: [String] = []
        var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if trimmed == targetHeader || trimmed.hasPrefix("[\(sectionName).") {
                    skipping = true
                    continue
                } else {
                    skipping = false
                }
            }
            if !skipping {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Subprocess & Binary Helpers

    func resolveBinary(_ name: String) -> String? {
        let fm = FileManager.default
        let dirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(realHome)/.local/bin",
            "\(realHome)/.bun/bin",
            "\(realHome)/.cargo/bin",
            "\(realHome)/boo_box/env/bin",
            "\(realHome)/boo_box/env/.local/bin",
            "/usr/bin",
        ]
        for dir in dirs {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        // Check latest fnm node bin for npm-installed CLIs (omp, claude, codex, opencode, gemini)
        for fnmRoot in [
            "\(realHome)/.local/share/fnm/node-versions",
            "\(realHome)/Library/Application Support/fnm/node-versions",
        ] {
            if let versions = try? fm.contentsOfDirectory(atPath: fnmRoot).sorted(by: >) {
                for v in versions {
                    let p = "\(fnmRoot)/\(v)/installation/bin/\(name)"
                    if fm.isExecutableFile(atPath: p) { return p }
                }
            }
        }
        return nil
    }

    private func runCapture(_ executable: String, _ args: [String], extraEnv: [String: String] = [:]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        let curPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(curPath)"
        for (k, v) in extraEnv { env[k] = v }
        proc.environment = env
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
