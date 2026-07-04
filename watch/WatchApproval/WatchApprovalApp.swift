import SwiftUI
import WatchKit
import UserNotifications

/// Main entry point for the Watch Approval app.
/// Handles notification registration and action responses.
@main
struct WatchApprovalApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching() {
        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    WKExtension.shared().registerForRemoteNotifications()
                }
            }
            if let error {
                print("[WatchApproval] Notification permission error: \(error)")
            }
        }

        // Register actionable notification category
        let approveAction = UNNotificationAction(
            identifier: "APPROVE_ACTION",
            title: "✓ Approve",
            options: [.foreground]
        )
        let denyAction = UNNotificationAction(
            identifier: "DENY_ACTION",
            title: "✗ Deny",
            options: [.destructive, .foreground]
        )
        let category = UNNotificationCategory(
            identifier: "APPROVAL_REQUEST",
            actions: [approveAction, denyAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().delegate = self

        print("[WatchApproval] Launch complete, registered notification category")
    }

    // MARK: - Remote Notification Registration

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[WatchApproval] Device token: \(token)")

        // Register with the relay server
        Task {
            await ServerClient.shared.registerDevice(token: token)
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        print("[WatchApproval] Failed to register: \(error)")
    }

    // MARK: - Notification Action Handling

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        guard let requestId = userInfo["request_id"] as? String else {
            print("[WatchApproval] No request_id in notification")
            completionHandler()
            return
        }

        let decision: String
        switch response.actionIdentifier {
        case "APPROVE_ACTION":
            decision = "approve"
        case "DENY_ACTION":
            decision = "deny"
        case UNNotificationDefaultActionIdentifier:
            // User tapped the notification itself — treat as approve
            decision = "approve"
        case UNNotificationDismissActionIdentifier:
            // User dismissed — treat as deny
            decision = "deny"
        default:
            completionHandler()
            return
        }

        print("[WatchApproval] Sending \(decision) for request \(requestId)")

        // Send the decision to the relay server
        Task {
            let success = await ServerClient.shared.respond(requestId: requestId, decision: decision)
            if success {
                // Update the delivered notification to show the result
                self.updateNotification(result: decision)
            }
            completionHandler()
        }
    }

    private func updateNotification(result: String) {
        let content = UNMutableNotificationContent()
        content.title = result == "approve" ? "Approved ✓" : "Denied ✗"
        content.body = "Response sent"
        let request = UNNotificationRequest(
            identifier: "result-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
