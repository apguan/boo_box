import AppKit
import SwiftUI

/// Native macOS vibrancy surface (NSVisualEffectView) for modern translucent sidebar chrome.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Invisible AppKit hit target that initiates a native macOS window drag on mouseDown.
/// Used only on top chrome strips so dragging inside the terminal selects text normally.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// Lightweight ObservableObject hover box (avoids macOS 27 SwiftUIMacros @State dependency).
@MainActor
final class HoverState: ObservableObject {
    @Published var isHovered = false
}

/// Clean macOS-style borderless icon button with subtle rounded pill hover feedback.
struct ChromeIconButton: View {
    let systemName: String
    let helpText: String
    var tint: Color = .secondary
    var activeTint: Color = .primary
    var size: CGFloat = 12
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hover.isHovered ? activeTint : tint)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover.isHovered ? Color.primary.opacity(0.09) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hover.isHovered = hovering
            }
        }
        .help(helpText)
    }
}

/// Sleek soft-fill pill action button with refined hover highlight (no harsh outlined boxes).
struct SoftPillButton: View {
    let title: String
    let systemName: String
    var shortcut: String? = nil
    var tint: Color = .primary
    var hoverTint: Color = .primary
    var baseFill: Color = Color.primary.opacity(0.065)
    var hoverFill: Color = Color.primary.opacity(0.115)
    var expandWidth: Bool = false
    let helpText: String
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let shortcut {
                    Spacer(minLength: 4)
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(hover.isHovered ? hoverTint : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: expandWidth ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hover.isHovered ? hoverFill : baseFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(hover.isHovered ? 0.12 : 0.06), lineWidth: 0.5)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hover.isHovered = hovering
            }
        }
        .help(helpText)
    }
}
/// Unified frosted split-button: primary click creates a standard sandboxed session,
/// trailing chevron opens a native menu for specialized / unsandboxed host shells.
struct NewSessionSplitButton: View {
    var pinnedProjectName: String? = nil
    let onNewSandbox: () -> Void
    var onNewScratch: (() -> Void)? = nil
    let onOpenProjectFolder: () -> Void
    var onClearPinnedProject: (() -> Void)? = nil
    let onNewPrivateVM: () -> Void
    let onNewHostShell: () -> Void
    @StateObject private var primaryHover = HoverState()
    @StateObject private var menuHover = HoverState()

    private let mintAccent = Color(red: 0.25, green: 0.84, blue: 0.72)

    var body: some View {
        let isPinned = pinnedProjectName != nil
        HStack(spacing: 0) {
            Button(action: onNewSandbox) {
                HStack(spacing: 6) {
                    Image(systemName: isPinned ? "folder.badge.plus" : "plus")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isPinned ? mintAccent : Color.primary.opacity(primaryHover.isHovered ? 1.0 : 0.90))
                    Text(pinnedProjectName.map { "New \($0)" } ?? "New Session")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("⌘T")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Color.primary.opacity(primaryHover.isHovered ? 1.0 : 0.90))
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(primaryHover.isHovered ? Color.primary.opacity(0.06) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.11)) {
                    primaryHover.isHovered = hovering
                }
            }
            .help(
                pinnedProjectName.map { "New isolated APFS clone of \($0) (⌘T)" }
                    ?? "New Sandboxed Session (⌘T)"
            )

            Rectangle()
                .fill(isPinned ? mintAccent.opacity(0.22) : Color.primary.opacity(0.09))
                .frame(width: 0.5, height: 16)

            Menu {
                Section("Sandboxed") {
                    Button {
                        onNewSandbox()
                    } label: {
                        Label(
                            pinnedProjectName.map { "New \($0) Clone" } ?? "New Session",
                            systemImage: isPinned ? "folder.badge.plus" : "lock.shield"
                        )
                    }
                    if isPinned, let onNewScratch {
                        Button {
                            onNewScratch()
                        } label: {
                            Label("New Empty Scratch Session", systemImage: "lock.shield")
                        }
                    }
                    Button {
                        onOpenProjectFolder()
                    } label: {
                        Label("Open Folder in Sandbox…", systemImage: "folder")
                    }
                    if let name = pinnedProjectName, let onClearPinnedProject {
                        Button {
                            onClearPinnedProject()
                        } label: {
                            Label("Unpin \(name)", systemImage: "pin.slash")
                        }
                    }
                    Button {
                        onNewPrivateVM()
                    } label: {
                        Label("New Private VM", systemImage: "eye.slash")
                    }
                }
                Section("Unsandboxed") {
                    Button {
                        onNewHostShell()
                    } label: {
                        Label("New Host Shell", systemImage: "exclamationmark.triangle")
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(menuHover.isHovered ? Color.primary : Color.secondary)
                    .frame(width: 28, height: 30)
                    .background(menuHover.isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.11)) {
                    menuHover.isHovered = hovering
                }
            }
            .help("More Session Options (⇧⌘N Private VM · ⌥⌘T Host Shell)")
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPinned ? mintAccent.opacity(0.10) : Color.primary.opacity(0.075))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isPinned ? mintAccent.opacity(0.28) : Color.primary.opacity(0.09),
                            lineWidth: 0.5
                        )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
