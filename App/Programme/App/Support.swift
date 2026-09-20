import BackgroundTasks
import Foundation
import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftUI
import WidgetKit

#if canImport(UIKit)
    import UIKit
#endif

/// One global preference for Programme-added haptics.
///
/// System controls such as switches and pickers may still provide their own
/// platform feedback. This key governs feedback Programme explicitly adds to
/// custom interactions and completed operations.
enum HapticPreferences {
    static let key = "hapticFeedbackEnabled"

    static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}

/// Short, semantic physical confirmation for Programme-owned interactions.
///
/// View-local state changes should prefer SwiftUI `sensoryFeedback` through
/// `programmeSensoryFeedback` below. Imperative domain/async operations use
/// this helper so scoring, creation and failure feedback all respect the same
/// setting.
@MainActor
enum Haptics {
    #if canImport(UIKit)
        private static let impact = UIImpactFeedbackGenerator(style: .medium)
        private static let selection = UISelectionFeedbackGenerator()
        private static let notification = UINotificationFeedbackGenerator()
    #endif

    static func prepare() {
        guard HapticPreferences.isEnabled else { return }
        #if canImport(UIKit)
            impact.prepare()
            selection.prepare()
        #endif
    }

    /// An event was recorded.
    static func recorded() {
        guard HapticPreferences.isEnabled else { return }
        #if canImport(UIKit)
            impact.impactOccurred(intensity: 0.7)
        #endif
    }

    /// A goal. Noticeably stronger, but still momentary — never a celebration
    /// that gets in the way of the next event.
    static func goal() {
        guard HapticPreferences.isEnabled else { return }
        #if canImport(UIKit)
            notification.notificationOccurred(.success)
        #endif
    }

    static func selectionChanged() {
        guard HapticPreferences.isEnabled else { return }
        #if canImport(UIKit)
            selection.selectionChanged()
        #endif
    }

    static func undone() {
        guard HapticPreferences.isEnabled else { return }
        #if canImport(UIKit)
            impact.impactOccurred(intensity: 0.45)
        #endif
    }

    static func rejected() {
        guard HapticPreferences.isEnabled else { return }
        #if canImport(UIKit)
            notification.notificationOccurred(.warning)
        #endif
    }

    /// A user-requested operation completed successfully.
    static func success() {
        guard HapticPreferences.isEnabled else { return }
        #if canImport(UIKit)
            notification.notificationOccurred(.success)
        #endif
    }

    /// A user-requested operation failed and the interface is showing the error.
    static func error() {
        guard HapticPreferences.isEnabled else { return }
        #if canImport(UIKit)
            notification.notificationOccurred(.error)
        #endif
    }
}

private struct ProgrammeHapticsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var programmeHapticsEnabled: Bool {
        get { self[ProgrammeHapticsEnabledKey.self] }
        set { self[ProgrammeHapticsEnabledKey.self] = newValue }
    }
}

private struct ProgrammeSensoryFeedbackModifier<Trigger: Equatable>: ViewModifier {
    @Environment(\.programmeHapticsEnabled) private var hapticsEnabled

    let feedback: SensoryFeedback
    let trigger: Trigger
    let condition: ((Trigger, Trigger) -> Bool)?

    func body(content: Content) -> some View {
        content.sensoryFeedback(feedback, trigger: trigger) { oldValue, newValue in
            hapticsEnabled && (condition?(oldValue, newValue) ?? true)
        }
    }
}

extension View {
    /// Programme-owned semantic feedback that obeys the app's Haptic Feedback
    /// setting. Native controls keep their own system-provided feedback.
    func programmeSensoryFeedback<Trigger: Equatable>(
        _ feedback: SensoryFeedback,
        trigger: Trigger
    ) -> some View {
        modifier(
            ProgrammeSensoryFeedbackModifier(
                feedback: feedback, trigger: trigger, condition: nil))
    }

    func programmeSensoryFeedback<Trigger: Equatable>(
        _ feedback: SensoryFeedback,
        trigger: Trigger,
        condition: @escaping (Trigger, Trigger) -> Bool
    ) -> some View {
        modifier(
            ProgrammeSensoryFeedbackModifier(
                feedback: feedback, trigger: trigger, condition: condition))
    }
}

/// Spoken confirmation of domain-level results, posted at exactly the same
/// boundary as `Haptics` — the `LiveMatchSession` funnels — so a VoiceOver
/// scorer hears what a sighted scorer sees in the transient notice bar.
/// Nothing here fires for clock ticks, navigation, or layout: only recorded
/// facts, undo/redo, edit confirmations, and failures.
///
/// `posted` is an in-memory record of what was announced (capped, never
/// persisted) so tests can assert the scorer-facing copy without VoiceOver.
@MainActor
enum Announcer {
    private static let capacity = 20
    private(set) static var posted: [String] = []

    static func post(_ message: String) {
        posted.append(message)
        if posted.count > capacity {
            posted.removeFirst(posted.count - capacity)
        }
        AccessibilityNotification.Announcement(message).post()
    }

    /// Takes and clears the in-memory record. Tests only.
    static func drain() -> [String] {
        defer { posted = [] }
        return posted
    }
}

enum WidgetRefresher {
    static func reload() {
        #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Reloads only the match-status timeline: live scores, clock state,
    /// and upcoming fixtures. Called on every snapshot refresh.
    static func reloadMatchStatus() {
        #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.matchStatus)
        #endif
    }

    /// Reloads only the season-record timeline: record text and recent
    /// results. Called only when season data may have changed (launch,
    /// team switch, finalize/close) — never for ordinary live events.
    static func reloadSeasonRecord() {
        #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.seasonRecord)
        #endif
    }
}

/// Background work is only ever maintenance. Nothing about a match's
/// correctness depends on a future background launch.
enum MaintenanceScheduler {
    static let identifier = "com.gbyo.programme.maintenance"

    static func register() {
        #if os(iOS)
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                guard let task = task as? BGProcessingTask else { return }
                runMaintenance(task: task)
            }
        #endif
    }

    static func scheduleIfNeeded() {
        #if os(iOS)
            let request = BGProcessingTaskRequest(identifier: identifier)
            request.requiresNetworkConnectivity = false
            request.requiresExternalPower = false
            request.earliestBeginDate = Date().addingTimeInterval(60 * 60 * 12)
            try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    #if os(iOS)
        private static func runMaintenance(task: BGProcessingTask) {
            task.expirationHandler = { task.setTaskCompleted(success: false) }
            // Clear recovery journals for matches that finished a month ago.
            let journal = try? RecoveryJournal.makeDefault()
            _ = journal?.pruneClosedJournals()
            WidgetRefresher.reload()
            task.setTaskCompleted(success: true)
            scheduleIfNeeded()
        }
    #endif
}

extension Date {
    var matchDayText: String {
        formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var matchTimeText: String {
        formatted(.dateTime.hour().minute())
    }
}

/// Minutes rendered the way a coach reads them.
func minutesText(_ seconds: Int) -> String {
    "\(publishedMinutes(fromSeconds: seconds))'"
}
