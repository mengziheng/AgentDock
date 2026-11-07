import Foundation
import UserNotifications
import AgentDockCore

/// Posts a system notification when a tracked conversation needs the user, and opens it on click.
@MainActor
final class ConversationNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    /// Notification Center requires a bundled app; an unbundled `swift run` build skips notifications.
    private let center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : .current()

    override init() {
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ conversation: Conversation) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = conversation.state.followUpCategory.title + " · " + conversation.application.name
        content.body = conversation.displayTitle
        content.sound = .default
        content.userInfo = ["conversationID": conversation.id]
        center.add(UNNotificationRequest(identifier: conversation.id + "|" + conversation.revision, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["conversationID"] as? String else { return }
        await MainActor.run { onOpen?(id) }
    }
}
