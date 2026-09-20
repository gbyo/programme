import Testing

@testable import ProgrammeCore

struct OpponentCorrectionTests {

    @Test func opponentAttributionUsesOpponentRosterIdentity() throws {
        let opponent = PlayerSnapshot(
            firstName: "Dane",
            lastName: "Kessler",
            jerseyNumber: 9,
            position: .forward)

        var fixture = MatchFixture(tracking: .bothTeams)
        fixture.context.opponentRoster = RosterSnapshot(players: [opponent])
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 14)

        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .opponent,
                    shooter: .unidentified,
                    outcome: .offTarget)))

        let event = try #require(fixture.lastEvent)
        try fixture.edit(.attribute(event.id, .primary, .player(opponent.id)))

        let corrected = try #require(fixture.context.events.first { $0.id == event.id })
        guard case .shot(let shot) = corrected.payload else {
            Issue.record("Expected a shot event")
            return
        }

        #expect(shot.shooter == .player(opponent.id))
        #expect(fixture.snapshot.player(opponent.id).side == .opponent)
        #expect(fixture.snapshot.player(opponent.id).shots == 1)
        #expect(corrected.revisions.last?.summary == "Attributed to #9 Kessler")
    }
}
