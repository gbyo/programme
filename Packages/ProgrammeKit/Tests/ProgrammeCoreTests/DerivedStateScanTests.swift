import Foundation
import Testing

@testable import ProgrammeCore

/// Guards the issue-102 optimization: the live session narrates the last
/// meaningful event with the already-derived `snapshot.score` instead of
/// replaying every scoring event, and validation derives its period facts
/// once instead of rescanning history per event. Events remain the only
/// truth; these tests lock the equivalences the optimization relies on.
@Suite("Derived state reuses already-derived facts")
struct DerivedStateScanTests {

    /// A long synthetic match: goals for both sides plus many non-scoring
    /// events, with a note and a clock adjustment trailing the last
    /// meaningful event.
    private func longMatch(eventCount: Int = 200) throws -> MatchFixture {
        var fixture = MatchFixture()
        try fixture.startMatch()
        for index in 0..<eventCount {
            fixture.seek(period: 1, minutes: index % 39, seconds: index % 60)
            if index.isMultiple(of: 10) {
                try fixture.perform(
                    .recordShot(
                        ShotEvent(
                            side: .us, shooter: .player(ProgrammeSample.carter),
                            outcome: .goal)))
            } else if index.isMultiple(of: 15) {
                try fixture.perform(
                    .recordShot(
                        ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)))
            } else {
                try fixture.perform(
                    .recordShot(
                        ShotEvent(
                            side: .us, shooter: .player(ProgrammeSample.carter),
                            outcome: .offTarget)))
            }
        }
        try fixture.perform(.addNote("Scout note after the last meaningful event"))
        try fixture.perform(.adjustClock(toSeconds: 60, reason: "Clock check"))
        return fixture
    }

    private func replayedScore(
        events: [MatchEvent],
        upTo lastID: EventID
    ) -> SidePair<Int> {
        var score = SidePair(repeating: 0)
        for event in events {
            if case .shot(let shot) = event.payload, shot.outcome.isGoal {
                score[shot.scoringSide] += 1
            }
            if event.id == lastID { break }
        }
        return score
    }

    private func lastMeaningfulEvent(in context: MatchContext) throws -> MatchEvent {
        try #require(
            context.activeEvents.last {
                switch $0.payload {
                case .note, .clockAdjusted: false
                default: true
                }
            })
    }

    @Test("Snapshot score equals the replay up to the last meaningful event")
    func snapshotScoreMatchesReplay() throws {
        let fixture = try longMatch()
        let last = try lastMeaningfulEvent(in: fixture.context)
        let replayed = replayedScore(events: fixture.context.activeEvents, upTo: last.id)
        #expect(replayed == fixture.snapshot.score)
        // Narrating with the snapshot score is therefore identical to the
        // removed per-commit replay.
        let viaSnapshot = MatchNarrator.describe(
            last, context: fixture.context, scoreAfter: fixture.snapshot.score)
        let viaReplay = MatchNarrator.describe(last, context: fixture.context, scoreAfter: replayed)
        #expect(viaSnapshot == viaReplay)
    }

    @Test("Snapshot score matches when a period end is the last meaningful event")
    func snapshotScoreMatchesWhenPeriodEndsLast() throws {
        var fixture = try longMatch(eventCount: 60)
        try fixture.completePeriod(1)
        let last = try lastMeaningfulEvent(in: fixture.context)
        #expect(last.category == .clock)
        let replayed = replayedScore(events: fixture.context.activeEvents, upTo: last.id)
        #expect(replayed == fixture.snapshot.score)
        let viaSnapshot = MatchNarrator.describe(
            last, context: fixture.context, scoreAfter: fixture.snapshot.score)
        #expect(viaSnapshot.scoreText != nil)
    }

    @Test("Undoing the trailing noise still rederives from events")
    func undoTrailsRederiveFromEvents() throws {
        var fixture = try longMatch(eventCount: 60)
        let scoreBeforeUndo = fixture.snapshot.score
        try fixture.undo()
        try fixture.undo()
        let last = try lastMeaningfulEvent(in: fixture.context)
        let replayed = replayedScore(events: fixture.context.activeEvents, upTo: last.id)
        #expect(replayed == fixture.snapshot.score)
        #expect(fixture.snapshot.score == scoreBeforeUndo)
    }

    @Test("Validation on a long match is deterministic")
    func validationIsDeterministicOnLongMatch() throws {
        let fixture = try longMatch()
        let snapshot = fixture.snapshot
        let first = ValidationEngine.issues(context: fixture.context, snapshot: snapshot)
        let second = ValidationEngine.issues(context: fixture.context, snapshot: snapshot)
        #expect(first == second)
        #expect(first.allSatisfy { $0.kind != .eventOutsidePeriod })
    }
}
