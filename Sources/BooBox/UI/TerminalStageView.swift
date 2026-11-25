import AppKit
import SwiftUI

/// Persistent AppKit stage hosting all live session split trees.
/// Inactive sessions are hidden + occluded rather than dismantled, so switching
/// sessions or flipping the sidebar Left <-> Right never tears down Metal surfaces.
@MainActor
final class TerminalStageView: NSView {
    private var sessionContainers: [UUID: NSView] = [:]
    private var paneWrappers: [UUID: PaneContainerView] = [:]

    var backgroundColor: NSColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0) {
        didSet {
            layer?.backgroundColor = backgroundColor.cgColor
            for wrapper in paneWrappers.values {
                wrapper.updateBackground(backgroundColor)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func sync(sessions: [TerminalSession], selectedSessionID: UUID?, focusActive: Bool) {
        let validIDs = Set(sessions.map(\.id))

        for existingID in Array(sessionContainers.keys) where !validIDs.contains(existingID) {
            removeSession(existingID)
        }

        for session in sessions {
            if sessionContainers[session.id] == nil {
                rebuildSession(session)
            }
        }

        for session in sessions {
            let isActive = session.id == selectedSessionID
            if let container = sessionContainers[session.id] {
                container.isHidden = !isActive
            }
            for pane in session.rootNode.allPanes {
                pane.surfaceView.setVisible(isActive)
            }
            if isActive {
                updateFocusVisuals(for: session)
                if focusActive, let target = session.focusedPane?.surfaceView {
                    focusSurface(target)
                }
            }
        }
    }

    func rebuildSession(_ session: TerminalSession) {
        if let oldContainer = sessionContainers.removeValue(forKey: session.id) {
            oldContainer.removeFromSuperview()
        }

        let paneIDs = Set(session.rootNode.allPanes.map(\.id))
        for pane in session.rootNode.allPanes {
            pane.surfaceView.removeFromSuperview()
        }

        let isSplit = paneIDs.count > 1
        let rootView = buildView(from: session.rootNode, focusedPaneID: session.focusedPaneID, isSplit: isSplit)
        rootView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootView)

        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootView.topAnchor.constraint(equalTo: topAnchor),
            rootView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        sessionContainers[session.id] = rootView
        layoutSubtreeIfNeeded()
        for pane in session.rootNode.allPanes {
            pane.surfaceView.syncSurfaceSize()
        }
    }

    func removeSession(_ sessionID: UUID) {
        if let container = sessionContainers.removeValue(forKey: sessionID) {
            container.removeFromSuperview()
        }
        paneWrappers = paneWrappers.filter { $0.value.superview != nil }
    }

    func updateFocusVisuals(for session: TerminalSession) {
        let panes = session.rootNode.allPanes
        let showDim = panes.count > 1
        for pane in panes {
            let dimmed = showDim && pane.id != session.focusedPaneID
            paneWrappers[pane.id]?.setDimmed(dimmed)
        }
    }

    func focusSurface(_ surfaceView: TerminalSurfaceView, attemptsRemaining: Int = 5) {
        guard let window = surfaceView.window else {
            if attemptsRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak surfaceView] in
                    guard let self, let surfaceView else { return }
                    self.focusSurface(surfaceView, attemptsRemaining: attemptsRemaining - 1)
                }
            }
            return
        }
        if window.firstResponder !== surfaceView {
            window.makeFirstResponder(surfaceView)
        }
        surfaceView.syncSurfaceSize()
    }

    private func buildView(from node: SplitNode, focusedPaneID: UUID, isSplit: Bool) -> NSView {
        switch node {
        case .leaf(let pane):
            let wrapper = PaneContainerView(surfaceView: pane.surfaceView, backgroundColor: backgroundColor)
            wrapper.setDimmed(isSplit && pane.id != focusedPaneID)
            paneWrappers[pane.id] = wrapper
            return wrapper

        case .split(_, let axis, let first, let second):
            let splitView = HairlineSplitView()
            splitView.isVertical = (axis == .horizontal)
            splitView.dividerStyle = .thin

            let firstView = buildView(from: first, focusedPaneID: focusedPaneID, isSplit: true)
            let secondView = buildView(from: second, focusedPaneID: focusedPaneID, isSplit: true)

            splitView.addArrangedSubview(firstView)
            splitView.addArrangedSubview(secondView)
            splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

            DispatchQueue.main.async { [weak splitView] in
                guard let splitView else { return }
                let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
                if total > 40 {
                    splitView.setPosition(total / 2.0, ofDividerAt: 0)
                }
            }
            return splitView
        }
    }
}

@MainActor
private final class PaneContainerView: NSView {
    private static let innerPadding: CGFloat = 10

    private let surfaceView: TerminalSurfaceView
    private let dimView: PassthroughDimView

    init(surfaceView: TerminalSurfaceView, backgroundColor: NSColor) {
        self.surfaceView = surfaceView
        self.dimView = PassthroughDimView()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        dimView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(surfaceView)
        addSubview(dimView)

        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.innerPadding),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.innerPadding),
            surfaceView.topAnchor.constraint(equalTo: topAnchor, constant: Self.innerPadding - 2),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.innerPadding),

            dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimView.topAnchor.constraint(equalTo: topAnchor),
            dimView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func updateBackground(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    func setDimmed(_ dimmed: Bool) {
        dimView.isHidden = !dimmed
    }
}

private final class PassthroughDimView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class HairlineSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1.0 }

    override var dividerColor: NSColor {
        NSColor.white.withAlphaComponent(0.09)
    }
}

struct TerminalStageRepresentable: NSViewRepresentable {
    let stageView: TerminalStageView

    func makeNSView(context: Context) -> TerminalStageView {
        stageView
    }

    func updateNSView(_ nsView: TerminalStageView, context: Context) {}
}
