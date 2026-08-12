import Foundation
import UserNotifications
import VibeSignalCore

enum NotificationPreferences {
    static let attentionKey = "notifications.needsAttention"
    static let completionKey = "notifications.completion"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            attentionKey: true,
            completionKey: true
        ])
    }

    static var needsAttentionEnabled: Bool {
        UserDefaults.standard.bool(forKey: attentionKey)
    }

    static var completionEnabled: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }
}

final class NotificationCoordinator {
    static let categoryIdentifier = "VIBE_SIGNAL_SESSION"
    static let sessionKeyUserInfoKey = "sessionKey"
    static let jumpURLUserInfoKey = "jumpURL"
    static let hostBundleUserInfoKey = "hostBundleIdentifier"
    static let workspaceUserInfoKey = "workspace"

    private let center: UNUserNotificationCenter
    private var previousEvents: [String: SignalEvent] = [:]
    private var activeSince: [String: Date] = [:]
    private var hasBaseline = false
    private let minimumCompletionDuration: TimeInterval = 15

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func configure() {
        NotificationPreferences.registerDefaults()
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        guard NotificationPreferences.needsAttentionEnabled
                || NotificationPreferences.completionEnabled else {
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func process(_ snapshot: SignalSnapshot) {
        let currentEvents = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionKey, $0) })

        if !hasBaseline {
            previousEvents = currentEvents
            for event in snapshot.sessions where event.state.isActive {
                activeSince[event.sessionKey] = event.startedAt ?? event.updatedAt
            }
            hasBaseline = true
            return
        }

        for event in snapshot.sessions {
            let previous = previousEvents[event.sessionKey]

            if event.state.isActive, previous?.state.isActive != true {
                activeSince[event.sessionKey] = event.startedAt ?? event.updatedAt
            }

            if shouldNotifyForAttention(event: event, previous: previous) {
                schedule(
                    event: event,
                    kind: "attention",
                    status: event.state == .error ? "Error" : "Needs input",
                    sound: .default
                )
            } else if shouldNotifyForCompletion(event: event, previous: previous) {
                schedule(
                    event: event,
                    kind: "completion",
                    status: "Finished",
                    sound: nil
                )
            }

            if !event.state.isActive {
                activeSince[event.sessionKey] = nil
            }
        }

        previousEvents = currentEvents
        activeSince = activeSince.filter { currentEvents[$0.key]?.state.isActive == true }
    }

    private func shouldNotifyForAttention(event: SignalEvent, previous: SignalEvent?) -> Bool {
        guard NotificationPreferences.needsAttentionEnabled,
              event.state == .blocked || event.state == .error else {
            return false
        }
        return previous?.state != event.state
    }

    private func shouldNotifyForCompletion(event: SignalEvent, previous: SignalEvent?) -> Bool {
        guard NotificationPreferences.completionEnabled,
              event.state == .idle,
              previous?.state.isActive == true,
              let startedAt = activeSince[event.sessionKey] else {
            return false
        }
        return event.updatedAt.timeIntervalSince(startedAt) >= minimumCompletionDuration
    }

    private func schedule(
        event: SignalEvent,
        kind: String,
        status: String,
        sound: UNNotificationSound?
    ) {
        let content = UNMutableNotificationContent()
        content.title = event.title?.nonEmpty ?? fallbackTitle(for: event)
        content.subtitle = status
        content.body = event.message?.nonEmpty
            ?? event.workspace.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? event.reason
        content.categoryIdentifier = Self.categoryIdentifier
        var userInfo: [AnyHashable: Any] = [Self.sessionKeyUserInfoKey: event.sessionKey]
        if case .string(let jumpURL)? = event.metadata?["jump_url"] {
            userInfo[Self.jumpURLUserInfoKey] = jumpURL
        }
        if case .string(let bundleIdentifier)? = event.metadata?["host_bundle_id"] {
            userInfo[Self.hostBundleUserInfoKey] = bundleIdentifier
        }
        if let workspace = event.workspace {
            userInfo[Self.workspaceUserInfoKey] = workspace
        }
        content.userInfo = userInfo
        content.sound = sound

        let identifier = "vibe-signal.\(event.sessionKey).\(kind)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func fallbackTitle(for event: SignalEvent) -> String {
        if let workspace = event.workspace {
            let name = URL(fileURLWithPath: workspace).lastPathComponent
            if !name.isEmpty {
                return name
            }
        }
        return "Coding task"
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
