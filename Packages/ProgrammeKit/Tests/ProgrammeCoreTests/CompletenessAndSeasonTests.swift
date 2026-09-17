import Foundation
import Testing

@testable import ProgrammeCore

@Suite("A zero means zero; not tracked means unknown")
struct CompletenessTests {

    @Test("A category the profile does not track reports as not tracked, never as zero")
    func untrackedIsNotZero() throws {
        var fixture = MatchFixture(profile: .scoreOnly)
        try fixture.startMatch()
        try fixture.playFullMatchAndFinalize()

        let snapshot = fixture.snapshot
        #expect(snapshot.completeness(.goals) == .complete)
        #expect(snapshot.completeness(.cards) == .complete)
        #expect(snapshot.completeness(.steals) == .notTracked)
        #expect(snapshot.completeness(.shots) == .notTracked)
        #expect(snapshot.completeness(.goalkeeping) == .notTracked)

        let steals = fixture.context.profile.value(.steals, snapshot.team.us.steals)
        #expect(steals == .notTracked)
        #expect(steals.text() == "—")
    }

    @Test("A tracked category with no events reports a genuine zero")
    func trackedZeroIsZero() throws {
        var fixture = MatchFixture(profile: .maxPreps)
        try fixture.startMatch()
        try fixture.playFullMatchAndFinalize()

        let snapshot = fixture.snapshot
        #expect(snapshot.completeness(.steals) == .complete)
        let steals = fixture.context.profile.value(.steals, snapshot.team.us.steals)
        #expect(steals == .count(0))
        #expect(steals.text() == "0")
    }

    @Test("An outstanding attribution marks only the affected categories for review")
    func reviewAffectsRelatedCategoriesOnly() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(.recordSteal(side: .us, player: .unidentified))

        let snapshot = fixture.snapshot
        #expect(snapshot.completeness(.steals) == .needsReview)
        #expect(snapshot.completeness(.goals) == .complete)
        #expect(snapshot.completeness(.corners) == .complete)
    }

    @Test("Events recorded outside the profile are kept and reported, never discarded")
    func untrackedEventsAreKept() throws {
        var fixture = MatchFixture(profile: .scoreOnly)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12)
        try fixture.perform(.recordSteal(side: .us, player: .player(ProgrammeSample.mabry)))

        // The event is stored and the raw count is right...
        #expect(fixture.snapshot.player(ProgrammeSample.mabry).steals == 1)
        // ...but the match still reports steals as untracked, and says why.
        #expect(fixture.snapshot.completeness(.steals) == .notTracked)
        #expect(fixture.issues.contains { $0.kind == .untrackedCategoryHasEvents })
        #expect(fixture.issues.first { $0.kind == .untrackedCategoryHasEvents }?.severity == .info)
    }
}

@Suite("Season aggregation preserves the tracked distinction")
struct SeasonTests {

    private func summary(_ context: MatchContext) -> MatchStatSummary {
        MatchStatSummary(
            snapshot: StatEngine.snapshot(context: context),
            tracked: context.profile.tracked,
            isFinalized: context.phase == .finalized
        )
    }

    @Test("Records and goal totals accumulate across matches")
    func seasonRecord() {
        let contexts = ProgrammeSample.seasonContexts()
        let season = SeasonEngine.aggregate(contexts.map(summary))

        #expect(season.matchesPlayed == 4)
        #expect(season.wins == 3)
        #expect(season.losses == 1)
        #expect(season.draws == 0)
        #expect(season.recordText == "3-1-0")
        #expect(season.goalsFor == 10)
        #expect(season.goalsAgainst == 5)
        #expect(season.teamShutouts == 1)
    }

    @Test("A category tracked in only some matches reports its coverage")
    func partialCoverage() throws {
        var tracked = MatchFixture(profile: .maxPreps)
        try tracked.startMatch()
        tracked.seek(period: 1, minutes: 10)
        try tracked.perform(.recordSteal(side: .us, player: .player(ProgrammeSample.mabry)))
        try tracked.playFullMatchAndFinalize()

        var untracked = MatchFixture(profile: .scoreOnly)
        try untracked.startMatch()
        try untracked.playFullMatchAndFinalize()

        let season = SeasonEngine.aggregate([summary(tracked.context), summary(untracked.context)])
        let mabry = try #require(season.players[ProgrammeSample.mabry])

        #expect(mabry.matchesPlayed == 2)
        #expect(mabry.value(.steals, \.steals) == .count(1))
        #expect(mabry.coverage(.steals) == (1, 2))
        #expect(season.completeness(.steals) == .needsReview)
        #expect(season.completeness(.goals) == .complete)
    }

    @Test("A statistic no match tracked stays unknown at season level")
    func seasonWideUntracked() throws {
        var first = MatchFixture(profile: .scoreOnly)
        try first.startMatch()
        try first.playFullMatchAndFinalize()
        var second = MatchFixture(profile: .scoreOnly)
        try second.startMatch()
        try second.playFullMatchAndFinalize()

        let season = SeasonEngine.aggregate([summary(first.context), summary(second.context)])
        #expect(season.completeness(.steals) == .notTracked)
        let carter = try #require(season.players[ProgrammeSample.carter])
        #expect(carter.value(.steals, \.steals) == .notTracked)
        #expect(carter.shotAccuracy == .notTracked)
    }

    @Test("Season goalkeeping totals combine minutes, saves and shutouts")
    func seasonGoalkeeping() {
        let contexts = ProgrammeSample.seasonContexts()
        let season = SeasonEngine.aggregate(contexts.map(summary))
        let keeper = season.keepers[ProgrammeSample.keeper]

        #expect(keeper != nil)
        #expect((keeper?.totals.secondsPlayed ?? 0) > 0)
        #expect(keeper?.savePercentage.isTracked == true)
        #expect(keeper?.goalsAgainstAverage.isTracked == true)
    }
}

@Suite("The acceptance scenario end to end")
struct AcceptanceScenarioTests {

    @Test("A scorer can run a full match, correct mistakes, and finalize cleanly")
    func fullScenario() throws {
        var fixture = MatchFixture()

        // Confirm the starting eleven and kick off.
        try fixture.startMatch()
        #expect(fixture.context.phase == .inPeriod)
        #expect(fixture.snapshot.activeLineup.count == 11)

        // #9 takes a shot off target.
        fixture.seek(period: 1, minutes: 3, seconds: 12)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .offTarget)))

        // The opponent puts one on target and the goalkeeper saves it. One event,
        // not an opponent shot plus an opponent shot on goal plus a save.
        fixture.seek(period: 1, minutes: 7, seconds: 40)
        try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved)))
        #expect(fixture.context.activeEvents.filter { $0.category == .save }.count == 1)
        #expect(fixture.snapshot.keeper(ProgrammeSample.keeper).saves == 1)
        #expect(fixture.snapshot.team.opponent.shotsOnGoal == 1)

        // #7 assists #9. The score becomes 1–0 immediately.
        fixture.seek(period: 1, minutes: 12, seconds: 50)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal,
                    assist: .player(ProgrammeSample.williams))))
        #expect(fixture.snapshot.scoreText == "1 – 0")

        // #12 replaces #8.
        fixture.seek(period: 1, minutes: 31, seconds: 4)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.mabry], playersIn: [ProgrammeSample.ridgeway])))
        let substitution = try #require(fixture.lastEvent)

        // Five minutes later the scorer realises it happened two minutes earlier.
        fixture.seek(period: 1, minutes: 36)
        try fixture.edit(.changeTime(substitution.id, MatchTime.period(1, 29, 4)))

        // A shot whose taker could not be identified.
        fixture.seek(period: 1, minutes: 37, seconds: 20)
        try fixture.perform(.recordShot(ShotEvent(side: .us, shooter: .unidentified, outcome: .saved)))
        #expect(fixture.snapshot.needsReviewCount == 1)

        // Halftime.
        try fixture.completePeriod(1)
        #expect(fixture.context.phase == .periodBreak)
        let halftime = fixture.snapshot
        #expect(halftime.score.us == 1)
        #expect(halftime.eventsNeedingReview.count == 1)

        // Resolve the attribution to #10.
        let unattributed = try #require(halftime.eventsNeedingReview.first)
        try fixture.edit(.attribute(unattributed.id, .primary, .player(ProgrammeSample.sanders)))
        #expect(fixture.snapshot.needsReviewCount == 0)

        // Second half, including a player coming back on.
        try fixture.perform(.startNextPeriod)
        fixture.seek(period: 2, minutes: 12)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.ridgeway], playersIn: [ProgrammeSample.mabry])))
        fixture.seek(period: 2, minutes: 25)
        try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)))
        fixture.seek(period: 2, minutes: 33)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.sanders), outcome: .goal,
                    assist: .player(ProgrammeSample.carter))))

        try fixture.completePeriod(2)
        #expect(fixture.context.phase == .awaitingFinalization)

        // Everything reconciles.
        let final = fixture.snapshot
        #expect(final.score.us == 2)
        #expect(final.score.opponent == 1)
        #expect(final.result == .win)
        #expect(fixture.issues.canFinalizeCleanly)

        // #8 played 29 minutes in the first half and 28 in the second.
        #expect(fixture.minutes(ProgrammeSample.mabry) == 57)
        #expect(fixture.minutes(ProgrammeSample.ridgeway) == 23)
        #expect(fixture.minutes(ProgrammeSample.carter) == 80)

        // Goalkeeping reconciles against the score.
        let keeper = final.keeper(ProgrammeSample.keeper)
        #expect(keeper.saves == 1)
        #expect(keeper.goalsAllowed == 1)
        #expect(keeper.minutesPlayed == 80)

        // The game-winning goal belongs to the scorer of the second goal.
        try fixture.perform(.finalize)
        #expect(fixture.snapshot.player(ProgrammeSample.sanders).gameWinningGoals == 1)

        // Complete versus not tracked is explicit.
        let completeness = fixture.snapshot.completeness
        #expect(completeness[.goals] == .complete)
        #expect(completeness[.assists] == .complete)
        #expect(completeness[.goalkeeping] == .complete)
        #expect(completeness[.shots] == .complete)
        #expect(completeness[.steals] == .complete)
        #expect(completeness[.offsides] == .notTracked)
        #expect(completeness[.fouls] == .notTracked)
    }
}
