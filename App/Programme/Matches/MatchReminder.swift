import Foundation
import ProgrammeCore
import UserNotifications

/// The reminder choices Programme offers for a scheduled match. Deliberately
/// small: None / 15 / 30 / 60 minutes. No engagement notifications, no
/// server, no push — a single local notification before kickoff.
enum MatchReminderOption: Int, CaseIterable, Identifiable, Sendable {
    case none
    case fifteenMinutes
    case thirtyMinutes
    case oneHour

    var id: Int { rawValue }

    /// Nil means no reminder; the store persists exactly this.
    var minutesBefore: Int? {
        switch self {
        case .none: nil
        case .fifteenMinutes: 15
        case .thirtyMinutes: 30
        case .oneHour: 60
        }
    }

    var label: String {
        switch self {
        case .none: "None"
        case .fifteenMinutes: "15 minutes before"
        case .thirtyMinutes: "30 minutes before"
        case .oneHour: "1 hour before"
        }
    }

    static func option(minutesBefore: Int?) -> MatchReminderOption {
        switch minutesBefore {
        case 15: .fifteenMinutes
        case 30: .thirtyMinutes
        case 60: .oneHour
        default: .none
        }
    }
}

/// Pure scheduling math, unit-testable without UserNotifications. The center
/// below maps this onto real notification requests.
enum MatchReminderRequest {
    /// Stable across launches and reschedules: replacing the preference
    /// overwrites the same pending request instead of stacking duplicates.
    static func notificationID(for matchID: MatchID) -> String {
        "programme.match-reminder.\(matchID.rawValue.uuidString)"
    }

    /// When the notification should fire, or nil when scheduling makes no
    /// sense (no reminder chosen, or the fire time already passed).
    static func fireDate(kickoff: Date, minutesBefore: Int?, now: Date = Date()) -> Date? {
        guard let minutesBefore else { return nil }
        let fire = kickoff.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        return fire > now ? fire : nil
    }

    static func title(descriptor: MatchDescriptor) -> String {
        "\(descriptor.teamShortName) \(descriptor.venue.shortLabel) \(descriptor.opponentShortName)"
    }

    static func body(descriptor: MatchDescriptor, minutesBefore: Int) -> String {
        var text = "Kickoff in \(minutesBefore) minutes"
        if let location = descriptor.location {
            text += " at \(location.name)"
        }
        return text
    }
}

/// Boundary over `UNUserNotificationCenter` so scheduling logic is testable
/// with a fake. Only the live implementation touches the real center.
protocol MatchNotificationScheduling: Sendable {
    func add(_ request: UNNotificationRequest) async throws
    func removePending(withIdentifiers identifiers: [String]) async
    func pendingIdentifiers() async -> [String]
}

struct LiveNotificationScheduler: MatchNotificationScheduling {
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removePending(withIdentifiers identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: identifiers)
    }

    func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }
}

/// Owns the device-local reminder lifecycle for scheduled matches.
///
/// Permission is requested only from the explicit Remind Me action, never at
/// launch. Scheduling failures are swallowed deliberately: a reminder is a
/// convenience, and the match is always safe with or without one.
struct MatchReminderCenter: Sendable {
    private let scheduler: any MatchNotificationScheduling

    init(scheduler: any MatchNotificationScheduling = LiveNotificationScheduler()) {
        self.scheduler = scheduler
    }

    /// Asks for notification permission. Called only from the explicit
    /// Remind Me action — never at launch, never in the background.
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert, .sound,
        ])) ?? false
    }

    /// Reconciles the pending notification with the stored preference:
    /// schedules when a future fire date exists, otherwise leaves nothing
    /// pending. Rescheduling replaces the same stable identifier.
    func sync(
        matchID: MatchID, kickoff: Date, minutesBefore: Int?,
        title: String, body: String, now: Date = Date()
    ) async {
        let id = MatchReminderRequest.notificationID(for: matchID)
        await scheduler.removePending(withIdentifiers: [id])
        guard
            let fire = MatchReminderRequest.fireDate(
                kickoff: kickoff, minutesBefore: minutesBefore, now: now)
        else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await scheduler.add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(matchID: MatchID) async {
        await scheduler.removePending(
            withIdentifiers: [MatchReminderRequest.notificationID(for: matchID)])
    }
}
