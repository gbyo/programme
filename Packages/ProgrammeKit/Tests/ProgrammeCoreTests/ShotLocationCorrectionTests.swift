import Testing

@testable import ProgrammeCore

struct ShotLocationCorrectionTests {

    @Test func addingMovingAndClearingLocationDoesNotChangeShotTotals() throws {
        var fixture = MatchFixture(profile: .standard)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 9)

        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us,
                    shooter: .player(ProgrammeSample.carter),
                    outcome: .saved)))

        let event = try #require(fixture.lastEvent)
        let shotsBefore = fixture.snapshot.player(ProgrammeSample.carter).shots
        let onGoalBefore = fixture.snapshot.player(ProgrammeSample.carter).shotsOnGoal

        guard case .shot(var shot) = event.payload else {
            Issue.record("Expected a shot event")
            return
        }

        let first = PitchPoint(x: 0.81, y: 0.44)
        shot.location = first
        try fixture.edit(.replacePayload(event.id, .shot(shot), summary: "Shot location added"))

        guard case .shot(var moved) = try #require(
            fixture.context.events.first { $0.id == event.id }).payload
        else {
            Issue.record("Expected a shot event")
            return
        }
        #expect(moved.location == first)

        let second = PitchPoint(x: 0.9, y: 0.61)
        moved.location = second
        try fixture.edit(.replacePayload(event.id, .shot(moved), summary: "Shot location moved"))

        guard case .shot(var cleared) = try #require(
            fixture.context.events.first { $0.id == event.id }).payload
        else {
            Issue.record("Expected a shot event")
            return
        }
        #expect(cleared.location == second)

        cleared.location = nil
        try fixture.edit(.replacePayload(event.id, .shot(cleared), summary: "Shot location cleared"))

        guard case .shot(let final) = try #require(
            fixture.context.events.first { $0.id == event.id }).payload
        else {
            Issue.record("Expected a shot event")
            return
        }

        #expect(final.location == nil)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).shots == shotsBefore)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).shotsOnGoal == onGoalBefore)
        #expect(fixture.context.activeEvents.count == 2) // lineup + shot; edits append no events
    }
}
