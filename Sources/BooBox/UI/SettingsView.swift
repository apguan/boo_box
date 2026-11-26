import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case connections = "Connections"
    case secretsNetwork = "Secrets & Network"
    case privateVM = "Private VM"
    case globalEnv = "Global Env"
    case access = "Sandbox Access"
    case setup = "Ephemeral Setup"
    case cache = "Package Cache"
    case themes = "Themes"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .connections: "link.circle.fill"
        case .secretsNetwork: "key.fill"
        case .privateVM: "cpu"
        case .globalEnv: "cube.box"
        case .access: "lock.shield"
        case .setup: "shippingbox"
        case .cache: "internaldrive"
        case .themes: "paintpalette"
        }
    }
}

@MainActor
final class SettingsNavState: ObservableObject {
    static let shared = SettingsNavState()
    @Published var selectedTab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @ObservedObject private var nav = SettingsNavState.shared
    var body: some View {
        HStack(spacing: 0) {
            // Left navigation rail
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.25, green: 0.84, blue: 0.72))
                    VStack(alignment: .leading, spacing: 0.5) {
                        Text("boo_box")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text("Settings")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)

                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        nav.selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 16)
                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: nav.selectedTab == tab ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer()
                        }
                        .foregroundStyle(nav.selectedTab == tab ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(nav.selectedTab == tab ? Color.primary.opacity(0.11) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    Button {
                        configManager.openConfigInEditor()
                    } label: {
                        Label("Open config.json", systemImage: "doc.text")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        configManager.reloadFromDisk()
                    } label: {
                        Label("Reload from Disk", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 8)
            .frame(width: 196)
            .background(Color.primary.opacity(0.035))

            Divider()

            Group {
                switch nav.selectedTab {
                case .general:
                    GeneralSettingsTab(configManager: configManager)
                case .connections:
                    ConnectionsSettingsTab(configManager: configManager)
                case .secretsNetwork:
                    SecretsNetworkSettingsTab(configManager: configManager)
                case .privateVM:
                    PrivateVMSettingsTab(configManager: configManager)
                case .globalEnv:
                    GlobalEnvSettingsTab(configManager: configManager)
                case .access:
                    SandboxAccessSettingsTab(configManager: configManager)
                case .setup:
                    EphemeralSetupSettingsTab(configManager: configManager)
                case .cache:
                    PackageCacheSettingsTab(configManager: configManager)
                case .themes:
                    ThemesSettingsTab(configManager: configManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 560)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @ObservedObject private var updateManager = UpdateManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: "General",
                    subtitle: "Semantic session naming, auto-updates, safety prompts, and config management."
                )

                SettingsCard(title: "Sessions") {
                    SettingsToggleRow(
                        title: "Semantic auto-naming for sessions",
                        subtitle: "Automatically names sessions from repo, Git branch, sub-package, or agent title (e.g. my-app · feat/auth) until you manually rename.",
                        isOn: $configManager.config.general.autoNameSessions
                    )
                    Divider()

                    SettingsToggleRow(
                        title: "Persistent detached sessions (booboxd)",
                        subtitle: "Runs macOS Sandbox shells & coding agents inside a detached PTY daemon so live processes survive app quits, crashes, and auto-updates with scrollback replay.",
                        isOn: $configManager.config.general.persistentSessionsEnabled
                    )

                    Divider()

                    SettingsToggleRow(
                        title: "Reopen active sessions on launch",
                        subtitle: "Automatically restores your open tabs (reattaching straight to live booboxd sessions) and remembers window size/position across restarts.",
                        isOn: $configManager.config.general.restoreSessionsOnLaunch
                    )

                    Divider()

                    SettingsToggleRow(
                        title: "macOS notifications for background tabs",
                        subtitle: "Shows clickable notifications and a Dock badge when unfocused tabs finish long commands (≥5s), ring bells, emit agent alerts, or block secret leaks.",
                        isOn: $configManager.config.general.desktopNotificationsEnabled
                    )

                    Divider()

                    SettingsToggleRow(
                        title: "Confirm before permanently deleting sessions",
                        subtitle: "Shows a warning alert explaining that the entire session folder will be deleted. Re-enable this here if you previously checked \"Don't ask again\".",
                        isOn: $configManager.config.general.confirmBeforeDeletingSession
                    )

                    Divider()

                    SettingsToggleRow(
                        title: "Confirm before opening websites from sandboxes",
                        subtitle: "Shows a dismissible prompt when clicking http(s) links inside sandboxed tabs (non-web URL schemes always ask). Re-enable here if you checked \"Don't ask again\".",
                        isOn: $configManager.config.general.confirmOpeningWebLinks
                    )
                }
                SettingsCard(title: "Updates (\(updateManager.repoSlug))") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsToggleRow(
                            title: "Automatically check for updates",
                            subtitle: "Checks github.com/\(updateManager.repoSlug) on launch and every 6 hours. Turn off to disable all automatic update checks.",
                            isOn: $configManager.config.general.autoUpdateEnabled
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "Auto-download verified release updates",
                            subtitle: "When a signed GitHub Release .zip is published, download and stage it automatically. Local main-branch updates always ask first.",
                            isOn: $configManager.config.general.autoDownloadUpdates
                        )
                        .disabled(!configManager.config.general.autoUpdateEnabled)
                        .opacity(configManager.config.general.autoUpdateEnabled ? 1 : 0.5)

                        Divider()

                        HStack(spacing: 8) {
                            let commitBadge = updateManager.currentCommit.isEmpty
                                ? "v\(updateManager.currentVersion)"
                                : "v\(updateManager.currentVersion) · \(updateManager.currentCommit)"
                            Text(commitBadge)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )

                            updateStatusBadge

                            Spacer()

                            Button("GitHub") {
                                NSWorkspace.shared.open(updateManager.repoURL)
                            }
                            .controlSize(.small)

                            if case .available(let update) = updateManager.state {
                                Button(update.installButtonTitle) {
                                    updateManager.installAvailableUpdate()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            Button("Check Now") {
                                updateManager.checkForUpdates(userInitiated: true)
                            }
                            .controlSize(.small)
                            .disabled(isUpdateBusy)
                        }

                        if case .downloading(let progress, let version) = updateManager.state {
                            ProgressView(value: progress) {
                                Text("Downloading \(version) (\(Int(progress * 100))%)…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .controlSize(.small)
                        } else if case .installing(let msg) = updateManager.state {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        } else if case .error(let msg) = updateManager.state {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }

                SettingsCard(title: "Project Workspaces (boo <dir>)") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Workspace isolation engine")
                                    .font(.system(size: 12.5, weight: .medium))
                                Text("Instant CoW Overlay mounts any size folder (even multi-million-file monorepos or entire partitions) in ~20 ms via read-only host lower layer + isolated upper layer. APFS Full Clone creates a frozen point-in-time copy.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Picker("", selection: $configManager.config.general.workspaceMode) {
                                ForEach(WorkspaceIsolationMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 245)
                        }
                    }

                    Divider()

                    SettingsToggleRow(
                        title: "Exclude .env* files from host folder",
                        subtitle: "Off by default so local dev servers work immediately. Turn on (or run `boo --no-env .`) to hide host `.env` / `.env.local` while keeping `.env.example` (you can still create sandbox-local `.env` files).",
                        isOn: $configManager.config.general.excludeEnvFilesWhenCloning
                    )

                    if configManager.config.general.workspaceMode == .apfsClone {
                        Divider()

                        SettingsToggleRow(
                            title: "Slim APFS clone (skip node_modules & build caches)",
                            subtitle: "Only applies in APFS Full Clone mode. Skips heavy ignored dirs for faster cold clones.",
                            isOn: $configManager.config.general.skipHeavyDirsWhenCloning
                        )
                    }
                }

                SettingsCard(title: "Configuration File") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("~/boo_box/config.json")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                            Spacer()
                            Button("Reveal") {
                                configManager.revealConfigInFinder()
                            }
                            .controlSize(.small)
                            Button("Edit in Text Editor") {
                                configManager.openConfigInEditor()
                            }
                            .controlSize(.small)
                        }

                        Text("All settings are stored as pretty-printed JSON so you can version, back up, or hand-edit them directly.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Reload from Disk") {
                                configManager.reloadFromDisk()
                            }
                            .controlSize(.small)

                            Spacer()

                            Button("Reset All Settings to Defaults", role: .destructive) {
                                configManager.resetToDefaults()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private var isUpdateBusy: Bool {
        switch updateManager.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var updateStatusBadge: some View {
        switch updateManager.state {
        case .idle:
            Text(configManager.config.general.autoUpdateEnabled ? "Auto-update on" : "Auto-update off")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let date):
            Text("Up to date · \(date.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .available(let update):
            Text("Update available: \(update.version)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
        case .downloading(_, let version):
            Text("Downloading \(version)…")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        case .installing:
            Text("Installing…")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        case .error:
            Text("Check failed")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Secrets & Network Tab (Host Vault + boobox-proxy Sidecar)

@MainActor
private final class SecretsNetworkViewState: ObservableObject {
    @Published var newEnvVar = ""
    @Published var newSource: VaultSecretSource = .keychain
    @Published var newSecretValue = ""
    @Published var newOnePasswordRef = ""
    @Published var newAllowedHosts = ""
    @Published var newBaseURLVar = ""
    @Published var newBaseURLPrefix = ""
    @Published var newDomainText = ""
    @Published var statusMessage: String?
    @Published var statusIsError = false
    @Published var proxyPort: UInt16?
    @Published var auditEvents: [ProxyAuditEventItem] = []
}

private struct SecretsNetworkSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @StateObject private var state = SecretsNetworkViewState()
    private let mintAccent = Color(red: 0.25, green: 0.84, blue: 0.72)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: "Secrets & Network",
                    subtitle: "Keep real API keys on your host in Keychain or 1Password while sandboxes only ever see worthless phantom tokens (bbx_ph_...) swapped at boobox-proxy."
                )

                // 1. Egress Proxy & Firewall
                SettingsCard(title: "Egress Proxy Sidecar (boobox-proxy)") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(state.proxyPort != nil ? mintAccent : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(state.proxyPort.map { "Running on 127.0.0.1:\(String($0))" } ?? "Sidecar stopped")
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            Spacer()
                            Toggle("", isOn: $configManager.config.secretsNetwork.proxyEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Outbound Network Policy (macOS Sandboxes)")
                                .font(.system(size: 12, weight: .medium))
                            Picker("", selection: $configManager.config.secretsNetwork.egressMode) {
                                ForEach(EgressNetworkMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text(configManager.config.secretsNetwork.egressMode.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if configManager.config.secretsNetwork.egressMode == .full {
                            Divider()
                            SettingsToggleRow(
                                title: "Strict Seatbelt proxy lock in Full mode",
                                subtitle: "Denies direct outbound IP sockets so even curl --noproxy '*' must pass through boobox-proxy for audit logging (always enforced in Dev Allowlist and Offline modes).",
                                isOn: $configManager.config.secretsNetwork.strictProxyRouting
                            )
                        }

                        if configManager.config.secretsNetwork.egressMode == .allowlist {
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Custom Allowed Domains (added to built-in LLM + npm/PyPI/crates/Go/GitHub allowlist)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 6) {
                                    TextField("api.stripe.com or *.vercel.com", text: $state.newDomainText)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .onSubmit { addCustomDomain() }
                                    Button("Add Domain") { addCustomDomain() }
                                        .controlSize(.small)
                                        .disabled(state.newDomainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }

                                if !configManager.config.secretsNetwork.customAllowedDomains.isEmpty {
                                    FlowChipLayout(spacing: 6) {
                                        ForEach(configManager.config.secretsNetwork.customAllowedDomains, id: \.self) { domain in
                                            HStack(spacing: 4) {
                                                Text(domain)
                                                    .font(.system(size: 10.5, design: .monospaced))
                                                Button {
                                                    configManager.config.secretsNetwork.customAllowedDomains.removeAll { $0 == domain }
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 8.5, weight: .bold))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // 2. Host Secret Vault
                SettingsCard(title: "Host Secret Vault (Phantom-Token Injection)") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Real secrets stay in macOS Keychain or 1Password (`op://`) and are NEVER written to `config.json` or sandbox files. Sending a phantom token to any host outside its allowed list is hard-blocked (`403`).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            Text("Presets:")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            ForEach(VaultSecretEntry.presets) { preset in
                                Button(preset.label) {
                                    state.newEnvVar = preset.envVar
                                    state.newAllowedHosts = preset.allowedHosts.joined(separator: ", ")
                                    state.newBaseURLVar = preset.baseURLVar
                                    state.newBaseURLPrefix = preset.baseURLPathPrefix
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("ENV_VAR (e.g. ANTHROPIC_API_KEY)", text: $state.newEnvVar)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                Picker("", selection: $state.newSource) {
                                    ForEach(VaultSecretSource.allCases) { src in
                                        Text(src.label).tag(src)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 155)
                            }

                            if state.newSource == .keychain {
                                SecureField("Secret value (saved to macOS Keychain)", text: $state.newSecretValue)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                            } else {
                                HStack(spacing: 6) {
                                    TextField("op://Vault/Item/credential", text: $state.newOnePasswordRef)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11.5, design: .monospaced))
                                    if !SecretsVaultManager.shared.isOnePasswordAvailable {
                                        Text("`op` CLI not installed")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }

                            HStack(spacing: 8) {
                                TextField("Allowed hosts (e.g. api.anthropic.com)", text: $state.newAllowedHosts)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                TextField("Base URL var (optional)", text: $state.newBaseURLVar)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(width: 175)
                            }

                            HStack {
                                if let msg = state.statusMessage {
                                    Text(msg)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(state.statusIsError ? Color.orange : mintAccent)
                                }
                                Spacer()
                                Button("Save Secret to Vault") {
                                    addVaultSecret()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(mintAccent)
                                .controlSize(.small)
                                .disabled(!canSaveNewSecret)
                            }
                        }

                        if !configManager.config.secretsNetwork.secrets.isEmpty {
                            Divider()
                            VStack(spacing: 8) {
                                ForEach($configManager.config.secretsNetwork.secrets) { $entry in
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: $entry.enabled)
                                            .toggleStyle(.switch)
                                            .controlSize(.mini)
                                            .labelsHidden()

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(entry.envVar)
                                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                                Text(entry.source == .keychain ? "Keychain" : "1Password")
                                                    .font(.system(size: 9.5, weight: .medium))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1.5)
                                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                                                    .foregroundStyle(.secondary)
                                                if !entry.baseURLVar.isEmpty {
                                                    Text("→ \(entry.baseURLVar)")
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundStyle(mintAccent)
                                                }
                                            }
                                            Text("Allowed hosts: \(entry.allowedHosts.joined(separator: ", "))")
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Button(role: .destructive) {
                                            deleteVaultSecret(entry)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                }
                            }
                        }
                    }
                }

                // 3. Live Egress Audit Log
                SettingsCard(title: "Live Egress Activity") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(state.auditEvents.count) recent request(s)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Refresh") { refreshProxyState() }
                                .controlSize(.mini)
                            Button("Clear") {
                                SecretsVaultManager.shared.clearAuditEvents {
                                    state.auditEvents = []
                                }
                            }
                            .controlSize(.mini)
                            .disabled(state.auditEvents.isEmpty)
                        }

                        if state.auditEvents.isEmpty {
                            Text("No proxied requests recorded yet.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(state.auditEvents.prefix(20)) { ev in
                                    HStack(spacing: 8) {
                                        Text(ev.formattedTime)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(badgeText(for: ev.decision))
                                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(badgeColor(for: ev.decision))
                                            .frame(width: 66, alignment: .leading)
                                        Text(ev.host)
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(ev.reason)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .onAppear { refreshProxyState() }
        .onChange(of: configManager.config.secretsNetwork.proxyEnabled) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { refreshProxyState() }
        }
    }

    private var canSaveNewSecret: Bool {
        let env = state.newEnvVar.trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = state.newAllowedHosts.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !env.isEmpty, !hosts.isEmpty else { return false }
        switch state.newSource {
        case .keychain:
            return !state.newSecretValue.isEmpty
        case .onePassword:
            return state.newOnePasswordRef.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("op://")
        }
    }

    private func addVaultSecret() {
        let envVar = state.newEnvVar.trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = state.newAllowedHosts
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !envVar.isEmpty, !hosts.isEmpty else { return }

        let entryID = UUID()
        if state.newSource == .keychain {
            do {
                try SecretsVaultManager.shared.saveKeychainSecret(state.newSecretValue, for: entryID)
            } catch {
                state.statusMessage = error.localizedDescription
                state.statusIsError = true
                return
            }
        }

        let entry = VaultSecretEntry(
            id: entryID,
            envVar: envVar,
            source: state.newSource,
            onePasswordRef: state.newSource == .onePassword ? state.newOnePasswordRef.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            allowedHosts: hosts,
            baseURLVar: state.newBaseURLVar.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURLPathPrefix: state.newBaseURLPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: true
        )
        configManager.config.secretsNetwork.secrets.append(entry)
        state.newEnvVar = ""
        state.newSecretValue = ""
        state.newOnePasswordRef = ""
        state.newAllowedHosts = ""
        state.newBaseURLVar = ""
        state.newBaseURLPrefix = ""
        state.statusMessage = "Saved \(envVar) to host vault (new sandboxes get a phantom token)"
        state.statusIsError = false
        refreshProxyState()
    }

    private func deleteVaultSecret(_ entry: VaultSecretEntry) {
        if entry.source == .keychain {
            SecretsVaultManager.shared.deleteKeychainSecret(for: entry.id)
        }
        configManager.config.secretsNetwork.secrets.removeAll { $0.id == entry.id }
    }

    private func addCustomDomain() {
        let cleaned = state.newDomainText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return }
        if !configManager.config.secretsNetwork.customAllowedDomains.contains(cleaned) {
            configManager.config.secretsNetwork.customAllowedDomains.append(cleaned)
        }
        state.newDomainText = ""
    }

    private func refreshProxyState() {
        state.proxyPort = SecretsVaultManager.shared.currentProxyPort
        SecretsVaultManager.shared.fetchAuditEvents { events in
            state.auditEvents = events
        }
    }

    private func badgeText(for decision: String) -> String {
        switch decision {
        case "secret_injected": "SECRET"
        case "leak_blocked": "LEAK!"
        case "blocked": "BLOCKED"
        default: "ALLOW"
        }
    }

    private func badgeColor(for decision: String) -> Color {
        switch decision {
        case "secret_injected": mintAccent
        case "leak_blocked": .red
        case "blocked": .orange
        default: .secondary
        }
    }
}

// MARK: - Private Linux MicroVM Tab

private struct PrivateVMSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager

    private var memoryOptionsMB: [Int] {
        let maxMB = PrivateVMConfig.maxMemoryMB
        return [512, 1024, 2048, 4096, 8192, 16384].filter { $0 <= maxMB }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: "Private Linux MicroVM",
                    subtitle: "Configure CPU, memory, networking, warm pool, and optional VirtioFS sharing for arm64 Linux microVMs (`⌘⌥N`). Changes apply to newly created VMs."
                )

                SettingsCard(title: "Compute & Warm Pool") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Virtual CPUs")
                                    .font(.system(size: 12.5, weight: .medium))
                                Text("Allocated vCPU cores per Linux microVM (host has \(PrivateVMConfig.maxCPUCount) cores).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Stepper(
                                "\(configManager.config.privateVM.clampedCPUCount) vCPU",
                                value: $configManager.config.privateVM.cpuCount,
                                in: 1...PrivateVMConfig.maxCPUCount
                            )
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Memory (RAM)")
                                    .font(.system(size: 12.5, weight: .medium))
                                Text("Lazily faulted by Apple Silicon Virtualization.framework (only used pages consume host RAM).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $configManager.config.privateVM.memoryMB) {
                                ForEach(memoryOptionsMB, id: \.self) { mb in
                                    Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }

                        Divider()

                        SettingsToggleRow(
                            title: "Keep 1 standby warm VM ready",
                            subtitle: "Pre-boots one idle Alpine Linux VM after your first Private VM launch so subsequent `⌘⌥N` presses open in <1 ms. Turn off to save ~40 MB idle RAM.",
                            isOn: $configManager.config.privateVM.prewarmPool
                        )
                    }
                }

                SettingsCard(title: "Network Isolation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $configManager.config.privateVM.networkMode) {
                            ForEach(PrivateVMNetworkMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text(configManager.config.privateVM.networkMode.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsCard(title: "Optional Host Folder Share (VirtioFS → /mnt/host)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Private VMs are air-gapped from your Mac by default. Optionally share one folder via VirtioFS mounted at `/mnt/host` inside the guest.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Text(configManager.config.privateVM.sharedHostPath.isEmpty
                                 ? "None (air-gapped)"
                                 : configManager.config.privateVM.sharedHostPath)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(configManager.config.privateVM.sharedHostPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )

                            Button("Browse…") { pickSharedVMFolder() }
                                .controlSize(.small)

                            if !configManager.config.privateVM.sharedHostPath.isEmpty {
                                Button("Clear") {
                                    configManager.config.privateVM.sharedHostPath = ""
                                }
                                .controlSize(.small)
                            }
                        }

                        if !configManager.config.privateVM.sharedHostPath.isEmpty {
                            SettingsToggleRow(
                                title: "Mount shared folder Read-Only",
                                subtitle: "Recommended. Unchecking grants the Linux VM write access to the selected Mac folder.",
                                isOn: $configManager.config.privateVM.sharedHostReadOnly
                            )
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func pickSharedVMFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Host Folder to Share into Private VM (/mnt/host)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        configManager.config.privateVM.sharedHostPath = resolved.hasPrefix(home + "/")
            ? "~/" + String(resolved.dropFirst(home.count + 1))
            : resolved
    }
}

// MARK: - Ephemeral Box Setup Tab

@MainActor
private final class SetupInputState: ObservableObject {
    @Published var newEnvKey = ""
    @Published var newEnvValue = ""
    @Published var showNewValue = false
}

@MainActor
private final class EnvVarRowState: ObservableObject {
    @Published var isRevealed = false
    @Published var justCopied = false
}

private struct EphemeralSetupSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @StateObject private var input = SetupInputState()
    @FocusState private var focusNewValue: Bool
    private let suggestedEnvVars = [
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "OPENROUTER_API_KEY",
        "GEMINI_API_KEY",
        "GITHUB_TOKEN",
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: "Ephemeral Box Setup",
                    subtitle: "Define what gets installed and executed automatically in every new Private VM or macOS Sandbox session."
                )

                SettingsCard(title: "Private VM — Startup Script (/bin/sh)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Runs automatically inside every new Private VM (Alpine Linux; base includes zsh, git, curl, python3, ripgrep, jq, vim). Logs saved to `/var/log/boobox-setup.log`.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        CodeEditorBox(
                            text: $configManager.config.ephemeralSetup.privateVMSetupScript,
                            placeholder: "# Example:\n# apk add --no-cache nodejs npm tmux\n# git config --global init.defaultBranch main"
                        )
                    }
                }

                SettingsCard(title: "macOS Sandbox — First-Run Setup Script (/bin/zsh)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Runs once inside `sandbox-exec` the first time a new macOS Sandbox session opens (never re-runs on saved session resume).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        CodeEditorBox(
                            text: $configManager.config.ephemeralSetup.sandboxSetupScript,
                            placeholder: "# Example:\n# git config --global init.defaultBranch main"
                        )
                    }
                }

                SettingsCard(title: "Environment Variables") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Loaded via a private `0600` `.boobox-env.sh` file sourced by `.zshrc` (never exposed in `ps` args). Stored owner-only (`0600`) in `~/boo_box/config.json`.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 16) {
                            Toggle("macOS Sandbox sessions", isOn: $configManager.config.ephemeralSetup.injectEnvIntoMacSandbox)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11.5, weight: .medium))
                            Toggle("Private VMs (Linux)", isOn: $configManager.config.ephemeralSetup.injectEnvIntoPrivateVM)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .padding(.bottom, 2)

                        if !configManager.config.ephemeralSetup.envVars.isEmpty {
                            VStack(spacing: 6) {
                                ForEach($configManager.config.ephemeralSetup.envVars) { $entry in
                                    EnvVarRowView(
                                        entry: $entry,
                                        onDelete: {
                                            let targetID = entry.id
                                            configManager.config.ephemeralSetup.envVars.removeAll { $0.id == targetID }
                                        }
                                    )
                                }
                            }
                        }
                        // New KEY = VALUE entry row
                        HStack(spacing: 6) {
                            TextField("NAME", text: $input.newEnvKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                                .frame(width: 170)
                                .onSubmit { focusNewValue = true }

                            Text("=")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)

                            Group {
                                if input.showNewValue {
                                    TextField("value", text: $input.newEnvValue)
                                } else {
                                    SecureField("value", text: $input.newEnvValue)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .focused($focusNewValue)
                            .onSubmit { addEnvVar() }

                            Button {
                                input.showNewValue.toggle()
                            } label: {
                                Image(systemName: input.showNewValue ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help(input.showNewValue ? "Hide value" : "Show value")

                            Button("Add") { addEnvVar() }
                                .controlSize(.small)
                                .disabled(input.newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        HStack(spacing: 6) {
                            Text("Quick key:")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                            FlowChipLayout(spacing: 5) {
                                ForEach(suggestedEnvVars, id: \.self) { key in
                                    Button {
                                        input.newEnvKey = key
                                        focusNewValue = true
                                    } label: {
                                        Text(key)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2.5)
                                            .background(Capsule().fill(Color.primary.opacity(0.055)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func addEnvVar() {
        let cleanedKey = input.newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else { return }
        if let idx = configManager.config.ephemeralSetup.envVars.firstIndex(where: { $0.key == cleanedKey }) {
            configManager.config.ephemeralSetup.envVars[idx].value = input.newEnvValue
        } else {
            configManager.config.ephemeralSetup.envVars.append(
                EnvVarEntry(key: cleanedKey, value: input.newEnvValue)
            )
        }
        input.newEnvKey = ""
        input.newEnvValue = ""
        input.showNewValue = false
    }
}

private struct EnvVarRowView: View {
    @Binding var entry: EnvVarEntry
    let onDelete: () -> Void
    @StateObject private var state = EnvVarRowState()

    var body: some View {
        HStack(spacing: 6) {
            TextField("NAME", text: $entry.key)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .frame(width: 170)

            Text("=")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)

            Group {
                if state.isRevealed {
                    TextField("value", text: $entry.value)
                } else {
                    SecureField("value", text: $entry.value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5, design: .monospaced))

            Button {
                state.isRevealed.toggle()
            } label: {
                Image(systemName: state.isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(state.isRevealed ? Color.primary : Color.secondary)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help(state.isRevealed ? "Hide value" : "Show value")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.value, forType: .string)
                state.justCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    state.justCopied = false
                }
            } label: {
                Image(systemName: state.justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(state.justCopied ? Color(red: 0.25, green: 0.84, blue: 0.72) : Color.secondary)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Copy value")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Delete variable")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }
}


// MARK: - Sandbox Access Tab

// MARK: - Global Env Tab

@MainActor
private final class GlobalEnvViewState: ObservableObject {
    @Published var inventory: GlobalEnvInventory = .empty
    @Published var isLoading = false
    @Published var installScript = ""
    @Published var isRunningAction = false
    @Published var outputLog: String? = nil
    @Published var outputIsError = false
}

private struct GlobalEnvSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @StateObject private var state = GlobalEnvViewState()

    private let mintAccent = Color(red: 0.25, green: 0.84, blue: 0.72)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: "Global Sandbox Environment",
                    subtitle: "Run any install script inside an isolated sandbox targeting ~/boo_box/env. Every directory with executables is automatically discovered and added to PATH across all sessions."
                )

                SettingsCard(title: "Install Into Global Env (Sandboxed)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste any install command (curl | sh, npm i -g, bun add -g, uv tool install, go install, cargo install, tarball extract…). Runs inside Seatbelt with HOME=\(configManager.config.sandboxAccess.sandboxToolsPath) — your Mac stays untouched.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        CodeEditorBox(
                            text: $state.installScript,
                            placeholder: "# Example:\n# curl -LsSf https://astral.sh/uv/install.sh | sh\n# npm install -g @openai/codex"
                        )
                        .frame(height: 82)

                        HStack(spacing: 8) {
                            Text("boo env run '<script>'  ·  boo env shell  ·  boo tools")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer()
                            Button(state.isRunningAction ? "Running…" : "Run in Sandbox") {
                                runScript(state.installScript)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(
                                state.isRunningAction
                                    || !configManager.config.sandboxAccess.persistentSandboxTools
                                    || state.installScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }

                        if state.isRunningAction {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Executing inside Seatbelt sandbox (HOME=\(configManager.config.sandboxAccess.sandboxToolsPath))…")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } else if let log = state.outputLog, !log.isEmpty {
                            ScrollView {
                                Text(log)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(state.outputIsError ? Color.orange : mintAccent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 96)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                    }
                }

                SettingsCard(title: "Installed Toolchains (by Directory Path)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("\(state.inventory.directories.count) path\(state.inventory.directories.count == 1 ? "" : "s") · \(state.inventory.totalBinaries) executable\(state.inventory.totalBinaries == 1 ? "" : "s") on sandbox PATH")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                refreshInventory()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(state.isLoading)
                            .help("Rescan ~/boo_box/env for executable directories")
                        }

                        if state.inventory.directories.isEmpty {
                            Text("No custom toolchains installed yet. Paste an install command above or run boo env run '<script>' — agents can also install global tools directly inside any sandbox.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 6)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(state.inventory.directories) { entry in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "folder.fill")
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(mintAccent)
                                            Text(entry.displayPath)
                                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .textSelection(.enabled)
                                            Spacer()
                                            Button("Reveal") {
                                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                                            }
                                            .controlSize(.mini)
                                            if entry.path != state.inventory.envRoot + "/bin" {
                                                Button("Remove") {
                                                    removeDir(entry.path)
                                                }
                                                .controlSize(.mini)
                                                .disabled(state.isRunningAction)
                                            }
                                        }

                                        FlowChipLayout(spacing: 4) {
                                            ForEach(entry.binaries.prefix(32), id: \.self) { bin in
                                                Text(bin)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 6.5)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                                            }
                                            if entry.binaries.count > 32 {
                                                Text("+\(entry.binaries.count - 32) more")
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(.tertiary)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                            }
                                        }
                                    }
                                    .padding(9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                }
                            }
                        }
                    }
                }

                SettingsCard(title: "Environment Location") {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsToggleRow(
                            title: "Share Global Environment Across All Sandboxes",
                            subtitle: "Confines all installed toolchains and global packages to one isolated directory so sessions share them without ever modifying host /opt/homebrew.",
                            isOn: $configManager.config.sandboxAccess.persistentSandboxTools
                        )

                        if configManager.config.sandboxAccess.persistentSandboxTools {
                            Divider()
                            HStack(spacing: 6) {
                                TextField("~/boo_box/env", text: $configManager.config.sandboxAccess.sandboxToolsPath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                Button("Browse…") { pickEnvFolder() }
                                    .controlSize(.small)
                                Button("Reveal") {
                                    let url = configManager.config.sandboxAccess.resolvedToolsURL()
                                    GlobalEnvManager.shared.ensureLayout(at: url)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                .controlSize(.small)
                                Button("Reset", role: .destructive) {
                                    resetEnv()
                                }
                                .controlSize(.small)
                                .disabled(state.isRunningAction)
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .onAppear {
            refreshInventory()
        }
    }

    private func refreshInventory() {
        let url = configManager.config.sandboxAccess.resolvedToolsURL()
        state.isLoading = true
        GlobalEnvManager.shared.fetchInventory(at: url) { inv in
            state.inventory = inv
            state.isLoading = false
        }
    }

    private func runScript(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !state.isRunningAction else { return }
        let url = configManager.config.sandboxAccess.resolvedToolsURL()
        state.isRunningAction = true
        state.outputLog = nil
        state.outputIsError = false
        GlobalEnvManager.shared.runInstallScript(trimmed, at: url) { result in
            state.isRunningAction = false
            switch result {
            case .success(let out):
                state.outputLog = out
                state.outputIsError = false
                state.installScript = ""
                refreshInventory()
            case .failure(let err):
                state.outputLog = err.localizedDescription
                state.outputIsError = true
                refreshInventory()
            }
        }
    }

    private func removeDir(_ path: String) {
        guard !state.isRunningAction else { return }
        let url = configManager.config.sandboxAccess.resolvedToolsURL()
        state.isRunningAction = true
        GlobalEnvManager.shared.removeDirectory(path, at: url) { result in
            state.isRunningAction = false
            switch result {
            case .success(let out):
                state.outputLog = out
                state.outputIsError = false
                refreshInventory()
            case .failure(let err):
                state.outputLog = err.localizedDescription
                state.outputIsError = true
            }
        }
    }

    private func resetEnv() {
        guard !state.isRunningAction else { return }
        let url = configManager.config.sandboxAccess.resolvedToolsURL()
        state.isRunningAction = true
        GlobalEnvManager.shared.reset(at: url) { result in
            state.isRunningAction = false
            switch result {
            case .success(let out):
                state.outputLog = out
                state.outputIsError = false
                refreshInventory()
            case .failure(let err):
                state.outputLog = err.localizedDescription
                state.outputIsError = true
            }
        }
    }

    private func pickEnvFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Global Sandbox Environment Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        configManager.config.sandboxAccess.sandboxToolsPath = resolved.hasPrefix(home + "/")
            ? "~/" + String(resolved.dropFirst(home.count + 1))
            : resolved
        refreshInventory()
    }
}

@MainActor
private final class SandboxAccessInputState: ObservableObject {
    @Published var newPathText = ""
    @Published var newConfigPathText = ""
}

private struct SandboxAccessSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @StateObject private var input = SandboxAccessInputState()

    private let builtInToolchains = [
        "/opt/homebrew", "/usr/bin", "fnm / nvm Node", "pnpm",
        "~/.bun/bin", "~/.cargo/bin", "~/.rustup", "~/.local/bin",
        "~/go/bin", "~/.deno/bin", "uv", "pyenv / rbenv",
    ]
    private let suggestedExtraPaths = [
        "~/bin", "~/.conda", "~/miniconda3", "~/.orbstack/bin", "~/.mix",
    ]
    private let suggestedConfigPaths = [
        "~/.config/nvim", "~/.continue", "~/.ollama", "~/.aws",
    ]
    private var riskyConfiguredPaths: [(path: String, warning: String)] {
        configManager.config.sandboxAccess.extraReadPaths.compactMap { path in
            SandboxAccessConfig.riskWarning(for: path).map { (path, $0) }
        }
    }

    private var riskyConfigPaths: [(path: String, warning: String)] {
        configManager.config.sandboxAccess.extraConfigPaths.compactMap { path in
            SandboxAccessConfig.riskWarning(for: path).map { (path, $0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: "Sandbox Access",
                    subtitle: "Control which host CLI configs, binaries, and sockets non-private macOS Sandbox sessions can reach. Private VMs always remain air-gapped."
                )

                SettingsCard(title: "CLI Tool Configs & Auth (Read-Write)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mounted directly into each session's `$HOME` so agent CLIs keep your existing config, models, extensions, and auth with zero re-setup. Tools can edit their own config folders; all other files (`Desktop`, `Documents`, `~/.ssh`, real repos) remain kernel-blocked.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Divider()

                        SettingsToggleRow(
                            title: "OMP (~/.omp)",
                            subtitle: "Shares OMP settings, models, MCP servers, extensions, and auth.",
                            isOn: $configManager.config.sandboxAccess.shareOMPConfig
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "Claude Code (~/.claude, ~/.claude.json)",
                            subtitle: "Shares Claude Code settings, skills, MCP servers, and auth.",
                            isOn: $configManager.config.sandboxAccess.shareClaudeConfig
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "Codex CLI (~/.codex)",
                            subtitle: "Shares OpenAI Codex CLI config, LSP decisions, and auth.",
                            isOn: $configManager.config.sandboxAccess.shareCodexConfig
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "OpenCode (~/.config/opencode, ~/.local/share/opencode)",
                            subtitle: "Shares OpenCode config, themes, plugins, and auth.",
                            isOn: $configManager.config.sandboxAccess.shareOpenCodeConfig
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "Gemini CLI (~/.gemini)",
                            subtitle: "Shares Google Gemini CLI settings and OAuth credentials.",
                            isOn: $configManager.config.sandboxAccess.shareGeminiConfig
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "Other Major Agent Harnesses",
                            subtitle: "Auto-mounts any installed configs for Cursor, Amp, Pi, Aider, Goose, Factory/Droid, Cline, Augment, Codeium, Kimi, Qwen, and Vibe.",
                            isOn: $configManager.config.sandboxAccess.shareOtherAgentConfigs
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "GitHub CLI (~/.config/gh)",
                            subtitle: "Opt-in: exposes host GitHub CLI auth tokens so `gh` commands work inside sandboxes.",
                            isOn: $configManager.config.sandboxAccess.shareGHConfig
                        )

                        Divider()

                        Text("Custom Tool Config Folders (Read-Write)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        if !riskyConfigPaths.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sensitive host path granted read-write access")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(Color.orange)
                                    ForEach(riskyConfigPaths, id: \.path) { item in
                                        Text("\(item.path) — \(item.warning)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.orange.opacity(0.11))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.75)
                                    )
                            )
                        }

                        if !configManager.config.sandboxAccess.extraConfigPaths.isEmpty {
                            VStack(spacing: 5) {
                                ForEach(configManager.config.sandboxAccess.extraConfigPaths, id: \.self) { path in
                                    let risk = SandboxAccessConfig.riskWarning(for: path)
                                    HStack(spacing: 8) {
                                        Image(systemName: risk != nil ? "exclamationmark.triangle.fill" : "folder.badge.gearshape")
                                            .font(.system(size: 11))
                                            .foregroundStyle(risk != nil ? Color.orange : Color.secondary)
                                        Text(path)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("read-write")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                        Button {
                                            configManager.config.sandboxAccess.extraConfigPaths.removeAll { $0 == path }
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 22, height: 20)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove config folder")
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                }
                            }
                        }

                        HStack(spacing: 6) {
                            TextField("~/.my-agent-cli", text: $input.newConfigPathText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                                .onSubmit { addConfigPath() }
                            Button("Add") { addConfigPath() }
                                .controlSize(.small)
                                .disabled(input.newConfigPathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Browse…") { pickConfigFolder() }
                                .controlSize(.small)
                        }

                        HStack(spacing: 6) {
                            Text("Quick add:")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                            FlowChipLayout(spacing: 5) {
                                ForEach(suggestedConfigPaths, id: \.self) { candidate in
                                    let added = configManager.config.sandboxAccess.extraConfigPaths.contains(candidate)
                                    Button {
                                        if !added {
                                            configManager.config.sandboxAccess.extraConfigPaths.append(candidate)
                                        }
                                    } label: {
                                        Text(added ? "✓ \(candidate)" : "+ \(candidate)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(added ? Color(red: 0.25, green: 0.84, blue: 0.72) : .secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2.5)
                                            .background(Capsule().fill(Color.primary.opacity(0.055)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                SettingsCard(title: "Default Read-Only Mac Binaries") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Available read-only out of the box in every macOS Sandbox session. Real `$HOME` (`Desktop`, `Documents`, `~/.ssh`, `~/.aws`, Keychain) stays kernel-denied.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        FlowChipLayout(spacing: 5) {
                            ForEach(builtInToolchains, id: \.self) { label in
                                Text(label)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                    }
                }

                SettingsCard(title: "Custom Read-Only Paths & Binaries") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Add custom toolchain or binary folders inside `$HOME` (granted read-only access and appended to sandbox `PATH`). Applies to new & resumed sessions.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if !riskyConfiguredPaths.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sensitive host path exposed to sandboxed sessions")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(Color.orange)
                                    ForEach(riskyConfiguredPaths, id: \.path) { item in
                                        Text("\(item.path) — \(item.warning)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.orange.opacity(0.11))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.75)
                                    )
                            )
                        }

                        if !configManager.config.sandboxAccess.extraReadPaths.isEmpty {
                            VStack(spacing: 5) {
                                ForEach(configManager.config.sandboxAccess.extraReadPaths, id: \.self) { path in
                                    let risk = SandboxAccessConfig.riskWarning(for: path)
                                    HStack(spacing: 8) {
                                        Image(systemName: risk != nil ? "exclamationmark.triangle.fill" : "folder")
                                            .font(.system(size: 11))
                                            .foregroundStyle(risk != nil ? Color.orange : Color.secondary)
                                        Text(path)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("read-only")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                        Button {
                                            configManager.config.sandboxAccess.extraReadPaths.removeAll { $0 == path }
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 22, height: 20)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove path")
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                }
                            }
                        }

                        HStack(spacing: 6) {
                            TextField("~/my-tools/bin", text: $input.newPathText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                                .onSubmit { addPath() }
                            Button("Add") { addPath() }
                                .controlSize(.small)
                                .disabled(input.newPathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Browse…") { pickExtraFolder() }
                                .controlSize(.small)
                        }

                        HStack(spacing: 6) {
                            Text("Quick add:")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                            FlowChipLayout(spacing: 5) {
                                ForEach(suggestedExtraPaths, id: \.self) { candidate in
                                    let added = configManager.config.sandboxAccess.extraReadPaths.contains(candidate)
                                    Button {
                                        if !added {
                                            configManager.config.sandboxAccess.extraReadPaths.append(candidate)
                                        }
                                    } label: {
                                        Text(added ? "✓ \(candidate)" : "+ \(candidate)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(added ? Color(red: 0.25, green: 0.84, blue: 0.72) : .secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2.5)
                                            .background(Capsule().fill(Color.primary.opacity(0.055)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                SettingsCard(title: "Opt-In Host Integrations (Off by Default)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.orange)
                            Text("Enabling host integrations weakens sandbox isolation. Only turn on what your workflow requires.")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.orange.opacity(0.92))
                        }

                        Divider()

                        SettingsToggleRow(
                            title: "Allow Read-Only Host ~/.gitconfig",
                            subtitle: "Shares your git name, email, and aliases read-only via GIT_CONFIG_GLOBAL (does not expose ~/.git-credentials).",
                            isOn: $configManager.config.sandboxAccess.allowHostGitConfig
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "Allow Host SSH Agent (SSH_AUTH_SOCK)",
                            subtitle: "Warning: lets sandboxed agents authenticate with loaded ssh-agent keys (e.g. git push/fetch) without reading ~/.ssh key files.",
                            isOn: $configManager.config.sandboxAccess.allowSSHAgent
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "Allow Host Docker / OrbStack Socket",
                            subtitle: "High Risk: Docker daemon access can bind-mount host folders and bypass the filesystem sandbox. Enable only for trusted container work.",
                            isOn: $configManager.config.sandboxAccess.allowDockerSocket
                        )

                        Divider()

                        SettingsToggleRow(
                            title: "Block Host localhost Network (127.0.0.1 / ::1)",
                            subtitle: "Extra hardening: blocks sandboxed agents from reaching local databases or dev services running on your Mac's loopback interface.",
                            isOn: $configManager.config.sandboxAccess.blockLocalNetwork
                        )
                    }
                }
            }
            .padding(22)
        }
    }

    private func addPath() {
        let trimmed = input.newPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !configManager.config.sandboxAccess.extraReadPaths.contains(trimmed) {
            configManager.config.sandboxAccess.extraReadPaths.append(trimmed)
        }
        input.newPathText = ""
    }

    private func addConfigPath() {
        let trimmed = input.newConfigPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !configManager.config.sandboxAccess.extraConfigPaths.contains(trimmed) {
            configManager.config.sandboxAccess.extraConfigPaths.append(trimmed)
        }
        input.newConfigPathText = ""
    }

    private func pickConfigFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose CLI Tool Config Folder (Read-Write)"
        panel.message = "Selected folder under your home directory will be mounted read-write and symlinked into sandboxed sessions."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        let display = resolved.hasPrefix(home + "/")
            ? "~/" + String(resolved.dropFirst(home.count + 1))
            : resolved
        if !configManager.config.sandboxAccess.extraConfigPaths.contains(display) {
            configManager.config.sandboxAccess.extraConfigPaths.append(display)
        }
    }

    private func pickExtraFolder() {
        let panel = NSOpenPanel()
        panel.title = "Allow Read-Only Folder in macOS Sandbox"
        panel.prompt = "Allow Read-Only"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let realHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        let display = resolved.hasPrefix(realHome + "/")
            ? "~" + resolved.dropFirst(realHome.count)
            : resolved
        if !configManager.config.sandboxAccess.extraReadPaths.contains(display) {
            configManager.config.sandboxAccess.extraReadPaths.append(display)
        }
    }
}

// MARK: - Shared Package Cache Tab

private struct PackageCacheSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: "Shared Package Cache",
                    subtitle: "Reuse downloaded dependencies across isolated macOS Sandbox sessions so `pnpm`, `bun`, `uv`, and `cargo` stay instant without re-downloading."
                )

                SettingsCard(title: "Cache Policy") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggleRow(
                            title: "Enable Shared Package Cache",
                            subtitle: "Applies to all new and resumed macOS Sandbox sessions. Private VMs remain air-gapped.",
                            isOn: $configManager.config.packageCache.enabled
                        )

                        if configManager.config.packageCache.enabled {
                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Picker("Access Mode", selection: $configManager.config.packageCache.accessMode) {
                                    ForEach(PackageCacheAccessMode.allCases) { mode in
                                        Text(mode.label).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Text(configManager.config.packageCache.accessMode.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Divider()

                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Cache Location")
                                        .font(.system(size: 11.5, weight: .medium))
                                    TextField("~/boo_box/cache", text: $configManager.config.packageCache.cacheDirectory)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11.5, design: .monospaced))
                                }

                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(configManager.formattedCacheSize)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 6) {
                                        Button("Reveal") {
                                            configManager.revealCacheInFinder()
                                        }
                                        .controlSize(.small)
                                        Button("Clear Cache", role: .destructive) {
                                            configManager.clearPackageCache()
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                }

                if configManager.config.packageCache.enabled {
                    SettingsCard(title: "Cached Ecosystems") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            CacheEcosystemToggle(
                                title: "pnpm",
                                envVar: "PNPM_STORE_DIR",
                                isOn: $configManager.config.packageCache.pnpm
                            )
                            CacheEcosystemToggle(
                                title: "npm",
                                envVar: "npm_config_cache",
                                isOn: $configManager.config.packageCache.npm
                            )
                            CacheEcosystemToggle(
                                title: "Bun",
                                envVar: "BUN_INSTALL_CACHE_DIR",
                                isOn: $configManager.config.packageCache.bun
                            )
                            CacheEcosystemToggle(
                                title: "uv (Python)",
                                envVar: "UV_CACHE_DIR",
                                isOn: $configManager.config.packageCache.uv
                            )
                            CacheEcosystemToggle(
                                title: "pip",
                                envVar: "PIP_CACHE_DIR",
                                isOn: $configManager.config.packageCache.pip
                            )
                            CacheEcosystemToggle(
                                title: "Cargo (Rust)",
                                envVar: "CARGO_HOME",
                                isOn: $configManager.config.packageCache.cargo
                            )
                        }
                    }
                }
            }
            .padding(22)
        }
        .onAppear {
            configManager.refreshCacheSize()
        }
    }
}

private struct CacheEcosystemToggle: View {
    let title: String
    let envVar: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(envVar)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - Themes Tab (Live Ghostty Theme Switcher)

private enum ThemeFilter: String, CaseIterable, Identifiable {
    case popular = "Popular"
    case all = "All"
    case dark = "Dark"
    case light = "Light"

    var id: String { rawValue }
}

@MainActor
private final class ThemeBrowserState: ObservableObject {
    @Published var searchText = ""
    @Published var filter: ThemeFilter = .popular
}

private struct ThemesSettingsTab: View {
    @ObservedObject var configManager: BooBoxConfigManager
    @StateObject private var browser = ThemeBrowserState()

    private var displayedThemes: [GhosttyThemeInfo] {
        let query = browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = configManager.availableThemes

        if !query.isEmpty {
            return all.filter { $0.name.lowercased().contains(query) }
        }

        switch browser.filter {
        case .popular:
            let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
            return BooBoxConfigManager.popularThemeNames.compactMap { byName[$0] }
        case .all:
            return all
        case .dark:
            return all.filter { !$0.isLight }
        case .light:
            return all.filter { $0.isLight }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: header + search + filter
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SettingsHeader(
                        title: "Themes",
                        subtitle: "Powered by Ghostty (\(configManager.availableThemes.count) built-in themes). Changes apply live to every open terminal."
                    )
                    Spacer()
                    if let active = configManager.config.appearance.themeName {
                        Text(active)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.25, green: 0.84, blue: 0.72))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color(red: 0.25, green: 0.84, blue: 0.72).opacity(0.14))
                            )
                    } else {
                        Text("Ghostty Default")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        TextField("Search \(configManager.availableThemes.count) themes…", text: $browser.searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !browser.searchText.isEmpty {
                            Button {
                                browser.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                    Picker("", selection: $browser.filter) {
                        ForEach(ThemeFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 215)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            // Theme preview cards
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    if browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DefaultThemeCard(isSelected: configManager.config.appearance.themeName == nil) {
                            configManager.config.appearance.themeName = nil
                        }
                    }

                    ForEach(displayedThemes) { theme in
                        ThemePreviewCard(
                            theme: theme,
                            isSelected: configManager.config.appearance.themeName == theme.name
                        ) {
                            configManager.config.appearance.themeName = theme.name
                        }
                    }
                }
                .padding(18)
            }

            Divider()

            // Typography & Opacity bar
            HStack(spacing: 20) {
                HStack(spacing: 8) {
                    Text("Font Size")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Stepper(
                        value: Binding(
                            get: { configManager.config.appearance.fontSize ?? 13.0 },
                            set: { configManager.config.appearance.fontSize = $0 }
                        ),
                        in: 10...24,
                        step: 1
                    ) {
                        Text(configManager.config.appearance.fontSize.map { "\(Int($0)) pt" } ?? "Default")
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 52, alignment: .trailing)
                    }
                    if configManager.config.appearance.fontSize != nil {
                        Button("Auto") {
                            configManager.config.appearance.fontSize = nil
                        }
                        .controlSize(.mini)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("Opacity")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $configManager.config.appearance.backgroundOpacity,
                        in: 0.75...1.0,
                        step: 0.05
                    )
                    .frame(width: 110)
                    Text("\(Int((configManager.config.appearance.backgroundOpacity * 100).rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.025))
        }
    }
}

private struct DefaultThemeCard: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.12, green: 0.13, blue: 0.17))
                        .frame(height: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("~/.config/ghostty")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.82))
                        Text("inherit user config")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }

                HStack {
                    Text("Ghostty Default")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.25, green: 0.84, blue: 0.72))
                    }
                }
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color(red: 0.25, green: 0.84, blue: 0.72) : Color.primary.opacity(0.08),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ThemePreviewCard: View {
    let theme: GhosttyThemeInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text("boo_box")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.palette.last?.swiftUIColor ?? theme.foreground.swiftUIColor)
                        Text("%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.foreground.swiftUIColor.opacity(0.7))
                        Text("ls")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.foreground.swiftUIColor)
                    }

                    HStack(spacing: 4) {
                        ForEach(Array(theme.palette.prefix(6).enumerated()), id: \.offset) { _, color in
                            Circle()
                                .fill(color.swiftUIColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 10)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.background.swiftUIColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                )

                HStack(spacing: 4) {
                    Text(theme.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.25, green: 0.84, blue: 0.72))
                    }
                }
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color(red: 0.25, green: 0.84, blue: 0.72) : Color.primary.opacity(0.08),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared UI Helpers

struct SettingsHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                    )
            )
        }
    }
}

private struct CodeEditorBox: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
        }
        .frame(height: 88)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                )
        )
    }
}

/// Simple wrapping horizontal flow layout for package/env chips.
private struct FlowChipLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 480
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
