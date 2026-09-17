import Foundation
import Testing

@testable import ProgrammeCore

@Suite("Goalkeeping statistics")
struct GoalkeeperTests {

    /// Faces `saves` saved shots and `conceded` goals in the first half.
    private func matchFacing(saves: Int, conceded: Int) throws -> MatchFixture {
        var fixture = MatchFixture()
        try fixture.startMatch()
        var minute = 2
        for _ in 0..<saves {
            fixture.seek(period: 1, minutes: minute)
            try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved)))
            minute += 1
        }
        for _ in 0..<conceded {
            fixture.seek(period: 1, minutes: minute)
            try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)))
            minute += 1
        }
        return fixture
    }

    @Test(
        "Save percentage is saves over shots on goal faced",
        arguments: [(6, 2, 0.75), (9, 1, 0.9), (0, 3, 0.0), (5, 0, 1.0)]
    )
    func savePercentage(saves: Int, conceded: Int, expected: Double) throws {
        let fixture = try matchFacing(saves: saves, conceded: conceded)
        let keeper = fixture.snapshot.keeper(ProgrammeSample.keeper)
        #expect(keeper.saves == saves)
        #expect(keeper.goalsAllowed == conceded)
        #expect(keeper.shotsOnGoalFaced == saves + conceded)
        let percentage = try #require(keeper.savePercentage)
        #expect(abs(percentage - expected) < 0.0001)
    }

    @Test("An untested goalkeeper has no save percentage rather than zero")
    func untestedKeeperHasNoSavePercentage() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.playFullMatchAndFinalize()
        let keeper = fixture.snapshot.keeper(ProgrammeSample.keeper)
        #expect(keeper.shotsOnGoalFaced == 0)
        #expect(keeper.savePercentage == nil)
    }

    @Test("Goals-against average scales goals allowed to a regulation match")
    func goalsAgainstAverage() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)))
        // The starter plays 40 minutes, then is replaced.
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        fixture.seek(period: 2, minutes: 0)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.keeper], playersIn: [ProgrammeSample.backupKeeper],
                    goalkeeperAfter: ProgrammeSample.backupKeeper)))
        try fixture.completePeriod(2)
        try fixture.perform(.finalize)

        let keeper = fixture.snapshot.keeper(ProgrammeSample.keeper)
        #expect(keeper.minutesPlayed == 40)
        // One goal in half a match is a two-goal average over 80 minutes.
        let gaa = try #require(keeper.goalsAgainstAverage(regulationSeconds: 4_800))
        #expect(abs(gaa - 2.0) < 0.0001)

        let backup = fixture.snapshot.keeper(ProgrammeSample.backupKeeper)
        #expect(backup.goalsAllowed == 0)
        #expect(backup.goalsAgainstAverage(regulationSeconds: 4_800) == 0)
    }

    @Test("A goalkeeper who plays a whole clean sheet earns a shutout")
    func fullMatchShutout() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        try fixture.playFullMatchAndFinalize()

        let keeper = fixture.snapshot.keeper(ProgrammeSample.keeper)
        #expect(keeper.shutouts == 1)
        #expect(keeper.sharedShutouts == 0)
        #expect(keeper.wins == 1)
        #expect(fixture.snapshot.result == .win)
    }

    @Test("A clean sheet shared by two goalkeepers is recorded as shared, not doubled")
    func sharedShutout() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        fixture.seek(period: 2, minutes: 0)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.keeper], playersIn: [ProgrammeSample.backupKeeper],
                    goalkeeperAfter: ProgrammeSample.backupKeeper)))
        try fixture.completePeriod(2)
        try fixture.perform(.finalize)

        let snapshot = fixture.snapshot
        #expect(snapshot.keeper(ProgrammeSample.keeper).minutesPlayed == 40)
        #expect(snapshot.keeper(ProgrammeSample.backupKeeper).minutesPlayed == 40)
        #expect(snapshot.keeper(ProgrammeSample.keeper).shutouts == 0)
        #expect(snapshot.keeper(ProgrammeSample.keeper).sharedShutouts == 1)
        #expect(snapshot.keeper(ProgrammeSample.backupKeeper).sharedShutouts == 1)
        // Minutes are equal, so the decision goes to whoever finished in goal.
        #expect(snapshot.keeper(ProgrammeSample.backupKeeper).wins == 1)
        #expect(snapshot.keeper(ProgrammeSample.keeper).wins == 0)
    }

    @Test("The goalkeeper decision goes to whoever played the most minutes")
    func decisionFollowsMinutes() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        // The starter plays 40 + 30, the replacement only the last 10.
        fixture.seek(period: 2, minutes: 30)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.keeper],
                    playersIn: [ProgrammeSample.backupKeeper],
                    goalkeeperAfter: ProgrammeSample.backupKeeper)))
        try fixture.completePeriod(2)
        try fixture.perform(.finalize)

        let snapshot = fixture.snapshot
        #expect(snapshot.keeper(ProgrammeSample.keeper).minutesPlayed == 70)
        #expect(snapshot.keeper(ProgrammeSample.backupKeeper).minutesPlayed == 10)
        #expect(snapshot.keeper(ProgrammeSample.keeper).wins == 1)
        #expect(snapshot.keeper(ProgrammeSample.backupKeeper).wins == 0)
    }

    @Test("The same events always produce the same goalkeeper decisions")
    func derivationIsDeterministic() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        fixture.seek(period: 2, minutes: 0)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.keeper],
                    playersIn: [ProgrammeSample.backupKeeper],
                    goalkeeperAfter: ProgrammeSample.backupKeeper)))
        try fixture.completePeriod(2)
        try fixture.perform(.finalize)

        // Nothing derived may depend on dictionary enumeration order.
        let first = StatEngine.snapshot(context: fixture.context, at: fixture.date)
        for _ in 0..<25 {
            let again = StatEngine.snapshot(context: fixture.context, at: fixture.date)
            #expect(again.keepers == first.keepers)
            #expect(again.players == first.players)
            #expect(again.score == first.score)
        }
    }

    @Test("Goals conceded are attributed to whichever goalkeeper was in goal")
    func goalsAttributedToKeeperOnFieldAtTheTime() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        fixture.seek(period: 2, minutes: 5)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.keeper], playersIn: [ProgrammeSample.backupKeeper],
                    goalkeeperAfter: ProgrammeSample.backupKeeper)))
        fixture.seek(period: 2, minutes: 15)
        try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)))
        try fixture.completePeriod(2)
        try fixture.perform(.finalize)

        #expect(fixture.snapshot.keeper(ProgrammeSample.keeper).goalsAllowed == 0)
        #expect(fixture.snapshot.keeper(ProgrammeSample.backupKeeper).goalsAllowed == 1)
        #expect(fixture.issues.contains { $0.kind == .goalkeeperStatMismatch } == false)
    }
}

@Suite("Match results and the game-winning goal")
struct MatchResultTests {

    /// Scores `us`-`them` with our goals first, then theirs, then alternating.
    private func match(us: Int, them: Int) throws -> MatchFixture {
        var fixture = MatchFixture()
        try fixture.startMatch()
        var minute = 4
        let scorers = [ProgrammeSample.carter, ProgrammeSample.sanders, ProgrammeSample.trotter]
        for index in 0..<max(us, them) {
            if index < us {
                fixture.seek(period: 1, minutes: minute)
                try fixture.perform(
                    .recordShot(
                        ShotEvent(
                            side: .us, shooter: .player(scorers[index % scorers.count]), outcome: .goal)))
                minute += 2
            }
            if index < them {
                fixture.seek(period: 1, minutes: minute)
                try fixture.perform(
                    .recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)))
                minute += 2
            }
        }
        try fixture.playFullMatchAndFinalize()
        return fixture
    }

    @Test(
        "The result follows the score",
        arguments: [(3, 1, MatchResult.win), (1, 2, .loss), (2, 2, .draw), (0, 0, .draw)]
    )
    func result(us: Int, them: Int, expected: MatchResult) throws {
        // A drawn match under high-school rules would go to overtime, so use a
        // ruleset where a draw simply stands.
        var fixture = MatchFixture(rules: .highSchoolNoOvertime)
        try fixture.startMatch()
        var minute = 4
        for _ in 0..<us {
            fixture.seek(period: 1, minutes: minute)
            try fixture.perform(
                .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
            minute += 2
        }
        for _ in 0..<them {
            fixture.seek(period: 1, minutes: minute)
            try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)))
            minute += 2
        }
        try fixture.playFullMatchAndFinalize()
        #expect(fixture.snapshot.result == expected)
    }

    @Test("The game-winning goal is the one that put the winner ahead to stay")
    func gameWinningGoal() throws {
        let fixture = try match(us: 3, them: 1)
        let snapshot = fixture.snapshot
        // 3–1: the winner's second goal is the game winner.
        #expect(snapshot.player(ProgrammeSample.carter).gameWinningGoals == 0)
        #expect(snapshot.player(ProgrammeSample.sanders).gameWinningGoals == 1)
        #expect(snapshot.gameWinningGoalEventID != nil)
    }

    @Test("A 1–0 win makes the only goal the game winner")
    func gameWinningGoalInShutout() throws {
        let fixture = try match(us: 1, them: 0)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).gameWinningGoals == 1)
    }

    @Test("A draw has no game-winning goal")
    func drawHasNoGameWinner() throws {
        var fixture = MatchFixture(rules: .highSchoolNoOvertime)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)))
        try fixture.playFullMatchAndFinalize()

        #expect(fixture.snapshot.result == .draw)
        #expect(fixture.snapshot.gameWinningGoalEventID == nil)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).gameWinningGoals == 0)
    }

    @Test("No result is derived while the match is still being played")
    func noResultWhileLive() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        #expect(fixture.snapshot.result == nil)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).gameWinningGoals == 0)
    }
}

@Suite("Shootouts")
struct ShootoutTests {

    /// Play out regulation and both overtime periods level, then take kicks.
    private func matchAtShootout() throws -> MatchFixture {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.completePeriod(1)
        try fixture.perform(.startNextPeriod)
        try fixture.completePeriod(2)
        try fixture.perform(.startNextPeriod)
        try fixture.completePeriod(3, atMinute: 10)
        try fixture.perform(.startNextPeriod)
        try fixture.completePeriod(4, atMinute: 10)
        return fixture
    }

    @Test("A shootout decides the result without changing the score")
    func shootoutDecidesResult() throws {
        var fixture = try matchAtShootout()

        let takers = [
            ProgrammeSample.carter, ProgrammeSample.sanders, ProgrammeSample.williams,
        ]
        for (index, taker) in takers.enumerated() {
            try fixture.perform(
                .recordShootoutAttempt(
                    ShootoutAttemptEvent(
                        side: .us, taker: .player(taker), scored: true, order: index * 2 + 1)))
            try fixture.perform(
                .recordShootoutAttempt(
                    ShootoutAttemptEvent(
                        side: .opponent, taker: .untracked,
                        goalkeeper: .player(ProgrammeSample.keeper), scored: index < 2,
                        order: index * 2 + 2)))
        }
        try fixture.perform(.finalize)

        let snapshot = fixture.snapshot
        // The match itself stayed goalless.
        #expect(snapshot.score.us == 0)
        #expect(snapshot.score.opponent == 0)
        #expect(snapshot.shootoutScore.us == 3)
        #expect(snapshot.shootoutScore.opponent == 2)
        #expect(snapshot.result == .win)

        // Shootout kicks never count as goals.
        #expect(snapshot.player(ProgrammeSample.carter).goals == 0)
        #expect(snapshot.player(ProgrammeSample.carter).shootoutGoals == 1)
        #expect(snapshot.player(ProgrammeSample.carter).shootoutAttempts == 1)
        #expect(snapshot.player(ProgrammeSample.carter).points == 0)
        // Nor does a shootout create a game-winning goal.
        #expect(snapshot.gameWinningGoalEventID == nil)
    }

    @Test("A goalkeeper is credited with the shootout kicks they stop")
    func keeperSavesInShootout() throws {
        var fixture = try matchAtShootout()
        for order in 1...3 {
            try fixture.perform(
                .recordShootoutAttempt(
                    ShootoutAttemptEvent(
                        side: .opponent, taker: .untracked,
                        goalkeeper: .player(ProgrammeSample.keeper), scored: order == 1,
                        order: order)))
        }
        let keeper = fixture.snapshot.keeper(ProgrammeSample.keeper)
        #expect(keeper.penaltiesFaced == 3)
        #expect(keeper.penaltySaves == 2)
        // A shootout kick is not a goal allowed in the match.
        #expect(keeper.goalsAllowed == 0)
    }

    @Test("Shootout kicks do not raise validation issues")
    func shootoutIsClean() throws {
        var fixture = try matchAtShootout()
        for order in 1...6 {
            try fixture.perform(
                .recordShootoutAttempt(
                    ShootoutAttemptEvent(
                        side: order.isMultiple(of: 2) ? .opponent : .us,
                        taker: order.isMultiple(of: 2) ? .untracked : .player(ProgrammeSample.carter),
                        scored: order < 5, order: order)))
        }
        // A shootout has no clock, so its kicks must not read as events recorded
        // in a period that was never played.
        #expect(!fixture.issues.contains { $0.kind == .eventOutsidePeriod })
        #expect(fixture.issues.canFinalizeCleanly)
    }

    @Test("A shootout is refused under rules that do not allow one")
    func shootoutRequiresRules() throws {
        var fixture = MatchFixture(rules: .highSchoolNoOvertime)
        try fixture.startMatch()
        #expect(throws: MatchCommandError.shootoutNotAvailable) {
            try fixture.perform(
                .recordShootoutAttempt(
                    ShootoutAttemptEvent(
                        side: .us, taker: .player(ProgrammeSample.carter), scored: true, order: 1)))
        }
    }
}
