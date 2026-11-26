import AppKit
import SwiftUI

struct CommandPaletteItem: Identifiable {
    enum Kind {
        case openSession(UUID)
        case savedSession(MacSandboxSession)
        case action(() -> Void)
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let accentColor: Color
    let shortcut: String?
    let badge: String?
    let kind: Kind
}

/// Keyboard-first Command Palette / Quick Switcher (`⌘K`) for jumping across open sessions,
@MainActor
private final class CommandPaletteState: ObservableObject {
    @Published var query = ""
    @Published var selectedIndex = 0
}

struct CommandPaletteOverlay: View {
    @ObservedObject var store: SessionStore
    @StateObject private var local = CommandPaletteState()

    private var filteredItems: [CommandPaletteItem] {
        let all = buildAllItems()
        let q = local.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        let terms = q.split(separator: " ").map(String.init)
        return all.filter { item in
            let haystack = "\(item.title) \(item.subtitle) \(item.badge ?? "")".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture {
                    store.closeCommandPalette()
                }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    CommandPaletteSearchField(
                        text: $local.query,
                        placeholder: "Jump to session or run a command…",
                        onMoveUp: {
                            let count = filteredItems.count
                            if count > 0 { local.selectedIndex = (local.selectedIndex - 1 + count) % count }
                        },
                        onMoveDown: {
                            let count = filteredItems.count
                            if count > 0 { local.selectedIndex = (local.selectedIndex + 1) % count }
                        },
                        onSubmit: {
                            executeSelected()
                        },
                        onCancel: {
                            store.closeCommandPalette()
                        }
                    )
                    .frame(height: 22)

                    if !local.query.isEmpty {
                        Button {
                            local.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("esc")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().opacity(0.5)

                let items = filteredItems
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Text("No matching sessions or commands")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                    paletteRow(item, isSelected: idx == local.selectedIndex)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            execute(item)
                                        }
                                        .onHover { hovering in
                                            if hovering { local.selectedIndex = idx }
                                        }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: local.selectedIndex) { _, nextIdx in
                            if items.indices.contains(nextIdx) {
                                proxy.scrollTo(items[nextIdx].id, anchor: .center)
                            }
                        }
                    }
                }

                Divider().opacity(0.4)

                HStack(spacing: 14) {
                    hintKey("↑↓", "navigate")
                    hintKey("↵", "select")
                    hintKey("esc", "close")
                    Spacer()
                    Text("\(items.count) items")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.03))
            }
            .frame(width: 560)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 24, y: 12)
            .padding(.top, 64)
        }
        .onAppear {
            local.selectedIndex = 0
        }
        .onChange(of: local.query) { _, _ in
            local.selectedIndex = 0
        }
    }

    private func paletteRow(_ item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isSelected ? item.accentColor : item.accentColor.opacity(0.8))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let badge = item.badge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(item.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(item.accentColor.opacity(0.14)))
                    }
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private func hintKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func executeSelected() {
        let items = filteredItems
        guard items.indices.contains(local.selectedIndex) else { return }
        execute(items[local.selectedIndex])
    }

    private func execute(_ item: CommandPaletteItem) {
        store.closeCommandPalette()
        switch item.kind {
        case .openSession(let id):
            store.selectSession(id)
        case .savedSession(let sb):
            store.resumeSavedMacSession(sb)
        case .action(let fn):
            fn()
        }
    }

    private func buildAllItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // 1. Open sessions
        for (idx, sess) in store.sessions.enumerated() {
            let color: Color = sess.mode.isRawHost
                ? Color(red: 1.0, green: 0.42, blue: 0.38)
                : (sess.mode.isLinuxVM ? Color(red: 0.38, green: 0.72, blue: 1.0) : Color(red: 0.25, green: 0.84, blue: 0.72))
            let badge: String? = sess.isRunningCommand
                ? (sess.runningProcessName.map { "running · \($0)" } ?? "running")
                : (sess.id == store.selectedSessionID ? "active" : nil)
            items.append(CommandPaletteItem(
                id: "open-\(sess.id.uuidString)",
                title: sess.displayTitle,
                subtitle: sess.displayPwd ?? sess.mode.label,
                symbol: sess.mode.isRawHost ? "exclamationmark.triangle.fill" : (sess.mode.isLinuxVM ? "cpu" : "lock.shield"),
                accentColor: color,
                shortcut: idx < 9 ? "⌘\(idx + 1)" : nil,
                badge: badge,
                kind: .openSession(sess.id)
            ))
        }

        // 2. Quick actions
        let actions: [(String, String, String, Color, String?, () -> Void)] = [
            ("New Session", "Create a new isolated sandbox tab", "plus.square", Color(red: 0.25, green: 0.84, blue: 0.72), "⌘T", { store.newSession(mode: .sandbox) }),
            ("New Scratch Sandbox", "Create an empty scratch macOS sandbox", "sparkles", Color(red: 0.25, green: 0.84, blue: 0.72), nil, { store.newScratchSession() }),
            ("Open Folder in Sandbox…", "Zero-copy APFS clone a project folder", "folder.badge.plus", Color(red: 0.25, green: 0.84, blue: 0.72), "⇧⌘O", { store.openProjectFolderPicker() }),
            ("New Private Linux VM", "Boot an isolated arm64 Linux microVM", "cpu", Color(red: 0.38, green: 0.72, blue: 1.0), "⇧⌘N", { store.newSession(mode: .linuxVM) }),
            ("New Unsandboxed Host Shell", "Open raw macOS shell with host access", "exclamationmark.triangle", Color(red: 1.0, green: 0.42, blue: 0.38), "⌥⌘T", { store.newSession(mode: .rawHost) }),
            ("Configure Active Sandbox…", "Per-sandbox network, secrets, env & resource limits", "slider.horizontal.3", .accentColor, "⌥⌘,", { store.openActiveSandboxConfig() }),
            ("Rename Active Session…", "Set a custom title for the current session", "pencil", .secondary, "⇧⌘E", { store.beginRenameActiveSession() }),
            ("Split Pane Right", "Add a horizontal split inside this sandbox", "rectangle.split.2x1", .secondary, "⌘D", { store.splitFocusedPane(direction: .right) }),
            ("Split Pane Down", "Add a vertical split inside this sandbox", "rectangle.split.1x2", .secondary, "⇧⌘D", { store.splitFocusedPane(direction: .down) }),
            ("Toggle Sidebar", "Show or hide the session sidebar", "sidebar.left", .secondary, "⌘B", { store.toggleSidebarVisibility() }),
            ("Flip Sidebar Side", "Move sidebar between left and right", "arrow.left.arrow.right", .secondary, nil, { store.toggleSidebarPosition() }),
            ("Settings…", "Open boo_box Settings", "gearshape", .secondary, "⌘,", { store.openSettings() }),
            ("Connections (Apps & MCPs)…", "1-click setup for GitHub, cloud CLIs, MCP servers & LLM keys", "link.circle.fill", Color(red: 0.25, green: 0.84, blue: 0.72), nil, {
                SettingsNavState.shared.selectedTab = .connections
                store.openSettings()
            }),
            ("Find in Terminal…", "Search scrollback in the active terminal pane", "magnifyingglass", .accentColor, "⌘F", { store.openTerminalSearch() }),
            ("Check for Updates…", "Check github.com/apguan/boo_box for updates", "arrow.down.circle", .accentColor, nil, {
                SettingsNavState.shared.selectedTab = .general
                store.openSettings()
                UpdateManager.shared.checkForUpdates(userInitiated: true)
            }),
        ]
        for (i, a) in actions.enumerated() {
            items.append(CommandPaletteItem(
                id: "act-\(i)-\(a.0)",
                title: a.0,
                subtitle: a.1,
                symbol: a.2,
                accentColor: a.3,
                shortcut: a.4,
                badge: nil,
                kind: .action(a.5)
            ))
        }

        // 3. Past saved sessions
        for saved in store.savedMacSessions {
            items.append(CommandPaletteItem(
                id: "saved-\(saved.id.uuidString)",
                title: saved.sandbox.name,
                subtitle: "Reopen saved sandbox · \(saved.sandbox.shortID) · \(saved.fileCount) items",
                symbol: "clock.arrow.circlepath",
                accentColor: .secondary,
                shortcut: nil,
                badge: "PAST",
                kind: .savedSession(saved.sandbox)
            ))
        }

        return items
    }
}

/// Native AppKit search field that claims `window.makeFirstResponder` immediately on mount
/// (preventing the sidebar search field or Metal terminal view from stealing focus) and
/// intercepts ↑ / ↓ / ↵ / Esc directly inside the field editor.
private struct CommandPaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 14)
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class AutoFocusTextField: NSTextField {
        private var didClaimInitialFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            claimFocusIfNeeded()
        }

        private func claimFocusIfNeeded() {
            guard !didClaimInitialFocus, let win = window else { return }
            didClaimInitialFocus = true
            DispatchQueue.main.async { [weak self, weak win] in
                guard let self, let win else { return }
                win.makeFirstResponder(self)
                if let editor = self.currentEditor() {
                    editor.selectedRange = NSRange(location: self.stringValue.utf16.count, length: 0)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandPaletteSearchField

        init(parent: CommandPaletteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
