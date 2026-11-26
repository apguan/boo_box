import AppKit
import SwiftUI

private enum MCPFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case oauth = "OAuth Apps"
    case tools = "No-Login Tools"

    var id: String { rawValue }
}

@MainActor
private final class ConnectionsUIState: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var mcpFilter: MCPFilter = .all
    @Published var detectedAgents: [MCPAgentTarget] = []
    @Published var oauthConnectedByID: [String: Bool] = [:]
    @Published var mcpInstalledByID: [String: Set<MCPAgentTarget>] = [:]
    @Published var githubAccountLabel: String? = nil

    /// Active OAuth sign-in state (service ID, live message, optional GitHub device code).
    @Published var signingInServiceID: String? = nil
    @Published var signingInMessage: String? = nil
    @Published var signingInDeviceCode: String? = nil

    /// Optional collapsed inline fine-grained PAT override under GitHub.
    @Published var editingGitHubPAT: Bool = false
    @Published var draftGitHubPAT: String = ""

    /// Busy ID for MCP toggle / sync actions.
    @Published var busyID: String? = nil

    @Published var statusBanner: String? = nil
    @Published var statusIsError: Bool = false

    func refreshStatus(config: BooBoxConfig) {
        let mgr = ConnectionsManager.shared
        let oauth = OAuthFlowManager.shared
        let ghLabel = config.connections.accounts.first(where: { $0.id == "github" })?.accountLabel

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let agents = mgr.detectInstalledAgents()

            var oauthMap: [String: Bool] = [:]
            for svc in OAuthFlowManager.oauthServices {
                oauthMap[svc.id] = oauth.isOAuthConnected(svc)
            }

            var mcpMap: [String: Set<MCPAgentTarget>] = [:]
            for preset in ConnectionsManager.mcpPresets {
                mcpMap[preset.id] = mgr.agentsWithMCPInstalled(preset.id)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.detectedAgents = agents
                self.oauthConnectedByID = oauthMap
                self.mcpInstalledByID = mcpMap
                self.githubAccountLabel = ghLabel
            }
        }
    }
}

struct ConnectionsSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @StateObject private var state = ConnectionsUIState()

    /// OAuth MCP services (excluding GitHub, which lives in the dedicated Sandbox Shell Auth card).
    private var oauthMCPServices: [OAuthServicePreset] {
        OAuthFlowManager.oauthServices.filter { $0.id != "github" }
    }

    private var githubService: OAuthServicePreset? {
        OAuthFlowManager.oauthServices.first { $0.id == "github" }
    }

    /// Agent-managed OAuth MCPs (install config in 1 click; agent opens browser OAuth on first call).
    private static let agentOAuthMCPIDs: [String] = ["figma", "slack"]

    /// Zero-login / local MCPs (no external OAuth flow needed).
    private static let noLoginMCPIDs: [String] = [
        "context7",
        "cloudflare-docs",
        "playwright",
        "sequential-thinking",
        "github",
    ]

    private var activeTargetAgents: [MCPAgentTarget] {
        let configured = configManager.config.connections.mcpTargetAgents.compactMap { MCPAgentTarget(rawValue: $0) }
        if !configured.isEmpty { return configured }
        if !state.detectedAgents.isEmpty { return state.detectedAgents }
        return [.omp, .opencode, .claude]
    }

    private var isGitHubConnected: Bool {
        state.oauthConnectedByID["github"] == true
    }

    private var connectedMCPCount: Int {
        let oauthCount = oauthMCPServices.filter { state.oauthConnectedByID[$0.id] == true }.count
        let otherIDs = Self.agentOAuthMCPIDs + Self.noLoginMCPIDs
        let otherCount = otherIDs.filter { !(state.mcpInstalledByID[$0] ?? []).isEmpty }.count
        return oauthCount + otherCount
    }

    private func matchesSearch(_ fields: String...) -> Bool {
        let q = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return fields.contains { $0.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: "Connections",
                    subtitle: "Two clean layers: Sandbox Git auth for your terminal shells, and 1-click MCP servers for your coding agents."
                )

                // Live OAuth in-progress banner (with Cancel + optional GitHub device code)
                if let activeID = state.signingInServiceID, let msg = state.signingInMessage {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(msg)
                                .font(.system(size: 11.5, weight: .medium))
                            if let code = state.signingInDeviceCode {
                                Text("Device code \(code) copied to clipboard — paste it on github.com/login/device.")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Cancel") {
                            OAuthFlowManager.shared.cancelActiveFlow()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                            )
                    )
                    .id("oauth-banner-\(activeID)")
                }

                // Result / error feedback banner
                if let msg = state.statusBanner, state.signingInServiceID == nil {
                    HStack(spacing: 8) {
                        Image(systemName: state.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(state.statusIsError ? .orange : .green)
                        Text(msg)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            state.statusBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((state.statusIsError ? Color.orange : Color.green).opacity(0.11))
                    )
                }

                // SECTION 1: SANDBOX SHELL AUTH (Terminal `git` & `gh` commands)
                if let gh = githubService {
                    SettingsCard(title: "Sandbox Shell Auth (Terminal Commands)") {
                        VStack(alignment: .leading, spacing: 10) {
                            githubShellRow(gh)
                        }
                    }
                }

                // SECTION 2: AGENT MCP SERVERS (Explicitly scoped to OMP / OpenCode / Claude / Codex / Gemini)
                SettingsCard(title: "Agent MCP Servers (\(connectedMCPCount) active)") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Agent target pills + search inside the MCP card so scope is unmistakable
                        HStack(spacing: 6) {
                            Text("Sync to:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            ForEach(MCPAgentTarget.allCases) { agent in
                                let isSelected = activeTargetAgents.contains(agent)
                                let isDetected = state.detectedAgents.contains(agent)
                                Button {
                                    toggleTargetAgent(agent)
                                } label: {
                                    HStack(spacing: 4.5) {
                                        Circle()
                                            .fill(isSelected ? Color(red: 0.25, green: 0.84, blue: 0.72) : Color.secondary.opacity(0.3))
                                            .frame(width: 5.5, height: 5.5)
                                        Text(agent.displayName)
                                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                                    }
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? Color(red: 0.25, green: 0.84, blue: 0.72).opacity(0.16) : Color.primary.opacity(0.05))
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(isDetected ? "\(agent.displayName) detected on this Mac — click to toggle MCP sync" : "Click to include \(agent.displayName) in MCP installs")
                            }
                            Spacer()
                        }

                        // Filter pills + search
                        HStack(spacing: 6) {
                            ForEach(MCPFilter.allCases) { f in
                                let active = state.mcpFilter == f
                                Button(f.rawValue) {
                                    state.mcpFilter = f
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Color.accentColor : .secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                                )
                            }
                            Spacer()
                            HStack(spacing: 5) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                TextField("Filter MCPs…", text: $state.searchQuery)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11.5))
                                    .frame(width: 135)
                                if !state.searchQuery.isEmpty {
                                    Button {
                                        state.searchQuery = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                        }

                        Text("OAuth Apps open browser sign-in from boo_box and sync live tokens directly into OMP & OpenCode (Claude Code, Codex & Gemini register the server URL).")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)

                        // 2a. 1-Click Browser OAuth MCPs
                        if state.mcpFilter == .all || state.mcpFilter == .oauth {
                            let oauthMCPs = oauthMCPServices.filter {
                                matchesSearch($0.name, $0.subtitle, $0.id)
                            }
                            ForEach(Array(oauthMCPs.enumerated()), id: \.element.id) { idx, service in
                                if idx > 0 { Divider() }
                                oauthMCPRow(service)
                            }

                            // Agent-managed OAuth MCPs (Figma, Slack) — honestly labeled
                            let agentOAuths = Self.agentOAuthMCPIDs.compactMap { ConnectionsManager.mcpPreset(id: $0) }.filter {
                                matchesSearch($0.name, $0.subtitle, $0.id)
                            }
                            ForEach(agentOAuths) { preset in
                                Divider()
                                standardMCPRow(preset, badge: "Agent OAuth")
                            }
                        }

                        // 2b. No-Login Local & Docs MCPs
                        if state.mcpFilter == .all || state.mcpFilter == .tools {
                            let tools = Self.noLoginMCPIDs.compactMap { ConnectionsManager.mcpPreset(id: $0) }.filter {
                                matchesSearch($0.name, $0.subtitle, $0.id)
                            }
                            ForEach(Array(tools.enumerated()), id: \.element.id) { idx, preset in
                                if state.mcpFilter == .all || idx > 0 { Divider() }
                                let badge = preset.id == "github" ? "Uses GitHub Auth" : "No Login"
                                standardMCPRow(preset, badge: badge)
                            }
                        }
                    }
                }

                // SECTION 3: CLEAN LINKS TO EXISTING SPECIALIZED TABS (ZERO DUPLICATION)
                HStack(spacing: 12) {
                    jumpLinkButton(
                        title: "LLM API Keys (Proxy Vault)",
                        subtitle: "Anthropic, OpenAI, OpenRouter, Gemini",
                        symbol: "key.fill"
                    ) {
                        SettingsNavState.shared.selectedTab = .secretsNetwork
                    }
                    jumpLinkButton(
                        title: "Custom Shell Env Vars",
                        subtitle: "NPM_TOKEN, FLY_API_TOKEN, etc.",
                        symbol: "shippingbox"
                    ) {
                        SettingsNavState.shared.selectedTab = .setup
                    }
                }
            }
            .padding(22)
        }
        .onAppear {
            state.refreshStatus(config: configManager.config)
        }
        .onChange(of: configManager.config.connections) { _, _ in
            state.refreshStatus(config: configManager.config)
        }
    }

    // MARK: - Section 1: GitHub Shell Row

    private func githubShellRow(_ service: OAuthServicePreset) -> some View {
        let isConnected = isGitHubConnected
        let isSigningIn = state.signingInServiceID == "github"
        let anySigningIn = state.signingInServiceID != nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: service.symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isConnected ? Color(red: 0.25, green: 0.84, blue: 0.72) : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isConnected ? Color(red: 0.25, green: 0.84, blue: 0.72).opacity(0.13) : Color.primary.opacity(0.06))
                    )

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 6) {
                        Text("GitHub (git + gh CLI)")
                            .font(.system(size: 12.5, weight: .semibold))
                        if isConnected {
                            let badge = state.githubAccountLabel.flatMap { $0.isEmpty ? nil : "Connected · \($0)" } ?? "Connected ✓"
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }
                    }
                    Text("Authenticates HTTPS git pull/push and gh CLI across all open & new sandboxes (live hot-reload; token stays in Seatbelt-blocked ~/boo_box/vault).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if isSigningIn {
                        ProgressView().controlSize(.mini)
                        Button("Cancel") {
                            OAuthFlowManager.shared.cancelActiveFlow()
                        }
                        .controlSize(.small)
                    } else if isConnected {
                        Button("Use Scoped PAT") {
                            state.editingGitHubPAT.toggle()
                            state.draftGitHubPAT = ""
                        }
                        .controlSize(.small)
                        Button("Disconnect", role: .destructive) {
                            disconnectOAuthService(service)
                        }
                        .controlSize(.small)
                        .disabled(anySigningIn)
                    } else {
                        Button("Connect") {
                            startOAuthSignIn(service)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(anySigningIn)
                    }
                }
            }

            if state.editingGitHubPAT {
                HStack(spacing: 8) {
                    SecureField("Paste fine-grained PAT (github_pat_…)", text: $state.draftGitHubPAT)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit { saveCustomGitHubPAT() }
                    Button("Save") {
                        saveCustomGitHubPAT()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.draftGitHubPAT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Create PAT ↗") {
                        if let url = URL(string: "https://github.com/settings/personal-access-tokens/new") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 38)
            }
        }
    }

    // MARK: - Section 2: MCP Rows

    private func oauthMCPRow(_ service: OAuthServicePreset) -> some View {
        let isConnected = state.oauthConnectedByID[service.id] == true
        let isSigningIn = state.signingInServiceID == service.id
        let anySigningIn = state.signingInServiceID != nil
        let installedAgents = service.mcpID.flatMap { state.mcpInstalledByID[$0] } ?? []
        let targets = Set(activeTargetAgents)
        let needsAgentSync = isConnected && service.mcpID != nil && !targets.isEmpty && !targets.isSubset(of: installedAgents)

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: service.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isConnected ? Color(red: 0.25, green: 0.84, blue: 0.72) : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(isConnected ? Color(red: 0.25, green: 0.84, blue: 0.72).opacity(0.13) : Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(service.name)
                        .font(.system(size: 12.5, weight: .medium))
                    if isConnected {
                        Text("Connected ✓")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.14)))
                    } else {
                        Text("Browser OAuth")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    ForEach(MCPAgentTarget.allCases.filter { installedAgents.contains($0) }) { agent in
                        Text("\(agent.displayName) ✓")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
                Text(service.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if isSigningIn {
                    ProgressView().controlSize(.mini)
                    Button("Cancel") {
                        OAuthFlowManager.shared.cancelActiveFlow()
                    }
                    .controlSize(.small)
                } else if isConnected {
                    if needsAgentSync, let mcpID = service.mcpID, let mcpPreset = ConnectionsManager.mcpPreset(id: mcpID) {
                        Button("Sync All") {
                            syncExistingOAuthToAgents(service: service, mcpPreset: mcpPreset)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(anySigningIn)
                    }
                    Button("Disconnect", role: .destructive) {
                        disconnectOAuthService(service)
                    }
                    .controlSize(.small)
                    .disabled(anySigningIn)
                } else {
                    Button("Connect") {
                        startOAuthSignIn(service)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(anySigningIn)
                }
            }
        }
    }

    private func standardMCPRow(_ preset: MCPPreset, badge: String) -> some View {
        let installedIn = state.mcpInstalledByID[preset.id] ?? []
        let targets = Set(activeTargetAgents)
        let partiallyInstalled = !installedIn.isEmpty && !targets.isEmpty && !targets.isSubset(of: installedIn)
        let isBusy = state.busyID == "tool:\(preset.id)"
        let needsGitHub = preset.id == "github" && !isGitHubConnected

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: preset.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(!installedIn.isEmpty ? Color.accentColor : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(badge)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(needsGitHub ? .orange : .secondary)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill((needsGitHub ? Color.orange : Color.primary).opacity(needsGitHub ? 0.14 : 0.07)))
                    ForEach(MCPAgentTarget.allCases.filter { installedIn.contains($0) }) { agent in
                        Text("\(agent.displayName) ✓")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.14)))
                    }
                }
                Text(preset.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if isBusy { ProgressView().controlSize(.mini) }
                if !installedIn.isEmpty {
                    if partiallyInstalled {
                        Button("Sync All") {
                            installMCP(preset)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isBusy)
                    }
                    Button("Remove", role: .destructive) {
                        removeMCP(preset)
                    }
                    .controlSize(.small)
                    .disabled(isBusy)
                } else {
                    Button("Enable") {
                        installMCP(preset)
                    }
                    .controlSize(.small)
                    .disabled(isBusy || needsGitHub)
                }
            }
        }
    }

    private func jumpLinkButton(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func toggleTargetAgent(_ agent: MCPAgentTarget) {
        var current = activeTargetAgents
        if let idx = current.firstIndex(of: agent) {
            if current.count > 1 { current.remove(at: idx) }
        } else {
            current.append(agent)
        }
        configManager.config.connections.mcpTargetAgents = current.map(\.rawValue)
    }

    private func startOAuthSignIn(_ service: OAuthServicePreset) {
        let targets = activeTargetAgents
        state.signingInServiceID = service.id
        state.signingInMessage = "Starting \(service.name) browser OAuth…"
        state.signingInDeviceCode = nil
        state.statusBanner = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let msg = try OAuthFlowManager.shared.connectService(
                    service,
                    targetAgents: targets
                ) { event in
                    DispatchQueue.main.async {
                        self.state.signingInMessage = event.message
                        self.state.signingInDeviceCode = event.deviceCode
                    }
                }
                DispatchQueue.main.async {
                    self.state.signingInServiceID = nil
                    self.state.signingInMessage = nil
                    self.state.signingInDeviceCode = nil
                    if service.id == "github" {
                        self.upsertConnectionMetadata(id: "github", envVar: "GH_TOKEN", enabled: true)
                        self.configManager.config.sandboxAccess.allowHostGitConfig = true
                        self.configManager.config.sandboxAccess.shareGHConfig = true
                    }
                    self.configManager.onSyncLiveEnv?()
                    self.state.statusIsError = false
                    self.state.statusBanner = msg
                    self.state.refreshStatus(config: self.configManager.config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.signingInServiceID = nil
                    self.state.signingInMessage = nil
                    self.state.signingInDeviceCode = nil
                    if case OAuthFlowError.cancelled = error {
                        self.state.statusIsError = false
                        self.state.statusBanner = "Cancelled \(service.name) sign-in."
                    } else {
                        self.state.statusIsError = true
                        self.state.statusBanner = error.localizedDescription
                    }
                    self.state.refreshStatus(config: self.configManager.config)
                }
            }
        }
    }

    private func saveCustomGitHubPAT() {
        let token = state.draftGitHubPAT.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ConnectionsManager.shared.saveToken(token, for: "github")
                let label = ConnectionsManager.shared.configureHostGitForGitHub(token: token)
                DispatchQueue.main.async {
                    self.upsertConnectionMetadata(id: "github", envVar: "GH_TOKEN", enabled: true, accountLabel: label)
                    self.configManager.config.sandboxAccess.allowHostGitConfig = true
                    self.configManager.config.sandboxAccess.shareGHConfig = true
                    self.configManager.onSyncLiveEnv?()
                    self.state.draftGitHubPAT = ""
                    self.state.editingGitHubPAT = false
                    self.state.statusIsError = false
                    self.state.statusBanner = "Updated GitHub token in host vault — active across all sandboxes."
                    self.state.refreshStatus(config: self.configManager.config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.statusIsError = true
                    self.state.statusBanner = error.localizedDescription
                }
            }
        }
    }

    private func syncExistingOAuthToAgents(service: OAuthServicePreset, mcpPreset: MCPPreset) {
        let targets = activeTargetAgents
        state.busyID = "sync:\(service.id)"
        DispatchQueue.global(qos: .userInitiated).async {
            var record = OAuthFlowManager.shared.loadTokenRecord(serviceID: service.id)
            if record == nil, case .mcpOAuthDCR(let mcpURL, _) = service.kind {
                record = OAuthFlowManager.shared.readOMPOAuthCredential(serviceID: service.id, mcpURL: mcpURL)
                if let r = record {
                    try? OAuthFlowManager.shared.saveTokenRecord(r)
                }
            }
            if let record {
                OAuthFlowManager.shared.writeOMPOAuthCredential(record: record)
                OAuthFlowManager.shared.writeOpenCodeOAuthCredential(record: record)
            }
            do {
                try ConnectionsManager.shared.installMCP(mcpPreset, into: targets)
                let names = targets.map(\.displayName).joined(separator: ", ")
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = false
                    self.state.statusBanner = "Synced \(service.name) MCP & OAuth credentials to \(names)."
                    self.state.refreshStatus(config: self.configManager.config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = true
                    self.state.statusBanner = error.localizedDescription
                    self.state.refreshStatus(config: self.configManager.config)
                }
            }
        }
    }

    private func disconnectOAuthService(_ service: OAuthServicePreset) {
        let targets = activeTargetAgents
        DispatchQueue.global(qos: .userInitiated).async {
            OAuthFlowManager.shared.disconnectService(service, targetAgents: targets)
            DispatchQueue.main.async {
                if service.id == "github" {
                    self.configManager.config.connections.accounts.removeAll { $0.id == "github" }
                }
                self.configManager.onSyncLiveEnv?()
                self.state.statusIsError = false
                self.state.statusBanner = "Disconnected \(service.name) and removed credentials."
                self.state.refreshStatus(config: self.configManager.config)
            }
        }
    }

    private func installMCP(_ preset: MCPPreset) {
        let targets = activeTargetAgents
        guard !targets.isEmpty else {
            state.statusIsError = true
            state.statusBanner = "Select at least one coding agent above to enable \(preset.name)."
            return
        }
        state.busyID = "tool:\(preset.id)"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ConnectionsManager.shared.installMCP(preset, into: targets)
                let names = targets.map(\.displayName).joined(separator: ", ")
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = false
                    self.state.statusBanner = "Enabled \(preset.name) MCP in \(names)."
                    self.state.refreshStatus(config: self.configManager.config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = true
                    self.state.statusBanner = error.localizedDescription
                    self.state.refreshStatus(config: self.configManager.config)
                }
            }
        }
    }

    private func removeMCP(_ preset: MCPPreset) {
        state.busyID = "tool:\(preset.id)"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ConnectionsManager.shared.removeMCP(preset, from: MCPAgentTarget.allCases)
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = false
                    self.state.statusBanner = "Removed \(preset.name) MCP from all agents."
                    self.state.refreshStatus(config: self.configManager.config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = true
                    self.state.statusBanner = error.localizedDescription
                    self.state.refreshStatus(config: self.configManager.config)
                }
            }
        }
    }

    private func upsertConnectionMetadata(id: String, envVar: String, enabled: Bool, accountLabel: String? = nil) {
        var list = configManager.config.connections.accounts
        if let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].enabled = enabled
            list[idx].envVar = envVar
            if let accountLabel { list[idx].accountLabel = accountLabel }
        } else {
            list.append(ConnectionAccount(id: id, enabled: enabled, envVar: envVar, accountLabel: accountLabel))
        }
        configManager.config.connections.accounts = list
    }
}
