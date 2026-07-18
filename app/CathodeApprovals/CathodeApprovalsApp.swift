import SwiftUI
import UIKit
import UserNotifications

/// iPhone app. Receives APNs pushes when a Cathode agent needs approval,
/// shows an actionable notification (which mirrors to the Apple Watch), and
/// POSTs the tapped decision back to the relay in the background.
@main
struct CathodeApprovalsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    static let APPROVE = "APPROVE_ACTION"
    static let DENY = "DENY_ACTION"
    static let CATEGORY = "APPROVAL_REQUEST"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerCategory()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
            if let error { print("[Approvals] Notification permission error: \(error)") }
        }
        return true
    }

    /// Approve/Deny buttons ride on the notification itself, so they appear on the
    /// mirrored Apple Watch alert. No `.foreground` option → the taps are handled in
    /// the background without launching the app (an iPhone can network from here; a
    /// watch can't reliably, which is why this app lives on the phone).
    private func registerCategory() {
        let approve = UNNotificationAction(identifier: Self.APPROVE, title: "✓ Approve", options: [])
        let deny = UNNotificationAction(identifier: Self.DENY, title: "✗ Deny", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: Self.CATEGORY,
            actions: [approve, deny],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: Remote registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[Approvals] Device token: \(token)")
        UserDefaults.standard.set(token, forKey: "deviceToken")
        Task { await ServerClient.shared.registerDevice(token: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Approvals] Failed to register for remote notifications: \(error)")
    }

    // MARK: Foreground presentation — still show the banner if the app is open.

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: Action handling

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let requestId = userInfo["request_id"] as? String else {
            print("[Approvals] No request_id in notification payload")
            completionHandler()
            return
        }

        let decision: String
        switch response.actionIdentifier {
        case Self.APPROVE:
            decision = "approve"
        case Self.DENY:
            decision = "deny"
        case UNNotificationDismissActionIdentifier:
            // Swiping the alert away is a conservative "deny" for a permission gate.
            decision = "deny"
        case UNNotificationDefaultActionIdentifier:
            // Tapping the body just opens the app — don't silently decide.
            completionHandler()
            return
        default:
            completionHandler()
            return
        }

        print("[Approvals] Sending '\(decision)' for request \(requestId)")

        // Keep the process alive long enough to finish the POST from the background.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "respond") {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        }

        Task {
            _ = await ServerClient.shared.respond(requestId: requestId, decision: decision)
            completionHandler()
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        }
    }
}
