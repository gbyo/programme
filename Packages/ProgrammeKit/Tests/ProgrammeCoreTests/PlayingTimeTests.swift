import Foundation
import Testing

@testable import ProgrammeCore

@Suite("Playing time is derived from lineup intervals")
struct PlayingTimeTests {

    @Test("A starter who is never substituted plays the whole match")
    func starterPlaysFullMatch() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.playFullMatchAndFinalize()

        #expect(fixture.minutes(ProgrammeSample.carter) == 80)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).started)
        #expect(fixture.snapshot.timeline.periods.totalSecondsPlayed == 4_800)
    }

    @Test("A player substituted out stops accruing minutes at that moment")
    func substitutedOut() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 25)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.mabry], playersIn: [ProgrammeSample.ridgeway])))
        try fixture.playFullMatchAndFinalize()

        #expect(fixture.minutes(ProgrammeSample.mabry) == 25)
        #expect(fixture.minutes(ProgrammeSample.ridgeway) == 55)
        #expect(fixture.snapshot.player(ProgrammeSample.ridgeway).started == false)
        #expect(fixture.snapshot.player(ProgrammeSample.ridgeway).appeared)
    }

    @Test("A player who re-enters accumulates both spells")
    func reEntry() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()

        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.trotter], playersIn: [ProgrammeSample.ridgeway])))
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)

        fixture.seek(period: 2, minutes: 10)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.ridgeway], playersIn: [ProgrammeSample.trotter])))
        try fixture.completePeriod(2)
        try fixture.perform(.finalize)

        // 20 in the first half, 30 in the second.
        #expect(fixture.minutes(ProgrammeSample.trotter) == 50)
        #expect(fixture.minutes(ProgrammeSample.ridgeway) == 30)
        #expect(fixture.snapshot.timeline.intervals(for: ProgrammeSample.trotter).count == 2)
    }

    @Test("Several players can be substituted at one timestamp")
    func multiSubstitution() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 30)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us,
                    playersOut: [ProgrammeSample.mabry, ProgrammeSample.trotter, ProgrammeSample.sanders],
                    playersIn: [
                        ProgrammeSample.ridgeway, ProgrammeSample.playerID("Kade.Hollis"),
                        ProgrammeSample.playerID("Theo.Nance"),
                    ])))
        try fixture.playFullMatchAndFinalize()

        #expect(fixture.minutes(ProgrammeSample.mabry) == 30)
        #expect(fixture.minutes(ProgrammeSample.trotter) == 30)
        #expect(fixture.minutes(ProgrammeSample.sanders) == 30)
        #expect(fixture.minutes(ProgrammeSample.ridgeway) == 50)
        #expect(fixture.snapshot.activeLineup.count == 11)
        #expect(fixture.issues.blocking.isEmpty)
    }

    @Test("Correcting a substitution's time repairs both players' minutes")
    func editingSubstitutionTimeRecalculatesMinutes() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 31, seconds: 4)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.playerID("Drew.Mabry")],
                    playersIn: [ProgrammeSample.ridgeway])))
        let substitution = try #require(fixture.lastEvent)
        try fixture.playFullMatchAndFinalize()

        #expect(fixture.minutes(ProgrammeSample.mabry) == 31)
        #expect(fixture.minutes(ProgrammeSample.ridgeway) == 49)

        // The scorer realises it actually happened two minutes earlier.
        try fixture.edit(.changeTime(substitution.id, MatchTime.period(1, 29, 4)))

        #expect(fixture.minutes(ProgrammeSample.mabry) == 29)
        #expect(fixture.minutes(ProgrammeSample.ridgeway) == 51)
        // Total playing time across the eleven is unchanged.
        let total = fixture.snapshot.players.values.reduce(0) { $0 + $1.secondsPlayed }
        #expect(total == 11 * 4_800)
    }

    @Test("Goalkeeper minutes split across a goalkeeper change")
    func goalkeeperReplacement() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)

        fixture.seek(period: 2, minutes: 20)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.keeper], playersIn: [ProgrammeSample.backupKeeper],
                    goalkeeperAfter: ProgrammeSample.backupKeeper)))
        try fixture.completePeriod(2)
        try fixture.perform(.finalize)

        let snapshot = fixture.snapshot
        #expect(snapshot.keeper(ProgrammeSample.keeper).minutesPlayed == 60)
        #expect(snapshot.keeper(ProgrammeSample.backupKeeper).minutesPlayed == 20)
        #expect(snapshot.timeline.currentGoalkeeper(side: .us) == ProgrammeSample.backupKeeper)
    }

    @Test("A player sent off stops accruing minutes and is not replaced")
    func dismissalEndsInterval() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 18)
        try fixture.perform(
            .recordCard(CardEvent(side: .us, player: .player(ProgrammeSample.sanders), card: .red)))
        try fixture.playFullMatchAndFinalize()

        #expect(fixture.minutes(ProgrammeSample.sanders) == 18)
        #expect(fixture.snapshot.activeLineup.count == 10)
        #expect(fixture.snapshot.player(ProgrammeSample.sanders).redCards == 1)
        // Being a player short because of a dismissal is not a validation issue.
        #expect(!fixture.issues.contains { $0.kind == .tooFewActive })
    }

    @Test("Overtime minutes accumulate on top of regulation")
    func overtimeMinutes() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        try fixture.completePeriod(2)
        // 0–0 after regulation, so overtime is available.
        #expect(fixture.context.phase == .periodBreak)
        try fixture.perform(.startNextPeriod)
        try fixture.completePeriod(3, atMinute: 10)
        try fixture.perform(.finalize)

        #expect(fixture.minutes(ProgrammeSample.carter) == 90)
        #expect(fixture.snapshot.timeline.periods.spans.count == 3)
    }

    @Test("A period that ends early only counts the minutes actually played")
    func shortenedPeriod() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.completePeriod(1, atMinute: 33)
        try fixture.perform(.startNextPeriod)
        try fixture.completePeriod(2, atMinute: 40)
        try fixture.perform(.finalize)

        #expect(fixture.minutes(ProgrammeSample.carter) == 73)
    }

    @Test(
        "Minutes are correct for every substitution minute",
        arguments: [5, 12, 20, 33, 39, 40]
    )
    func minutesAcrossSubstitutionTimes(subMinute: Int) throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: subMinute)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.carter], playersIn: [ProgrammeSample.ridgeway])))
        try fixture.playFullMatchAndFinalize()

        #expect(fixture.minutes(ProgrammeSample.carter) == subMinute)
        #expect(fixture.minutes(ProgrammeSample.ridgeway) == 80 - subMinute)
    }
}
