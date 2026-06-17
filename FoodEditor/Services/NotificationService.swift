import Foundation
import UserNotifications

/// Local notifications so the creator gets pinged when the (potentially slow) Gemini analysis
/// finishes — even if they backgrounded the app while waiting. No server / push certificates needed.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Set as the notification-center delegate so notifications also show while the app is foreground.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask once for permission (alert + sound). Safe to call repeatedly.
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            Log.notif("Authorization granted: \(granted)")
        } catch {
            Log.notif("Authorization error: \(error.localizedDescription)")
        }
    }

    /// Post an immediate local notification.
    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.notif("Post failed: \(error.localizedDescription)") }
            else { Log.notif("Posted → \(title): \(body)") }
        }
    }

    // Show banners + play sound even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
