# Update-Finished Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One background-only macOS notification per finished update run (single or Update All), click-to-focus.

**Architecture:** New `UpdateNotifier` in GimmeUI wrapping `UNUserNotificationCenter`; `GimmeStore` calls it from `upgrade`/`updateAll` completion paths. A minimal `AppDelegate` adaptor handles the delegate.

**Tech Stack:** SwiftUI + UserNotifications; no new dependencies. No automated tests (GUI v1 decision) — verification is build + launch.

**Spec:** `docs/superpowers/specs/2026-08-22-update-notifications-design.md`

## Global Constraints

- English only; Conventional Commits; no AI attribution; commit only what the plan touches.
- `swift build` (all targets) green before every commit.
- macOS 13 floor: `UNNotification` `willPresent` must compile on 13 (use `.banner` — available macOS 11+ as `UNNotificationPresentationOption.banner`).

---

### Task 1: `UpdateNotifier` + `AppDelegate` wiring

**Files:**
- Create: `Sources/GimmeUI/UpdateNotifier.swift`
- Modify: `Sources/GimmeUI/GimmeApp.swift` (adaptor + store wiring + call sites)

**Interfaces:**
- Produces: `final class UpdateNotifier` with
  `func requestAuthorizationIfNeeded() async`,
  `func runFinished(updated: [(name: String, version: String?)], failed: [(name: String, error: String)])`
  — arrays of one for single updates, `UpdateSummary` contents for Update All.

- [ ] **Step 1: Implement `Sources/GimmeUI/UpdateNotifier.swift`**

```swift
import SwiftUI
import UserNotifications

/// Posts one macOS notification per finished update run, only when Gimme is
/// not the active app (spec: 2026-08-22-update-notifications-design.md).
/// Authorization is requested contextually at the first Update action; after
/// a denial the system never re-prompts and every post checks settings and
/// skips silently. Safe in non-bundle contexts (raw SwiftPM binary).
final class UpdateNotifier {
    private let center = UNUserNotificationCenter.current()

    /// True when notifications are possible at all in this process.
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

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
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "gimme"
            content.body = Self.body(updated: updated, failed: failed)
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
/// must be set before the app finishes launching, hence the adaptor.
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
```

- [ ] **Step 2: Wire into `GimmeApp.swift`**

Add the adaptor to `GimmeApp`:

```swift
@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
```

In `GimmeStore`: add `private let notifier = UpdateNotifier()`.

In `upgrade(_ pkg: OutdatedPackage)`: `await notifier.requestAuthorizationIfNeeded()` first; wrap the existing do/catch to call the notifier on both paths:

```swift
    func upgrade(_ pkg: OutdatedPackage) async {
        await notifier.requestAuthorizationIfNeeded()
        upgradeStatus[pkg.id] = .upgrading
        do {
            try await gimme.upgrade(name: pkg.name, from: pkg.manager)
            upgradeStatus[pkg.id] = .done
            log("upgraded \(pkg.name)")
            notifier.runFinished(updated: [(pkg.name, pkg.latestVersion)], failed: [])
            await loadAll(refresh: false)
        } catch {
            upgradeStatus[pkg.id] = .failed("\(error)")
            showError(error)
            notifier.runFinished(updated: [], failed: [(pkg.name, "\(error)")])
        }
    }
```

In `updateAll()`: `await notifier.requestAuthorizationIfNeeded()` after the reentrancy guard; after the do/catch completes (success path), call:

```swift
            notifier.runFinished(
                updated: summary.succeeded.map { id in (id, nil) },
                failed: summary.failed.map { ($0.id, $0.error) })
```

(The catch path keeps only the error alert — a failed *run* still shows in-app.)

- [ ] **Step 3: Build all targets**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Launch verification**

Run: `open app/Gimme.app` (after `sh app/build-app.sh`), confirm no crash on
launch, and the manual check per spec §5 (update with Gimme unfocused →
banner; click → focus).

- [ ] **Step 5: Commit**

```bash
git add Sources/GimmeUI/UpdateNotifier.swift Sources/GimmeUI/GimmeApp.swift
git commit -m "feat: background notification when update runs finish"
```

---

### Task 2: Ship loop

- [ ] Rebuild app bundle, reinstall to /Applications, relaunch.
- [ ] Repackage `dist/` (2.2.0, --skip-notarize), push.
