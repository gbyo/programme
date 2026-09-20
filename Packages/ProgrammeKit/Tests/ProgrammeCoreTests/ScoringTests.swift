import Foundation
import Testing

@testable import ProgrammeCore

@Suite("Goals, shots and saves cannot contradict each other")
struct ScoringTests {

    @Test("A goal implies a shot and a shot on goal")
    func goalImpliesShotAndShotOnGoal() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12, seconds: 51)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal,
                    assist: .player(ProgrammeSample.williams))))

        let snapshot = fixture.snapshot
        #expect(snapshot.score.us == 1)
        #expect(snapshot.team.us.shots == 1)
        #expect(snapshot.team.us.shotsOnGoal == 1)
        #expect(snapshot.player(ProgrammeSample.carter).goals == 1)
        #expect(snapshot.player(ProgrammeSample.carter).shots == 1)
        #expect(snapshot.player(ProgrammeSample.carter).shotsOnGoal == 1)
        #expect(snapshot.player(ProgrammeSample.williams).assists == 1)
        // A goal is two points and an assist one.
        #expect(snapshot.player(ProgrammeSample.carter).points == 2)
        #expect(snapshot.player(ProgrammeSample.williams).points == 1)
        // Exactly one event was recorded — no separate shot or shot-on-goal.
        #expect(fixture.context.activeEvents.filter { $0.category == .goal }.count == 1)
    }

    @Test("A save implies one opponent shot on goal and nothing more")
    func saveImpliesOpponentShotOnGoal() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 8)
        try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved)))

        let snapshot = fixture.snapshot
        #expect(snapshot.team.opponent.shots == 1)
        #expect(snapshot.team.opponent.shotsOnGoal == 1)
        #expect(snapshot.team.us.saves == 1)
        let keeper = snapshot.keeper(ProgrammeSample.keeper)
        #expect(keeper.saves == 1)
        #expect(keeper.shotsOnGoalFaced == 1)
        #expect(keeper.goalsAllowed == 0)
        #expect(snapshot.score.opponent == 0)
    }

    @Test(
        "Shot outcomes map to shots and shots on goal exactly once",
        arguments: [
            (ShotOutcome.offTarget, 1, 0, 0),
            (ShotOutcome.blocked, 1, 0, 0),
            (ShotOutcome.woodwork, 1, 0, 0),
            (ShotOutcome.saved, 1, 1, 0),
            (ShotOutcome.goal, 1, 1, 1),
        ]
    )
    func shotOutcomes(outcome: ShotOutcome, shots: Int, onGoal: Int, goals: Int) throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: outcome)))

        let line = fixture.snapshot.player(ProgrammeSample.carter)
        #expect(line.shots == shots)
        #expect(line.shotsOnGoal == onGoal)
        #expect(line.goals == goals)
        #expect(fixture.snapshot.score.us == goals)
    }

    @Test("Deleting a goal corrects the score and every derived total")
    func deletingGoalCorrectsStatistics() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal,
                    assist: .player(ProgrammeSample.williams))))
        let goal = try #require(fixture.firstGoalEvent())
        #expect(fixture.snapshot.score.us == 1)

        try fixture.edit(.void(goal.id))

        let snapshot = fixture.snapshot
        #expect(snapshot.score.us == 0)
        #expect(snapshot.player(ProgrammeSample.carter).goals == 0)
        #expect(snapshot.player(ProgrammeSample.carter).shots == 0)
        #expect(snapshot.player(ProgrammeSample.williams).assists == 0)
        // The event is retained, so the correction is auditable and reversible.
        #expect(fixture.context.events.contains { $0.id == goal.id && $0.isVoided })
    }

    @Test("A saved shot can be corrected into a goal without duplicating the shot")
    func convertSavedShotToGoal() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 22)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .saved)))
        let shot = try #require(fixture.lastEvent)
        guard case .shot(var payload) = shot.payload else { Issue.record("not a shot"); return }

        payload.outcome = .goal
        payload.assist = .player(ProgrammeSample.williams)
        try fixture.edit(.replacePayload(shot.id, .shot(payload), summary: "Outcome changed to Goal"))

        let snapshot = fixture.snapshot
        #expect(snapshot.score.us == 1)
        #expect(snapshot.player(ProgrammeSample.carter).shots == 1)
        #expect(snapshot.player(ProgrammeSample.carter).shotsOnGoal == 1)
        #expect(snapshot.player(ProgrammeSample.carter).goals == 1)
        #expect(snapshot.player(ProgrammeSample.williams).assists == 1)
        #expect(fixture.context.activeEvents.filter { $0.payload.category != .structural && $0.category != .clock }.count == 1)
    }

    @Test("Correcting an assist moves the credit and leaves the goal intact")
    func assistCorrection() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 30)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal,
                    assist: .player(ProgrammeSample.williams))))
        let goal = try #require(fixture.firstGoalEvent())

        try fixture.edit(.attribute(goal.id, .assist, .player(ProgrammeSample.mabry)))

        let snapshot = fixture.snapshot
        #expect(snapshot.player(ProgrammeSample.williams).assists == 0)
        #expect(snapshot.player(ProgrammeSample.mabry).assists == 1)
        #expect(snapshot.player(ProgrammeSample.carter).goals == 1)
        #expect(snapshot.score.us == 1)
    }

    @Test("An own goal counts for the other team and is never credited to a scorer")
    func ownGoal() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 15)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.playerID("Tyrell.Boyd")), outcome: .goal,
                    isOwnGoal: true)))

        let snapshot = fixture.snapshot
        #expect(snapshot.score.opponent == 1)
        #expect(snapshot.score.us == 0)
        let boyd = snapshot.player(ProgrammeSample.playerID("Tyrell.Boyd"))
        #expect(boyd.goals == 0)
        #expect(boyd.shots == 0)
        #expect(boyd.ownGoals == 1)
        // The goalkeeper is charged with the goal so save percentage stays coherent.
        let keeper = snapshot.keeper(ProgrammeSample.keeper)
        #expect(keeper.goalsAllowed == 1)
        #expect(keeper.shotsOnGoalFaced == 1)
    }

    @Test("A penalty kick records an attempt and, when scored, a penalty goal")
    func penaltyKick() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 26)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.sanders), outcome: .goal, phase: .penaltyKick)))
        fixture.seek(period: 1, minutes: 34)
        try fixture.perform(
            .recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved, phase: .penaltyKick)))

        let snapshot = fixture.snapshot
        let sanders = snapshot.player(ProgrammeSample.sanders)
        #expect(sanders.penaltyAttempts == 1)
        #expect(sanders.penaltyGoals == 1)
        #expect(sanders.goals == 1)
        let keeper = snapshot.keeper(ProgrammeSample.keeper)
        #expect(keeper.penaltiesFaced == 1)
        #expect(keeper.penaltySaves == 1)
        #expect(keeper.saves == 1)
    }

    @Test("Cards accumulate, and a second yellow counts as both")
    func cards() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(
            .recordCard(CardEvent(side: .us, player: .player(ProgrammeSample.mabry), card: .yellow)))
        fixture.seek(period: 1, minutes: 35)
        try fixture.perform(
            .recordCard(CardEvent(side: .us, player: .player(ProgrammeSample.mabry), card: .secondYellow)))

        let line = fixture.snapshot.player(ProgrammeSample.mabry)
        #expect(line.yellowCards == 2)
        #expect(line.redCards == 1)
        #expect(fixture.snapshot.activeLineup.contains(ProgrammeSample.mabry) == false)
    }

    @Test("Corners and steals are credited to the player who made them")
    func cornersAndSteals() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 5)
        try fixture.perform(.recordCorner(side: .us, player: .player(ProgrammeSample.williams)))
        try fixture.perform(.recordSteal(side: .us, player: .player(ProgrammeSample.mabry)))
        try fixture.perform(.recordCorner(side: .opponent, player: .untracked))

        let snapshot = fixture.snapshot
        #expect(snapshot.player(ProgrammeSample.williams).corners == 1)
        #expect(snapshot.player(ProgrammeSample.mabry).steals == 1)
        #expect(snapshot.team.us.corners == 1)
        #expect(snapshot.team.opponent.corners == 1)
    }
}

@Suite("Opponent tracking modes")
struct OpponentTrackingTests {

    private func opponentRoster() -> RosterSnapshot {
        RosterSnapshot(players: [
            PlayerSnapshot(firstName: "Ray", lastName: "Pettit", jerseyNumber: 8, position: .midfielder),
            PlayerSnapshot(firstName: "Dane", lastName: "Kessler", jerseyNumber: 9, position: .forward),
            PlayerSnapshot(firstName: "Otis", lastName: "Vance", jerseyNumber: 1, position: .goalkeeper),
        ])
    }

    @Test("Our Team mode records opponent events as team totals only")
    func ourTeamMode() throws {
        var fixture = MatchFixture(tracking: .ourTeam)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 9)
        try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)))
        try fixture.perform(.recordCorner(side: .opponent, player: .untracked))

        let snapshot = fixture.snapshot
        #expect(snapshot.score.opponent == 1)
        #expect(snapshot.team.opponent.corners == 1)
        // Unattributed opponent events are deliberate, not something to review.
        #expect(snapshot.needsReviewCount == 0)
        #expect(fixture.issues.contains { $0.kind == .unresolvedAttribution } == false)
    }

    @Test("Both Teams mode attributes opponent players through the same engine")
    func bothTeamsMode() throws {
        var fixture = MatchFixture(tracking: .bothTeams)
        fixture.context.opponentRoster = opponentRoster()
        try fixture.startMatch()

        let kessler = try #require(fixture.context.opponentRoster.players.first { $0.jerseyNumber == 9 })
        let pettit = try #require(fixture.context.opponentRoster.players.first { $0.jerseyNumber == 8 })

        fixture.seek(period: 1, minutes: 14)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .opponent, shooter: .player(kessler.id), outcome: .goal,
                    assist: .player(pettit.id))))
        fixture.seek(period: 1, minutes: 22)
        try fixture.perform(.recordCorner(side: .opponent, player: .player(pettit.id)))

        let snapshot = fixture.snapshot
        #expect(snapshot.score.opponent == 1)
        #expect(snapshot.player(kessler.id).goals == 1)
        #expect(snapshot.player(kessler.id).side == .opponent)
        #expect(snapshot.player(pettit.id).assists == 1)
        #expect(snapshot.player(pettit.id).corners == 1)

        // Our goalkeeper is still credited correctly for the goal conceded.
        #expect(snapshot.keeper(ProgrammeSample.keeper).goalsAllowed == 1)
        // And the opponent's players do not leak into our team's totals.
        #expect(snapshot.team.us.goals == 0)
        #expect(snapshot.team.us.corners == 0)
    }

    @Test("Both Teams secondary events use the same attributed stat engine")
    func bothTeamsSecondaryEvents() throws {
        var fixture = MatchFixture(profile: .advanced, tracking: .bothTeams)
        fixture.context.opponentRoster = opponentRoster()
        try fixture.startMatch()

        let kessler = try #require(fixture.context.opponentRoster.players.first { $0.jerseyNumber == 9 })
        let pettit = try #require(fixture.context.opponentRoster.players.first { $0.jerseyNumber == 8 })

        fixture.seek(period: 1, minutes: 18)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .opponent,
                    shooter: .player(kessler.id),
                    outcome: .saved,
                    phase: .penaltyKick)))
        try fixture.perform(.recordSteal(side: .opponent, player: .player(pettit.id)))
        try fixture.perform(.recordFoul(side: .opponent, player: .player(pettit.id)))
        try fixture.perform(.recordOffside(side: .opponent, player: .player(kessler.id)))
        try fixture.perform(
            .recordCard(
                CardEvent(side: .opponent, player: .player(pettit.id), card: .secondYellow)))

        let snapshot = fixture.snapshot
        let shooter = snapshot.player(kessler.id)
        let midfielder = snapshot.player(pettit.id)
        let keeper = snapshot.keeper(ProgrammeSample.keeper)

        #expect(shooter.penaltyAttempts == 1)
        #expect(shooter.offsides == 1)
        #expect(midfielder.steals == 1)
        #expect(midfielder.fouls == 1)
        #expect(midfielder.yellowCards == 1)
        #expect(midfielder.redCards == 1)

        #expect(snapshot.team.opponent.steals == 1)
        #expect(snapshot.team.opponent.fouls == 1)
        #expect(snapshot.team.opponent.offsides == 1)
        #expect(snapshot.team.opponent.yellowCards == 1)
        #expect(snapshot.team.opponent.redCards == 1)

        #expect(keeper.penaltiesFaced == 1)
        #expect(keeper.penaltySaves == 1)
        #expect(keeper.saves == 1)
    }

    @Test("Opponent statistics stay out of our season totals")
    func opponentStatsExcludedFromSeason() throws {
        var fixture = MatchFixture(tracking: .bothTeams)
        fixture.context.opponentRoster = opponentRoster()
        try fixture.startMatch()
        let kessler = try #require(fixture.context.opponentRoster.players.first { $0.jerseyNumber == 9 })
        fixture.seek(period: 1, minutes: 14)
        try fixture.perform(
            .recordShot(ShotEvent(side: .opponent, shooter: .player(kessler.id), outcome: .goal)))
        try fixture.playFullMatchAndFinalize()

        let season = SeasonEngine.aggregate([
            MatchStatSummary(
                snapshot: fixture.snapshot, tracked: fixture.context.profile.tracked, isFinalized: true)
        ])
        #expect(season.players[kessler.id] == nil)
        #expect(season.goalsAgainst == 1)
        #expect(season.losses == 1)
    }
}
