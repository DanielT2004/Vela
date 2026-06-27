import Foundation
import UserNotifications
import UIKit

/// Local + remote notifications so the creator gets pinged when the (potentially slow) Gemini analysis
/// finishes. The **local** path covers the app-still-alive case. The **remote** path (APNs) is the only
/// thing that can notify a fully-closed phone: we register for a device token here and hand it to the
/// server with the analyze job, and the `gemini-proxy` worker pushes when the job finishes.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private static let tokenKey = "apnsDeviceToken"

    /// The APNs device token (hex), if registration has succeeded. Persisted so the very first analyze
    /// after a relaunch can attach it synchronously, before registration round-trips again.
    private(set) var deviceTokenHex: String? = UserDefaults.standard.string(forKey: NotificationService.tokenKey)

    /// Set as the notification-center delegate so notifications also show while the app is foreground.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask once for permission (alert + sound). On grant, also register for **remote** (APNs) pushes so
    /// the server can reach a closed app. Safe to call repeatedly.
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            Log.notif("Authorization granted: \(granted)")
            if granted {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
        } catch {
            Log.notif("Authorization error: \(error.localizedDescription)")
        }
    }

    // MARK: - Remote (APNs) registration callbacks (forwarded from AppDelegate)

    func didRegister(deviceTokenHex hex: String) {
        deviceTokenHex = hex
        UserDefaults.standard.set(hex, forKey: Self.tokenKey)
        Log.notif("APNs device token registered: \(hex.prefix(8))…")
    }

    func didFailToRegister(_ error: Error) {
        // Expected on the simulator and until the Push capability is added (Phase 2). Non-fatal: the
        // token stays nil → the server simply skips the push and the local notification still fires.
        Log.notif("APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Posting

    /// Post an immediate local notification. `screen` is stashed in the payload so a tap routes the same
    /// way a remote push does (see `didReceive`).
    func notify(title: String, body: String, screen: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let screen { content.userInfo = ["screen": screen] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.notif("Post failed: \(error.localizedDescription)") }
            else { Log.notif("Posted → \(title): \(body)") }
        }
    }

    // MARK: - Delegate

    // Show banners + play sound even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // A tap (local or remote) carrying `{"screen":"analysis"}` asks the app to open to the results.
    // We stash the intent on `AppRoute`; `RootView` consumes it once it's safe to navigate.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if (info["screen"] as? String) == "analysis" {
            Task { @MainActor in AppRoute.shared.pending = .analysis }
        }
        completionHandler()
    }
}
