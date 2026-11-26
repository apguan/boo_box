import AppKit
import SwiftUI

private enum SandboxJumpSection: String, Identifiable, Hashable {
    // macOS Sandbox sections (all rendered on one continuous page)
    case network = "Network"
    case secrets = "Secrets"
    case environment = "Environment"
    case access = "Host Access"
    case resources = "Resources"

    // Private Linux MicroVM sections (all rendered on one continuous page)
    case vmCompute = "Compute"
    case vmIsolation = "Network & Share"
    case vmDockerfile = "Dockerfile"
    case vmEnvironment = "VM Environment"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .network: "network"
        case .secrets: "key.fill"
        case .environment: "terminal"
        case .access: "lock.shield"
        case .resources: "gauge.with.dots.needle.50percent"
        case .vmCompute: "cpu"
        case .vmIsolation: "network"
        case .vmDockerfile: "doc.text.magnifyingglass"
        case .vmEnvironment: "terminal"
        }
    }

    var displayLabel: String {
        switch self {
        case .vmEnvironment: "Environment"
        default: rawValue
        }
    }

    static let macSections: [SandboxJumpSection] = [.network, .secrets, .environment, .access, .resources]
    static let vmSections: [SandboxJumpSection] = [.vmCompute, .vmIsolation, .vmDockerfile, .vmEnvironment]
}

private enum TriStateOverride: String, CaseIterable, Identifiable {
    case inherit = "inherit"
    case enabled = "on"
    case disabled = "off"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inherit: "Inherit"
        case .enabled: "On"
        case .disabled: "Off"
        }
    }

    init(from optionalBool: Bool?) {
        switch optionalBool {
        case nil: self = .inherit
        case true?: self = .enabled
        case false?: self = .disabled
        }
    }

    var optionalBool: Bool? {
        switch self {
        case .inherit: nil
        case .enabled: true
        case .disabled: false
        }
    }
}

private enum VMShareChoice: String, CaseIterable, Identifiable {
    case inherit = "inherit"
    case none = "none"
    case custom = "custom"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inherit: "Inherit Global"
        case .none: "Air-gapped (None)"
        case .custom: "Custom Folder"
        }
    }
}

@MainActor
private final class SandboxConfigDraftState: ObservableObject {
    @Published var draft: SandboxOverrideConfig
    @Published var activeSection: SandboxJumpSection
    @Published var newDomainText = ""
    @Published var newEnvKey = ""
    @Published var newEnvValue = ""
    @Published var newReadPath = ""
    @Published var showDockerfileScript = false

    init(initial: SandboxOverrideConfig, isLinuxVM: Bool) {
        self.draft = initial
        self.activeSection = isLinuxVM ? .vmCompute : .network
    }
}

/// Single-page per-sandbox configuration sheet with a left section jump rail.
/// Every option lives on one scrollable page; clicking a section on the left scrolls straight to it.
struct SandboxConfigSheet: View {
    @ObservedObject var store: SessionStore
    let target: SandboxConfigTarget

    @ObservedObject private var configManager = BooBoxConfigManager.shared
    @StateObject private var state: SandboxConfigDraftState
    @Environment(\.dismiss) private var dismiss

    private let mintAccent = Color(red: 0.25, green: 0.84, blue: 0.72)
    private let vmBlueAccent = Color(red: 0.38, green: 0.72, blue: 1.0)

    init(store: SessionStore, target: SandboxConfigTarget) {
        self.store = store
        self.target = target
        let vmFlag: Bool = {
            if case .active(let session) = target { return session.mode.isLinuxVM }
            return false
        }()
        let initial: SandboxOverrideConfig = switch target {
        case .active(let session): session.overrides
        case .saved(let sandbox): sandbox.overrides
        }
        _state = StateObject(wrappedValue: SandboxConfigDraftState(initial: initial, isLinuxVM: vmFlag))
    }

    private var isLinuxVM: Bool {
        if case .active(let session) = target {
            return session.mode.isLinuxVM
        }
        return false
    }

    private var isActiveSession: Bool {
        if case .active = target { return true }
        return false
    }

    private var accentColor: Color {
        isLinuxVM ? vmBlueAccent : mintAccent
    }

    private var sections: [SandboxJumpSection] {
        isLinuxVM ? SandboxJumpSection.vmSections : SandboxJumpSection.macSections
    }

    private var titleText: String {
        switch target {
        case .active(let session): session.displayTitle
        case .saved(let sandbox): sandbox.name
        }
    }

    private var badgeSubtitle: String {
        switch target {
        case .active(let session):
            if session.mode.isLinuxVM { return "Private VM" }
            if let sb = session.macSandbox { return sb.shortID }
            return "macOS Sandbox"
        case .saved(let sandbox):
            return "\(sandbox.shortID) · saved"
        }
    }

    private var hasAnyOverrides: Bool {
        isLinuxVM ? state.draft.hasPrivateVMOverrides : state.draft.hasMacSandboxOverrides
    }

    private func sectionHasOverrides(_ section: SandboxJumpSection) -> Bool {
        switch section {
        case .network:
            return state.draft.egressMode != nil || !state.draft.extraAllowedDomains.isEmpty || state.draft.blockLocalNetwork != nil
        case .secrets:
            return state.draft.secretAccessMode != .inheritGlobal
        case .environment:
            return !state.draft.cleanedEnvVars.isEmpty || state.draft.useGlobalEnvTools != nil
        case .access:
            return !state.draft.extraReadPaths.isEmpty || state.draft.allowHostGitConfig != nil || state.draft.allowSSHAgent != nil || state.draft.allowDockerSocket != nil
        case .resources:
            return state.draft.hasResourceLimits
        case .vmCompute:
            return state.draft.vmCPUCount != nil || state.draft.vmMemoryMB != nil
        case .vmIsolation:
            return state.draft.vmNetworkMode != nil || state.draft.vmSharedHostPath != nil || state.draft.vmSharedHostReadOnly != nil
        case .vmDockerfile:
            return state.draft.vmDockerfilePath != nil || state.draft.vmDockerfileCopyContext != nil
        case .vmEnvironment:
            return !state.draft.cleanedEnvVars.isEmpty
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                // Left section jump rail
                leftRail(scrollProxy: proxy)

                Divider()

                // Right single scrollable page + sticky footer
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            pageHeader
                                .padding(.top, 32)
                                .padding(.bottom, 4)
                                .id("pageTop")

                            if isLinuxVM {
                                sectionAnchor(.vmCompute) { vmComputeCard }
                                sectionAnchor(.vmIsolation) { vmNetworkAndShareCard }
                                sectionAnchor(.vmDockerfile) { vmDockerfileCard }
                                sectionAnchor(.vmEnvironment) {
                                    envVarsCard(subtitle: "Injected into /root/.boobox-env.sh (0600) on VM boot. Reboot VM to apply.")
                                }
                            } else {
                                sectionAnchor(.network) { macNetworkCard }
                                sectionAnchor(.secrets) { macSecretsCard }
                                sectionAnchor(.environment) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        envVarsCard(subtitle: "Merged over global env vars for this sandbox (written to 0600 ~/.boobox-env.sh).")
                                        macGlobalEnvCard
                                    }
                                }
                                sectionAnchor(.access) { macAccessCard }
                                sectionAnchor(.resources) { macResourcesCard }
                            }
                        }
                        .padding(.horizontal, 36)
                        .padding(.bottom, 40)
                    }

                    Divider()
                    footerBar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                // Prevent macOS from auto-focusing the KEY TextField down the page and scrolling past the header
                DispatchQueue.main.async {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    proxy.scrollTo("pageTop", anchor: .top)
                }
            }
        }
        .frame(width: 840, height: 620)
    }

    // MARK: - Left Section Jump Rail

    private func leftRail(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: isLinuxVM ? "cpu" : "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(accentColor.opacity(0.14))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleText)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(badgeSubtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 26)
            .padding(.bottom, 16)

            Text("SECTIONS")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

            ForEach(sections) { section in
                let active = state.activeSection == section
                let modified = sectionHasOverrides(section)
                Button {
                    state.activeSection = section
                    withAnimation(.easeInOut(duration: 0.22)) {
                        if section == sections.first {
                            scrollProxy.scrollTo("pageTop", anchor: .top)
                        } else {
                            scrollProxy.scrollTo(section, anchor: .top)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 16)
                        Text(section.displayLabel)
                            .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer()
                        if modified {
                            Circle()
                                .fill(accentColor)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? Color.primary.opacity(0.11) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                if hasAnyOverrides {
                    Button {
                        state.draft = .default
                    } label: {
                        Label("Reset to Globals", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Inheriting all global defaults")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 16)
        .frame(width: 216)
        .background(Color.primary.opacity(0.035))
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isLinuxVM ? "Private VM Configuration" : "Workspace Sandbox Configuration")
                    .font(.system(size: 17, weight: .semibold))
                Text(isLinuxVM
                     ? "Override CPU, RAM, network isolation, VirtioFS share, and environment for this VM only."
                     : "Override global network, Vault secrets, environment, host access, and resource limits for this sandbox only.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if hasAnyOverrides {
                Text("Custom")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accentColor.opacity(0.14)))
            }
        }
    }

    private func sectionAnchor<Content: View>(
        _ section: SandboxJumpSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.top, 24)
            .id(section)
    }
    // MARK: - macOS Sandbox Sections

    private var macNetworkCard: some View {
        let globalMode = configManager.config.secretsNetwork.egressMode
        let globalShort: String = switch globalMode {
        case .full: "Full"
        case .allowlist: "Allowlist"
        case .offline: "Offline"
        }
        let modeBinding = Binding<String>(
            get: { state.draft.egressMode?.rawValue ?? "inherit" },
            set: { raw in
                state.draft.egressMode = (raw == "inherit") ? nil : EgressNetworkMode(rawValue: raw)
            }
        )
        let effectiveMode = state.draft.egressMode ?? globalMode

        return sheetCard(title: "Network") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Outbound Network Policy")
                    .font(.system(size: 12, weight: .medium))

                Picker("", selection: modeBinding) {
                    Text("Inherit (\(globalShort))").tag("inherit")
                    Text("Full").tag(EgressNetworkMode.full.rawValue)
                    Text("Dev Allowlist").tag(EgressNetworkMode.allowlist.rawValue)
                    Text("Offline").tag(EgressNetworkMode.offline.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(effectiveMode.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if effectiveMode == .allowlist {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Extra Allowed Domains (this sandbox only)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("api.stripe.com or *.vercel.com", text: $state.newDomainText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                                .onSubmit { addExtraDomain() }
                            Button("Add") { addExtraDomain() }
                                .controlSize(.small)
                                .disabled(state.newDomainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if !state.draft.extraAllowedDomains.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(state.draft.extraAllowedDomains, id: \.self) { dom in
                                    removableChip(dom) {
                                        state.draft.extraAllowedDomains.removeAll { $0 == dom }
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()
                triStateRow(
                    title: "Block host localhost / 127.0.0.1",
                    subtitle: "Global: \(configManager.config.sandboxAccess.blockLocalNetwork ? "Blocked" : "Allowed")",
                    optionalBool: $state.draft.blockLocalNetwork
                )
            }
        }
    }

    private var macSecretsCard: some View {
        let vaultSecrets = configManager.config.secretsNetwork.secrets.filter(\.enabled)

        return sheetCard(title: "Secrets (Host Vault Phantom Tokens)") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $state.draft.secretAccessMode) {
                    ForEach(SessionSecretAccessMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch state.draft.secretAccessMode {
                case .inheritGlobal:
                    Text("Exposes all \(vaultSecrets.count) enabled Vault secret(s) as phantom tokens (bbx_ph_...) bound to their allowed hosts.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .none:
                    Text("Zero Vault secrets exposed to this sandbox. Even if a phantom token is pasted into this tab, boobox-proxy blocks it (403).")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                case .custom:
                    if vaultSecrets.isEmpty {
                        Text("No secrets configured yet in Global Settings → Secrets & Network.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(vaultSecrets) { secret in
                                let isIncluded = Binding<Bool>(
                                    get: { state.draft.allowedSecretIDs.contains(secret.id) },
                                    set: { checked in
                                        if checked {
                                            if !state.draft.allowedSecretIDs.contains(secret.id) {
                                                state.draft.allowedSecretIDs.append(secret.id)
                                            }
                                        } else {
                                            state.draft.allowedSecretIDs.removeAll { $0 == secret.id }
                                        }
                                    }
                                )
                                Toggle(isOn: isIncluded) {
                                    HStack(spacing: 6) {
                                        Text(secret.envVar)
                                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                        Text("(\(secret.allowedHosts.joined(separator: ", ")))")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
        }
    }

    private var macGlobalEnvCard: some View {
        let globalAccess = configManager.config.sandboxAccess
        return sheetCard(title: "Shared Global Toolchains") {
            triStateRow(
                title: "Mount ~/boo_box/env on sandbox PATH",
                subtitle: "Global: \(globalAccess.persistentSandboxTools ? "Enabled" : "Disabled"). Turn Off to isolate this sandbox from shared toolchains.",
                optionalBool: $state.draft.useGlobalEnvTools
            )
        }
    }

    private var macAccessCard: some View {
        let globalAccess = configManager.config.sandboxAccess

        return sheetCard(title: "Host Access") {
            VStack(alignment: .leading, spacing: 10) {
                triStateRow(
                    title: "Read-Only ~/.gitconfig",
                    subtitle: "Global: \(globalAccess.allowHostGitConfig ? "On" : "Off")",
                    optionalBool: $state.draft.allowHostGitConfig
                )
                Divider()
                triStateRow(
                    title: "Forward SSH Agent (SSH_AUTH_SOCK)",
                    subtitle: "Global: \(globalAccess.allowSSHAgent ? "On" : "Off")",
                    optionalBool: $state.draft.allowSSHAgent
                )
                Divider()
                triStateRow(
                    title: "Host Docker / OrbStack Socket",
                    subtitle: "Global: \(globalAccess.allowDockerSocket ? "On" : "Off") · High risk",
                    optionalBool: $state.draft.allowDockerSocket
                )
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra Read-Only Host Paths (this sandbox only)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        TextField("~/path/to/read-only-folder", text: $state.newReadPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .onSubmit { addReadPath() }
                        Button("Browse…") { browseReadPath() }
                            .controlSize(.small)
                        Button("Add") { addReadPath() }
                            .controlSize(.small)
                            .disabled(state.newReadPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ForEach(state.draft.extraReadPaths, id: \.self) { path in
                        HStack {
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let warn = SandboxAccessConfig.riskWarning(for: path) {
                                Text(warn)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                            Button(role: .destructive) {
                                state.draft.extraReadPaths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
        }
    }

    private var macResourcesCard: some View {
        let maxCPUBinding = Binding<Int>(
            get: { state.draft.maxCPUSeconds ?? 0 },
            set: { state.draft.maxCPUSeconds = $0 == 0 ? nil : $0 }
        )
        let maxFilesBinding = Binding<Int>(
            get: { state.draft.maxOpenFiles ?? 0 },
            set: { state.draft.maxOpenFiles = $0 == 0 ? nil : $0 }
        )
        let maxSizeBinding = Binding<Int>(
            get: { state.draft.maxFileSizeMB ?? 0 },
            set: { state.draft.maxFileSizeMB = $0 == 0 ? nil : $0 }
        )

        return sheetCard(title: "Resources (Per-Process rlimit + CPU Priority)") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Strictly per-process POSIX resource caps enforced before launching this sandbox's shell. Child processes cannot raise hard limits.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CPU Scheduling Priority")
                            .font(.system(size: 12, weight: .medium))
                        Text("Lower priority keeps heavy builds/agents from slowing down your Mac.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $state.draft.cpuPriority) {
                        ForEach(SandboxCPUPriority.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max CPU Time per Process (ulimit -Ht)")
                            .font(.system(size: 12, weight: .medium))
                        Text("Kills runaway infinite CPU spin loops per process without affecting other apps.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: maxCPUBinding) {
                        Text("Unlimited").tag(0)
                        Text("60 sec").tag(60)
                        Text("5 min").tag(300)
                        Text("30 min").tag(1800)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max Open Files (ulimit -Hn)")
                            .font(.system(size: 12, weight: .medium))
                        Text("Caps open file descriptors and sockets per process.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: maxFilesBinding) {
                        Text("Default").tag(0)
                        Text("2,048").tag(2048)
                        Text("4,096").tag(4096)
                        Text("8,192").tag(8192)
                        Text("16,384").tag(16384)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max Single File Size (ulimit -Hf)")
                            .font(.system(size: 12, weight: .medium))
                        Text("Stops runaway logs or infinite write loops from filling your SSD.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: maxSizeBinding) {
                        Text("Unlimited").tag(0)
                        Text("100 MB").tag(100)
                        Text("512 MB").tag(512)
                        Text("2 GB").tag(2048)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
        }
    }

    // MARK: - Private Linux MicroVM Sections

    private var vmComputeCard: some View {
        let globalVM = configManager.config.privateVM
        let cpuBinding = Binding<Int>(
            get: { state.draft.vmCPUCount ?? 0 },
            set: { state.draft.vmCPUCount = $0 == 0 ? nil : $0 }
        )
        let memBinding = Binding<Int>(
            get: { state.draft.vmMemoryMB ?? 0 },
            set: { state.draft.vmMemoryMB = $0 == 0 ? nil : $0 }
        )
        let memOptions = [512, 1024, 2048, 4096, 8192, 16384].filter { $0 <= PrivateVMConfig.maxMemoryMB }
        let globalMemLabel = globalVM.clampedMemoryMB >= 1024 ? "\(globalVM.clampedMemoryMB / 1024) GB" : "\(globalVM.clampedMemoryMB) MB"

        return sheetCard(title: "Compute (Hypervisor Resource Allocation)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Virtual CPUs")
                            .font(.system(size: 12, weight: .medium))
                        Text("Global default: \(globalVM.clampedCPUCount) vCPU (host has \(PrivateVMConfig.maxCPUCount) cores).")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: cpuBinding) {
                        Text("Inherit (\(globalVM.clampedCPUCount) vCPU)").tag(0)
                        ForEach(1...PrivateVMConfig.maxCPUCount, id: \.self) { count in
                            Text("\(count) vCPU").tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 155)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Memory (RAM)")
                            .font(.system(size: 12, weight: .medium))
                        Text("Global default: \(globalMemLabel). Lazily faulted by Apple Virtualization.framework.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: memBinding) {
                        Text("Inherit (\(globalMemLabel))").tag(0)
                        ForEach(memOptions, id: \.self) { mb in
                            Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 155)
                }
            }
        }
    }

    private var vmNetworkAndShareCard: some View {
        let globalVM = configManager.config.privateVM
        let globalNetShort = globalVM.networkMode == .nat ? "NAT" : "Offline"
        let netBinding = Binding<String>(
            get: { state.draft.vmNetworkMode?.rawValue ?? "inherit" },
            set: { raw in
                state.draft.vmNetworkMode = (raw == "inherit") ? nil : PrivateVMNetworkMode(rawValue: raw)
            }
        )
        let shareChoiceBinding = Binding<VMShareChoice>(
            get: {
                guard let path = state.draft.vmSharedHostPath else { return .inherit }
                return path.isEmpty ? .none : .custom
            },
            set: { choice in
                switch choice {
                case .inherit: state.draft.vmSharedHostPath = nil
                case .none: state.draft.vmSharedHostPath = ""
                case .custom:
                    if (state.draft.vmSharedHostPath ?? "").isEmpty {
                        pickVMSharedFolder()
                    }
                }
            }
        )

        return sheetCard(title: "Network & VirtioFS Share (/mnt/host)") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Virtual Network")
                        .font(.system(size: 11.5, weight: .medium))
                    Picker("", selection: netBinding) {
                        Text("Inherit (\(globalNetShort))").tag("inherit")
                        Text("NAT (Internet)").tag(PrivateVMNetworkMode.nat.rawValue)
                        Text("Offline (Air-gapped)").tag(PrivateVMNetworkMode.offline.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("VirtioFS Shared Host Folder → /mnt/host")
                        .font(.system(size: 11.5, weight: .medium))
                    Picker("", selection: shareChoiceBinding) {
                        ForEach(VMShareChoice.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if let customPath = state.draft.vmSharedHostPath, !customPath.isEmpty {
                        HStack(spacing: 8) {
                            Text(customPath)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                            Button("Change…") { pickVMSharedFolder() }
                                .controlSize(.small)
                        }

                        triStateRow(
                            title: "Mount Read-Only",
                            subtitle: "Global: \(globalVM.sharedHostReadOnly ? "Read-Only" : "Read-Write")",
                            optionalBool: $state.draft.vmSharedHostReadOnly
                        )
                    }
                }
            }
        }
    }

    private var vmDockerfileCard: some View {
        let effectiveCfg = configManager.config.applying(overrides: state.draft).privateVM
        let resolvedDF = DockerfileParser.resolveDockerfile(for: effectiveCfg)
        let parsedDF = resolvedDF.flatMap { try? DockerfileParser.parse(at: $0.url, contextDirectoryURL: $0.contextDir) }

        let choiceBinding = Binding<VMShareChoice>(
            get: {
                guard let path = state.draft.vmDockerfilePath else { return .inherit }
                return path.isEmpty ? .none : .custom
            },
            set: { choice in
                switch choice {
                case .inherit: state.draft.vmDockerfilePath = nil
                case .none: state.draft.vmDockerfilePath = ""
                case .custom:
                    if (state.draft.vmDockerfilePath ?? "").isEmpty {
                        pickVMDockerfile()
                    }
                }
            }
        )

        return sheetCard(title: "Dockerfile / Containerfile Setup") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Automatically parses `FROM`, `ARG`, `ENV`, `WORKDIR`, `COPY`, and `RUN` instructions when booting or resetting this Private VM.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: choiceBinding) {
                    Text("Inherit Global").tag(VMShareChoice.inherit)
                    Text("Disabled").tag(VMShareChoice.none)
                    Text("Custom Dockerfile").tag(VMShareChoice.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let customPath = state.draft.vmDockerfilePath, !customPath.isEmpty {
                    HStack(spacing: 8) {
                        Text(customPath)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        Button("Change…") { pickVMDockerfile() }
                            .controlSize(.small)
                    }
                }

                triStateRow(
                    title: "Allow Read-Only COPY context",
                    subtitle: "Global: \(configManager.config.privateVM.dockerfileCopyContext ? "Enabled" : "Disabled")",
                    optionalBool: $state.draft.vmDockerfileCopyContext
                )

                if let parsedDF, let resolvedDF {
                    DockerfileInspectionPreview(
                        parsed: parsedDF,
                        autoDetected: resolvedDF.autoDetected,
                        copyContextEnabled: effectiveCfg.dockerfileCopyContext,
                        isOffline: effectiveCfg.networkMode == .offline,
                        showScript: $state.showDockerfileScript
                    )
                }
            }
        }
    }

    // MARK: - Shared Env Vars Card

    private func envVarsCard(subtitle: String) -> some View {
        sheetCard(title: "Environment Variables") {
            VStack(alignment: .leading, spacing: 8) {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    TextField("KEY", text: $state.newEnvKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 165)
                    TextField("value", text: $state.newEnvValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit { addEnvVar() }
                    Button("Add") { addEnvVar() }
                        .controlSize(.small)
                        .disabled(state.newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if state.draft.envVars.isEmpty {
                    Text("No per-sandbox env overrides (inheriting global setup env vars).")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    VStack(spacing: 5) {
                        ForEach(state.draft.envVars) { entry in
                            HStack(spacing: 8) {
                                Text(entry.key)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text("=")
                                    .foregroundStyle(.secondary)
                                Text(entry.value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(role: .destructive) {
                                    state.draft.envVars.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10.5))
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if isActiveSession {
                Button("Save Only") {
                    commit(restart: false)
                }
                .help("Saves overrides and updates live boobox-proxy policy immediately; Seatbelt/env/resource changes take effect on next restart")

                Button(isLinuxVM ? "Save & Reboot VM" : "Save & Restart Sandbox") {
                    commit(restart: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Save Overrides") {
                    commit(restart: false)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 18)
    }

    // MARK: - Actions & Helpers

    private func commit(restart: Bool) {
        switch target {
        case .active(let session):
            store.applySandboxOverrides(state.draft, to: session.id, restart: restart)
        case .saved(let sandbox):
            store.applySandboxOverrides(state.draft, toSaved: sandbox)
        }
        dismiss()
    }

    private func addExtraDomain() {
        let cleaned = state.newDomainText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return }
        if !state.draft.extraAllowedDomains.contains(cleaned) {
            state.draft.extraAllowedDomains.append(cleaned)
        }
        state.newDomainText = ""
    }

    private func addEnvVar() {
        let key = state.newEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        state.draft.envVars.removeAll { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) == key }
        state.draft.envVars.append(EnvVarEntry(key: key, value: state.newEnvValue))
        state.newEnvKey = ""
        state.newEnvValue = ""
    }

    private func addReadPath() {
        let cleaned = state.newReadPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !state.draft.extraReadPaths.contains(cleaned) {
            state.draft.extraReadPaths.append(cleaned)
        }
        state.newReadPath = ""
    }

    private func browseReadPath() {
        let panel = NSOpenPanel()
        panel.title = "Choose Read-Only Host Folder for This Sandbox"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        let display = resolved.hasPrefix(home + "/") ? "~/" + String(resolved.dropFirst(home.count + 1)) : resolved
        if !state.draft.extraReadPaths.contains(display) {
            state.draft.extraReadPaths.append(display)
        }
    }

    private func pickVMSharedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Host Folder to Share into This Private VM (/mnt/host)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        state.draft.vmSharedHostPath = resolved.hasPrefix(home + "/")
            ? "~/" + String(resolved.dropFirst(home.count + 1))
            : resolved
    }

    private func pickVMDockerfile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Dockerfile or Containerfile for This Private VM"
        panel.prompt = "Select Dockerfile"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let resolved = url.resolvingSymlinksInPath().path
        state.draft.vmDockerfilePath = resolved.hasPrefix(home + "/")
            ? "~/" + String(resolved.dropFirst(home.count + 1))
            : resolved
    }

    private func triStateRow(title: String, subtitle: String, optionalBool: Binding<Bool?>) -> some View {
        let binding = Binding<TriStateOverride>(
            get: { TriStateOverride(from: optionalBool.wrappedValue) },
            set: { optionalBool.wrappedValue = $0.optionalBool }
        )
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: binding) {
                ForEach(TriStateOverride.allCases) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)
        }
    }

    private func removableChip(_ text: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func sheetCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
                    )
            )
        }
    }
}
