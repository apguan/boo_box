import AppKit
import Foundation
import SwiftUI

// MARK: - Config Schema (~/boo_box/config.json)

enum PackageCacheAccessMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case readWrite = "read_write"
    case readOnly = "read_only"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .readWrite: "Read-Write (Shared)"
        case .readOnly: "Read-Only (Strict)"
        }
    }

    var summary: String {
        switch self {
        case .readWrite:
            "Sessions share and populate one cache automatically (fastest across tabs)."
        case .readOnly:
            "Sessions can read existing cached packages but cannot write to or poison the shared cache."
        }
    }
}

struct EnvVarEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

struct EphemeralSetupConfig: Codable, Equatable, Sendable {
    /// Shell commands executed automatically inside every fresh Private VM (Alpine Linux).
    var privateVMSetupScript: String = ""
    /// Shell commands executed once when a new macOS Sandbox session is created.
    var sandboxSetupScript: String = ""
    /// Explicit KEY=VALUE environment variables injected into opted-in session types.
    var envVars: [EnvVarEntry] = []
    /// Inject envVars into macOS Sandbox sessions via $HOME/.boobox-env.sh (0600, sourced by .zshrc).
    var injectEnvIntoMacSandbox: Bool = true
    /// Opt-in: inject envVars into Private VMs via /root/.boobox-env.sh (0600, sourced by /root/.zshrc).
    var injectEnvIntoPrivateVM: Bool = false
    /// Optional extra read-only host paths (e.g. ~/.config/omp) allowed inside macOS Sandbox sessions.
    var sandboxExtraReadPaths: [String] = []

    var hasPrivateVMProvisioning: Bool {
        !privateVMSetupScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (injectEnvIntoPrivateVM && !cleanedEnvVars.isEmpty)
    }

    var cleanedEnvVars: [(key: String, value: String)] {
        var orderedKeys: [String] = []
        var valuesByKey: [String: String] = [:]
        for entry in envVars {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                continue
            }
            if valuesByKey[key] == nil {
                orderedKeys.append(key)
            }
            valuesByKey[key] = entry.value
        }
        return orderedKeys.compactMap { k in
            valuesByKey[k].map { (key: k, value: $0) }
        }
    }

    init(
        privateVMSetupScript: String = "",
        sandboxSetupScript: String = "",
        envVars: [EnvVarEntry] = [],
        injectEnvIntoMacSandbox: Bool = true,
        injectEnvIntoPrivateVM: Bool = false,
        sandboxExtraReadPaths: [String] = []
    ) {
        self.privateVMSetupScript = privateVMSetupScript
        self.sandboxSetupScript = sandboxSetupScript
        self.envVars = envVars
        self.injectEnvIntoMacSandbox = injectEnvIntoMacSandbox
        self.injectEnvIntoPrivateVM = injectEnvIntoPrivateVM
        self.sandboxExtraReadPaths = sandboxExtraReadPaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.privateVMSetupScript = try c.decodeIfPresent(String.self, forKey: .privateVMSetupScript) ?? ""
        self.sandboxSetupScript = try c.decodeIfPresent(String.self, forKey: .sandboxSetupScript) ?? ""
        self.envVars = try c.decodeIfPresent([EnvVarEntry].self, forKey: .envVars) ?? []
        self.injectEnvIntoMacSandbox = try c.decodeIfPresent(Bool.self, forKey: .injectEnvIntoMacSandbox) ?? true
        self.injectEnvIntoPrivateVM = try c.decodeIfPresent(Bool.self, forKey: .injectEnvIntoPrivateVM) ?? false
        self.sandboxExtraReadPaths = try c.decodeIfPresent([String].self, forKey: .sandboxExtraReadPaths) ?? []
    }
}

struct PackageCacheConfig: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var accessMode: PackageCacheAccessMode = .readWrite
    var cacheDirectory: String = "~/boo_box/cache"
    var pnpm: Bool = true
    var npm: Bool = true
    var bun: Bool = true
    var uv: Bool = true
    var pip: Bool = true
    var cargo: Bool = true

    func resolvedCacheURL() -> URL {
        let expanded = (cacheDirectory as NSString).expandingTildeInPath
        let raw = expanded.isEmpty ? (NSHomeDirectory() + "/boo_box/cache") : expanded
        return URL(fileURLWithPath: raw, isDirectory: true).resolvingSymlinksInPath()
    }
}

struct AppearanceConfig: Codable, Equatable, Sendable {
    /// Ghostty theme name (nil = inherit ~/.config/ghostty/config).
    var themeName: String? = nil
    /// Optional Ghostty font size override (nil = inherit ~/.config/ghostty/config).
    var fontSize: Double? = nil
    /// Background opacity (0.75 ... 1.0).
    var backgroundOpacity: Double = 1.0
}

struct GeneralConfig: Codable, Equatable, Sendable {
    /// Prompt with a warning alert before permanently deleting a session directory.
    var confirmBeforeDeletingSession: Bool = true
    /// Automatically name sessions from repo, Git branch, sub-package, or agent title until manually renamed.
    var autoNameSessions: Bool = true
    /// Exclude `.env` / `.env.*` files (except `.env.example`/`.sample`/`.template`) when cloning a project folder.
    var excludeEnvFilesWhenCloning: Bool = false
    /// Optional slim clone: skip `node_modules`, `.next`, `.turbo`, `.venv`, `target`, `.build`.
    /// Off by default so APFS zero-copy cloning brings over 100% of files (zero `npm/bun install` needed).
    var skipHeavyDirsWhenCloning: Bool = false
    /// Show a dismissible confirmation alert before opening http(s) websites clicked inside sandboxed terminals.
    /// Non-http(s) URL schemes (e.g. file://, custom app links) always ask in sandboxed tabs.
    var confirmOpeningWebLinks: Bool = true
    /// Automatically check `apguan/boo_box` on GitHub for new releases/updates on launch and periodically.
    var autoUpdateEnabled: Bool = true
    /// When automatic updates are enabled, automatically download and install verified GitHub Release updates.
    var autoDownloadUpdates: Bool = false
    /// Send native macOS notifications when unfocused tabs finish long commands, ring bells, or emit agent notifications.
    var desktopNotificationsEnabled: Bool = true
    /// Remember open sessions across app restarts and auto-updates.
    var restoreSessionsOnLaunch: Bool = true
    /// Run macOS Sandbox PTYs through `booboxd` so live shells and coding agents survive quits and auto-updates.
    var persistentSessionsEnabled: Bool = true

    init(
        confirmBeforeDeletingSession: Bool = true,
        autoNameSessions: Bool = true,
        excludeEnvFilesWhenCloning: Bool = false,
        skipHeavyDirsWhenCloning: Bool = false,
        confirmOpeningWebLinks: Bool = true,
        autoUpdateEnabled: Bool = true,
        autoDownloadUpdates: Bool = false,
        desktopNotificationsEnabled: Bool = true,
        restoreSessionsOnLaunch: Bool = true,
        persistentSessionsEnabled: Bool = true
    ) {
        self.confirmBeforeDeletingSession = confirmBeforeDeletingSession
        self.autoNameSessions = autoNameSessions
        self.excludeEnvFilesWhenCloning = excludeEnvFilesWhenCloning
        self.skipHeavyDirsWhenCloning = skipHeavyDirsWhenCloning
        self.confirmOpeningWebLinks = confirmOpeningWebLinks
        self.autoUpdateEnabled = autoUpdateEnabled
        self.autoDownloadUpdates = autoDownloadUpdates
        self.desktopNotificationsEnabled = desktopNotificationsEnabled
        self.restoreSessionsOnLaunch = restoreSessionsOnLaunch
        self.persistentSessionsEnabled = persistentSessionsEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.confirmBeforeDeletingSession = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeDeletingSession) ?? true
        self.autoNameSessions = try c.decodeIfPresent(Bool.self, forKey: .autoNameSessions) ?? true
        self.excludeEnvFilesWhenCloning = try c.decodeIfPresent(Bool.self, forKey: .excludeEnvFilesWhenCloning) ?? false
        self.skipHeavyDirsWhenCloning = try c.decodeIfPresent(Bool.self, forKey: .skipHeavyDirsWhenCloning) ?? false
        self.confirmOpeningWebLinks = try c.decodeIfPresent(Bool.self, forKey: .confirmOpeningWebLinks) ?? true
        self.autoUpdateEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateEnabled) ?? true
        self.autoDownloadUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoDownloadUpdates) ?? false
        self.desktopNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .desktopNotificationsEnabled) ?? true
        self.restoreSessionsOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .restoreSessionsOnLaunch) ?? true
        self.persistentSessionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .persistentSessionsEnabled) ?? true
    }
}

// MARK: - Private Linux MicroVM Configuration

enum PrivateVMNetworkMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case nat = "nat"
    case offline = "offline"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nat: "NAT (Internet)"
        case .offline: "Offline (Air-gapped)"
        }
    }

    var summary: String {
        switch self {
        case .nat: "Standard Apple Virtualization NAT with outbound internet access."
        case .offline: "No virtual network interface attached — pure hypervisor air-gap."
        }
    }
}

struct PrivateVMConfig: Codable, Equatable, Sendable {
    /// Number of vCPUs allocated to each Private Linux MicroVM.
    var cpuCount: Int = PrivateVMConfig.defaultCPUCount
    /// Guest RAM in MiB (lazily faulted by Apple Silicon hypervisor).
    var memoryMB: Int = 1024
    /// Virtual network attachment mode.
    var networkMode: PrivateVMNetworkMode = .nat
    /// Keep 1 standby Linux VM pre-booted after first VM launch for <1 ms spin-up.
    var prewarmPool: Bool = true
    /// Optional host folder mounted via VirtioFS at `/mnt/host` inside Private VMs (empty = air-gapped).
    var sharedHostPath: String = ""
    /// Mount optional VirtioFS folder read-only (recommended when sharing host files into a VM).
    var sharedHostReadOnly: Bool = true

    static var defaultCPUCount: Int {
        let host = ProcessInfo.processInfo.processorCount
        return max(2, min(4, host / 2))
    }

    static var maxCPUCount: Int {
        max(2, ProcessInfo.processInfo.processorCount)
    }

    static var maxMemoryMB: Int {
        let hostMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        return max(1024, min(16384, hostMB / 2))
    }

    var clampedCPUCount: Int {
        max(1, min(Self.maxCPUCount, cpuCount))
    }

    var clampedMemoryMB: Int {
        max(512, min(Self.maxMemoryMB, memoryMB))
    }

    var resolvedSharedHostURL: URL? {
        let trimmed = sharedHostPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).resolvingSymlinksInPath()
    }

    init(
        cpuCount: Int = PrivateVMConfig.defaultCPUCount,
        memoryMB: Int = 1024,
        networkMode: PrivateVMNetworkMode = .nat,
        prewarmPool: Bool = true,
        sharedHostPath: String = "",
        sharedHostReadOnly: Bool = true
    ) {
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.networkMode = networkMode
        self.prewarmPool = prewarmPool
        self.sharedHostPath = sharedHostPath
        self.sharedHostReadOnly = sharedHostReadOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? Self.defaultCPUCount
        self.memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB) ?? 1024
        self.networkMode = try c.decodeIfPresent(PrivateVMNetworkMode.self, forKey: .networkMode) ?? .nat
        self.prewarmPool = try c.decodeIfPresent(Bool.self, forKey: .prewarmPool) ?? true
        self.sharedHostPath = try c.decodeIfPresent(String.self, forKey: .sharedHostPath) ?? ""
        self.sharedHostReadOnly = try c.decodeIfPresent(Bool.self, forKey: .sharedHostReadOnly) ?? true
    }
}

// MARK: - Host Secret Vault & Egress Proxy Configuration

enum EgressNetworkMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case full = "full"
    case allowlist = "allowlist"
    case offline = "offline"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: "Full (Vault Protected)"
        case .allowlist: "Dev Allowlist"
        case .offline: "Offline (Air-gapped)"
        }
    }

    var summary: String {
        switch self {
        case .full:
            "All outbound domains allowed. Vault secrets stay on host as phantom tokens and are only injected for their bound hosts."
        case .allowlist:
            "Seatbelt forces all traffic through boobox-proxy and blocks direct DNS. Only LLM APIs, package registries, GitHub, and custom domains are allowed."
        case .offline:
            "Seatbelt blocks all outbound network and DNS. Zero external connectivity."
        }
    }
}

enum VaultSecretSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case keychain = "keychain"
    case onePassword = "onepassword"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keychain: "macOS Keychain"
        case .onePassword: "1Password (op://)"
        }
    }
}

struct VaultSecretEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// Environment variable exposed inside sandboxes as a worthless phantom token (`bbx_ph_...`).
    var envVar: String
    /// Where the real secret value lives on the trusted host (never written to config.json).
    var source: VaultSecretSource
    /// 1Password reference (`op://Vault/Item/field`) when `source == .onePassword`.
    var onePasswordRef: String
    /// Exact or wildcard hostnames allowed to receive the real secret (e.g. `api.anthropic.com`).
    var allowedHosts: [String]
    /// Optional base URL env var pointed at `boobox-proxy` reverse-proxy route (e.g. `ANTHROPIC_BASE_URL`).
    var baseURLVar: String
    /// Optional upstream path prefix (e.g. `/v1` or `/api/v1`) appended to the proxy base URL.
    var baseURLPathPrefix: String
    var enabled: Bool

    var primaryHost: String? {
        allowedHosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty && !$0.contains("*") }
    }

    init(
        id: UUID = UUID(),
        envVar: String,
        source: VaultSecretSource = .keychain,
        onePasswordRef: String = "",
        allowedHosts: [String],
        baseURLVar: String = "",
        baseURLPathPrefix: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.envVar = envVar
        self.source = source
        self.onePasswordRef = onePasswordRef
        self.allowedHosts = allowedHosts
        self.baseURLVar = baseURLVar
        self.baseURLPathPrefix = baseURLPathPrefix
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.envVar = try c.decodeIfPresent(String.self, forKey: .envVar) ?? ""
        self.source = try c.decodeIfPresent(VaultSecretSource.self, forKey: .source) ?? .keychain
        self.onePasswordRef = try c.decodeIfPresent(String.self, forKey: .onePasswordRef) ?? ""
        self.allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        self.baseURLVar = try c.decodeIfPresent(String.self, forKey: .baseURLVar) ?? ""
        self.baseURLPathPrefix = try c.decodeIfPresent(String.self, forKey: .baseURLPathPrefix) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    struct Preset: Identifiable, Sendable {
        var id: String { envVar }
        let label: String
        let envVar: String
        let allowedHosts: [String]
        let baseURLVar: String
        let baseURLPathPrefix: String
    }

    static let presets: [Preset] = [
        Preset(label: "Anthropic", envVar: "ANTHROPIC_API_KEY", allowedHosts: ["api.anthropic.com"], baseURLVar: "ANTHROPIC_BASE_URL", baseURLPathPrefix: ""),
        Preset(label: "OpenAI", envVar: "OPENAI_API_KEY", allowedHosts: ["api.openai.com"], baseURLVar: "OPENAI_BASE_URL", baseURLPathPrefix: "/v1"),
        Preset(label: "OpenRouter", envVar: "OPENROUTER_API_KEY", allowedHosts: ["openrouter.ai"], baseURLVar: "OPENROUTER_BASE_URL", baseURLPathPrefix: "/api/v1"),
        Preset(label: "Gemini", envVar: "GEMINI_API_KEY", allowedHosts: ["generativelanguage.googleapis.com"], baseURLVar: "GOOGLE_GEMINI_BASE_URL", baseURLPathPrefix: ""),
        Preset(label: "GitHub", envVar: "GITHUB_TOKEN", allowedHosts: ["api.github.com", "github.com"], baseURLVar: "", baseURLPathPrefix: ""),
    ]
}

struct SecretsNetworkConfig: Codable, Equatable, Sendable {
    /// Run the host-side `boobox-proxy` sidecar for phantom-token secret injection and egress filtering.
    var proxyEnabled: Bool = true
    /// Outbound network policy for macOS Sandbox sessions.
    var egressMode: EgressNetworkMode = .full
    /// Force all outbound traffic through `boobox-proxy` via Seatbelt even in `Full` mode (automatically on for Allowlist/Offline).
    var strictProxyRouting: Bool = false
    /// Additional allowed hostnames/wildcards when `egressMode == .allowlist` (e.g. `api.stripe.com`, `*.vercel.com`).
    var customAllowedDomains: [String] = []
    /// Vault secret metadata (real values stay in macOS Keychain or 1Password, never in config.json).
    var secrets: [VaultSecretEntry] = []

    var requiresSeatbeltNetworkLock: Bool {
        switch egressMode {
        case .offline, .allowlist:
            return true
        case .full:
            return strictProxyRouting && proxyEnabled
        }
    }

    static let builtInDevAllowlist: [String] = [
        "api.anthropic.com",
        "api.openai.com",
        "openrouter.ai",
        "generativelanguage.googleapis.com",
        "api.x.ai",
        "api.groq.com",
        "api.mistral.ai",
        "github.com",
        "api.github.com",
        "raw.githubusercontent.com",
        "objects.githubusercontent.com",
        "codeload.github.com",
        "release-assets.githubusercontent.com",
        "gitlab.com",
        "registry.npmjs.org",
        "registry.yarnpkg.com",
        "pypi.org",
        "files.pythonhosted.org",
        "crates.io",
        "static.crates.io",
        "index.crates.io",
        "proxy.golang.org",
        "sum.golang.org",
        "rubygems.org",
        "astral.sh",
        "sh.rustup.rs",
        "static.rust-lang.org",
        "bun.sh",
        "nodejs.org",
        "deno.land",
        "jsr.io",
        "huggingface.co",
        "*.hf.co",
    ]

    var effectiveAllowlistDomains: [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in Self.builtInDevAllowlist + customAllowedDomains + secrets.flatMap(\.allowedHosts) {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            out.append(cleaned)
        }
        return out
    }

    init(
        proxyEnabled: Bool = true,
        egressMode: EgressNetworkMode = .full,
        strictProxyRouting: Bool = false,
        customAllowedDomains: [String] = [],
        secrets: [VaultSecretEntry] = []
    ) {
        self.proxyEnabled = proxyEnabled
        self.egressMode = egressMode
        self.strictProxyRouting = strictProxyRouting
        self.customAllowedDomains = customAllowedDomains
        self.secrets = secrets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.proxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? true
        self.egressMode = try c.decodeIfPresent(EgressNetworkMode.self, forKey: .egressMode) ?? .full
        self.strictProxyRouting = try c.decodeIfPresent(Bool.self, forKey: .strictProxyRouting) ?? false
        self.customAllowedDomains = try c.decodeIfPresent([String].self, forKey: .customAllowedDomains) ?? []
        self.secrets = try c.decodeIfPresent([VaultSecretEntry].self, forKey: .secrets) ?? []
    }
}

struct SandboxAccessConfig: Codable, Equatable, Sendable {
    /// Share host `~/.omp` read-write so `omp` keeps auth, models, MCP servers, and extensions with zero re-setup.
    var shareOMPConfig: Bool = true
    /// Share host `~/.claude`, `~/.claude.json`, and `~/.config/claude` read-write.
    var shareClaudeConfig: Bool = true
    /// Share host `~/.codex` and `~/.config/codex` read-write.
    var shareCodexConfig: Bool = true
    /// Share host `~/.config/opencode`, `~/.local/share/opencode`, and `~/.local/state/opencode` read-write.
    var shareOpenCodeConfig: Bool = true
    /// Share host `~/.gemini` and `~/.config/gemini` read-write.
    var shareGeminiConfig: Bool = true
    /// Share installed major agent harness configs (Cursor, Amp, Pi, Aider, Goose, Factory/Droid, Cline, Augment, Codeium, Kimi, Qwen, Vibe) read-write.
    var shareOtherAgentConfigs: Bool = true
    /// Opt-in: share host `~/.config/gh` read-write for GitHub CLI auth.
    var shareGHConfig: Bool = false
    /// Shared global sandbox environment (`~/boo_box/env`) writable by both user (`boo install …`) and
    /// sandboxed agents (`npm i -g`, `bun add -g`, `go install`, `cargo install`, `uv tool install`, `boo install`).
    var persistentSandboxTools: Bool = true
    /// Directory for the shared global sandbox environment (isolated from host `/opt/homebrew`).
    var sandboxToolsPath: String = "~/boo_box/env"
    var extraConfigPaths: [String] = []
    /// Extra host directories granted read-only access (and added to PATH when applicable) inside macOS Sandbox sessions.
    var extraReadPaths: [String] = []
    /// Opt-in: expose host `~/.gitconfig` read-only for git user name/email/aliases (never `~/.git-credentials`).
    var allowHostGitConfig: Bool = false
    /// Opt-in (risk): forward host `SSH_AUTH_SOCK` so sandboxed tools can use loaded ssh-agent keys without reading `~/.ssh`.
    var allowSSHAgent: Bool = false
    /// Opt-in (high risk): expose host Docker / OrbStack socket (container bind mounts can escape the filesystem sandbox).
    var allowDockerSocket: Bool = false
    /// Optional hardening: block outbound connections to host `localhost` / `127.0.0.1` / `::1`.
    var blockLocalNetwork: Bool = false

    init(
        shareOMPConfig: Bool = true,
        shareClaudeConfig: Bool = true,
        shareCodexConfig: Bool = true,
        shareOpenCodeConfig: Bool = true,
        shareGeminiConfig: Bool = true,
        shareOtherAgentConfigs: Bool = true,
        shareGHConfig: Bool = false,
        persistentSandboxTools: Bool = true,
        sandboxToolsPath: String = "~/boo_box/env",
        extraConfigPaths: [String] = [],
        extraReadPaths: [String] = [],
        allowHostGitConfig: Bool = false,
        allowSSHAgent: Bool = false,
        allowDockerSocket: Bool = false,
        blockLocalNetwork: Bool = false
    ) {
        self.shareOMPConfig = shareOMPConfig
        self.shareClaudeConfig = shareClaudeConfig
        self.shareCodexConfig = shareCodexConfig
        self.shareOpenCodeConfig = shareOpenCodeConfig
        self.shareGeminiConfig = shareGeminiConfig
        self.shareOtherAgentConfigs = shareOtherAgentConfigs
        self.shareGHConfig = shareGHConfig
        self.persistentSandboxTools = persistentSandboxTools
        self.sandboxToolsPath = sandboxToolsPath
        self.extraConfigPaths = extraConfigPaths
        self.extraReadPaths = extraReadPaths
        self.allowHostGitConfig = allowHostGitConfig
        self.allowSSHAgent = allowSSHAgent
        self.allowDockerSocket = allowDockerSocket
        self.blockLocalNetwork = blockLocalNetwork
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.shareOMPConfig = try c.decodeIfPresent(Bool.self, forKey: .shareOMPConfig) ?? true
        self.shareClaudeConfig = try c.decodeIfPresent(Bool.self, forKey: .shareClaudeConfig) ?? true
        self.shareCodexConfig = try c.decodeIfPresent(Bool.self, forKey: .shareCodexConfig) ?? true
        self.shareOpenCodeConfig = try c.decodeIfPresent(Bool.self, forKey: .shareOpenCodeConfig) ?? true
        self.shareGeminiConfig = try c.decodeIfPresent(Bool.self, forKey: .shareGeminiConfig) ?? true
        self.shareOtherAgentConfigs = try c.decodeIfPresent(Bool.self, forKey: .shareOtherAgentConfigs) ?? true
        self.shareGHConfig = try c.decodeIfPresent(Bool.self, forKey: .shareGHConfig) ?? false
        self.persistentSandboxTools = try c.decodeIfPresent(Bool.self, forKey: .persistentSandboxTools) ?? true
        let rawToolsPath = try c.decodeIfPresent(String.self, forKey: .sandboxToolsPath) ?? "~/boo_box/env"
        // Seamless upgrade from earlier default `~/boo_box/tools` when that folder has no custom installs
        if rawToolsPath == "~/boo_box/tools" {
            let oldPath = (rawToolsPath as NSString).expandingTildeInPath
            let hasCustomBins = ["bin", "npm/bin", "bun/bin", "go/bin", "cargo/bin"].contains { sub in
                let p = oldPath + "/" + sub
                return ((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []).contains { !$0.hasPrefix(".") }
            }
            self.sandboxToolsPath = hasCustomBins ? rawToolsPath : "~/boo_box/env"
        } else {
            self.sandboxToolsPath = rawToolsPath
        }
        self.extraConfigPaths = try c.decodeIfPresent([String].self, forKey: .extraConfigPaths) ?? []
        self.extraReadPaths = try c.decodeIfPresent([String].self, forKey: .extraReadPaths) ?? []
        self.allowHostGitConfig = try c.decodeIfPresent(Bool.self, forKey: .allowHostGitConfig) ?? false
        self.allowSSHAgent = try c.decodeIfPresent(Bool.self, forKey: .allowSSHAgent) ?? false
        self.allowDockerSocket = try c.decodeIfPresent(Bool.self, forKey: .allowDockerSocket) ?? false
        self.blockLocalNetwork = try c.decodeIfPresent(Bool.self, forKey: .blockLocalNetwork) ?? false
    }

    func resolvedToolsURL() -> URL {
        let trimmed = sandboxToolsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = ((trimmed.isEmpty ? "~/boo_box/env" : trimmed) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).resolvingSymlinksInPath()
    }

    struct SharedConfigMapping: Equatable, Sendable {
        /// Relative path under `$HOME` (e.g. `.omp`, `.config/opencode`).
        let relativePath: String
        /// Resolved canonical host path (e.g. `/Users/alice/.omp`).
        let hostPath: String
        /// True if this entry is a single file (uses SBPL `literal`); false if a directory (uses `subpath`).
        let isFile: Bool
    }

    /// Resolves all enabled host CLI config directories/files to mount RW and symlink into sandbox `$HOME`.
    func resolvedSharedConfigMappings(realHome: String) -> [SharedConfigMapping] {
        let fm = FileManager.default
        var out: [SharedConfigMapping] = []
        var seen = Set<String>()

        func addRel(_ rel: String, createIfMissing: Bool = false) {
            let hostPath = "\(realHome)/\(rel)"
            guard !seen.contains(hostPath) else { return }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: hostPath, isDirectory: &isDir) {
                seen.insert(hostPath)
                out.append(SharedConfigMapping(relativePath: rel, hostPath: hostPath, isFile: !isDir.boolValue))
            } else if createIfMissing {
                try? fm.createDirectory(atPath: hostPath, withIntermediateDirectories: true)
                if fm.fileExists(atPath: hostPath) {
                    seen.insert(hostPath)
                    out.append(SharedConfigMapping(relativePath: rel, hostPath: hostPath, isFile: false))
                }
            }
        }

        if shareOMPConfig {
            addRel(".omp", createIfMissing: true)
        }
        if shareClaudeConfig {
            addRel(".claude")
            addRel(".claude.json")
            addRel(".config/claude")
        }
        if shareCodexConfig {
            addRel(".codex")
            addRel(".config/codex")
        }
        if shareOpenCodeConfig {
            addRel(".config/opencode")
            addRel(".local/share/opencode")
            addRel(".local/state/opencode")
        }
        if shareGeminiConfig {
            addRel(".gemini")
            addRel(".config/gemini")
        }
        if shareOtherAgentConfigs {
            for rel in [
                ".cursor", ".config/cursor",
                ".config/amp", ".local/share/amp",
                ".pi",
                ".aider", ".aider.conf.yml", ".aider.model.settings.yml", ".aider.model.metadata.json",
                ".config/goose",
                ".factory",
                ".cline",
                ".augment",
                ".codeium",
                ".kimi",
                ".qwen",
                ".vibe",
            ] {
                addRel(rel)
            }
        }
        if shareGHConfig {
            addRel(".config/gh")
        }
        for raw in extraConfigPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
            // Safety guard: never allow symlinking/mounting the entire home dir or root
            guard expanded.hasPrefix(realHome + "/") else { continue }
            let rel = String(expanded.dropFirst(realHome.count + 1))
            guard !rel.isEmpty, !seen.contains(expanded) else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
                seen.insert(expanded)
                out.append(SharedConfigMapping(relativePath: rel, hostPath: expanded, isFile: !isDir.boolValue))
            }
        }
        return out
    }
    /// Returns a human-readable warning if a custom read path exposes a sensitive host location.
    static func riskWarning(for rawPath: String) -> String? {
        let realHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let expanded = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        if expanded == "/" || expanded == "/Users" || expanded == realHome {
            return "Exposes your entire home directory (including credentials and private files)!"
        }
        let sensitivePrefixes: [(String, String)] = [
            ("\(realHome)/.ssh", "Exposes SSH private keys"),
            ("\(realHome)/.aws", "Exposes AWS credentials"),
            ("\(realHome)/.gnupg", "Exposes GPG private keys"),
            ("\(realHome)/Library/Keychains", "Exposes macOS Keychain files"),
            ("\(realHome)/.config", "May contain CLI auth tokens under ~/.config"),
            ("\(realHome)/Desktop", "Exposes personal Desktop files"),
            ("\(realHome)/Documents", "Exposes personal Documents"),
            ("\(realHome)/boo_box", "Exposes boo_box config.json and other sessions"),
        ]
        for (prefix, reason) in sensitivePrefixes {
            if expanded == prefix || expanded.hasPrefix(prefix + "/") {
                return reason
            }
        }
        return nil
    }
}

// MARK: - Per-Sandbox Configuration Overrides (persisted per session)

enum SessionSecretAccessMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case inheritGlobal = "inherit"
    case custom = "custom"
    case none = "none"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inheritGlobal: "Inherit Global"
        case .custom: "Selected Secrets"
        case .none: "None (0 Secrets)"
        }
    }
}

enum SandboxCPUPriority: String, Codable, CaseIterable, Sendable, Identifiable {
    case normal = "normal"
    case background = "background"
    case low = "low"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: "Normal (nice 0)"
        case .background: "Background (nice 10)"
        case .low: "Low (nice 19)"
        }
    }

    var niceValue: Int {
        switch self {
        case .normal: 0
        case .background: 10
        case .low: 19
        }
    }
}

struct SandboxOverrideConfig: Codable, Equatable, Sendable {
    // Network & Secrets (macOS Sandbox)
    var egressMode: EgressNetworkMode? = nil
    var extraAllowedDomains: [String] = []
    var blockLocalNetwork: Bool? = nil
    var secretAccessMode: SessionSecretAccessMode = .inheritGlobal
    var allowedSecretIDs: [UUID] = []

    // Environment & Host Access (macOS Sandbox + VM envVars)
    var envVars: [EnvVarEntry] = []
    var useGlobalEnvTools: Bool? = nil
    var extraReadPaths: [String] = []
    var allowHostGitConfig: Bool? = nil
    var allowSSHAgent: Bool? = nil
    var allowDockerSocket: Bool? = nil

    // macOS Sandbox Resource Limits (strictly per-process hard kernel rlimits + nice)
    var cpuPriority: SandboxCPUPriority = .normal
    var maxCPUSeconds: Int? = nil      // ulimit -Ht / -St (per-process CPU seconds cap)
    var maxOpenFiles: Int? = nil       // ulimit -Hn / -Sn
    var maxFileSizeMB: Int? = nil      // ulimit -Hf / -Sf
    // Private Linux MicroVM Compute & Isolation Overrides
    var vmCPUCount: Int? = nil
    var vmMemoryMB: Int? = nil
    var vmNetworkMode: PrivateVMNetworkMode? = nil
    /// nil = inherit global; "" = explicitly air-gapped; non-empty = custom VirtioFS host folder
    var vmSharedHostPath: String? = nil
    var vmSharedHostReadOnly: Bool? = nil

    static let `default` = SandboxOverrideConfig()

    var cleanedEnvVars: [(key: String, value: String)] {
        var ordered: [String] = []
        var map: [String: String] = [:]
        for e in envVars {
            let k = e.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty,
                  k.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                continue
            }
            if map[k] == nil { ordered.append(k) }
            map[k] = e.value
        }
        return ordered.compactMap { k in map[k].map { (key: k, value: $0) } }
    }

    var hasMacSandboxOverrides: Bool {
        egressMode != nil
            || !extraAllowedDomains.isEmpty
            || blockLocalNetwork != nil
            || secretAccessMode != .inheritGlobal
            || !cleanedEnvVars.isEmpty
            || useGlobalEnvTools != nil
            || !extraReadPaths.isEmpty
            || allowHostGitConfig != nil
            || allowSSHAgent != nil
            || allowDockerSocket != nil
            || cpuPriority != .normal
            || maxCPUSeconds != nil
            || maxOpenFiles != nil
            || maxFileSizeMB != nil
    }

    var hasPrivateVMOverrides: Bool {
        vmCPUCount != nil
            || vmMemoryMB != nil
            || vmNetworkMode != nil
            || vmSharedHostPath != nil
            || vmSharedHostReadOnly != nil
            || !cleanedEnvVars.isEmpty
    }

    var hasResourceLimits: Bool {
        cpuPriority != .normal || maxCPUSeconds != nil || maxOpenFiles != nil || maxFileSizeMB != nil
    }

    func shortBadge(isLinuxVM: Bool) -> String? {
        if isLinuxVM {
            guard hasPrivateVMOverrides else { return nil }
            if vmNetworkMode == .offline { return "Offline" }
            if let c = vmCPUCount, let m = vmMemoryMB {
                let mStr = m >= 1024 ? "\(m / 1024)G" : "\(m)M"
                return "\(c)c·\(mStr)"
            }
            if let c = vmCPUCount { return "\(c) vCPU" }
            if let m = vmMemoryMB { return m >= 1024 ? "\(m / 1024) GB" : "\(m) MB" }
            return "Custom"
        } else {
            guard hasMacSandboxOverrides else { return nil }
            if let mode = egressMode {
                switch mode {
                case .offline: return "Offline"
                case .allowlist: return "Allowlist"
                case .full: break
                }
            }
            if secretAccessMode == .none { return "0 Secrets" }
            if hasResourceLimits { return "Capped" }
            return "Custom"
        }
    }

    init(
        egressMode: EgressNetworkMode? = nil,
        extraAllowedDomains: [String] = [],
        blockLocalNetwork: Bool? = nil,
        secretAccessMode: SessionSecretAccessMode = .inheritGlobal,
        allowedSecretIDs: [UUID] = [],
        envVars: [EnvVarEntry] = [],
        useGlobalEnvTools: Bool? = nil,
        extraReadPaths: [String] = [],
        allowHostGitConfig: Bool? = nil,
        allowSSHAgent: Bool? = nil,
        allowDockerSocket: Bool? = nil,
        cpuPriority: SandboxCPUPriority = .normal,
        maxCPUSeconds: Int? = nil,
        maxOpenFiles: Int? = nil,
        maxFileSizeMB: Int? = nil,
        vmCPUCount: Int? = nil,
        vmMemoryMB: Int? = nil,
        vmNetworkMode: PrivateVMNetworkMode? = nil,
        vmSharedHostPath: String? = nil,
        vmSharedHostReadOnly: Bool? = nil
    ) {
        self.egressMode = egressMode
        self.extraAllowedDomains = extraAllowedDomains
        self.blockLocalNetwork = blockLocalNetwork
        self.secretAccessMode = secretAccessMode
        self.allowedSecretIDs = allowedSecretIDs
        self.envVars = envVars
        self.useGlobalEnvTools = useGlobalEnvTools
        self.extraReadPaths = extraReadPaths
        self.allowHostGitConfig = allowHostGitConfig
        self.allowSSHAgent = allowSSHAgent
        self.allowDockerSocket = allowDockerSocket
        self.cpuPriority = cpuPriority
        self.maxCPUSeconds = maxCPUSeconds
        self.maxOpenFiles = maxOpenFiles
        self.maxFileSizeMB = maxFileSizeMB
        self.vmCPUCount = vmCPUCount
        self.vmMemoryMB = vmMemoryMB
        self.vmNetworkMode = vmNetworkMode
        self.vmSharedHostPath = vmSharedHostPath
        self.vmSharedHostReadOnly = vmSharedHostReadOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.egressMode = try c.decodeIfPresent(EgressNetworkMode.self, forKey: .egressMode)
        self.extraAllowedDomains = try c.decodeIfPresent([String].self, forKey: .extraAllowedDomains) ?? []
        self.blockLocalNetwork = try c.decodeIfPresent(Bool.self, forKey: .blockLocalNetwork)
        self.secretAccessMode = try c.decodeIfPresent(SessionSecretAccessMode.self, forKey: .secretAccessMode) ?? .inheritGlobal
        self.allowedSecretIDs = try c.decodeIfPresent([UUID].self, forKey: .allowedSecretIDs) ?? []
        self.envVars = try c.decodeIfPresent([EnvVarEntry].self, forKey: .envVars) ?? []
        self.useGlobalEnvTools = try c.decodeIfPresent(Bool.self, forKey: .useGlobalEnvTools)
        self.extraReadPaths = try c.decodeIfPresent([String].self, forKey: .extraReadPaths) ?? []
        self.allowHostGitConfig = try c.decodeIfPresent(Bool.self, forKey: .allowHostGitConfig)
        self.allowSSHAgent = try c.decodeIfPresent(Bool.self, forKey: .allowSSHAgent)
        self.allowDockerSocket = try c.decodeIfPresent(Bool.self, forKey: .allowDockerSocket)
        self.cpuPriority = try c.decodeIfPresent(SandboxCPUPriority.self, forKey: .cpuPriority) ?? .normal
        self.maxCPUSeconds = try c.decodeIfPresent(Int.self, forKey: .maxCPUSeconds)
        self.maxOpenFiles = try c.decodeIfPresent(Int.self, forKey: .maxOpenFiles)
        self.maxFileSizeMB = try c.decodeIfPresent(Int.self, forKey: .maxFileSizeMB)
        self.vmCPUCount = try c.decodeIfPresent(Int.self, forKey: .vmCPUCount)
        self.vmMemoryMB = try c.decodeIfPresent(Int.self, forKey: .vmMemoryMB)
        self.vmNetworkMode = try c.decodeIfPresent(PrivateVMNetworkMode.self, forKey: .vmNetworkMode)
        self.vmSharedHostPath = try c.decodeIfPresent(String.self, forKey: .vmSharedHostPath)
        self.vmSharedHostReadOnly = try c.decodeIfPresent(Bool.self, forKey: .vmSharedHostReadOnly)
    }
}

struct BooBoxConfig: Codable, Equatable, Sendable {
    var version: Int = 1
    var general: GeneralConfig = GeneralConfig()
    var ephemeralSetup: EphemeralSetupConfig = EphemeralSetupConfig()
    var sandboxAccess: SandboxAccessConfig = SandboxAccessConfig()
    var privateVM: PrivateVMConfig = PrivateVMConfig()
    var secretsNetwork: SecretsNetworkConfig = SecretsNetworkConfig()
    var packageCache: PackageCacheConfig = PackageCacheConfig()
    var appearance: AppearanceConfig = AppearanceConfig()

    static let `default` = BooBoxConfig()

    init(
        version: Int = 1,
        general: GeneralConfig = GeneralConfig(),
        ephemeralSetup: EphemeralSetupConfig = EphemeralSetupConfig(),
        sandboxAccess: SandboxAccessConfig = SandboxAccessConfig(),
        privateVM: PrivateVMConfig = PrivateVMConfig(),
        secretsNetwork: SecretsNetworkConfig = SecretsNetworkConfig(),
        packageCache: PackageCacheConfig = PackageCacheConfig(),
        appearance: AppearanceConfig = AppearanceConfig()
    ) {
        self.version = version
        self.general = general
        self.ephemeralSetup = ephemeralSetup
        self.sandboxAccess = sandboxAccess
        self.privateVM = privateVM
        self.secretsNetwork = secretsNetwork
        self.packageCache = packageCache
        self.appearance = appearance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
        let ephem = try c.decodeIfPresent(EphemeralSetupConfig.self, forKey: .ephemeralSetup) ?? EphemeralSetupConfig()
        self.ephemeralSetup = ephem
        var access = try c.decodeIfPresent(SandboxAccessConfig.self, forKey: .sandboxAccess) ?? SandboxAccessConfig()
        if access.extraReadPaths.isEmpty && !ephem.sandboxExtraReadPaths.isEmpty {
            access.extraReadPaths = ephem.sandboxExtraReadPaths
        }
        self.sandboxAccess = access
        self.privateVM = try c.decodeIfPresent(PrivateVMConfig.self, forKey: .privateVM) ?? PrivateVMConfig()
        self.secretsNetwork = try c.decodeIfPresent(SecretsNetworkConfig.self, forKey: .secretsNetwork) ?? SecretsNetworkConfig()
        self.packageCache = try c.decodeIfPresent(PackageCacheConfig.self, forKey: .packageCache) ?? PackageCacheConfig()
        self.appearance = try c.decodeIfPresent(AppearanceConfig.self, forKey: .appearance) ?? AppearanceConfig()
    }

    /// Merges per-sandbox overrides onto this global config snapshot without mutating globals.
    func applying(overrides o: SandboxOverrideConfig) -> BooBoxConfig {
        var copy = self

        // Network & Secrets
        if let mode = o.egressMode {
            copy.secretsNetwork.egressMode = mode
        }
        if !o.extraAllowedDomains.isEmpty {
            for dom in o.extraAllowedDomains {
                let cleaned = dom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !cleaned.isEmpty && !copy.secretsNetwork.customAllowedDomains.contains(cleaned) {
                    copy.secretsNetwork.customAllowedDomains.append(cleaned)
                }
            }
        }
        switch o.secretAccessMode {
        case .inheritGlobal:
            break
        case .none:
            copy.secretsNetwork.secrets = []
        case .custom:
            let allowed = Set(o.allowedSecretIDs)
            copy.secretsNetwork.secrets = copy.secretsNetwork.secrets.filter { allowed.contains($0.id) }
        }

        // Sandbox Access & Tools
        if let blockLocal = o.blockLocalNetwork {
            copy.sandboxAccess.blockLocalNetwork = blockLocal
        }
        if let useGlobalTools = o.useGlobalEnvTools {
            copy.sandboxAccess.persistentSandboxTools = useGlobalTools
        }
        if !o.extraReadPaths.isEmpty {
            for p in o.extraReadPaths {
                let cleaned = p.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty && !copy.sandboxAccess.extraReadPaths.contains(cleaned) {
                    copy.sandboxAccess.extraReadPaths.append(cleaned)
                }
            }
        }
        if let git = o.allowHostGitConfig {
            copy.sandboxAccess.allowHostGitConfig = git
        }
        if let ssh = o.allowSSHAgent {
            copy.sandboxAccess.allowSSHAgent = ssh
        }
        if let docker = o.allowDockerSocket {
            copy.sandboxAccess.allowDockerSocket = docker
        }

        // Environment Variables (per-sandbox values win over global keys)
        if !o.envVars.isEmpty {
            var merged = copy.ephemeralSetup.envVars
            for entry in o.envVars {
                let k = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty else { continue }
                merged.removeAll { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) == k }
                merged.append(entry)
            }
            copy.ephemeralSetup.envVars = merged
            copy.ephemeralSetup.injectEnvIntoMacSandbox = true
            if !o.cleanedEnvVars.isEmpty {
                copy.ephemeralSetup.injectEnvIntoPrivateVM = true
            }
        }

        // Private Linux MicroVM Overrides
        if let cpu = o.vmCPUCount {
            copy.privateVM.cpuCount = cpu
        }
        if let ram = o.vmMemoryMB {
            copy.privateVM.memoryMB = ram
        }
        if let vmNet = o.vmNetworkMode {
            copy.privateVM.networkMode = vmNet
        }
        if let path = o.vmSharedHostPath {
            copy.privateVM.sharedHostPath = path
        }
        if let ro = o.vmSharedHostReadOnly {
            copy.privateVM.sharedHostReadOnly = ro
        }

        return copy
    }
}

// MARK: - Ghostty Theme Preview Metadata

struct ThemeRGB: Hashable, Sendable {
    let r: Double
    let g: Double
    let b: Double

    var swiftUIColor: Color {
        Color(red: r, green: g, blue: b)
    }

    var luminance: Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let val = UInt32(cleaned, radix: 16) else { return nil }
        self.r = Double((val >> 16) & 0xFF) / 255.0
        self.g = Double((val >> 8) & 0xFF) / 255.0
        self.b = Double(val & 0xFF) / 255.0
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

struct GhosttyThemeInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let background: ThemeRGB
    let foreground: ThemeRGB
    let palette: [ThemeRGB] // Representative ANSI accents (1..6)

    var isLight: Bool {
        background.luminance > 0.52
    }
}

// MARK: - Config Manager

@MainActor
final class BooBoxConfigManager: ObservableObject {
    static let shared = BooBoxConfigManager()

    static let popularThemeNames: [String] = [
        "Catppuccin Mocha",
        "Catppuccin Macchiato",
        "Catppuccin Frappe",
        "Catppuccin Latte",
        "TokyoNight",
        "TokyoNight Storm",
        "TokyoNight Moon",
        "Rose Pine",
        "Rose Pine Moon",
        "Rose Pine Dawn",
        "Dracula",
        "Gruvbox Dark",
        "Gruvbox Light",
        "Nord",
        "Kanagawa Wave",
        "Kanagawa Dragon",
        "Atom One Dark",
        "Solarized Dark Higher Contrast",
    ]

    @Published var config: BooBoxConfig {
        didSet {
            guard !suppressAutosave, config != oldValue else { return }
            updateThreadSafeSnapshot(config)
            persistConfigToDisk(config)
            _ = writeGhosttyOverlayFile()
            if config.packageCache.enabled {
                ensureCacheDirectories()
            }
            onConfigChanged?(oldValue, config)
        }
    }

    @Published private(set) var availableThemes: [GhosttyThemeInfo] = []
    @Published private(set) var cacheSizeBytes: Int64 = 0
    @Published private(set) var lastStatusMessage: String?

    /// Hook wired by AppDelegate / SessionStore so appearance & VM changes apply immediately.
    var onConfigChanged: ((_ old: BooBoxConfig, _ new: BooBoxConfig) -> Void)?

    let rootDirURL: URL
    let configFileURL: URL
    let ghosttyOverrideURL: URL

    private nonisolated static let snapshotLock = NSLock()
    private nonisolated(unsafe) static var latestSnapshot: BooBoxConfig = .default
    private var suppressAutosave = false

    private init() {
        let realHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
        let root = realHome.appendingPathComponent("boo_box", isDirectory: true)
        self.rootDirURL = root
        self.configFileURL = root.appendingPathComponent("config.json")
        self.ghosttyOverrideURL = root.appendingPathComponent(".ghostty-override.conf")

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let loaded = Self.readConfig(from: configFileURL) ?? .default
        self.suppressAutosave = true
        self.config = loaded
        self.suppressAutosave = false
        updateThreadSafeSnapshot(loaded)

        // Ensure config.json & Ghostty overlay exist on disk right away
        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            persistConfigToDisk(loaded)
        }
        _ = writeGhosttyOverlayFile()
        if loaded.packageCache.enabled {
            ensureCacheDirectories()
        }

        loadAvailableThemesAsync()
        refreshCacheSize()
    }

    /// Thread-safe snapshot readable from any thread/queue without crossing MainActor.
    nonisolated static func currentSnapshot() -> BooBoxConfig {
        snapshotLock.lock()
        let copy = latestSnapshot
        snapshotLock.unlock()
        return copy
    }

    private func updateThreadSafeSnapshot(_ value: BooBoxConfig) {
        Self.snapshotLock.lock()
        Self.latestSnapshot = value
        Self.snapshotLock.unlock()
    }

    // MARK: - Persistence & Reload

    func reloadFromDisk() {
        let old = config
        guard let loaded = Self.readConfig(from: configFileURL) else {
            lastStatusMessage = "Could not parse \(configFileURL.path)"
            return
        }
        suppressAutosave = true
        config = loaded
        suppressAutosave = false
        updateThreadSafeSnapshot(loaded)
        _ = writeGhosttyOverlayFile()
        if loaded.packageCache.enabled {
            ensureCacheDirectories()
        }
        refreshCacheSize()
        onConfigChanged?(old, loaded)
        lastStatusMessage = "Reloaded config.json"
    }

    func resetToDefaults() {
        config = .default
        lastStatusMessage = "Reset to defaults"
    }

    func openConfigInEditor() {
        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            persistConfigToDisk(config)
        }
        NSWorkspace.shared.open(configFileURL)
    }

    func revealConfigInFinder() {
        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            persistConfigToDisk(config)
        }
        NSWorkspace.shared.activateFileViewerSelecting([configFileURL])
    }

    func revealCacheInFinder() {
        let url = config.packageCache.resolvedCacheURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func persistConfigToDisk(_ cfg: BooBoxConfig) {
        try? FileManager.default.createDirectory(at: rootDirURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(cfg) {
            try? data.write(to: configFileURL, options: .atomic)
            chmod(configFileURL.path, 0o600)
        }
    }

    private static func readConfig(from url: URL) -> BooBoxConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BooBoxConfig.self, from: data)
    }

    // MARK: - Ghostty Managed Overlay (.ghostty-override.conf)

    @discardableResult
    func writeGhosttyOverlayFile() -> String? {
        var lines: [String] = [
            "# Managed by boo_box Settings (~/boo_box/config.json)",
            "clipboard-read = ask",
        ]
        if let theme = config.appearance.themeName,
           !theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("theme = \(theme)")
        }
        if let fontSize = config.appearance.fontSize {
            let clamped = min(max(fontSize, 9.0), 32.0)
            lines.append(String(format: "font-size = %.1f", clamped))
        }
        if config.appearance.backgroundOpacity < 0.999 {
            let clamped = min(max(config.appearance.backgroundOpacity, 0.70), 1.0)
            lines.append(String(format: "background-opacity = %.2f", clamped))
        }

        let body = lines.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: rootDirURL, withIntermediateDirectories: true)
            try body.write(to: ghosttyOverrideURL, atomically: true, encoding: .utf8)
            return ghosttyOverrideURL.path
        } catch {
            return nil
        }
    }

    // MARK: - Shared Package Cache Helpers

    func ensureCacheDirectories() {
        let base = config.packageCache.resolvedCacheURL()
        let fm = FileManager.default
        let subdirs = ["pnpm", "npm", "bun", "uv", "pip", "cargo"]
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        for sub in subdirs {
            try? fm.createDirectory(at: base.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    func refreshCacheSize() {
        let base = config.packageCache.resolvedCacheURL()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bytes = Self.directoryByteSize(base)
            DispatchQueue.main.async { [weak self] in
                self?.cacheSizeBytes = bytes
            }
        }
    }

    func clearPackageCache() {
        let base = config.packageCache.resolvedCacheURL()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            if let children = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
                for child in children {
                    try? fm.removeItem(at: child)
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.ensureCacheDirectories()
                self?.refreshCacheSize()
                self?.lastStatusMessage = "Cleared shared package cache"
            }
        }
    }

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file)
    }

    private nonisolated static func directoryByteSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]),
                  vals.isRegularFile == true else { continue }
            total += Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Ghostty Built-In Theme Scanner

    private func loadAvailableThemesAsync() {
        let themesDir = Self.resolveGhosttyThemesDirectory()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let themesDir else { return }
            let parsed = Self.scanGhosttyThemes(in: themesDir)
            DispatchQueue.main.async { [weak self] in
                self?.availableThemes = parsed
            }
        }
    }

    private static func resolveGhosttyThemesDirectory() -> URL? {
        let fm = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"].map { "\($0)/themes" },
            Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes").path,
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        ]
        for case let path? in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    private nonisolated static func scanGhosttyThemes(in directory: URL) -> [GhosttyThemeInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }

        var results: [GhosttyThemeInfo] = []
        results.reserveCapacity(names.count)

        for name in names where !name.hasPrefix(".") {
            let fileURL = directory.appendingPathComponent(name)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            var bg = ThemeRGB(r: 0.11, g: 0.12, b: 0.15)
            var fg = ThemeRGB(r: 0.90, g: 0.92, b: 0.95)
            var paletteMap: [Int: ThemeRGB] = [:]

            for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { continue }
                guard let eqIdx = line.firstIndex(of: "=") else { continue }
                let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
                let val = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

                switch key {
                case "background":
                    if let parsed = ThemeRGB(hex: val) { bg = parsed }
                case "foreground":
                    if let parsed = ThemeRGB(hex: val) { fg = parsed }
                case "palette":
                    if let innerEq = val.firstIndex(of: "="),
                       let idx = Int(val[..<innerEq].trimmingCharacters(in: .whitespaces)),
                       (1...6).contains(idx),
                       let parsed = ThemeRGB(hex: String(val[val.index(after: innerEq)...])) {
                        paletteMap[idx] = parsed
                    }
                default:
                    break
                }
            }

            let orderedAccents = (1...6).compactMap { paletteMap[$0] }
            results.append(GhosttyThemeInfo(
                name: name,
                background: bg,
                foreground: fg,
                palette: orderedAccents.isEmpty ? [fg] : orderedAccents
            ))
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
