import Foundation
import XCTest

@testable import Programme

/// Entity and query behavior through the real `ProgrammeIntentProvider` — the
/// single place that owns team-aware entity construction — against a two-team
/// fixture. Runs on every deployment target.
///
/// The query structs themselves (`MatchEntityQuery`, `PlayerEntityQuery`)
/// resolve their provider via `@Dependency`, which the system only satisfies
/// inside the intent perform flow; calling them directly in-process traps.
/// The iOS 27-gated `AppIntentsTestingTests` covers those same structs through
/// Apple's testing framework where the dependency context exists.
@MainActor
final class EntityQueryTests: XCTestCase {
    func testMatchLookupByIdentifier() async throws {
        let harness = try await IntentTestHarness.make()
        let found = try await harness.provider.matches().filter {
            $0.id == harness.seed.matchA.rawValue
        }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].teamName, "NX")
    }

    func testPlayerLookupByIdentifier() async throws {
        let harness = try await IntentTestHarness.make()
        let found = try await harness.provider.players().filter {
            $0.id == harness.seed.playerA.rawValue
        }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].teamName, "NX")
    }

    func testSuggestedMatchesCoverBothTeams() async throws {
        let harness = try await IntentTestHarness.make()
        let suggested = try await harness.provider.matches()
        XCTAssertEqual(suggested.count, 2)
        XCTAssertEqual(Set(suggested.map(\.teamName)), ["NX", "GW"])
    }

    func testSuggestedPlayersCoverBothTeams() async throws {
        let harness = try await IntentTestHarness.make()
        let suggested = try await harness.provider.players()
        XCTAssertEqual(suggested.count, 2)
        XCTAssertEqual(Set(suggested.map(\.teamName)), ["NX", "GW"])
    }

    func testSameOpponentDisambiguatedByTeam() async throws {
        let harness = try await IntentTestHarness.make()
        let dixie = try await harness.provider.matches().filter { $0.opponent.contains("Dixie") }
        XCTAssertEqual(dixie.count, 2)
        // Same opponent, different teams: the team must be visible so Siri and
        // Spotlight never conflate them.
        XCTAssertEqual(Set(dixie.map(\.teamName)), ["NX", "GW"])
        XCTAssertNotEqual(dixie[0].displayRepresentation.subtitle, dixie[1].displayRepresentation.subtitle)
    }

    func testSamePlayerDisambiguatedByTeam() async throws {
        let harness = try await IntentTestHarness.make()
        let suggested = try await harness.provider.players()
        XCTAssertEqual(suggested.count, 2)
        XCTAssertTrue(suggested.allSatisfy { $0.name == "Tucker Bell" })
        XCTAssertEqual(suggested.map(\.jerseyNumber), [1, 1])
        XCTAssertEqual(Set(suggested.map(\.teamName)), ["NX", "GW"])
        // Distinct identities behind the shared name and number.
        XCTAssertNotEqual(suggested[0].id, suggested[1].id)
    }

    func testMissingIdentifiersDisappear() async throws {
        let harness = try await IntentTestHarness.make()
        let matches = try await harness.provider.matches().filter { $0.id == UUID() }
        XCTAssertTrue(matches.isEmpty)
        let players = try await harness.provider.players().filter { $0.id == UUID() }
        XCTAssertTrue(players.isEmpty)
    }

    func testDeletedMatchDisappears() async throws {
        let harness = try await IntentTestHarness.make()
        guard let store = harness.appModel.store else { return XCTFail("no store") }
        try await store.deleteMatch(harness.seed.matchA)
        let found = try await harness.provider.matches().filter {
            $0.id == harness.seed.matchA.rawValue
        }
        XCTAssertTrue(found.isEmpty)
        // The surviving team's match is untouched.
        let remaining = try await harness.provider.matches().filter {
            $0.id == harness.seed.matchB.rawValue
        }
        XCTAssertEqual(remaining.count, 1)
    }
}
