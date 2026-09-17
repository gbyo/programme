import Foundation
import Testing

@testable import ProgrammeCore

/// Who an event can legitimately belong to.
///
/// These rules exist so the scoring workspace can make an impossible attribution
/// unreachable instead of merely flagging it afterwards.
struct AttributionTests {

    @Test func liveShotsAreLimitedToPlayersOnTheField() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()

        let candidates = AttributionEngine.candidates(
            for: .shot, context: fixture.context, snapshot: fixture.snapshot)
        let ids = Set(candidates.map(\.id))

        #expect(ids == Set(ProgrammeSample.startingEleven))
        for starter in ProgrammeSample.startingEleven {
            #expect(
                AttributionEngine.allows(
                    starter, category: .shot, context: fixture.context, snapshot: fixture.snapshot))
        }
    }

    @Test func aBenchPlayerCannotBeCreditedWithOrdinaryLivePlay() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()

        let onField = fixture.snapshot.activeLineup
        let substitute = try #require(
            fixture.context.roster.activeRoster.first { !onField.contains($0.id) })

        for category in [
            AttributionCategory.shot, .assist, .penaltyKick, .ownGoal, .corner, .steal, .foul,
            .offside, .goalkeeperChange,
        ] {
            #expect(
                AttributionEngine.allows(
                    substitute.id, category: category, context: fixture.context,
                    snapshot: fixture.snapshot) == false,
                "\(category) should not be attributable to a player on the bench")
        }
    }

    @Test func aBenchPlayerCanStillBeCautioned() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()

        let onField = fixture.snapshot.activeLineup
        let substitute = try #require(
            fixture.context.roster.activeRoster.first { !onField.contains($0.id) })

        #expect(AttributionEngine.scope(for: .card) == .availableRoster)
        #expect(
            AttributionEngine.allows(
                substitute.id, category: .card, context: fixture.context, snapshot: fixture.snapshot))
    }

    @Test func aSentOffPlayerIsNeverOffered() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()

        let sentOff = try #require(ProgrammeSample.startingEleven.first)
        try fixture.perform(.recordCard(CardEvent(side: .us, player: .player(sentOff), card: .red)))

        for category in AttributionCategory.allCases {
            #expect(
                AttributionEngine.allows(
                    sentOff, category: category, context: fixture.context, snapshot: fixture.snapshot)
                    == false,
                "\(category) should not be attributable to a dismissed player")
        }
    }

    @Test func aPlayerWhoCameOnBecomesAvailableAndTheOneWhoCameOffDoesNot() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 20)

        let onField = fixture.snapshot.activeLineup
        let goingOut = try #require(
            ProgrammeSample.startingEleven.first { $0 != ProgrammeSample.keeper })
        let comingIn = try #require(
            fixture.context.roster.activeRoster.first { !onField.contains($0.id) })

        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [goingOut], playersIn: [comingIn.id],
                    goalkeeperAfter: nil)))

        #expect(
            AttributionEngine.allows(
                comingIn.id, category: .shot, context: fixture.context, snapshot: fixture.snapshot))
        #expect(
            AttributionEngine.allows(
                goingOut, category: .shot, context: fixture.context, snapshot: fixture.snapshot)
                == false)
        // A caution can still be shown to the player who has just come off.
        #expect(
            AttributionEngine.allows(
                goingOut, category: .card, context: fixture.context, snapshot: fixture.snapshot))
    }

    @Test func goalkeeperCandidatesComeFromTheFieldWithKeepersFirst() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()

        let candidates = AttributionEngine.goalkeeperCandidates(
            context: fixture.context, snapshot: fixture.snapshot)

        #expect(candidates.first?.id == ProgrammeSample.keeper)
        #expect(Set(candidates.map(\.id)) == Set(ProgrammeSample.startingEleven))
    }

    @Test func opponentAttributionOffersTheOpponentRoster() throws {
        var fixture = MatchFixture(tracking: .bothTeams)
        fixture.context.opponentRoster = ProgrammeSample.roster
        try fixture.startMatch()

        let candidates = AttributionEngine.candidates(
            for: .shot, side: .opponent, context: fixture.context, snapshot: fixture.snapshot)

        #expect(candidates.count == ProgrammeSample.roster.sortedByNumber.count)
    }
}
