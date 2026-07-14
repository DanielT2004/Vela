import SwiftUI
import UIKit

/// SwiftUI's `App` has no `UIApplicationDelegate`, but APNs device-token callbacks are only delivered
/// to one — so we bridge a minimal delegate in via `@UIApplicationDelegateAdaptor`. It just forwards the
/// registered token (or a failure) to `NotificationService`, which stores it for the next `analyze` call.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationService.shared.didRegister(deviceTokenHex: hex)
    }
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationService.shared.didFailToRegister(error)
    }
}

@main
struct FoodEditorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Log.app("FoodEditor (Vela) launched — MVP build. Verbose logging is ON.")
        NotificationService.shared.configure()
        AudioSession.configureForPlayback()
        #if DEBUG
        AuthStore.runSelfTest()
        StyleTemplate.runSelfTest()
        FileTemplateStore.runSelfTest()
        EditPlanValidator.selfCheck()   // Phase 1 — prints ✅/❌ to the console on every debug launch
        EditPlanRepair.selfCheck()      // b-roll source-not-kept repair
        EditPlanRepair.coverageSelfCheck()   // coverage holes → "watch it and decide" review segments
        WordSnapper.selfCheck()         // cuts snap to word boundaries — never mid-word
        ContentIndexNormalizer.selfCheck()   // PERCEIVE index: split >15s shots, drop zero-len spans
        EditPlanAdapter.selfCheck()     // DECIDE decisions + index → a valid EditPlan
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light) // Warm Editorial is a light scheme.
        }
    }
}
