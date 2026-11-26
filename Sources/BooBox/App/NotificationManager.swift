import AppKit
import Foundation
import UserNotifications

/// Native macOS notification & Dock badge manager for background sandbox/agent activity.
/// Clicking a notification activates `boo_box` and switches directly to the notifying session tab.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    var onSelectSession: ((UUID) -> Void)?
    private var authorizationRequested = false
    private var isAuthorized = false
    private var lastNotificationBySession: [UUID: Date] = [:]

    private override init() {
        super.init()
    }

    func setup() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .authorized, .provisional:
                    self.isAuthorized = true
                case .notDetermined:
                    self.requestAuthorizationIfNeeded()
                default:
                    self.isAuthorized = false
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                self?.isAuthorized = granted
            }
        }
    }

    func updateDockBadge(unreadCount: Int) {
        NSApp.dockTile.badgeLabel = unreadCount > 0 ? "\(unreadCount)" : nil
    }

    /// Posts a clickable macOS notification when a background/unfocused tab finishes a long command,
    /// triggers a bell, emits an agent OSC 9/777 desktop notification, or triggers a proxy security alert.
    func postSessionNotification(
        sessionID: UUID,
        title: String,
        body: String,
        subtitle: String? = nil,
        isUrgent: Bool = false
    ) {
        guard BooBoxConfigManager.shared.config.general.desktopNotificationsEnabled else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        // Rate-limit non-urgent notifications per session (3s cooldown) to prevent agent spam
        let now = Date()
        if !isUrgent, let last = lastNotificationBySession[sessionID], now.timeIntervalSince(last) < 3.0 {
            return
        }
        lastNotificationBySession[sessionID] = now

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        if isUrgent {
            content.interruptionLevel = .timeSensitive
        }

        let req = UNNotificationRequest(
            identifier: "boobox-\(sessionID.uuidString)-\(Int(now.timeIntervalSince1970 * 1000))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let rawID = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let rawID, let uuid = UUID(uuidString: rawID) {
                NotificationManager.shared.onSelectSession?(uuid)
            }
        }
        completionHandler()
    }
}
