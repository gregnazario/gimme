import SwiftUI
import UserNotifications

/// Posts one macOS notification per finished update run, only when Gimme is
/// not the active app (spec: 2026-08-22-update-notifications-design.md).
/// Authorization is requested contextually at the first Update action; after
/// a denial the system never re-prompts and every post checks settings and
/// skips silently. Safe in non-bundle contexts (raw SwiftPM binary).
/// `@unchecked Sendable`: `UNUserNotificationCenter` is a thread-safe
/// system singleton; the class itself holds no mutable state.
final class UpdateNotifier: @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    /// True when notifications are possible at all in this process.
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// True while any window is actually on screen (occlusion state) — i.e.
    /// the in-app update banner is visible. Unlike `NSApp.isActive` this is
    /// already true at first draw, before the app finishes activating, so a
    /// launch-time check that raises the banner can rely on it to skip a
    /// redundant post.
    var isAnyWindowOnScreen: Bool {
        NSApp.windows.contains { $0.occlusionState.contains(.visible) }
    }

    /// Ask once, at the moment the user first triggers an update.
    func requestAuthorizationIfNeeded() async {
        guard isBundled else { return }
        _ = try? await center.requestAuthorization(options: [.alert])
    }

    /// Post the run summary. Single updates pass one-element arrays.
    func runFinished(updated: [(name: String, version: String?)],
                      failed: [(name: String, error: String)]) {
        // Frontmost → the on-screen badges are the feedback; no banner.
        guard isBundled, NSApp.isActive == false else { return }
        post(title: "gimme", body: Self.body(updated: updated, failed: failed))
    }

    /// Informational post (e.g. a newer gimme release is available). Like
    /// run-finished summaries this is background-only: the in-app update
    /// banner announces it while a Gimme window is on screen, so a caller
    /// raising the banner also checks `isAnyWindowOnScreen` before posting.
    /// Settings/permission checks still apply; silent when denied.
    func post(title: String, body: String) {
        guard isBundled, NSApp.isActive == false else { return }
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "gimme-update-\(UUID().uuidString)",
                content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// Single line, truncated — a brew stderr dump must not make a giant banner.
    static func firstLine(_ s: String, limit: Int = 120) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        return line.count <= limit ? line : String(line.prefix(limit)) + "…"
    }

    static func body(updated: [(name: String, version: String?)],
                     failed: [(name: String, error: String)]) -> String {
        if updated.isEmpty, failed.count == 1 {
            return "\(failed[0].name) update failed — \(firstLine(failed[0].error))"
        }
        if failed.isEmpty, updated.count == 1 {
            let v = updated[0].version.map { " to \($0)" } ?? ""
            return "\(updated[0].name) updated\(v)"
        }
        var parts = ["Updates finished — \(updated.count) updated"]
        if !failed.isEmpty {
            parts[0] += ", \(failed.count) failed"
            parts.append("\(failed[0].name): \(firstLine(failed[0].error))")
        }
        return parts.joined(separator: "\n")
    }
}

/// UNUserNotificationCenter delegate: clicking a notification focuses Gimme.
/// Must be set before the app finishes launching, hence the adaptor.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])  // rare: post raced window focus
    }
}
