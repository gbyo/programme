import BackgroundTasks
import Foundation
import ProgrammeCore
import ProgrammePersistence
import SwiftUI
import WidgetKit

#if canImport(UIKit)
    import UIKit
#endif

/// Short, physical confirmation that an event landed. A scorer who is looking at
/// the pitch needs to feel that the tap registered.
@MainActor
enum Haptics {
    #if canImport(UIKit)
        private static let impact = UIImpactFeedbackGenerator(style: .medium)
        private static let selection = UISelectionFeedbackGenerator()
        private static let notification = UINotificationFeedbackGenerator()
    #endif

    static func prepare() {
        #if canImport(UIKit)
            impact.prepare()
            selection.prepare()
        #endif
    }

    /// An event was recorded.
    static func recorded() {
        #if canImport(UIKit)
            impact.impactOccurred(intensity: 0.7)
        #endif
    }

    /// A goal. Noticeably stronger, but still momentary — never a celebration
    /// that gets in the way of the next event.
    static func goal() {
        #if canImport(UIKit)
            notification.notificationOccurred(.success)
        #endif
    }

    static func selectionChanged() {
        #if canImport(UIKit)
            selection.selectionChanged()
        #endif
    }

    static func undone() {
        #if canImport(UIKit)
            impact.impactOccurred(intensity: 0.45)
        #endif
    }

    static func rejected() {
        #if canImport(UIKit)
            notification.notificationOccurred(.warning)
        #endif
    }
}

enum WidgetRefresher {
    static func reload() {
        #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

/// Background work is only ever maintenance. Nothing about a match's
/// correctness depends on a future background launch.
enum MaintenanceScheduler {
    static let identifier = "org.programme.maintenance"

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
