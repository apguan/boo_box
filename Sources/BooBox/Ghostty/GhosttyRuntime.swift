import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Actions emitted by libghostty that the session/window manager handles.
enum GhosttyHostAction: Sendable {
    case newTab
    case closeTab(mode: Int32)
    case newSplit(direction: SplitDirection)
    case gotoSplit(direction: SplitFocusDirection)
    case gotoTab(target: Int)
    case reloadConfig
    case quit
}

enum SplitDirection: Sendable {
    case right, down, left, up
}

enum SplitFocusDirection: Sendable {
    case previous, next, up, left, down, right
}

struct GhosttyThemeColors: Sendable {
    let background: NSColor
    let foreground: NSColor
}

@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var themeColors = GhosttyThemeColors(
        background: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0),
        foreground: NSColor(calibratedWhite: 0.92, alpha: 1.0)
    )
    private(set) var versionString: String = "Ghostty"

    var onHostAction: ((GhosttyHostAction, TerminalSurfaceView?) -> Bool)?
    var onCloseSurface: ((TerminalSurfaceView, Bool) -> Void)?

    private var initialized = false

    private init() {}

    func start() throws {
        guard !initialized else { return }

        configureResourcesDirectory()

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            throw NSError(
                domain: "BooBox.Ghostty",
                code: Int(initResult),
                userInfo: [NSLocalizedDescriptionKey: "ghostty_init failed with status \(initResult)"]
            )
        }
        let info = ghostty_info()
        if let vPtr = info.version, info.version_len > 0 {
            let bytes = UnsafeBufferPointer(
                start: UnsafeRawPointer(vPtr).assumingMemoryBound(to: UInt8.self),
                count: Int(info.version_len)
            )
            versionString = "Ghostty \(String(decoding: bytes, as: UTF8.self))"
        }

        guard let cfg = loadGhosttyConfig() else {
            throw NSError(
                domain: "BooBox.Ghostty",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ghostty_config_new failed"]
            )
        }
        self.config = cfg
        self.themeColors = Self.extractThemeColors(from: cfg)

        var runtimeCfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyWakeupCallback,
            action_cb: ghosttyActionCallback,
            read_clipboard_cb: ghosttyReadClipboardCallback,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboardCallback,
            write_clipboard_cb: ghosttyWriteClipboardCallback,
            close_surface_cb: ghosttyCloseSurfaceCallback
        )

        guard let appHandle = ghostty_app_new(&runtimeCfg, cfg) else {
            throw NSError(
                domain: "BooBox.Ghostty",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "ghostty_app_new failed"]
            )
        }
        self.app = appHandle
        self.initialized = true

        // Sync macOS appearance
        syncColorScheme()
    }

    func shutdown() {
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
        if let config {
            ghostty_config_free(config)
            self.config = nil
        }
        initialized = false
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setAppFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    func reloadConfig() {
        guard let app, let newConfig = loadGhosttyConfig() else { return }
        if let old = self.config {
            ghostty_config_free(old)
        }
        self.config = newConfig
        self.themeColors = Self.extractThemeColors(from: newConfig)
        ghostty_app_update_config(app, newConfig)
    }

    func syncColorScheme() {
        guard let app else { return }
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    private func configureResourcesDirectory() {
        let fm = FileManager.default
        let candidates: [String?] = [
            Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/ghostty").path,
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
        ]

        for case let path? in candidates {
            let shellIntegration = (path as NSString).appendingPathComponent("shell-integration")
            if fm.fileExists(atPath: shellIntegration) {
                setenv("GHOSTTY_RESOURCES_DIR", path, 1)
                // Ensure terminfo is discoverable if running outside .app bundle
                let parent = (path as NSString).deletingLastPathComponent
                let terminfoDir = (parent as NSString).appendingPathComponent("terminfo")
                if fm.fileExists(atPath: terminfoDir) {
                    setenv("TERMINFO_DIRS", "\(terminfoDir):", 0)
                }
                return
            }
        }
    }

    private func loadGhosttyConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)
        if let overlayPath = BooBoxConfigManager.shared.writeGhosttyOverlayFile() {
            overlayPath.withCString { ptr in
                ghostty_config_load_file(cfg, ptr)
            }
        }
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        return cfg
    }

    private static func extractThemeColors(from cfg: ghostty_config_t) -> GhosttyThemeColors {
        var bg = ghostty_config_color_s(r: 28, g: 31, b: 38)
        var fg = ghostty_config_color_s(r: 235, g: 237, b: 242)

        _ = "background".withCString { ptr in
            ghostty_config_get(cfg, &bg, ptr, UInt("background".utf8.count))
        }
        _ = "foreground".withCString { ptr in
            ghostty_config_get(cfg, &fg, ptr, UInt("foreground".utf8.count))
        }

        return GhosttyThemeColors(
            background: NSColor(
                srgbRed: CGFloat(bg.r) / 255.0,
                green: CGFloat(bg.g) / 255.0,
                blue: CGFloat(bg.b) / 255.0,
                alpha: 1.0
            ),
            foreground: NSColor(
                srgbRed: CGFloat(fg.r) / 255.0,
                green: CGFloat(fg.g) / 255.0,
                blue: CGFloat(fg.b) / 255.0,
                alpha: 1.0
            )
        )
    }

    // MARK: - Action Dispatch

    fileprivate func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let targetSurfaceView: TerminalSurfaceView? = {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let ud = ghostty_surface_userdata(surface) else {
                return nil
            }
            return Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
        }()

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let ptr = action.action.set_title.title {
                let title = String(cString: ptr)
                targetSurfaceView?.handleTitleChange(title)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            if let ptr = action.action.pwd.pwd {
                let pwd = String(cString: ptr)
                targetSurfaceView?.handlePwdChange(pwd)
            }
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let report = action.action.progress_report
            targetSurfaceView?.handleProgressReport(state: report.state, progress: report.progress)
            return true

        case GHOSTTY_ACTION_RING_BELL:
            targetSurfaceView?.handleBell()
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            targetSurfaceView?.handleMouseShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            NSCursor.setHiddenUntilMouseMoves(!visible)
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            let cs = action.action.cell_size
            targetSurfaceView?.handleCellSize(width: CGFloat(cs.width), height: CGFloat(cs.height))
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let info = action.action.child_exited
            targetSurfaceView?.handleChildExited(exitCode: info.exit_code, durationMs: info.timetime_ms)
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let openURL = action.action.open_url
            if let ptr = openURL.url, openURL.len > 0 {
                let bytes = UnsafeBufferPointer(
                    start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                    count: Int(openURL.len)
                )
                let str = String(decoding: bytes, as: UTF8.self)
                if let url = URL(string: str) {
                    handleOpenURL(url, from: targetSurfaceView)
                }
            }
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            return onHostAction?(.newTab, targetSurfaceView) ?? false

        case GHOSTTY_ACTION_CLOSE_TAB:
            return onHostAction?(.closeTab(mode: Int32(action.action.close_tab_mode.rawValue)), targetSurfaceView) ?? false

        case GHOSTTY_ACTION_NEW_SPLIT:
            let dir: SplitDirection = switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_DOWN: .down
            case GHOSTTY_SPLIT_DIRECTION_LEFT: .left
            case GHOSTTY_SPLIT_DIRECTION_UP: .up
            default: .right
            }
            return onHostAction?(.newSplit(direction: dir), targetSurfaceView) ?? false

        case GHOSTTY_ACTION_GOTO_SPLIT:
            let dir: SplitFocusDirection = switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: .previous
            case GHOSTTY_GOTO_SPLIT_NEXT: .next
            case GHOSTTY_GOTO_SPLIT_UP: .up
            case GHOSTTY_GOTO_SPLIT_LEFT: .left
            case GHOSTTY_GOTO_SPLIT_DOWN: .down
            case GHOSTTY_GOTO_SPLIT_RIGHT: .right
            default: .next
            }
            return onHostAction?(.gotoSplit(direction: dir), targetSurfaceView) ?? false

        case GHOSTTY_ACTION_GOTO_TAB:
            return onHostAction?(.gotoTab(target: Int(action.action.goto_tab.rawValue)), targetSurfaceView) ?? false

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reloadConfig()
            return true

        case GHOSTTY_ACTION_QUIT:
            return onHostAction?(.quit, targetSurfaceView) ?? {
                NSApp.terminate(nil)
                return true
            }()

        case GHOSTTY_ACTION_RENDER,
             GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_SELECTION_CHANGED,
             GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_COMMAND_FINISHED,
             GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_QUIT_TIMER,
             GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
             GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD,
             GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
            return true

        default:
            return false
        }
    }

    fileprivate func handleCloseSurface(view: TerminalSurfaceView, processAlive: Bool) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else { return }
            self.onCloseSurface?(view, processAlive)
        }
    }

    private func handleOpenURL(_ url: URL, from surfaceView: TerminalSurfaceView?) {
        let isSandboxed = surfaceView?.isSandboxedSurface ?? true
        guard isSandboxed else {
            NSWorkspace.shared.open(url)
            return
        }

        let scheme = (url.scheme ?? "").lowercased()
        let isWebLink = (scheme == "http" || scheme == "https")

        if isWebLink && !BooBoxConfigManager.shared.config.general.confirmOpeningWebLinks {
            NSWorkspace.shared.open(url)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = isWebLink ? .informational : .warning
        alert.messageText = isWebLink
            ? "Open website from sandbox?"
            : "Open external \(scheme.isEmpty ? "link" : "\(scheme)://") from sandbox?"
        alert.informativeText = isWebLink
            ? "\(url.absoluteString)\n\nLinks opened from a sandbox launch in your host browser."
            : "\(url.absoluteString)\n\nThis is a non-web URL scheme and will launch a host app outside the sandbox."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if isWebLink {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again for websites"
        }

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            if isWebLink && alert.suppressionButton?.state == .on {
                BooBoxConfigManager.shared.config.general.confirmOpeningWebLinks = false
            }
            NSWorkspace.shared.open(url)
        }

        if let window = surfaceView?.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

// MARK: - C Runtime Callbacks (File-level @convention(c))

private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    nonisolated(unsafe) let ud = userdata
    DispatchQueue.main.async {
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
        runtime.tick()
    }
}

private func ghosttyActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let app, let ud = ghostty_app_userdata(app) else { return false }
    nonisolated(unsafe) let safeUD = ud
    return MainActor.assumeIsolated {
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(safeUD).takeUnretainedValue()
        return runtime.handleAction(target: target, action: action)
    }
}

private func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ mimesLen: Int,
    _ list: Bool
) -> ghostty_clipboard_read_result_e {
    guard let userdata else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    nonisolated(unsafe) let safeUD = userdata
    nonisolated(unsafe) let safeState = state
    nonisolated(unsafe) let safeMimes = mimes
    return MainActor.assumeIsolated {
        let surfaceView = Unmanaged<TerminalSurfaceView>.fromOpaque(safeUD).takeUnretainedValue()
        guard let surface = surfaceView.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        guard location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        let pb = NSPasteboard.general
        var entries: [(mime: String, data: Data)] = []
        var seen = Set<String>()

        if let safeMimes {
            for i in 0..<mimesLen {
                guard let cMime = safeMimes[i] else { continue }
                let mime = String(cString: cMime)
                guard seen.insert(mime).inserted else { continue }
                if mime == "text/plain" || mime.hasPrefix("text/plain;") {
                    if let str = pb.string(forType: .string), let data = str.data(using: .utf8) {
                        entries.append((mime: mime, data: data))
                    }
                } else if let utType = UTType(mimeType: mime) {
                    let pbType = NSPasteboard.PasteboardType(utType.identifier)
                    if let data = pb.data(forType: pbType) {
                        entries.append((mime: mime, data: data))
                    }
                }
            }
        }

        let available: [String] = list ? (pb.string(forType: .string) != nil ? ["text/plain"] : []) : []
        if entries.isEmpty && !list {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        completeClipboardRequest(surface: surface, entries: entries, available: available, state: safeState)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }
}

private func ghosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata, let confirm else { return }
    nonisolated(unsafe) let safeUD = userdata
    nonisolated(unsafe) let safeState = state
    nonisolated(unsafe) let safeConfirm = confirm

    MainActor.assumeIsolated {
        let surfaceView = Unmanaged<TerminalSurfaceView>.fromOpaque(safeUD).takeUnretainedValue()
        guard surfaceView.surface != nil else { return }

        let c = safeConfirm.pointee
        var entries: [(mime: String, data: Data)] = []
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let item = contents[i]
                let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
                let data = (item.data != nil && item.len > 0) ? Data(bytes: item.data!, count: item.len) : Data()
                entries.append((mime: mime, data: data))
            }
        }

        var available: [String] = []
        if let avail = c.available {
            for i in 0..<c.available_len {
                if let ptr = avail[i] {
                    available.append(String(cString: ptr))
                }
            }
        }

        let preview = entries.first(where: { $0.mime.hasPrefix("text/plain") })
            .flatMap { String(data: $0.data, encoding: .utf8) }
            .map { String($0.prefix(300)) }
            ?? "\(entries.count) clipboard item(s)"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow terminal to read host clipboard?"
        alert.informativeText = preview
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        let finish: (NSApplication.ModalResponse) -> Void = { [weak surfaceView] response in
            guard let liveSurface = surfaceView?.surface else { return }
            if response == .alertFirstButtonReturn {
                completeClipboardRequest(
                    surface: liveSurface,
                    entries: entries,
                    available: available,
                    state: safeState,
                    confirmed: true
                )
            } else {
                ghostty_surface_deny_clipboard_request(liveSurface, safeState)
            }
        }

        if let window = surfaceView.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

private func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
    nonisolated(unsafe) let safeContent = content

    MainActor.assumeIsolated {
        var textToCopy: String?
        for i in 0..<len {
            let item = safeContent[i]
            let mime = item.mime.map { String(cString: $0) } ?? ""
            if mime.hasPrefix("text/plain"), let dataPtr = item.data, item.len > 0 {
                let data = Data(bytes: dataPtr, count: item.len)
                textToCopy = String(data: data, encoding: .utf8)
                break
            }
        }
        guard let textToCopy else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(textToCopy, forType: .string)
    }
}

private func ghosttyCloseSurfaceCallback(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let userdata else { return }
    nonisolated(unsafe) let safeUD = userdata
    MainActor.assumeIsolated {
        let surfaceView = Unmanaged<TerminalSurfaceView>.fromOpaque(safeUD).takeUnretainedValue()
        GhosttyRuntime.shared.handleCloseSurface(view: surfaceView, processAlive: processAlive)
    }
}

@MainActor
private func completeClipboardRequest(
    surface: ghostty_surface_t,
    entries: [(mime: String, data: Data)],
    available: [String],
    state: UnsafeMutableRawPointer?,
    confirmed: Bool = false,
    remember: Bool = false
) {
    var cStrings: [UnsafeMutablePointer<CChar>] = []
    var cDatas: [UnsafeMutableRawPointer] = []
    defer {
        cStrings.forEach { free($0) }
        cDatas.forEach { $0.deallocate() }
    }

    var cContents: [ghostty_clipboard_content_s] = []
    for entry in entries {
        guard let mime = strdup(entry.mime) else { continue }
        cStrings.append(mime)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
        cDatas.append(buf)
        entry.data.withUnsafeBytes { src in
            if let base = src.baseAddress {
                buf.copyMemory(from: base, byteCount: src.count)
            }
        }
        cContents.append(ghostty_clipboard_content_s(
            mime: mime,
            data: buf.assumingMemoryBound(to: CChar.self),
            len: entry.data.count
        ))
    }

    var cAvailable: [UnsafePointer<CChar>?] = []
    for mime in available {
        guard let str = strdup(mime) else { continue }
        cStrings.append(str)
        cAvailable.append(UnsafePointer(str))
    }

    cContents.withUnsafeBufferPointer { contentsBuf in
        cAvailable.withUnsafeBufferPointer { availableBuf in
            var complete = ghostty_clipboard_complete_s(
                contents: contentsBuf.baseAddress,
                contents_len: contentsBuf.count,
                available: availableBuf.baseAddress,
                available_len: availableBuf.count,
                confirmed: confirmed,
                remember: remember
            )
            ghostty_surface_complete_clipboard_request(surface, &complete, state)
        }
    }
}
