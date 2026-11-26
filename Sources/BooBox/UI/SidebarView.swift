import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class SidebarDragState: ObservableObject {
    var draggedSessionID: UUID?
}

@MainActor
private final class SessionRowLocalState: ObservableObject {
    @Published var isHovered = false
    @Published var showingActions = false
    @Published var draftTitle = ""
}

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @StateObject private var dragState = SidebarDragState()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topTitleHeader
            launchControls
            searchBar
            if let cloningName = store.cloningProjectName {
                cloningBanner(cloningName)
            }
            sessionList
            footerBar
        }
        .onChange(of: store.searchFocusRequestID) { _, _ in
            searchFocused = true
        }
        .background {
            ZStack {
                VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
                // Subtle tint marrying the macOS glass sidebar to the active Ghostty theme
                Color(nsColor: store.themeBackground).opacity(0.42)
            }
        }
    }

    // MARK: - Top Draggable Header (Traffic-light aware)

    private var topTitleHeader: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 6) {
                if store.sidebarPosition == .left {
                    // Clear space for native macOS traffic lights floating in top-left
                    Spacer().frame(width: 68)
                } else {
                    Text("boo_box")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                ChromeIconButton(
                    systemName: store.sidebarPosition == .left ? "sidebar.leading" : "sidebar.trailing",
                    helpText: "Hide Sidebar (⌘B)",
                    size: 12
                ) {
                    store.toggleSidebarVisibility()
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 38)
    }

    // MARK: - Unified Split Action Button (+ New Session | ▾)

    private var launchControls: some View {
        NewSessionSplitButton(
            onNewSandbox: { store.newSession(mode: .sandbox) },
            onOpenProjectFolder: { store.openProjectFolderPicker() },
            onPinFolder: { store.pinFolderPicker() },
            onNewPrivateVM: { store.newSession(mode: .linuxVM) },
            onNewHostShell: { store.newSession(mode: .rawHost) }
        )
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    // MARK: - Live Session Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(searchFocused ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.65))

            TextField("Search sessions…", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($searchFocused)
                .onExitCommand {
                    store.searchQuery = ""
                    searchFocused = false
                    store.refocusActiveTerminal()
                }

            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            } else if !searchFocused {
                Text("⇧⌘F")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(searchFocused ? 0.095 : 0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            searchFocused ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06),
                            lineWidth: searchFocused ? 1 : 0.5
                        )
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }


    private func cloningBanner(_ projectName: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("\(BooBoxConfigManager.shared.config.general.workspaceMode == .overlay ? "Opening" : "Cloning") \(projectName)…")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Cancel") {
                store.cancelActiveProjectClone()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Cancel cloning and clean up partial session")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func sectionHeader(title: String, count: Int, topPadding: CGFloat = 2) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.top, topPadding)
        .padding(.bottom, 2)
    }
    // MARK: - Session List

    private var sessionList: some View {
        let visibleSessions = store.filteredSessions
        let visibleSaved = store.filteredSavedMacSessions
        let isSearching = !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                if isSearching && visibleSessions.isEmpty && visibleSaved.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No matching sessions")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Button("Clear Search") {
                            store.searchQuery = ""
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    if !isSearching && !store.pinnedFolderPaths.isEmpty {
                        pinnedFoldersSection
                    }
                    if !visibleSessions.isEmpty {
                        sectionHeader(title: "OPEN", count: visibleSessions.count, topPadding: (!isSearching && !store.pinnedFolderPaths.isEmpty) ? 10 : 2)
                        ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { index, session in
                            let realIndex = store.sessions.firstIndex(where: { $0.id == session.id }) ?? index
                            let srcPath = session.macSandbox?.sourceProjectPath
                            SessionRowView(
                                session: session,
                                index: realIndex,
                                isSelected: store.selectedSessionID == session.id,
                                isRenaming: store.renamingSessionID == session.id,
                                sidebarPosition: store.sidebarPosition,
                                isFolderPinned: srcPath.map { store.isFolderPinned($0) } ?? false,
                                onSelect: { store.selectSession(session.id) },
                                onConfigure: { store.openSandboxConfig(for: session.id) },
                                onClose: { store.closeSession(session.id) },
                                onDeletePermanently: { store.deleteActiveSessionPermanently(session.id) },
                                onBeginRename: { store.renamingSessionID = session.id },
                                onCommitRename: { newName in store.renameSession(session.id, to: newName) },
                                onCancelRename: { store.renamingSessionID = nil },
                                onSplitRight: {
                                    store.selectSession(session.id)
                                    store.splitFocusedPane(direction: .right)
                                },
                                onSplitDown: {
                                    store.selectSession(session.id)
                                    store.splitFocusedPane(direction: .down)
                                },
                                onDuplicate: { store.duplicateSession(session.id) },
                                onTogglePinFolder: srcPath.map { path in { store.togglePinFolder(path) } },
                                onResetVM: { store.resetSessionVM(session.id) },
                                onRevealFolder: { store.revealSessionInFinder(session.id) },
                                onToggleSidebarSide: { store.toggleSidebarPosition() }
                            )
                            .onDrag {
                                return NSItemProvider(object: session.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: SessionDropDelegate(
                                    targetSessionID: session.id,
                                    dragState: dragState,
                                    store: store
                                )
                            )
                        }
                    }
                    if !visibleSaved.isEmpty {
                        savedMacSessionsSection(items: visibleSaved, hasOpenSessions: !visibleSessions.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
    }
    private var pinnedFoldersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(title: "PINNED", count: store.pinnedFolderPaths.count, topPadding: 2)
            ForEach(store.pinnedFolderPaths, id: \.self) { path in
                PinnedFolderRowView(
                    path: path,
                    onOpen: { store.openProjectFolder(URL(fileURLWithPath: path, isDirectory: true)) },
                    onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)]) },
                    onUnpin: { store.unpinFolder(path) }
                )
            }
        }
    }


    private func savedMacSessionsSection(items: [SavedMacSandboxItem], hasOpenSessions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader(title: "PAST", count: items.count, topPadding: hasOpenSessions ? 14 : 2)

            ForEach(items) { item in
                SavedMacSessionRowView(
                    item: item,
                    isRenaming: store.renamingSavedSessionID == item.id,
                    sidebarPosition: store.sidebarPosition,
                    onResume: { store.resumeSavedMacSession(item.sandbox) },
                    onConfigure: { store.openSandboxConfig(forSaved: item.sandbox) },
                    onBeginRename: { store.renamingSavedSessionID = item.id },
                    onCommitRename: { newName in store.renameSavedMacSession(item.sandbox, to: newName) },
                    onCancelRename: { store.renamingSavedSessionID = nil },
                    onReveal: { store.revealMacSandboxInFinder(item.sandbox) },
                    onDelete: { store.deleteSavedMacSession(item.sandbox) }
                )
            }
        }
    }

    // MARK: - Minimal Footer

    private var footerBar: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("boo_box")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("powered by Ghostty")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .help("boo_box · powered by \(GhosttyRuntime.shared.versionString)")

            Spacer(minLength: 4)

            ChromeIconButton(
                systemName: "gearshape",
                helpText: "Settings… (⌘,)",
                size: 12
            ) {
                store.openSettings()
            }

            HStack(spacing: 2) {
                dockToggleSegment(position: .left, icon: "sidebar.left", help: "Dock Sidebar Left")
                dockToggleSegment(position: .right, icon: "sidebar.right", help: "Dock Sidebar Right")
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    private func dockToggleSegment(position: SidebarPosition, icon: String, help: String) -> some View {
        let active = store.sidebarPosition == position
        return Button {
            store.setSidebarPosition(position)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.7))
                .frame(width: 26, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? Color.primary.opacity(0.13) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(help) (⌥⌘S)")
    }
}

private struct SessionRowView: View {
    @ObservedObject var session: TerminalSession
    let index: Int
    let isSelected: Bool
    let isRenaming: Bool
    let sidebarPosition: SidebarPosition
    let isFolderPinned: Bool

    let onSelect: () -> Void
    let onConfigure: () -> Void
    let onClose: () -> Void
    let onDeletePermanently: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onSplitRight: () -> Void
    let onSplitDown: () -> Void
    let onDuplicate: () -> Void
    let onTogglePinFolder: (() -> Void)?
    let onResetVM: () -> Void
    let onRevealFolder: () -> Void
    let onToggleSidebarSide: () -> Void
    @StateObject private var local = SessionRowLocalState()
    @FocusState private var renameFocused: Bool

    private var accentColor: Color {
        switch session.mode {
        case .rawHost: return Color(red: 1.0, green: 0.38, blue: 0.36)
        case .linuxVM: return Color(red: 0.38, green: 0.72, blue: 1.0)
        case .sandbox: return Color(red: 0.25, green: 0.84, blue: 0.72)
        }
    }

    private var modeSymbol: String {
        switch session.mode {
        case .rawHost: return "exclamationmark.triangle.fill"
        case .linuxVM: return "eye.slash"
        case .sandbox: return "lock.shield"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Refined leading selection indicator
            Capsule()
                .fill(isSelected ? accentColor : Color.clear)
                .frame(width: 2.5, height: 18)
                .padding(.trailing, 7)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 7) {
                    Image(systemName: modeSymbol)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isSelected ? accentColor : accentColor.opacity(0.72))
                        .frame(width: 14)

                    if isRenaming {
                        TextField("Rename session…", text: $local.draftTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                                    )
                            )
                            .focused($renameFocused)
                            .onSubmit {
                                onCommitRename(local.draftTitle)
                            }
                            .onExitCommand {
                                onCancelRename()
                            }
                            .onAppear {
                                local.draftTitle = session.customTitle ?? session.displayTitle
                                renameFocused = true
                            }
                    } else {
                        Text(session.displayTitle)
                            .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if session.pendingProxyAlert?.decision == "leak_blocked" {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .help("Blocked secret exfiltration attempt")
                    } else if session.isRunningCommand {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color(red: 0.25, green: 0.84, blue: 0.72))
                                .frame(width: 5.5, height: 5.5)
                            if let proc = session.runningProcessName, !proc.isEmpty, proc != "zsh" {
                                Text(proc)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.25, green: 0.84, blue: 0.72))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.84, blue: 0.72).opacity(0.14)))
                        .help("Command running inside sandbox")
                    } else if session.hasUnreadBell && !isSelected {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            .help("Needs attention")
                    }
                    Spacer(minLength: 4)

                    if !isRenaming {
                        if let badge = session.overrides.shortBadge(isLinuxVM: session.mode.isLinuxVM), !local.isHovered && !local.showingActions {
                            Text(badge)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(accentColor.opacity(0.14)))
                        }

                        // Fixed-width trailing trigger: never slides inward or covers the session title;
                        // opens an outward popover menu extending away from the sidebar.
                        ZStack {
                            if local.isHovered || local.showingActions {
                                Button {
                                    local.showingActions.toggle()
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(local.showingActions ? Color.primary : Color.secondary)
                                        .frame(width: 22, height: 18)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .fill(Color.primary.opacity(local.showingActions ? 0.16 : 0.09))
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Session Actions")
                            } else if index < 9 {
                                Text("⌘\(index + 1)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary.opacity(isSelected ? 0.9 : 0.65))
                            }
                        }
                        .frame(width: 24, height: 18)
                        .popover(
                            isPresented: $local.showingActions,
                            attachmentAnchor: .rect(.bounds),
                            arrowEdge: sidebarPosition == .left ? .trailing : .leading
                        ) {
                            sessionActionsPopover
                        }
                    }
                }

                if session.displayPwd != nil || session.paneCount > 1 {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 15)

                        if let pwd = session.displayPwd {
                            Text(pwd)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(isSelected ? 0.48 : 0.36))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }

                        Spacer(minLength: 2)

                        if session.paneCount > 1 {
                            Text("\(session.paneCount) splits")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                    }
                }

                if let progress = session.activeProgress {
                    ProgressView(value: progress.percent.map { Double($0) / 100.0 })
                        .progressViewStyle(.linear)
                        .tint(progress.state == .error ? .red : accentColor)
                        .scaleEffect(x: 1, y: 0.55, anchor: .center)
                        .padding(.leading, 21)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.11)) {
                local.isHovered = hovering
            }
        }
        .onTapGesture(count: 2) {
            onBeginRename()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .contextMenu {
            if !session.mode.isRawHost {
                Button("Configure Sandbox… (⌥⌘,)", action: onConfigure)
            }
            Button("Rename Session…", action: onBeginRename)
            Divider()
            Button("Split Right (⌘D)", action: onSplitRight)
            Button("Split Down (⇧⌘D)", action: onSplitDown)
            Button("Duplicate Session", action: onDuplicate)
            if let onTogglePinFolder {
                Button(isFolderPinned ? "Unpin Folder from Sidebar" : "Pin Folder to Sidebar", action: onTogglePinFolder)
            }
            if session.macSandbox != nil {
                Button("Reveal Session Folder in Finder", action: onRevealFolder)
            }
            if session.mode.isLinuxVM {
                Button("Reset Private VM", action: onResetVM)
            }
            Divider()
            Button(
                sidebarPosition == .left ? "Move Sidebar to Right" : "Move Sidebar to Left",
                action: onToggleSidebarSide
            )
            Divider()
            Button("Close Tab", action: onClose)
            if session.macSandbox != nil {
                Button("Delete Entire Session…", role: .destructive, action: onDeletePermanently)
            }
        }
    }

    private var sessionActionsPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !session.mode.isRawHost {
                SessionPopoverActionRow(
                    icon: "slider.horizontal.3",
                    title: "Configure Sandbox…",
                    shortcut: "⌥⌘,",
                    badge: session.overrides.shortBadge(isLinuxVM: session.mode.isLinuxVM),
                    accent: accentColor
                ) {
                    local.showingActions = false
                    onConfigure()
                }
            }
            SessionPopoverActionRow(icon: "pencil", title: "Rename Session…", shortcut: "⇧⌘E") {
                local.showingActions = false
                onBeginRename()
            }
            Divider().padding(.vertical, 3)
            SessionPopoverActionRow(icon: "rectangle.split.2x1", title: "Split Right", shortcut: "⌘D") {
                local.showingActions = false
                onSplitRight()
            }
            SessionPopoverActionRow(icon: "rectangle.split.1x2", title: "Split Down", shortcut: "⇧⌘D") {
                local.showingActions = false
                onSplitDown()
            }
            SessionPopoverActionRow(icon: "plus.square.on.square", title: "Duplicate Session") {
                local.showingActions = false
                onDuplicate()
            }
            if let onTogglePinFolder {
                SessionPopoverActionRow(
                    icon: isFolderPinned ? "pin.slash" : "pin",
                    title: isFolderPinned ? "Unpin Folder" : "Pin Folder to Sidebar"
                ) {
                    local.showingActions = false
                    onTogglePinFolder()
                }
            }
            if session.macSandbox != nil {
                SessionPopoverActionRow(icon: "folder", title: "Reveal in Finder") {
                    local.showingActions = false
                    onRevealFolder()
                }
            }
            if session.mode.isLinuxVM {
                SessionPopoverActionRow(icon: "arrow.counterclockwise", title: "Reset Private VM", shortcut: "⇧⌘K") {
                    local.showingActions = false
                    onResetVM()
                }
            }
            Divider().padding(.vertical, 3)
            SessionPopoverActionRow(icon: "xmark", title: "Close Tab") {
                local.showingActions = false
                onClose()
            }
            if session.macSandbox != nil {
                SessionPopoverActionRow(icon: "trash", title: "Delete Entire Session…", isDestructive: true) {
                    local.showingActions = false
                    onDeletePermanently()
                }
            }
        }
        .padding(6)
        .frame(width: 224)
    }

    private var rowBackground: Color {
        if isSelected {
            return session.mode.isRawHost
                ? Color.red.opacity(0.14)
                : Color.primary.opacity(0.095)
        }
        if local.isHovered {
            return Color.primary.opacity(0.045)
        }
        return Color.clear
    }
}

private struct SavedMacSessionRowView: View {
    let item: SavedMacSandboxItem
    let isRenaming: Bool
    let sidebarPosition: SidebarPosition
    let onResume: () -> Void
    let onConfigure: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    @StateObject private var local = SessionRowLocalState()
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(red: 0.25, green: 0.84, blue: 0.72).opacity(0.85))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1.5) {
                if isRenaming {
                    TextField("Rename session…", text: $local.draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                                )
                        )
                        .focused($renameFocused)
                        .onSubmit {
                            onCommitRename(local.draftTitle)
                        }
                        .onExitCommand {
                            onCancelRename()
                        }
                        .onAppear {
                            local.draftTitle = item.sandbox.name
                            renameFocused = true
                        }
                } else {
                    Text(item.sandbox.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(
                    item.sandbox.isOverlay
                        ? (item.fileCount == 0
                            ? "\(item.sandbox.shortID) · overlay · clean"
                            : "\(item.sandbox.shortID) · overlay · \(item.fileCount) edit\(item.fileCount == 1 ? "" : "s")")
                        : "\(item.sandbox.shortID) · \(item.fileCount) item\(item.fileCount == 1 ? "" : "s")"
                )
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if !isRenaming {
                if let badge = item.sandbox.overrides.shortBadge(isLinuxVM: false), !local.isHovered && !local.showingActions {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.25, green: 0.84, blue: 0.72))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.84, blue: 0.72).opacity(0.14)))
                }

                ZStack {
                    if local.isHovered || local.showingActions {
                        Button {
                            local.showingActions.toggle()
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(local.showingActions ? Color.primary : Color.secondary)
                                .frame(width: 22, height: 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.primary.opacity(local.showingActions ? 0.16 : 0.09))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Saved Session Actions")
                    }
                }
                .frame(width: 22, height: 18)
                .popover(
                    isPresented: $local.showingActions,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: sidebarPosition == .left ? .trailing : .leading
                ) {
                    savedSessionActionsPopover
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(local.isHovered || local.showingActions ? Color.primary.opacity(0.055) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.11)) {
                local.isHovered = hovering
            }
        }
        .onTapGesture {
            if !isRenaming {
                onResume()
            }
        }
        .contextMenu {
            Button("Reopen in Sandbox", action: onResume)
            Button("Configure Sandbox…", action: onConfigure)
            Button("Rename Session…", action: onBeginRename)
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Delete Entire Session…", role: .destructive, action: onDelete)
        }
        .help("Click to reopen persisted session at \(item.sandbox.shortDisplayPath)")
    }

    private var savedSessionActionsPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            SessionPopoverActionRow(icon: "arrow.uturn.forward", title: "Reopen in Sandbox") {
                local.showingActions = false
                onResume()
            }
            SessionPopoverActionRow(
                icon: "slider.horizontal.3",
                title: "Configure Sandbox…",
                badge: item.sandbox.overrides.shortBadge(isLinuxVM: false),
                accent: Color(red: 0.25, green: 0.84, blue: 0.72)
            ) {
                local.showingActions = false
                onConfigure()
            }
            SessionPopoverActionRow(icon: "pencil", title: "Rename Session…") {
                local.showingActions = false
                onBeginRename()
            }
            SessionPopoverActionRow(icon: "folder", title: "Reveal in Finder") {
                local.showingActions = false
                onReveal()
            }
            Divider().padding(.vertical, 3)
            SessionPopoverActionRow(icon: "trash", title: "Delete Entire Session…", isDestructive: true) {
                local.showingActions = false
                onDelete()
            }
        }
        .padding(6)
        .frame(width: 214)
    }
}

@MainActor
private final class PinnedRowHoverState: ObservableObject {
    @Published var isHovered = false
}

private struct PinnedFolderRowView: View {
    let path: String
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onUnpin: () -> Void
    @StateObject private var hover = PinnedRowHoverState()

    private let mintAccent = Color(red: 0.25, green: 0.84, blue: 0.72)

    private var displayName: String {
        URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(mintAccent.opacity(0.85))
                .frame(width: 14)

            Text(displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(hover.isHovered ? 0.95 : 0.80))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if hover.isHovered {
                Button(action: onUnpin) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Unpin \(displayName)")
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hover.isHovered ? mintAccent.opacity(0.10) : Color.primary.opacity(0.035))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.11)) {
                hover.isHovered = hovering
            }
        }
        .onTapGesture { onOpen() }
        .contextMenu {
            Button("Open in New Sandbox", action: onOpen)
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Unpin Folder", role: .destructive, action: onUnpin)
        }
        .help("Click to open a fresh isolated sandbox of \(path)")
    }
}

@MainActor
private final class PopoverRowHoverState: ObservableObject {
    @Published var hovered = false
}

private struct SessionPopoverActionRow: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    var badge: String? = nil
    var accent: Color = Color(red: 0.25, green: 0.84, blue: 0.72)
    var isDestructive: Bool = false
    let action: () -> Void

    @StateObject private var hoverState = PopoverRowHoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 15)
                    .foregroundStyle(isDestructive ? Color.red : (hoverState.hovered ? Color.primary : Color.secondary))
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(isDestructive ? Color.red : Color.primary)
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(accent.opacity(0.14)))
                } else if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hoverState.hovered ? (isDestructive ? Color.red.opacity(0.12) : Color.primary.opacity(0.09)) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoverState.hovered = $0 }
    }
}

private struct SessionDropDelegate: DropDelegate {
    let targetSessionID: UUID
    let dragState: SidebarDragState
    let store: SessionStore

    func dropEntered(info: DropInfo) {
        guard let draggedID = dragState.draggedSessionID,
              draggedID != targetSessionID,
              let fromIndex = store.sessions.firstIndex(where: { $0.id == draggedID }),
              let toIndex = store.sessions.firstIndex(where: { $0.id == targetSessionID }) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.14)) {
            let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
            store.moveSession(from: fromIndex, to: destination)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragState.draggedSessionID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
