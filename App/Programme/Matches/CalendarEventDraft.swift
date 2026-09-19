import Foundation
import ProgrammeCore

/// Everything the system calendar editor needs prefilled for a match.
///
/// Lives in the app layer on purpose: ProgrammeCore owns soccer truth and
/// must not know Calendar integration exists. A pure value depending only on
/// Core values, so the prefill logic stays unit-testable without EventKit.
/// The bridge maps this onto `EKEvent`; the system event editor owns
/// calendar choice, alerts, and saving. Programme never requests broad
/// calendar access merely to offer "Add to Calendar…".
struct CalendarEventDraft: Hashable, Sendable {
    var title: String
    var startDate: Date
    var endDate: Date
    var location: String?
    var notes: String?

    /// Extra time beyond regulation so the calendar block covers halftime
    /// and stoppages. Deliberately an estimate, not a promised final whistle.
    static let estimatedExtraTime: TimeInterval = 1_800

    init(descriptor: MatchDescriptor) {
        title = "\(descriptor.teamName) \(descriptor.venue.shortLabel) \(descriptor.opponentName)"
        startDate = descriptor.kickoff
        endDate = descriptor.kickoff.addingTimeInterval(
            TimeInterval(descriptor.rules.regulationLength) + Self.estimatedExtraTime)
        if let matchLocation = descriptor.location {
            location =
                [matchLocation.name, matchLocation.address]
                .compactMap { $0 }
                .joined(separator: ", ")
        }
        let details =
            [descriptor.competition, descriptor.rules.name]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        notes = details.isEmpty ? nil : details.joined(separator: " · ")
    }
}
