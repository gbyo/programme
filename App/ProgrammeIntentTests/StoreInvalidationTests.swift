import Foundation
import ProgrammeCollaboration
import ProgrammeCore
import XCTest

@testable import Programme

/// Which derived surfaces refresh for representative mutations.
///
/// These pin the contract from scoped invalidation: a write touches exactly
/// the scopes it affects, side work runs only where it can matter, and a
/// Team B write never reaches Team A's counters.
final class StoreInvalidationTests: XCTestCase {
    private let teamA = TeamID(UUID())
    private let teamB = TeamID(UUID())
    private let player = PlayerID(UUID())
    private let match = MatchID()
    private let season = SeasonID(UUID())

    func testPlayerWriteTouchesOnlyRosterPlayerAndSearch() {
        let impact = StoreInvalidation.impact(
            of: .players(teamID: teamA, playerIDs: [player]), teamID: teamA)

        XCTAssertEqual(
            impact.scopes, [.roster(teamA), .player(player), .search])
        XCTAssertEqual(impact.widgetTeamIDs, [teamA])
        XCTAssertTrue(impact.refreshSpotlight)
        XCTAssertFalse(impact.refreshRecovery)
    }

    func testDeletedPlayerTouchesOnlyRosterPlayerAndSearch() {
        let impact = StoreInvalidation.impact(
            of: .deletedPlayers(teamID: teamA, playerIDs: [player]), teamID: teamA)

        XCTAssertTrue(impact.scopes.contains(.roster(teamA)))
        XCTAssertTrue(impact.scopes.contains(.player(player)))
        XCTAssertFalse(impact.scopes.contains(.matches(teamA)))
        XCTAssertFalse(impact.refreshRecovery)
    }

    func testRecordedEventTouchesEventSurfacesWithoutSpotlight() {
        let impact = StoreInvalidation.impact(
            of: .events(matchID: match, eventIDs: [EventID()]), teamID: teamA)

        XCTAssertEqual(
            impact.scopes, [.teamEvents(teamA), .matches(teamA), .search])
        XCTAssertEqual(impact.widgetTeamIDs, [teamA])
        // Scores change; the indexed entity set does not. The debounced
        // observer pass still reindexes bursts.
        XCTAssertFalse(impact.refreshSpotlight)
        XCTAssertTrue(impact.refreshRecovery)
    }

    func testCreatedMatchTouchesListsStatsAndRecovery() {
        let impact = StoreInvalidation.impact(of: .match(match), teamID: teamA)

        XCTAssertEqual(
            impact.scopes, [.matches(teamA), .teamEvents(teamA), .search])
        XCTAssertTrue(impact.refreshSpotlight)
        XCTAssertTrue(impact.refreshRecovery)
    }

    func testDeletedMatchTouchesSeasonsToo() {
        let impact = StoreInvalidation.impact(
            of: .deletedMatch(matchID: match, teamID: teamA, eventIDs: []), teamID: teamA)

        XCTAssertEqual(
            impact.scopes, [.matches(teamA), .teamEvents(teamA), .seasons(teamA), .search])
        XCTAssertTrue(impact.refreshRecovery)
    }

    func testSeasonSwitchTouchesSeasonsAndMatchesWithoutRecovery() {
        let impact = StoreInvalidation.impact(
            of: .season(teamID: teamA, seasonID: season), teamID: teamA)

        XCTAssertEqual(
            impact.scopes, [.seasons(teamA), .matches(teamA), .search])
        XCTAssertFalse(impact.refreshRecovery)
    }

    func testTeamProfileWriteTouchesOnlyTeamsAndSearch() {
        let impact = StoreInvalidation.impact(of: .team(teamA), teamID: teamA)

        XCTAssertEqual(impact.scopes, [.teams, .search])
        XCTAssertFalse(impact.refreshRecovery)
    }

    func testOtherTeamWriteNeverReachesThisTeamsScopes() {
        // The player scope is keyed by player, not team: a detail view for a
        // changed player must reload whichever team owns them. Team B's
        // mutation therefore uses Team B's player.
        let otherPlayer = PlayerID(UUID())
        let mutations: [OutboundMutation] = [
            .players(teamID: teamB, playerIDs: [otherPlayer]),
            .events(matchID: match, eventIDs: [EventID()]),
            .season(teamID: teamB, seasonID: season),
            .deletedMatch(matchID: match, teamID: teamB, eventIDs: []),
        ]
        let teamAScopes: Set<InvalidationScope> = [
            .roster(teamA), .player(player), .matches(teamA), .teamEvents(teamA),
            .seasons(teamA),
        ]
        for mutation in mutations {
            let teamID: TeamID? = teamB
            let impact = StoreInvalidation.impact(of: mutation, teamID: teamID)
            XCTAssertTrue(
                impact.scopes.isDisjoint(with: teamAScopes),
                "Team B mutation \(mutation) reached Team A scopes: \(impact.scopes)")
            XCTAssertFalse(impact.widgetTeamIDs.contains(teamA))
        }
    }

    func testUnresolvableMatchFallsBackToConservativeRefresh() {
        let impact = StoreInvalidation.impact(
            of: .events(matchID: match, eventIDs: [EventID()]), teamID: nil)

        // The row is gone; refresh cross-team surfaces and run every side
        // refresh rather than risk a missed external delete.
        XCTAssertTrue(impact.scopes.contains(.search))
        XCTAssertTrue(impact.refreshSpotlight)
        XCTAssertTrue(impact.refreshRecovery)
    }
}
