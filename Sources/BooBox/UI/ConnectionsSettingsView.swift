import AppKit
import SwiftUI

@MainActor
private final class ConnectionsUIState: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var detectedAgents: [MCPAgentTarget] = []
    @Published var oauthConnectedByID: [String: Bool] = [:]
    @Published var mcpInstalledByID: [String: Set<MCPAgentTarget>] = [:]
    @Published var keychainPresentByID: [String: Bool] = [:]
    @Published var llmPresentByEnv: [String: Bool] = [:]

    /// Active OAuth sign-in flow state (service ID, live status message, optional GitHub device code).
    @Published var signingInServiceID: String? = nil
    @Published var signingInMessage: String? = nil
    @Published var signingInDeviceCode: String? = nil

    /// Busy ID for non-OAuth toggles/advanced saves.
    @Published var busyID: String? = nil

    /// Collapsed by default so the default view stays 100% 1-click OAuth!
    @Published var showAdvanced: Bool = false
    @Published var editingAdvancedID: String? = nil
    @Published var editingLLMEnvVar: String? = nil
    @Published var draftToken: String = ""

    @Published var statusBanner: String? = nil
    @Published var statusIsError: Bool = false

    func refreshStatus(config: BooBoxConfig) {
        let mgr = ConnectionsManager.shared
        let oauth = OAuthFlowManager.shared
        let vault = SecretsVaultManager.shared
        let secrets = config.secretsNetwork.secrets

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

            var keyMap: [String: Bool] = [:]
            for preset in ConnectionsManager.connectionPresets {
                keyMap[preset.id] = mgr.hasToken(for: preset.id)
            }

            var llmMap: [String: Bool] = [:]
            for preset in VaultSecretEntry.presets {
                if let entry = secrets.first(where: { $0.envVar == preset.envVar }) {
                    llmMap[preset.envVar] = (entry.source == .keychain && vault.hasKeychainSecret(for: entry.id))
                        || (entry.source == .onePassword && !entry.onePasswordRef.isEmpty)
                } else {
                    llmMap[preset.envVar] = false
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.detectedAgents = agents
                self.oauthConnectedByID = oauthMap
                self.mcpInstalledByID = mcpMap
                self.keychainPresentByID = keyMap
                self.llmPresentByEnv = llmMap
            }
        }
    }
}

struct ConnectionsSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @StateObject private var state = ConnectionsUIState()

    private static let instantToolIDs: [String] = [
        "context7",
        "cloudflare-docs",
        "playwright",
        "sequential-thinking",
        "figma",
        "slack",
    ]

    private static let advancedManualCLIs: [String] = [
        "github",
        "npm",
        "fly",
        "exa",
        "firecrawl",
    ]

    private var activeTargetAgents: [MCPAgentTarget] {
        let configured = configManager.config.connections.mcpTargetAgents.compactMap { MCPAgentTarget(rawValue: $0) }
        if !configured.isEmpty { return configured }
        if !state.detectedAgents.isEmpty { return state.detectedAgents }
        return [.omp, .opencode, .claude]
    }

    private var connectedOAuthCount: Int {
        OAuthFlowManager.oauthServices.filter { state.oauthConnectedByID[$0.id] == true }.count
    }

    private var activeToolsCount: Int {
        Self.instantToolIDs.filter { !(state.mcpInstalledByID[$0] ?? []).isEmpty }.count
    }

    private func matchesSearch(_ fields: String...) -> Bool {
        let q = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return fields.contains { $0.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack(alignment: .top) {
                    SettingsHeader(
                        title: "Connections",
                        subtitle: "1-click browser OAuth for your tools and coding agents. Credentials stay in macOS Keychain and sync across every sandbox."
                    )
                    Spacer()
                }

                // Compact status + search bar
                HStack(spacing: 8) {
                    summaryPill("\(connectedOAuthCount) connected", color: Color(red: 0.25, green: 0.84, blue: 0.72), symbol: "checkmark.shield.fill")
                    if activeToolsCount > 0 {
                        summaryPill("\(activeToolsCount) tools active", color: .accentColor, symbol: "puzzlepiece.extension.fill")
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("Search apps & tools…", text: $state.searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 155)
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
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                }

                // Target agent selector pills
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
                            .padding(.horizontal, 8.5)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color(red: 0.25, green: 0.84, blue: 0.72).opacity(0.16) : Color.primary.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                        .help(isDetected ? "\(agent.displayName) detected on this Mac — click to toggle sync" : "Click to include \(agent.displayName) in 1-click OAuth sync")
                    }
                    Spacer()
                }

                // Live OAuth in-progress banner (with Cancel button & GitHub device code if applicable)
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
                            cancelOAuthSignIn()
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

                // 1. HERO: 1-Click OAuth Connections (ZERO API key pasting!)
                let oauthItems = OAuthFlowManager.oauthServices.filter {
                    matchesSearch($0.name, $0.subtitle, $0.id)
                }
                if !oauthItems.isEmpty {
                    SettingsCard(title: "1-Click OAuth Connections") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(oauthItems.enumerated()), id: \.element.id) { idx, service in
                                if idx > 0 { Divider() }
                                oauthServiceRow(service)
                            }
                        }
                    }
                }

                // 2. Instant Tools (No Login Required / Agent-Managed)
                let instantTools = Self.instantToolIDs.compactMap { ConnectionsManager.mcpPreset(id: $0) }.filter {
                    matchesSearch($0.name, $0.subtitle, $0.id)
                }
                if !instantTools.isEmpty {
                    SettingsCard(title: "Instant Tools & Docs") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(instantTools.enumerated()), id: \.element.id) { idx, preset in
                                if idx > 0 { Divider() }
                                instantToolRow(preset)
                            }
                        }
                    }
                }

                // 3. Collapsed Disclosure: Advanced LLM API Keys & Manual Tokens
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            state.showAdvanced.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: state.showAdvanced ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text("Advanced: LLM API Keys & Manual Tokens")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Keychain / Proxy Vault")
                                .font(.system(size: 10.5))
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

                    if state.showAdvanced {
                        advancedSection
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

    // MARK: - 1-Click OAuth Row

    private func oauthServiceRow(_ service: OAuthServicePreset) -> some View {
        let isConnected = state.oauthConnectedByID[service.id] == true
        let isSigningIn = state.signingInServiceID == service.id
        let anySigningIn = state.signingInServiceID != nil
        let installedAgents = service.mcpID.flatMap { state.mcpInstalledByID[$0] } ?? []
        let targets = Set(activeTargetAgents)
        let needsAgentSync = isConnected && service.mcpID != nil && !targets.isEmpty && !targets.isSubset(of: installedAgents)

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: service.symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isConnected ? Color(red: 0.25, green: 0.84, blue: 0.72) : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isConnected ? Color(red: 0.25, green: 0.84, blue: 0.72).opacity(0.13) : Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(service.name)
                        .font(.system(size: 12.5, weight: .semibold))

                    if isConnected {
                        Text("Connected ✓")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.green.opacity(0.14)))
                    } else {
                        Text("OAuth")
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
                        cancelOAuthSignIn()
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

    // MARK: - Instant Tool Row

    private func instantToolRow(_ preset: MCPPreset) -> some View {
        let installedIn = state.mcpInstalledByID[preset.id] ?? []
        let targets = Set(activeTargetAgents)
        let partiallyInstalled = !installedIn.isEmpty && !targets.isEmpty && !targets.isSubset(of: installedIn)
        let isBusy = state.busyID == "tool:\(preset.id)"

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: preset.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(!installedIn.isEmpty ? Color.accentColor : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(preset.transport.badgeLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
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
                            installInstantTool(preset)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isBusy)
                    }
                    Button("Remove", role: .destructive) {
                        removeInstantTool(preset)
                    }
                    .controlSize(.small)
                    .disabled(isBusy)
                } else {
                    Button("Enable") {
                        installInstantTool(preset)
                    }
                    .controlSize(.small)
                    .disabled(isBusy)
                }
            }
        }
    }

    // MARK: - Advanced Section (LLM API Keys & Manual CLI Tokens)

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "LLM Providers (Proxy-Protected Phantom Tokens)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Real API keys stay strictly on your host Mac in Keychain and are swapped by boobox-proxy only on bound provider hosts. Sandboxes only see worthless bbx_ph_… phantom tokens.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(Array(VaultSecretEntry.presets.enumerated()), id: \.element.id) { idx, preset in
                        if idx > 0 { Divider() }
                        llmProviderRow(preset)
                    }
                }
            }

            SettingsCard(title: "Manual CLI Tokens (Services Without OAuth)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Optional Keychain-backed tokens for registries and CLIs that don't support browser OAuth (or to override GitHub with a repo-scoped fine-grained PAT).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    let manuals = Self.advancedManualCLIs.compactMap { ConnectionsManager.connectionPreset(id: $0) }
                    ForEach(Array(manuals.enumerated()), id: \.element.id) { idx, preset in
                        if idx > 0 { Divider() }
                        manualTokenRow(preset)
                    }
                }
            }
        }
    }

    private func llmProviderRow(_ preset: VaultSecretEntry.Preset) -> some View {
        let isConnected = state.llmPresentByEnv[preset.envVar] == true
        let isEditing = state.editingLLMEnvVar == preset.envVar

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isConnected ? .green : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.label)
                            .font(.system(size: 12.5, weight: .medium))
                        Text(preset.envVar)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if isConnected {
                            Text("Proxy Protected ✓")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }
                    }
                    Text("Injected via boobox-proxy only to \(preset.allowedHosts.joined(separator: ", ")).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if isConnected {
                        Button(isEditing ? "Cancel" : "Update") {
                            if isEditing {
                                state.editingLLMEnvVar = nil
                                state.draftToken = ""
                            } else {
                                state.editingAdvancedID = nil
                                state.editingLLMEnvVar = preset.envVar
                                state.draftToken = ""
                            }
                        }
                        .controlSize(.small)
                        Button("Remove", role: .destructive) {
                            removeLLMKey(preset)
                        }
                        .controlSize(.small)
                    } else {
                        Button(isEditing ? "Cancel" : "Add Key") {
                            if isEditing {
                                state.editingLLMEnvVar = nil
                                state.draftToken = ""
                            } else {
                                state.editingAdvancedID = nil
                                state.editingLLMEnvVar = preset.envVar
                                state.draftToken = ""
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            if isEditing {
                HStack(spacing: 8) {
                    SecureField("Paste \(preset.label) API key…", text: $state.draftToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit { saveLLMKey(preset) }
                    Button("Save to Vault") {
                        saveLLMKey(preset)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.draftToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 34)
            }
        }
    }

    private func manualTokenRow(_ preset: ConnectionPreset) -> some View {
        let hasKey = state.keychainPresentByID[preset.id] == true
        let isEditing = state.editingAdvancedID == preset.id

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hasKey ? .green : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.id == "github" ? "GitHub (Custom PAT Override)" : preset.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(preset.envVar)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if hasKey {
                            Text("Saved ✓")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }
                    }
                    Text(preset.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if preset.supportsHostImport && !hasKey {
                        Button("Import") {
                            importManualCLI(preset)
                        }
                        .controlSize(.small)
                    }
                    Button(isEditing ? "Cancel" : (hasKey ? "Update" : "Set Token")) {
                        if isEditing {
                            state.editingAdvancedID = nil
                            state.draftToken = ""
                        } else {
                            state.editingLLMEnvVar = nil
                            state.editingAdvancedID = preset.id
                            state.draftToken = ""
                        }
                    }
                    .controlSize(.small)
                    if hasKey {
                        Button("Remove", role: .destructive) {
                            removeManualToken(preset)
                        }
                        .controlSize(.small)
                    }
                }
            }

            if isEditing {
                HStack(spacing: 8) {
                    SecureField(preset.placeholder, text: $state.draftToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit { saveManualToken(preset) }
                    Button("Save to Keychain") {
                        saveManualToken(preset)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.draftToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Get Token ↗") {
                        if let url = URL(string: preset.tokenURL) { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 34)
            }
        }
    }

    private func summaryPill(_ text: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.13))
                .overlay(Capsule().strokeBorder(color.opacity(0.24), lineWidth: 1))
        )
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

    private func cancelOAuthSignIn() {
        OAuthFlowManager.shared.cancelActiveFlow()
    }

    private func syncExistingOAuthToAgents(service: OAuthServicePreset, mcpPreset: MCPPreset) {
        let targets = activeTargetAgents
        state.busyID = "sync:\(service.id)"
        DispatchQueue.global(qos: .userInitiated).async {
            if let record = OAuthFlowManager.shared.loadTokenRecord(serviceID: service.id) {
                OAuthFlowManager.shared.writeOMPOAuthCredential(record: record)
                OAuthFlowManager.shared.writeOpenCodeOAuthCredential(record: record)
            }
            do {
                try ConnectionsManager.shared.installMCP(mcpPreset, into: targets)
                let names = targets.map(\.displayName).joined(separator: ", ")
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = false
                    self.state.statusBanner = "Synced \(service.name) to \(names)."
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
                self.state.statusBanner = "Disconnected \(service.name) and removed OAuth credentials."
                self.state.refreshStatus(config: self.configManager.config)
            }
        }
    }

    private func installInstantTool(_ preset: MCPPreset) {
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
                    self.state.statusBanner = "Enabled \(preset.name) in \(names)."
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

    private func removeInstantTool(_ preset: MCPPreset) {
        state.busyID = "tool:\(preset.id)"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ConnectionsManager.shared.removeMCP(preset, from: MCPAgentTarget.allCases)
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = false
                    self.state.statusBanner = "Removed \(preset.name) from all agents."
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

    private func importManualCLI(_ preset: ConnectionPreset) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let imported = try ConnectionsManager.shared.importFromHostCLI(connectionID: preset.id)
                try ConnectionsManager.shared.saveToken(imported.token, for: preset.id)
                if preset.id == "github" {
                    _ = ConnectionsManager.shared.configureHostGitForGitHub(token: imported.token)
                }
                DispatchQueue.main.async {
                    self.upsertConnectionMetadata(id: preset.id, envVar: preset.envVar, enabled: true, accountLabel: imported.label)
                    self.configManager.onSyncLiveEnv?()
                    self.state.statusIsError = false
                    self.state.statusBanner = "Imported \(preset.name) into host vault."
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

    private func saveManualToken(_ preset: ConnectionPreset) {
        let token = state.draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try ConnectionsManager.shared.saveToken(token, for: preset.id)
            if preset.id == "github" {
                _ = ConnectionsManager.shared.configureHostGitForGitHub(token: token)
                configManager.config.sandboxAccess.allowHostGitConfig = true
                configManager.config.sandboxAccess.shareGHConfig = true
            }
            upsertConnectionMetadata(id: preset.id, envVar: preset.envVar, enabled: true)
            configManager.onSyncLiveEnv?()
            state.draftToken = ""
            state.editingAdvancedID = nil
            state.statusIsError = false
            state.statusBanner = "Saved \(preset.name) token in host vault."
            state.refreshStatus(config: configManager.config)
        } catch {
            state.statusIsError = true
            state.statusBanner = error.localizedDescription
        }
    }

    private func removeManualToken(_ preset: ConnectionPreset) {
        ConnectionsManager.shared.deleteToken(for: preset.id)
        configManager.config.connections.accounts.removeAll { $0.id == preset.id }
        configManager.onSyncLiveEnv?()
        state.editingAdvancedID = nil
        state.statusIsError = false
        state.statusBanner = "Removed \(preset.name) token from host vault."
        state.refreshStatus(config: configManager.config)
    }

    private func saveLLMKey(_ preset: VaultSecretEntry.Preset) {
        let token = state.draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        var secrets = configManager.config.secretsNetwork.secrets
        let entryID: UUID
        if let idx = secrets.firstIndex(where: { $0.envVar == preset.envVar }) {
            entryID = secrets[idx].id
            secrets[idx].source = .keychain
            secrets[idx].enabled = true
        } else {
            let newEntry = VaultSecretEntry(
                envVar: preset.envVar,
                source: .keychain,
                allowedHosts: preset.allowedHosts,
                baseURLVar: preset.baseURLVar,
                baseURLPathPrefix: preset.baseURLPathPrefix,
                enabled: true
            )
            entryID = newEntry.id
            secrets.append(newEntry)
        }
        do {
            try SecretsVaultManager.shared.saveKeychainSecret(token, for: entryID)
        } catch {
            state.statusIsError = true
            state.statusBanner = "Could not store \(preset.label) key in Keychain: \(error.localizedDescription)"
            return
        }
        configManager.config.secretsNetwork.proxyEnabled = true
        configManager.config.secretsNetwork.secrets = secrets
        state.draftToken = ""
        state.editingLLMEnvVar = nil
        state.statusIsError = false
        state.statusBanner = "Connected \(preset.label) via Host Vault proxy (phantom token only inside sandboxes)."
        state.refreshStatus(config: configManager.config)
    }

    private func removeLLMKey(_ preset: VaultSecretEntry.Preset) {
        var secrets = configManager.config.secretsNetwork.secrets
        if let idx = secrets.firstIndex(where: { $0.envVar == preset.envVar }) {
            SecretsVaultManager.shared.deleteKeychainSecret(for: secrets[idx].id)
            secrets.remove(at: idx)
            configManager.config.secretsNetwork.secrets = secrets
        }
        state.editingLLMEnvVar = nil
        state.statusIsError = false
        state.statusBanner = "Removed \(preset.label) from Host Vault."
        state.refreshStatus(config: configManager.config)
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
