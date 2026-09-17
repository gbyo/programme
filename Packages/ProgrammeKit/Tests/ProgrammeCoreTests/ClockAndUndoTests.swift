import Foundation
import Testing

@testable import ProgrammeCore

@Suite("The match clock is derived from anchors, never ticked")
struct ClockTests {

    @Test("Elapsed time comes from the wall clock, so backgrounding cannot corrupt it")
    func elapsedDerivedFromAnchor() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = ClockAnchor(period: 1, elapsedAtAnchor: 120, runningSince: start)
        #expect(anchor.elapsed(at: start) == 120)
        #expect(anchor.elapsed(at: start.addingTimeInterval(300)) == 420)
        // A gap of any length — a locked iPad, an app switch — is absorbed exactly.
        #expect(anchor.elapsed(at: start.addingTimeInterval(3_600)) == 3_720)
    }

    @Test("Stopping the clock freezes elapsed time")
    func stoppingFreezesTime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let running = ClockAnchor(period: 1, elapsedAtAnchor: 0, runningSince: start)
        let stopped = running.stopped(at: start.addingTimeInterval(65))
        #expect(stopped.isRunning == false)
        #expect(stopped.elapsed(at: start.addingTimeInterval(10_000)) == 65)
        let resumed = stopped.started(at: start.addingTimeInterval(10_000))
        #expect(resumed.elapsed(at: start.addingTimeInterval(10_030)) == 95)
    }

    @Test(
        "Countdown display reflects the period length without changing stored time",
        arguments: [
            (MatchTime.period(1, 0, 0), "40:00"),
            (MatchTime.period(1, 16, 19), "23:41"),
            (MatchTime.period(2, 40, 0), "0:00"),
        ]
    )
    func countdownDisplay(time: MatchTime, expected: String) {
        #expect(time.displayText(rules: .highSchool) == expected)
    }

    @Test("Cumulative display continues across periods")
    func cumulativeDisplay() {
        let rules = MatchRules.professional
        #expect(MatchTime.period(2, 20, 0).displayText(rules: rules) == "65:00")
        #expect(MatchTime.period(1, 20, 0).displayText(rules: rules) == "20:00")
    }

    @Test("Adjusting the clock records an auditable event and leaves history alone")
    func clockAdjustmentDoesNotRewriteHistory() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .offTarget)))
        let shot = try #require(fixture.lastEvent)

        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(.adjustClock(toSeconds: 17 * 60, reason: "Scoreboard correction"))

        // The earlier shot keeps the time it was recorded at.
        let stored = try #require(fixture.context.events.first { $0.id == shot.id })
        #expect(stored.time == MatchTime.period(1, 12, 0))
        #expect(stored.revision == 1)
        // The adjustment itself is in the record.
        #expect(
            fixture.context.activeEvents.contains {
                if case .clockAdjusted(let adjustment) = $0.payload {
                    return adjustment.fromSeconds == 1_200 && adjustment.toSeconds == 1_020
                }
                return false
            })
        #expect(fixture.context.clock.period == 1)
        #expect(Int(fixture.context.clock.elapsedAtAnchor) == 1_020)
    }

    @Test("Ending and starting periods moves the phase correctly")
    func periodTransitions() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        #expect(fixture.context.phase == .inPeriod)
        try fixture.completePeriod(1)
        #expect(fixture.context.phase == .periodBreak)
        try fixture.perform(.startNextPeriod)
        #expect(fixture.context.phase == .inPeriod)
        #expect(fixture.context.clock.period == 2)
    }

    @Test("A decisive regulation score skips overtime")
    func decisiveScoreEndsMatch() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        try fixture.completePeriod(2)
        #expect(fixture.context.phase == .awaitingFinalization)
    }

    @Test("A tied regulation score under high-school rules goes to overtime")
    func tiedScoreGoesToOvertime() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        try fixture.completePeriod(2)
        #expect(fixture.context.phase == .periodBreak)
        try fixture.perform(.startNextPeriod)
        #expect(fixture.context.clock.period == 3)
        #expect(fixture.context.rules.period(at: 3)?.kind == .overtime)
    }

    @Test("Sudden-victory overtime ends the match as soon as someone scores")
    func suddenVictory() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        try fixture.completePeriod(2)
        try fixture.perform(.startNextPeriod)
        fixture.seek(period: 3, minutes: 4)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        try fixture.perform(.endCurrentPeriod)
        #expect(fixture.context.phase == .awaitingFinalization)
    }
}

@Suite("Undo and redo")
struct UndoTests {

    @Test("Undo removes the most recent event immediately")
    func undoIsImmediate() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        #expect(fixture.snapshot.score.us == 1)

        try fixture.undo()
        #expect(fixture.snapshot.score.us == 0)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).goals == 0)
    }

    @Test("Redo restores what undo removed")
    func redoRestores() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal,
                    assist: .player(ProgrammeSample.williams))))
        try fixture.undo()
        try fixture.redo()

        let snapshot = fixture.snapshot
        #expect(snapshot.score.us == 1)
        #expect(snapshot.player(ProgrammeSample.carter).goals == 1)
        #expect(snapshot.player(ProgrammeSample.williams).assists == 1)
    }

    @Test("Undoing several events walks back in order")
    func repeatedUndo() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        for minute in [5, 10, 15] {
            fixture.seek(period: 1, minutes: minute)
            try fixture.perform(
                .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        }
        #expect(fixture.snapshot.score.us == 3)
        try fixture.undo()
        try fixture.undo()
        #expect(fixture.snapshot.score.us == 1)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).goals == 1)
    }

    @Test("Undoing the end of a period restores the clock and phase")
    func undoEndPeriod() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 22)
        try fixture.perform(.endCurrentPeriod)
        #expect(fixture.context.phase == .periodBreak)

        try fixture.undo()
        #expect(fixture.context.phase == .inPeriod)
        #expect(fixture.context.clock.period == 1)
        #expect(Int(fixture.context.clock.elapsedAtAnchor) == 1_320)
        #expect(fixture.context.clock.isRunning == false)
    }

    @Test("Undoing the start of a period returns to the break before it")
    func undoStartPeriod() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        try fixture.undo()

        #expect(fixture.context.phase == .periodBreak)
        #expect(fixture.context.clock.period == 1)
        #expect(fixture.context.startedPeriods == [1])
    }

    @Test("Undo never removes the finalization event")
    func undoSkipsFinalization() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 30)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        try fixture.playFullMatchAndFinalize()

        let target = MatchEngine.undoTarget(fixture.context)
        #expect(target != nil)
        if case .matchFinalized = target?.payload { Issue.record("undo targeted finalization") }
    }

    @Test("Undo on an empty match reports that there is nothing to undo")
    func nothingToUndo() throws {
        let fixture = MatchFixture()
        #expect(throws: MatchCommandError.nothingToUndo) {
            _ = try MatchEngine.undo(fixture.context, at: fixture.date)
        }
    }
}
