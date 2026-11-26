import AppKit
import SwiftUI

private enum ConnectionsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case apps = "Apps & CLIs"
    case mcps = "MCP Servers"
    case llms = "LLM Providers"

    var id: String { rawValue }
}

@MainActor
private final class ConnectionsViewState: ObservableObject {
    @Published var filter: ConnectionsFilter = .all
    @Published var searchQuery: String = ""
    @Published var editingConnectionID: String? = nil
    @Published var editingLLMEnvVar: String? = nil
    @Published var draftToken: String = ""
    @Published var busyID: String? = nil
    @Published var statusBanner: String? = nil
    @Published var statusIsError: Bool = false

    @Published var detectedAgents: [MCPAgentTarget] = []
    @Published var mcpInstalledByID: [String: Set<MCPAgentTarget>] = [:]
    @Published var keychainPresentByID: [String: Bool] = [:]
    @Published var llmPresentByEnvVar: [String: Bool] = [:]

    func refreshStatus(config: BooBoxConfig) {
        let mgr = ConnectionsManager.shared
        let vault = SecretsVaultManager.shared
        let secrets = config.secretsNetwork.secrets
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let agents = mgr.detectInstalledAgents()
            var mcpMap: [String: Set<MCPAgentTarget>] = [:]
            for preset in ConnectionsManager.mcpPresets {
                mcpMap[preset.id] = mgr.agentsWithMCPInstalled(preset.id)
            }
            var kcMap: [String: Bool] = [:]
            for preset in ConnectionsManager.connectionPresets {
                kcMap[preset.id] = mgr.hasToken(for: preset.id)
            }
            var llmMap: [String: Bool] = [:]
            for p in VaultSecretEntry.presets where !p.baseURLVar.isEmpty {
                if let existing = secrets.first(where: { $0.envVar == p.envVar }) {
                    llmMap[p.envVar] = (existing.source == .keychain)
                        ? vault.hasKeychainSecret(for: existing.id)
                        : existing.onePasswordRef.hasPrefix("op://")
                } else {
                    llmMap[p.envVar] = false
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.detectedAgents = agents
                self.mcpInstalledByID = mcpMap
                self.keychainPresentByID = kcMap
                self.llmPresentByEnvVar = llmMap
            }
        }
    }
}

/// Unified 1-click Connections hub in Settings:
///   • Keychain-backed CLI & account logins (GitHub, Cloudflare, Vercel, Supabase, Linear, Stripe, …)
///   • 1-Click MCP Server installer synced across installed coding agents (OMP, OpenCode, Claude, Codex, Gemini)
///   • Proxy-protected LLM Providers (Anthropic, OpenAI, OpenRouter, Gemini — phantom tokens only in sandboxes)
struct ConnectionsSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @StateObject private var state = ConnectionsViewState()

    private var llmPresets: [VaultSecretEntry.Preset] {
        VaultSecretEntry.presets.filter { !$0.baseURLVar.isEmpty }
    }

    private var activeTargetAgents: [MCPAgentTarget] {
        let configured = configManager.config.connections.mcpTargetAgents.compactMap(MCPAgentTarget.init(rawValue:))
        if !configured.isEmpty { return configured }
        return state.detectedAgents.isEmpty ? [.omp] : state.detectedAgents
    }

    private var connectedAccountCount: Int {
        configManager.config.connections.accounts.filter { $0.enabled && state.keychainPresentByID[$0.id] == true }.count
            + state.llmPresentByEnvVar.values.filter { $0 }.count
    }

    private var installedMCPCount: Int {
        state.mcpInstalledByID.values.filter { !$0.isEmpty }.count
    }

    private func matchesSearch(_ fields: String...) -> Bool {
        let q = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        let joined = fields.joined(separator: " ").lowercased()
        return q.split(separator: " ").allSatisfy { joined.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    SettingsHeader(
                        title: "Connections",
                        subtitle: "1-click setup for accounts, CLIs, MCP servers, and proxy-protected LLM keys. All tokens stay in macOS Keychain — never plaintext in config.json."
                    )
                    Spacer()
                }

                // Status & filter bar
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        summaryPill("\(connectedAccountCount) connected", color: Color(red: 0.25, green: 0.84, blue: 0.72), symbol: "checkmark.shield.fill")
                        summaryPill("\(installedMCPCount) MCPs active", color: .accentColor, symbol: "puzzlepiece.extension.fill")
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            TextField("Filter apps or MCPs…", text: $state.searchQuery)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .frame(width: 150)
                            if !state.searchQuery.isEmpty {
                                Button { state.searchQuery = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10.5))
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

                    HStack(spacing: 6) {
                        ForEach(ConnectionsFilter.allCases) { tab in
                            Button {
                                state.filter = tab
                            } label: {
                                Text(tab.rawValue)
                                    .font(.system(size: 11.5, weight: state.filter == tab ? .semibold : .regular))
                                    .foregroundStyle(state.filter == tab ? Color.primary : Color.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4.5)
                                    .background(
                                        Capsule()
                                            .fill(state.filter == tab ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.05))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }

                if let msg = state.statusBanner {
                    HStack(spacing: 8) {
                        Image(systemName: state.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(state.statusIsError ? Color.red : Color.green)
                        Text(msg)
                            .font(.system(size: 11.5))
                            .foregroundStyle(state.statusIsError ? Color.red : Color.primary)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((state.statusIsError ? Color.red : Color.green).opacity(0.11))
                    )
                }

                // 1. Apps & CLIs (Keychain-backed)
                if state.filter == .all || state.filter == .apps {
                    let apps = ConnectionsManager.connectionPresets.filter {
                        matchesSearch($0.name, $0.subtitle, $0.envVar, $0.id)
                    }
                    if !apps.isEmpty {
                        SettingsCard(title: "Apps & CLI Accounts (macOS Keychain)") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Tokens are stored encrypted in macOS Keychain (`dev.boo-box.connections`) and injected via private `0600` `.boobox-env.sh` into every new sandbox (automatically withheld on `None / 0 secrets` tabs).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                ForEach(Array(apps.enumerated()), id: \.element.id) { idx, preset in
                                    if idx > 0 { Divider() }
                                    connectionAppRow(preset)
                                }
                            }
                        }
                    }
                }

                // 2. 1-Click MCP Servers (Multi-Agent Sync)
                if state.filter == .all || state.filter == .mcps {
                    let mcps = ConnectionsManager.mcpPresets.filter {
                        matchesSearch($0.name, $0.subtitle, $0.id, $0.transport.badgeLabel)
                    }
                    if !mcps.isEmpty {
                        SettingsCard(title: "1-Click MCP Servers (Multi-Agent Sync)") {
                            VStack(alignment: .leading, spacing: 10) {
                                // Target agent selector bar
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
                                            HStack(spacing: 4) {
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
                                        .help(isDetected ? "\(agent.displayName) detected on this Mac — click to toggle MCP sync" : "Click to include \(agent.displayName) in 1-click MCP installs")
                                    }
                                    Spacer()
                                }

                                Text("Writes clean non-destructive entries into your shared agent configs (`~/.omp/agent/mcp.json`, `~/.config/opencode/opencode.json`, `~/.claude.json`, `~/.codex/config.toml`, `~/.gemini/settings.json`) and shares `~/.mcp-auth` so OAuth MCP logins persist across every sandbox.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                ForEach(Array(mcps.enumerated()), id: \.element.id) { idx, preset in
                                    if idx > 0 { Divider() }
                                    mcpServerRow(preset)
                                }
                            }
                        }
                    }
                }

                // 3. LLM Providers (Proxy-Protected Phantom Tokens)
                if state.filter == .all || state.filter == .llms {
                    let llms = llmPresets.filter {
                        matchesSearch($0.label, $0.envVar, $0.allowedHosts.joined(separator: " "))
                    }
                    if !llms.isEmpty {
                        SettingsCard(title: "LLM Providers (Proxy-Protected Phantom Tokens)") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Real API keys stay strictly on your host Mac in Keychain and are injected by `boobox-proxy` only on bound provider hosts. Sandboxes only ever see worthless `bbx_ph_…` phantom tokens.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                ForEach(Array(llms.enumerated()), id: \.element.id) { idx, preset in
                                    if idx > 0 { Divider() }
                                    llmProviderRow(preset)
                                }
                            }
                        }
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

    // MARK: - Row Builders

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
        )
    }

    private func connectionAppRow(_ preset: ConnectionPreset) -> some View {
        let acct = configManager.config.connections.accounts.first { $0.id == preset.id }
        let hasKey = state.keychainPresentByID[preset.id] == true
        let isConnected = hasKey && (acct?.enabled ?? false)
        let isEditing = state.editingConnectionID == preset.id
        let isBusy = state.busyID == preset.id

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isConnected ? Color(red: 0.25, green: 0.84, blue: 0.72) : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.name)
                            .font(.system(size: 12.5, weight: .medium))
                        Text(preset.envVar)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if isConnected {
                            let label = acct?.accountLabel.flatMap { $0.isEmpty ? nil : "Connected · \($0)" } ?? "Connected"
                            Text(label)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        } else if hasKey && acct?.enabled == false {
                            Text("Paused")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                    }
                    Text(preset.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView().controlSize(.mini)
                    }
                    if preset.supportsHostImport && !isConnected {
                        Button("Import") {
                            importHostConnection(preset)
                        }
                        .controlSize(.small)
                        .disabled(isBusy)
                        .help(preset.hostImportHint ?? "Import existing local CLI login into Keychain")
                    }
                    if isConnected || hasKey {
                        Toggle("", isOn: Binding(
                            get: { acct?.enabled ?? false },
                            set: { enabled in toggleConnectionEnabled(preset, enabled: enabled) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()

                        Button("Update") {
                            state.editingLLMEnvVar = nil
                            state.editingConnectionID = isEditing ? nil : preset.id
                            state.draftToken = ""
                        }
                        .controlSize(.small)

                        Button("Remove", role: .destructive) {
                            disconnectApp(preset)
                        }
                        .controlSize(.small)
                    } else {
                        Button(isEditing ? "Cancel" : "Connect") {
                            state.editingLLMEnvVar = nil
                            state.editingConnectionID = isEditing ? nil : preset.id
                            state.draftToken = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            if isEditing {
                HStack(spacing: 8) {
                    SecureField(preset.placeholder, text: $state.draftToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit {
                            saveConnectionToken(preset)
                        }

                    Button("Save to Keychain") {
                        saveConnectionToken(preset)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.draftToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)

                    Button("Get Token ↗") {
                        if let url = URL(string: preset.tokenURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 34)
            }
        }
    }

    private func mcpServerRow(_ preset: MCPPreset) -> some View {
        let installedIn = state.mcpInstalledByID[preset.id] ?? []
        let targets = Set(activeTargetAgents)
        let fullyInstalled = !targets.isEmpty && targets.isSubset(of: installedIn)
        let partiallyInstalled = !installedIn.isEmpty && !fullyInstalled
        let isBusy = state.busyID == "mcp:\(preset.id)"
        let needsConnection = preset.linkedConnectionID.map { id in
            if case .stdio(_, _, _?) = preset.transport {
                return state.keychainPresentByID[id] != true
            }
            return false
        } ?? false

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: preset.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(!installedIn.isEmpty ? Color.accentColor : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.system(size: 12.5, weight: .medium))

                    Text(preset.transport.badgeLabel)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
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

                    if needsConnection, let linkID = preset.linkedConnectionID {
                        Text("Connect \(linkID.capitalized) token above")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                Text(preset.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                }
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
                    Button("1-Click Install") {
                        installMCP(preset)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy)
                }
            }
        }
    }

    private func llmProviderRow(_ preset: VaultSecretEntry.Preset) -> some View {
        let isConnected = state.llmPresentByEnvVar[preset.envVar] == true
        let isEditing = state.editingLLMEnvVar == preset.envVar

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isConnected ? Color(red: 0.25, green: 0.84, blue: 0.72) : .secondary)
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
                            Text("Proxy Protected")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }
                    }
                    Text("Bound exclusively to \(preset.allowedHosts.joined(separator: ", ")) via `\(preset.baseURLVar)`.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isConnected {
                    Button("Rotate Key") {
                        state.editingConnectionID = nil
                        state.editingLLMEnvVar = isEditing ? nil : preset.envVar
                        state.draftToken = ""
                    }
                    .controlSize(.small)

                    Button("Remove", role: .destructive) {
                        removeLLMProvider(preset)
                    }
                    .controlSize(.small)
                } else {
                    Button(isEditing ? "Cancel" : "Connect") {
                        state.editingConnectionID = nil
                        state.editingLLMEnvVar = isEditing ? nil : preset.envVar
                        state.draftToken = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if isEditing {
                HStack(spacing: 8) {
                    SecureField("Paste \(preset.label) API key…", text: $state.draftToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit {
                            saveLLMProviderKey(preset)
                        }

                    Button("Save to Vault") {
                        saveLLMProviderKey(preset)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.draftToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 34)
            }
        }
    }

    // MARK: - Actions

    private func toggleTargetAgent(_ agent: MCPAgentTarget) {
        var current = Set(activeTargetAgents)
        if current.contains(agent) {
            if current.count > 1 { current.remove(agent) }
        } else {
            current.insert(agent)
        }
        configManager.config.connections.mcpTargetAgents = MCPAgentTarget.allCases
            .filter { current.contains($0) }
            .map(\.rawValue)
    }

    private func saveConnectionToken(_ preset: ConnectionPreset) {
        let token = state.draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        state.busyID = preset.id
        state.statusBanner = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ConnectionsManager.shared.saveToken(token, for: preset.id)
                var label = "Keychain"
                if preset.id == "github" {
                    if let login = ConnectionsManager.shared.configureHostGitForGitHub(token: token) {
                        label = login
                    } else {
                        label = "PAT"
                    }
                }
                DispatchQueue.main.async {
                    self.upsertConnectionConfig(preset: preset, label: label)
                    self.state.draftToken = ""
                    self.state.editingConnectionID = nil
                    self.state.busyID = nil
                    self.state.statusIsError = false
                    self.state.statusBanner = "\(preset.name) saved in macOS Keychain — active in all new sandboxes."
                    self.state.refreshStatus(config: self.configManager.config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = true
                    self.state.statusBanner = error.localizedDescription
                }
            }
        }
    }

    private func importHostConnection(_ preset: ConnectionPreset) {
        state.busyID = preset.id
        state.statusBanner = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let imported = try ConnectionsManager.shared.importFromHostCLI(connectionID: preset.id)
                try ConnectionsManager.shared.saveToken(imported.token, for: preset.id)
                DispatchQueue.main.async {
                    self.upsertConnectionConfig(preset: preset, label: imported.label)
                    self.state.busyID = nil
                    self.state.statusIsError = false
                    self.state.statusBanner = "Imported \(preset.name) (\(imported.label)) into macOS Keychain — active in all new sandboxes."
                    self.state.refreshStatus(config: self.configManager.config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = true
                    self.state.statusBanner = error.localizedDescription
                }
            }
        }
    }

    private func upsertConnectionConfig(preset: ConnectionPreset, label: String) {
        var accounts = configManager.config.connections.accounts
        if let idx = accounts.firstIndex(where: { $0.id == preset.id }) {
            accounts[idx].enabled = true
            accounts[idx].envVar = preset.envVar
            accounts[idx].accountLabel = label
        } else {
            accounts.append(ConnectionAccount(id: preset.id, enabled: true, envVar: preset.envVar, accountLabel: label))
        }
        configManager.config.connections.accounts = accounts
        if preset.id == "github" {
            configManager.config.sandboxAccess.allowHostGitConfig = true
            configManager.config.sandboxAccess.shareGHConfig = true
        }
    }

    private func toggleConnectionEnabled(_ preset: ConnectionPreset, enabled: Bool) {
        var accounts = configManager.config.connections.accounts
        if let idx = accounts.firstIndex(where: { $0.id == preset.id }) {
            accounts[idx].enabled = enabled
        } else if enabled {
            accounts.append(ConnectionAccount(id: preset.id, enabled: true, envVar: preset.envVar, accountLabel: "Keychain"))
        }
        configManager.config.connections.accounts = accounts
    }

    private func disconnectApp(_ preset: ConnectionPreset) {
        ConnectionsManager.shared.deleteToken(for: preset.id)
        configManager.config.connections.accounts.removeAll { $0.id == preset.id }
        state.editingConnectionID = nil
        state.statusIsError = false
        state.statusBanner = "Removed \(preset.name) token from macOS Keychain."
        state.refreshStatus(config: configManager.config)
    }

    private func installMCP(_ preset: MCPPreset) {
        let targets = activeTargetAgents
        state.busyID = "mcp:\(preset.id)"
        state.statusBanner = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ConnectionsManager.shared.installMCP(preset, into: targets)
                let names = targets.map(\.displayName).joined(separator: ", ")
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = false
                    self.state.statusBanner = "Installed \(preset.name) MCP into \(names)."
                    self.state.refreshStatus(config: self.configManager.config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = true
                    self.state.statusBanner = "Failed to install \(preset.name) MCP: \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeMCP(_ preset: MCPPreset) {
        state.busyID = "mcp:\(preset.id)"
        state.statusBanner = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ConnectionsManager.shared.removeMCP(preset, from: MCPAgentTarget.allCases)
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = false
                    self.state.statusBanner = "Removed \(preset.name) MCP from agent configs."
                    self.state.refreshStatus(config: self.configManager.config)
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.busyID = nil
                    self.state.statusIsError = true
                    self.state.statusBanner = "Failed to remove \(preset.name) MCP: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveLLMProviderKey(_ preset: VaultSecretEntry.Preset) {
        let key = state.draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        var secrets = configManager.config.secretsNetwork.secrets
        let entryID: UUID
        if let idx = secrets.firstIndex(where: { $0.envVar == preset.envVar }) {
            entryID = secrets[idx].id
            secrets[idx].enabled = true
            secrets[idx].source = .keychain
            secrets[idx].allowedHosts = preset.allowedHosts
            secrets[idx].baseURLVar = preset.baseURLVar
            secrets[idx].baseURLPathPrefix = preset.baseURLPathPrefix
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
            try SecretsVaultManager.shared.saveKeychainSecret(key, for: entryID)
            configManager.config.secretsNetwork.proxyEnabled = true
            configManager.config.secretsNetwork.secrets = secrets
            SecretsVaultManager.shared.syncPolicyToProxy(blocking: false)
            state.draftToken = ""
            state.editingLLMEnvVar = nil
            state.statusIsError = false
            state.statusBanner = "\(preset.label) key saved in Host Vault — sandboxes receive phantom tokens only."
            state.refreshStatus(config: configManager.config)
        } catch {
            state.statusIsError = true
            state.statusBanner = error.localizedDescription
        }
    }

    private func removeLLMProvider(_ preset: VaultSecretEntry.Preset) {
        var secrets = configManager.config.secretsNetwork.secrets
        if let idx = secrets.firstIndex(where: { $0.envVar == preset.envVar }) {
            SecretsVaultManager.shared.deleteKeychainSecret(for: secrets[idx].id)
            secrets.remove(at: idx)
            configManager.config.secretsNetwork.secrets = secrets
            SecretsVaultManager.shared.syncPolicyToProxy(blocking: false)
        }
        state.editingLLMEnvVar = nil
        state.statusIsError = false
        state.statusBanner = "Removed \(preset.label) from Host Vault."
        state.refreshStatus(config: configManager.config)
    }
}
