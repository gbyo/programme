import Foundation
import Testing

@testable import ProgrammeCore

/// Builds a match the way a scorer would, with the clock parked at an exact
/// moment so tests are deterministic.
struct MatchFixture {
    var context: MatchContext
    var date = Date(timeIntervalSince1970: 1_800_000_000)

    init(
        rules: MatchRules = .highSchool,
        profile: StatProfile = .maxPreps,
        roster: RosterSnapshot = ProgrammeSample.roster,
        tracking: OpponentTrackingMode = .ourTeam
    ) {
        var descriptor = ProgrammeSample.descriptor(rules: rules, profile: profile)
        descriptor.tracking = tracking
        context = MatchContext(descriptor: descriptor, roster: roster)
    }

    /// Park the clock at an exact point in a period.
    mutating func seek(period: Int, minutes: Int, seconds: Int = 0) {
        context.clock = ClockAnchor(
            period: period,
            elapsedAtAnchor: TimeInterval(minutes * 60 + seconds),
            runningSince: nil
        )
        date = date.addingTimeInterval(1)
    }

    @discardableResult
    mutating func perform(_ command: MatchCommand) throws -> [MatchEffect] {
        let effects = try MatchEngine.perform(command, on: context, at: date)
        MatchEngine.apply(effects, to: &context)
        date = date.addingTimeInterval(1)
        return effects
    }

    @discardableResult
    mutating func edit(_ command: EventEditCommand) throws -> [MatchEffect] {
        let effects = try MatchEngine.perform(command, on: context, at: date)
        MatchEngine.apply(effects, to: &context)
        date = date.addingTimeInterval(1)
        return effects
    }

    mutating func undo() throws {
        let effects = try MatchEngine.undo(context, at: date)
        MatchEngine.apply(effects, to: &context)
        date = date.addingTimeInterval(1)
    }

    mutating func redo() throws {
        let effects = try MatchEngine.redo(context, at: date)
        MatchEngine.apply(effects, to: &context)
        date = date.addingTimeInterval(1)
    }

    /// Kick off with the sample starting eleven.
    mutating func startMatch(
        lineup: [PlayerID] = ProgrammeSample.startingEleven,
        goalkeeper: PlayerID? = ProgrammeSample.keeper
    ) throws {
        try perform(.setLineup(LineupEvent(side: .us, onField: lineup, goalkeeper: goalkeeper)))
        try perform(.startNextPeriod)
    }

    /// End the current period at its scheduled length and begin the next.
    mutating func completePeriod(_ period: Int, atMinute minutes: Int = 40) throws {
        seek(period: period, minutes: minutes)
        try perform(.endCurrentPeriod)
    }

    var snapshot: MatchSnapshot { StatEngine.snapshot(context: context, at: date) }

    var issues: [ValidationIssue] {
        ValidationEngine.issues(context: context, snapshot: snapshot)
    }

    func minutes(_ player: PlayerID) -> Int {
        snapshot.player(player).minutesPlayed
    }

    func seconds(_ player: PlayerID) -> Int {
        snapshot.player(player).secondsPlayed
    }

    var lastEvent: MatchEvent? {
        context.events.filter(\.isActive).max { $0.sequence < $1.sequence }
    }

    func events(matching predicate: (MatchEvent) -> Bool) -> [MatchEvent] {
        context.activeEvents.filter(predicate)
    }

    func firstGoalEvent() -> MatchEvent? {
        context.activeEvents.first {
            if case .shot(let shot) = $0.payload { return shot.outcome.isGoal }
            return false
        }
    }
}

extension MatchFixture {
    /// Play both halves out fully and finalize.
    mutating func playFullMatchAndFinalize() throws {
        try completePeriod(1)
        try perform(.startNextPeriod)
        try completePeriod(2)
        try perform(.finalize)
    }
}
