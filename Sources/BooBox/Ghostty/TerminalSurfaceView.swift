@preconcurrency import AppKit
import GhosttyKit
import QuartzCore

struct SurfaceLaunchOptions {
    var workingDirectory: String?
    var command: String?
    var environmentVariables: [String: String] = [:]
    var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_TAB
}

struct TerminalProgress: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case set
        case error
        case indeterminate
        case pause
    }
    let state: State
    let percent: Int?
}

@MainActor
final class TerminalSurfaceView: NSView {
    let paneID: UUID
    let isSandboxedSurface: Bool

    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    var onTitleChange: ((String) -> Void)?
    var onPwdChange: ((String) -> Void)?
    var onProgressChange: ((TerminalProgress?) -> Void)?
    var onBell: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onChildExited: ((UInt32) -> Void)?

    private(set) var isFocused: Bool = false
    private(set) var cellSize: CGSize = CGSize(width: 8, height: 16)
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var currentCursor: NSCursor = .iBeam
    private var suppressNextLeftMouseUp = false
    nonisolated(unsafe) private var localEventMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init(paneID: UUID, launchOptions: SurfaceLaunchOptions = SurfaceLaunchOptions()) {
        self.paneID = paneID
        self.isSandboxedSurface = launchOptions.environmentVariables["BOOBOX_MODE"] != "raw_host"
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))


        registerForDraggedTypes([.string, .fileURL])

        guard let app = GhosttyRuntime.shared.app else { return }

        let created = createSurface(app: app, options: launchOptions)
        self.surface = created

        updateTrackingAreas()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
            self?.handleLocalEvent(event) ?? event
        }
    }

    @objc private func handleWindowDidChangeScreen(_ notification: Notification) {
        guard let window,
              let noteWindow = notification.object as? NSWindow,
              window == noteWindow else { return }
        updateDisplayAndScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    func destroySurface() {
        NotificationCenter.default.removeObserver(self)
        if let localEventMonitor {
            self.localEventMonitor = nil
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let surface {
            self.surface = nil
            ghostty_surface_free(surface)
        }
    }

    private func createSurface(app: ghostty_app_t, options: SurfaceLaunchOptions) -> ghostty_surface_t? {
        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0
        cfg.context = options.context

        var dupedStrings: [UnsafeMutablePointer<CChar>] = []
        defer { dupedStrings.forEach { free($0) } }

        func dup(_ string: String?) -> UnsafePointer<CChar>? {
            guard let string, let c = strdup(string) else { return nil }
            dupedStrings.append(c)
            return UnsafePointer(c)
        }

        cfg.working_directory = dup(options.workingDirectory)
        cfg.command = dup(options.command)

        var envVars: [ghostty_env_var_s] = []
        for (k, v) in options.environmentVariables {
            envVars.append(ghostty_env_var_s(key: dup(k), value: dup(v)))
        }

        return envVars.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(app, &cfg)
        }
    }

    // MARK: - View Lifecycle & Sizing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateDisplayAndScale()
        syncSurfaceSize()
        if let surface {
            ghostty_surface_refresh(surface)
        }
    }

    override func layout() {
        super.layout()
        syncSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayAndScale()
        syncSurfaceSize()
    }

    /// Updates libghostty's occlusion visibility flag (`visible == true` renders).
    func setVisible(_ visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            ghostty_surface_refresh(surface)
        }
    }

    /// Applies an updated libghostty configuration (theme, font size, opacity) live.
    func updateConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
        ghostty_surface_refresh(surface)
    }

    private func updateDisplayAndScale() {
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        guard let surface else { return }

        if let screenNumber = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, screenNumber.uint32Value)
        }

        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
    }

    func syncSurfaceSize() {
        guard let surface else { return }
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        let backing = convertToBacking(bounds.size)
        let pxW = max(UInt32(backing.width.rounded()), 1)
        let pxH = max(UInt32(backing.height.rounded()), 1)
        ghostty_surface_set_size(surface, pxW, pxH)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            setSurfaceFocus(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            setSurfaceFocus(false)
        }
        return ok
    }

    func setSurfaceFocus(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        if !focused {
            suppressNextLeftMouseUp = false
        }
        if let surface {
            ghostty_surface_set_focus(surface, focused)
        }
        onFocusChange?(focused)
    }

    // MARK: - Local Event Monitor

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyUp:
            if event.modifierFlags.contains(.command), isFocused {
                keyUp(with: event)
                return nil
            }
            return event

        case .leftMouseDown:
            guard !isHiddenOrHasHiddenAncestor,
                  let window,
                  event.window == window,
                  let loc = window.contentView?.convert(event.locationInWindow, from: nil),
                  window.contentView?.hitTest(loc) === self else {
                return event
            }
            suppressNextLeftMouseUp = false
            guard window.firstResponder !== self else { return event }
            if NSApp.isActive && window.isKeyWindow {
                window.makeFirstResponder(self)
                suppressNextLeftMouseUp = true
                return nil
            }
            window.makeFirstResponder(self)
            return event

        default:
            return event
        }
    }

    // MARK: - Keyboard Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isFocused else { return false }

        // Let our app's main menu shortcuts win for window/sidebar/session navigation
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }

        // Check if Ghostty has a binding for this key
        if let surface {
            var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            var flags = ghostty_binding_flags_e(0)
            let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
                ghosttyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
            }
            if isBinding {
                keyDown(with: event)
                return true
            }
        }

        // Special Control keys AppKit otherwise swallows/beeps on
        if event.modifierFlags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "\r":
                keyDown(with: event)
                return true
            case "/" where event.modifierFlags.isDisjoint(with: [.shift, .command, .option]):
                if let remapped = NSEvent.keyEvent(
                    with: .keyDown,
                    location: event.locationInWindow,
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: "_",
                    charactersIgnoringModifiers: "_",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) {
                    keyDown(with: remapped)
                    return true
                }
            default:
                break
            }
        }

        if event.timestamp == 0 { return false }

        if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
            lastPerformKeyEvent = nil
            return false
        }

        if let last = lastPerformKeyEvent {
            lastPerformKeyEvent = nil
            if last == event.timestamp {
                keyDown(with: event)
                return true
            }
        }

        lastPerformKeyEvent = event.timestamp
        return false
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        let translationModsGhostty = GhosttyInput.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(surface, GhosttyInput.ghosttyMods(event.modifierFlags))
        )

        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let keyboardIDBefore = markedTextBefore ? nil : GhosttyInput.currentKeyboardLayoutID()
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardIDBefore != GhosttyInput.currentKeyboardLayoutID() {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                if Self.isControlCharDuringComposition(text, composing: composing) {
                    continue
                }
                if markedTextBefore {
                    _ = sendCommittedText(action, text: text)
                } else {
                    _ = sendKeyAction(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else {
            if Self.isControlCharDuringComposition(event.characters, composing: composing) {
                return
            }
            _ = sendKeyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: composing
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKeyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        if hasMarkedText() { return }

        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool = switch event.keyCode {
            case 0x3C: event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }
        _ = sendKeyAction(action, event: event)
    }

    private func sendKeyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEv = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEv.composing = composing

        if let text = text?.ghosttyKeyEventText {
            return text.withCString { ptr in
                keyEv.text = ptr
                return ghostty_surface_key(surface, keyEv)
            }
        }
        return ghostty_surface_key(surface, keyEv)
    }

    private func sendCommittedText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var keyEv = ghostty_input_key_s()
        keyEv.action = action
        keyEv.keycode = 0
        keyEv.composing = false
        keyEv.mods = GHOSTTY_MODS_NONE
        keyEv.consumed_mods = GHOSTTY_MODS_NONE
        keyEv.unshifted_codepoint = 0
        return text.withCString { ptr in
            keyEv.text = ptr
            return ghostty_surface_key(surface, keyEv)
        }
    }

    private static func isControlCharDuringComposition(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let first = scalars.first, scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return first.value < 0x20
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        guard let surface else { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        let btn = GhosttyInput.mouseButton(from: event.buttonNumber)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, btn, mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        let btn = GhosttyInput.mouseButton(from: event.buttonNumber)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, btn, mods)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        reportMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard NSEvent.pressedMouseButtons == 0, let surface else { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        reportMousePos(event)
    }

    override func mouseDragged(with event: NSEvent) {
        reportMousePos(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        reportMousePos(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        reportMousePos(event)
    }

    private func reportMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, Double(pos.x), Double(bounds.height - pos.y), mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }
        let mods = GhosttyInput.scrollMods(precision: precision, momentumPhase: event.momentumPhase)
        ghostty_surface_mouse_scroll(surface, Double(x), Double(y), mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: - Menu Actions

    @objc func copy(_ sender: Any?) {
        performBindingAction("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    @objc override func selectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }

    func clearScreen() {
        performBindingAction("clear_screen")
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }
        let menu = NSMenu()
        if let surface, ghostty_surface_has_selection(surface) {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Split Right", action: #selector(splitRightAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Split Down", action: #selector(splitDownAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Close Pane", action: #selector(closePaneAction(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Screen", action: #selector(clearScreenAction(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func splitRightAction(_ sender: Any?) {
        _ = GhosttyRuntime.shared.onHostAction?(.newSplit(direction: .right), self)
    }

    @objc private func splitDownAction(_ sender: Any?) {
        _ = GhosttyRuntime.shared.onHostAction?(.newSplit(direction: .down), self)
    }

    @objc private func closePaneAction(_ sender: Any?) {
        GhosttyRuntime.shared.onCloseSurface?(self, true)
    }

    @objc private func clearScreenAction(_ sender: Any?) {
        clearScreen()
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let surface else { return false }
        let pb = sender.draggingPasteboard

        let text: String?
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            text = urls.map { Self.shellEscape($0.path) }.joined(separator: " ")
        } else {
            text = pb.string(forType: .string)
        }

        guard let text, !text.isEmpty else { return false }
        text.withCString { ptr in
            ghostty_surface_paste_text(surface, ptr, UInt(text.utf8.count))
        }
        return true
    }

    private static func shellEscape(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-:@+"))
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Callbacks From GhosttyRuntime

    func handleTitleChange(_ title: String) {
        onTitleChange?(title)
    }

    func handlePwdChange(_ pwd: String) {
        onPwdChange?(pwd)
    }

    func handleProgressReport(state: ghostty_action_progress_report_state_e, progress: Int8) {
        switch state {
        case GHOSTTY_PROGRESS_STATE_REMOVE:
            onProgressChange?(nil)
        case GHOSTTY_PROGRESS_STATE_SET:
            onProgressChange?(TerminalProgress(state: .set, percent: progress >= 0 ? Int(progress) : nil))
        case GHOSTTY_PROGRESS_STATE_ERROR:
            onProgressChange?(TerminalProgress(state: .error, percent: progress >= 0 ? Int(progress) : nil))
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
            onProgressChange?(TerminalProgress(state: .indeterminate, percent: nil))
        case GHOSTTY_PROGRESS_STATE_PAUSE:
            onProgressChange?(TerminalProgress(state: .pause, percent: progress >= 0 ? Int(progress) : nil))
        default:
            break
        }
    }

    func handleBell() {
        onBell?()
    }

    func handleMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        currentCursor = GhosttyInput.cursor(for: shape)
        window?.invalidateCursorRects(for: self)
    }

    func handleCellSize(width: CGFloat, height: CGFloat) {
        if width > 0 && height > 0 {
            cellSize = CGSize(width: width, height: height)
        }
    }

    func handleChildExited(exitCode: UInt32, durationMs: UInt64) {
        onChildExited?(exitCode)
    }

    // MARK: - Preedit helper

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

// MARK: - NSTextInputClient

extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange(location: NSNotFound, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attr as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attr)
        case let str as String:
            markedText = NSMutableAttributedString(string: str)
        default:
            return
        }
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return nil }
        return NSAttributedString(string: String(cString: ptr))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let viewRect = NSRect(
            x: x,
            y: bounds.height - y,
            width: range.length == 0 ? 0 : width,
            height: max(height, cellSize.height)
        )
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let attr as NSAttributedString: chars = attr.string
        case let str as String: chars = str
        default: return
        }

        unmarkText()

        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        if !chars.isEmpty {
            _ = sendCommittedText(GHOSTTY_ACTION_PRESS, text: chars)
        }
    }

    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}
