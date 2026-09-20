import Testing

@testable import ProgrammeCore

struct ShotEditInvariantTests {

    @Test func correctingANonGoalToGoalLeavesAssistUnresolved() throws {
        var fixture = MatchFixture(profile: .maxPreps)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12)

        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us,
                    shooter: .player(ProgrammeSample.carter),
                    outcome: .saved)))

        let event = try #require(fixture.lastEvent)
        guard case .shot(var shot) = event.payload else {
            Issue.record("Expected a shot event")
            return
        }

        shot.outcome = .goal
        try fixture.edit(
            .replacePayload(event.id, .shot(shot), summary: "Outcome changed to Goal"))

        let corrected = try #require(fixture.context.events.first { $0.id == event.id })
        guard case .shot(let correctedShot) = corrected.payload else {
            Issue.record("Expected a shot event")
            return
        }

        #expect(correctedShot.assist == .unidentified)
        #expect(fixture.snapshot.score.us == 1)
        #expect(fixture.snapshot.needsReviewCount == 1)
        #expect(fixture.snapshot.players.values.allSatisfy { $0.assists == 0 })
    }

    @Test func correctingAnOwnGoalToANonGoalClearsOwnGoalState() throws {
        var fixture = MatchFixture(profile: .maxPreps)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 18)

        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us,
                    shooter: .player(ProgrammeSample.carter),
                    outcome: .goal,
                    isOwnGoal: true)))

        let event = try #require(fixture.lastEvent)
        guard case .shot(var shot) = event.payload else {
            Issue.record("Expected a shot event")
            return
        }

        shot.outcome = .saved
        try fixture.edit(
            .replacePayload(event.id, .shot(shot), summary: "Outcome changed to Saved"))

        let corrected = try #require(fixture.context.events.first { $0.id == event.id })
        guard case .shot(let correctedShot) = corrected.payload else {
            Issue.record("Expected a shot event")
            return
        }

        #expect(correctedShot.isOwnGoal == false)
        #expect(correctedShot.assist == nil)
        #expect(fixture.snapshot.score.opponent == 0)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).shots == 1)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).shotsOnGoal == 1)
    }

    @Test func changingAGoalToAPenaltyClearsItsAssist() throws {
        var fixture = MatchFixture(profile: .maxPreps)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 24)

        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us,
                    shooter: .player(ProgrammeSample.carter),
                    outcome: .goal,
                    assist: .player(ProgrammeSample.williams))))

        let event = try #require(fixture.lastEvent)
        guard case .shot(var shot) = event.payload else {
            Issue.record("Expected a shot event")
            return
        }

        shot.phase = .penaltyKick
        try fixture.edit(
            .replacePayload(event.id, .shot(shot), summary: "Phase changed to Penalty Kick"))

        let corrected = try #require(fixture.context.events.first { $0.id == event.id })
        guard case .shot(let correctedShot) = corrected.payload else {
            Issue.record("Expected a shot event")
            return
        }

        #expect(correctedShot.phase == .penaltyKick)
        #expect(correctedShot.assist == nil)
        #expect(fixture.snapshot.player(ProgrammeSample.williams).assists == 0)
        #expect(fixture.snapshot.needsReviewCount == 0)
    }

    @Test func blockedPenaltyIsRejectedAtTheDomainBoundary() throws {
        var fixture = MatchFixture(profile: .advanced)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 30)

        #expect(throws: MatchCommandError.invalidShotCombination) {
            try fixture.perform(
                .recordShot(
                    ShotEvent(
                        side: .us,
                        shooter: .player(ProgrammeSample.carter),
                        outcome: .blocked,
                        phase: .penaltyKick)))
        }

        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us,
                    shooter: .player(ProgrammeSample.carter),
                    outcome: .blocked)))

        let event = try #require(fixture.lastEvent)
        guard case .shot(var shot) = event.payload else {
            Issue.record("Expected a shot event")
            return
        }
        shot.phase = .penaltyKick

        #expect(throws: MatchCommandError.invalidShotCombination) {
            try fixture.edit(
                .replacePayload(event.id, .shot(shot), summary: "Phase changed to Penalty Kick"))
        }

        let unchanged = try #require(fixture.context.events.first { $0.id == event.id })
        guard case .shot(let unchangedShot) = unchanged.payload else {
            Issue.record("Expected a shot event")
            return
        }
        #expect(unchangedShot.phase == .openPlay)
        #expect(unchangedShot.outcome == .blocked)
    }
}
