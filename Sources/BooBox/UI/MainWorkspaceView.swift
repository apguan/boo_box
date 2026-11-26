import AppKit
import SwiftUI

struct MainWorkspaceView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var updateManager = UpdateManager.shared

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible && store.sidebarPosition == .left {
                SidebarView(store: store)
                    .frame(width: store.sidebarWidth)
                SidebarResizeHandle(store: store, position: .left)
            }

            // Fixed structural slot so toggling/flipping the sidebar never
            // dismantles or flickers any live Ghostty Metal surface.
            terminalColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.sidebarVisible && store.sidebarPosition == .right {
                SidebarResizeHandle(store: store, position: .right)
                SidebarView(store: store)
                    .frame(width: store.sidebarWidth)
            }
        }
        .background(Color(nsColor: store.themeBackground))
        .ignoresSafeArea(.all, edges: .top)
        .frame(minWidth: 780, minHeight: 500)
        .overlay {
            if store.isCommandPaletteOpen {
                CommandPaletteOverlay(store: store)
            }
        }
        .sheet(item: $store.configuringTarget) { target in
            SandboxConfigSheet(store: store, target: target)
        }
    }
    private var needsTrafficLightPadding: Bool {
        !store.sidebarVisible || store.sidebarPosition == .right
    }

    private var terminalColumn: some View {
        let activeSession = store.selectedSession
        let isRaw = activeSession?.mode.isRawHost == true

        return VStack(spacing: 0) {
            if let session = activeSession {
                SessionHeaderBar(
                    store: store,
                    session: session,
                    leadingTrafficLightClearance: needsTrafficLightPadding
                )
            } else {
                EmptyHeaderBar(
                    store: store,
                    leadingTrafficLightClearance: needsTrafficLightPadding
                )
            }

            if updateManager.shouldShowBanner, case .available(let update) = updateManager.state {
                UpdateAvailableBanner(update: update, updateManager: updateManager)
            } else if case .downloading(let progress, let version) = updateManager.state {
                UpdateProgressBanner(text: "Downloading boo_box \(version) (\(Int(progress * 100))%)…")
            } else if case .installing(let message) = updateManager.state {
                UpdateProgressBanner(text: message)
            }

            if let session = activeSession, let alert = session.pendingProxyAlert {
                ProxyAlertBanner(store: store, session: session, alert: alert)
            }

            ZStack {
                TerminalStageRepresentable(stageView: store.stageView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(activeSession == nil ? 0 : 1)
                    .allowsHitTesting(activeSession != nil)

                if activeSession == nil {
                    EmptyWorkspaceView(store: store)
                }
            }
        }
        .overlay {
            if isRaw {
                Rectangle()
                    .strokeBorder(Color(red: 1.0, green: 0.34, blue: 0.32).opacity(0.65), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct UpdateAvailableBanner: View {
    let update: AvailableUpdate
    @ObservedObject var updateManager: UpdateManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text("boo_box \(update.version) is available from \(updateManager.repoSlug)")
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button("Notes") {
                NSWorkspace.shared.open(update.htmlURL)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            Button(update.installButtonTitle) {
                updateManager.installAvailableUpdate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            Button {
                updateManager.dismissBanner(for: update.version)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss until next launch")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }
}

private struct UpdateProgressBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }
}

private struct ProxyAlertBanner: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var session: TerminalSession
    let alert: ProxyAuditEventItem

    private var isLeak: Bool {
        alert.decision == "leak_blocked"
    }

    private var isOffline: Bool {
        alert.reason.lowercased().contains("offline")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isLeak ? "exclamationmark.shield.fill" : "hand.raised.fill")
                .font(.system(size: 12))
                .foregroundStyle(isLeak ? Color.red : Color.orange)

            if isLeak {
                Text("Blocked secret exfiltration → \(alert.host) (\(alert.reason))")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Blocked \(alert.host) — \(alert.reason)")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isLeak {
                Button("Inspect") {
                    SettingsNavState.shared.selectedTab = .secretsNetwork
                    store.openSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.mini)
            } else if isOffline {
                Button("Configure") {
                    store.openSandboxConfig(for: session.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Button("Allow (this tab)") {
                    store.allowBlockedDomainForSession(alert.host, sessionID: session.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)

                Button("Allow globally") {
                    store.allowBlockedDomainGlobally(alert.host, sessionID: session.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Button {
                store.dismissProxyAlert(for: session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background((isLeak ? Color.red : Color.orange).opacity(isLeak ? 0.16 : 0.11))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }
}

private struct EmptyHeaderBar: View {
    @ObservedObject var store: SessionStore
    let leadingTrafficLightClearance: Bool

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 8) {
                if leadingTrafficLightClearance {
                    Spacer().frame(width: 68)
                }
                if !store.sidebarVisible {
                    ChromeIconButton(
                        systemName: store.sidebarPosition == .left ? "sidebar.left" : "sidebar.right",
                        helpText: "Show Sidebar (⌘B)",
                        size: 12.5
                    ) {
                        store.toggleSidebarVisibility()
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
    }
}

private struct EmptyWorkspaceView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No open sessions")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            SoftPillButton(
                title: "New Session",
                systemName: "plus",
                shortcut: "⌘T",
                tint: Color.primary.opacity(0.9),
                hoverTint: .primary,
                baseFill: Color.primary.opacity(0.08),
                hoverFill: Color.primary.opacity(0.14),
                helpText: "New Sandboxed Session (⌘T)"
            ) {
                store.newSession(mode: .sandbox)
            }
            .frame(width: 170)

            Text("⌘T new session · ⇧⌘N private VM · ⌥⌘T host shell")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class HeaderRenameState: ObservableObject {
    @Published var isEditing = false
    @Published var isHoveringTitle = false
    @Published var draftName = ""
}

private struct SessionHeaderBar: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var session: TerminalSession
    let leadingTrafficLightClearance: Bool
    @StateObject private var renameState = HeaderRenameState()
    @FocusState private var headerRenameFocused: Bool

    var body: some View {
        if session.mode.isRawHost {
            rawHostHeader
        } else {
            sandboxHeader
        }
    }

    // MARK: - Refined Sandbox Header (Unified with Titlebar)

    private var sandboxHeader: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 8) {
                if leadingTrafficLightClearance {
                    Spacer().frame(width: 68)
                }

                if !store.sidebarVisible {
                    ChromeIconButton(
                        systemName: store.sidebarPosition == .left ? "sidebar.left" : "sidebar.right",
                        helpText: "Show Sidebar (⌘B)",
                        size: 12.5
                    ) {
                        store.toggleSidebarVisibility()
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(vmStatusColor)
                        .frame(width: 7, height: 7)

                    if renameState.isEditing {
                        TextField("Rename session…", text: $renameState.draftName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .frame(minWidth: 110, maxWidth: 220)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                                    )
                            )
                            .focused($headerRenameFocused)
                            .onSubmit {
                                store.renameSession(session.id, to: renameState.draftName)
                                renameState.isEditing = false
                            }
                            .onExitCommand {
                                renameState.isEditing = false
                                store.refocusActiveTerminal()
                            }
                            .onAppear {
                                renameState.draftName = session.customTitle ?? session.displayTitle
                                headerRenameFocused = true
                            }
                    } else {
                        Button {
                            renameState.draftName = session.customTitle ?? session.displayTitle
                            renameState.isEditing = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(session.displayTitle)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Color.primary.opacity(0.9))
                                    .lineLimit(1)
                                Image(systemName: "pencil")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .opacity(renameState.isHoveringTitle ? 0.85 : 0.28)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(renameState.isHoveringTitle ? Color.primary.opacity(0.08) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.10)) {
                                renameState.isHoveringTitle = hovering
                            }
                        }
                        .help("Click to rename session (⇧⌘E)")
                    }
                    if let pwd = session.displayPwd {
                        Text("—")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.primary.opacity(0.22))

                        Text(pwd)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.42))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text(vmPillText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(vmStatusColor.opacity(0.9))
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(vmStatusColor.opacity(0.11))
                        )
                        .help(vmTooltip)
                }

                Spacer(minLength: 8)


                if session.paneCount > 1 {
                    Text("\(session.paneCount) panes")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                paneToolbarButtons
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
        .background(Color(nsColor: store.themeBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    // MARK: - Modern Unmistakable Raw Host Warning Header

    private var rawHostHeader: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 8) {
                if leadingTrafficLightClearance {
                    Spacer().frame(width: 68)
                }

                if !store.sidebarVisible {
                    ChromeIconButton(
                        systemName: store.sidebarPosition == .left ? "sidebar.left" : "sidebar.right",
                        helpText: "Show Sidebar (⌘B)",
                        tint: Color(red: 1.0, green: 0.45, blue: 0.42),
                        activeTint: Color(red: 1.0, green: 0.55, blue: 0.52),
                        size: 12.5
                    ) {
                        store.toggleSidebarVisibility()
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("HOST SHELL · UNSANDBOXED")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                }
                .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.45))
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(Color.red.opacity(0.18))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.red.opacity(0.32), lineWidth: 0.5)
                        )
                )

                Text("Full macOS access")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 1.0, green: 0.65, blue: 0.62).opacity(0.78))
                    .lineLimit(1)

                Spacer(minLength: 8)

                SoftPillButton(
                    title: "New Session",
                    systemName: "plus",
                    tint: Color.primary.opacity(0.85),
                    hoverTint: .primary,
                    baseFill: Color.primary.opacity(0.08),
                    hoverFill: Color.primary.opacity(0.14),
                    helpText: "Open a Sandboxed Session (⌘T)"
                ) {
                    store.newSession(mode: .sandbox)
                }
                .scaleEffect(0.90)

                paneToolbarButtons
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.42, green: 0.09, blue: 0.10).opacity(0.55),
                    Color(red: 0.30, green: 0.06, blue: 0.08).opacity(0.38),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .background(Color(nsColor: store.themeBackground))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(red: 1.0, green: 0.34, blue: 0.32).opacity(0.38))
                .frame(height: 0.75)
        }
    }

    private var vmStatusColor: Color {
        if session.mode == .sandbox {
            return Color(red: 0.25, green: 0.84, blue: 0.72)
        }
        switch session.vmState {
        case .booting, .provisioning: return Color.orange
        case .failed: return Color.red
        default: return Color(red: 0.38, green: 0.72, blue: 1.0)
        }
    }

    private var vmPillText: String {
        if session.mode == .sandbox {
            if let shortID = session.macSandbox?.shortID {
                return "sandbox · \(shortID)"
            }
            return "sandbox"
        }
        switch session.vmState {
        case .booting: return "booting…"
        case .provisioning: return "installing…"
        case .failed: return "vm error"
        default:
            if session.wasWarmPooled {
                return "private vm · warm"
            }
            if let ms = session.bootTimeMs {
                return "private vm · \(Int(ms.rounded()))ms"
            }
            return "private vm"
        }
    }

    private var vmTooltip: String {
        if session.mode == .sandbox, let sb = session.macSandbox {
            return "macOS kernel sandbox (Seatbelt) — files persist in \(sb.shortDisplayPath); real $HOME & outside writes blocked"
        }
        switch session.vmState {
        case .provisioning: return "Running Private VM startup script (/var/log/boobox-setup.log)"
        case .failed(let msg): return "VM error: \(msg)"
        default: return "Private Linux microVM (Virtualization.framework) — zero Mac access, wiped on close"
        }
    }

    private var paneToolbarButtons: some View {
        HStack(spacing: 4) {
            if !session.mode.isRawHost {
                let badge = session.overrides.shortBadge(isLinuxVM: session.mode.isLinuxVM)
                let accent = session.mode.isLinuxVM
                    ? Color(red: 0.38, green: 0.72, blue: 1.0)
                    : Color(red: 0.25, green: 0.84, blue: 0.72)
                Button {
                    store.openSandboxConfig(for: session.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                    }
                    .foregroundStyle(badge != nil ? accent : Color.secondary)
                    .padding(.horizontal, badge != nil ? 7 : 5)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(badge != nil ? accent.opacity(0.13) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Configure This Sandbox… (⌥⌘,)")
            }

            if session.macSandbox != nil {
                ChromeIconButton(
                    systemName: "folder",
                    helpText: "Reveal Session Folder in Finder",
                    size: 11.5
                ) {
                    store.revealSessionInFinder(session.id)
                }
            }

            if session.mode.isLinuxVM {
                ChromeIconButton(
                    systemName: "arrow.counterclockwise",
                    helpText: "Reset Private VM to Clean State (⇧⌘K)",
                    size: 11.5
                ) {
                    store.resetSessionVM(session.id)
                }
            }

            ChromeIconButton(
                systemName: "rectangle.split.2x1",
                helpText: "Split Right (⌘D)",
                size: 12
            ) {
                store.splitFocusedPane(direction: .right)
            }

            ChromeIconButton(
                systemName: "rectangle.split.1x2",
                helpText: "Split Down (⇧⌘D)",
                size: 12
            ) {
                store.splitFocusedPane(direction: .down)
            }
        }
    }
}

@MainActor
private final class ResizeDragState: ObservableObject {
    @Published var isHovering = false
    var dragStartWidth: CGFloat?
}

private struct SidebarResizeHandle: View {
    @ObservedObject var store: SessionStore
    let position: SidebarPosition

    @StateObject private var dragState = ResizeDragState()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(dragState.isHovering ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08))
                .frame(width: dragState.isHovering ? 1.5 : 0.5)
        }
        .frame(width: 5)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                dragState.isHovering = hovering
            }
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragState.dragStartWidth == nil {
                        dragState.dragStartWidth = store.sidebarWidth
                    }
                    let base = dragState.dragStartWidth ?? store.sidebarWidth
                    let delta = position == .left ? value.translation.width : -value.translation.width
                    store.sidebarWidth = min(
                        max(base + delta, SessionStore.minSidebarWidth),
                        SessionStore.maxSidebarWidth
                    )
                }
                .onEnded { _ in
                    dragState.dragStartWidth = nil
                }
        )
    }
}
