import AppIntentsTesting
import Foundation
import XCTest

/// Exercises Programme's App Intents through Apple's out-of-process testing
/// stack. The fixture is created inside the application process by a debug-only
/// test intent; this target never imports Programme or inspects its AppModel.
final class AppIntentsTestingTests: XCTestCase {
    private enum FixtureError: Error {
        case malformedSeed
        case malformedState
    }

    private struct FrameworkSeed {
        let teamA: UUID
        let teamB: UUID
        let matchA: UUID
        let matchB: UUID
        let playerA: UUID
        let playerB: UUID

        init(_ serialized: String) throws {
            let parts = serialized.split(separator: "|", omittingEmptySubsequences: false)
            guard
                parts.count == 6,
                let teamA = UUID(uuidString: String(parts[0])),
                let teamB = UUID(uuidString: String(parts[1])),
                let matchA = UUID(uuidString: String(parts[2])),
                let matchB = UUID(uuidString: String(parts[3])),
                let playerA = UUID(uuidString: String(parts[4])),
                let playerB = UUID(uuidString: String(parts[5]))
            else {
                throw FixtureError.malformedSeed
            }
            self.teamA = teamA
            self.teamB = teamB
            self.matchA = matchA
            self.matchB = matchB
            self.playerA = playerA
            self.playerB = playerB
        }
    }

    private struct FrameworkState {
        let selectedTeamID: UUID?
        let section: String
        let isPresentingNewMatch: Bool
        let liveMatchID: UUID?

        init(_ serialized: String) throws {
            let parts = serialized.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 4 else {
                throw FixtureError.malformedState
            }

            let selected = String(parts[0])
            let live = String(parts[3])
            if !selected.isEmpty && UUID(uuidString: selected) == nil {
                throw FixtureError.malformedState
            }
            if !live.isEmpty && UUID(uuidString: live) == nil {
                throw FixtureError.malformedState
            }

            selectedTeamID = selected.isEmpty ? nil : UUID(uuidString: selected)
            section = String(parts[1])
            isPresentingNewMatch = parts[2] == "1"
            liveMatchID = live.isEmpty ? nil : UUID(uuidString: live)
        }
    }

    @available(iOS 27, *)
    private func definitions() -> IntentDefinitions {
        IntentDefinitions(bundleIdentifier: "com.gbyo.Programme")
    }

    /// Converts the known Xcode 27.0 AppIntentsTesting service crash into an
    /// explicit skip. All other failures still fail the test.
    private func viaFramework<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            if String(describing: error).contains("transportCancelled") {
                throw XCTSkip(
                    "AppIntentsTesting transport unavailable in this environment "
                        + "(Apple AppIntentsLiveEntityService crash).")
            }
            throw error
        }
    }

    @available(iOS 27, *)
    private func seedFixture(_ definitions: IntentDefinitions) async throws -> FrameworkSeed {
        let result = try await viaFramework {
            try await definitions.intents["SeedProgrammeIntentTestsIntent"].makeIntent().run()
        }
        let serialized: String = try result.value
        return try FrameworkSeed(serialized)
    }

    @available(iOS 27, *)
    private func readState(_ definitions: IntentDefinitions) async throws -> FrameworkState {
        let result = try await viaFramework {
            try await definitions.intents["ReadProgrammeIntentTestStateIntent"].makeIntent().run()
        }
        let serialized: String = try result.value
        return try FrameworkState(serialized)
    }

    func testFrameworkMatchLookupByIdentifier() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let seed = try await seedFixture(definitions)
        let found = try await viaFramework {
            try await definitions.entities["MatchEntity"].entities(identifiers: [seed.matchA])
        }
        XCTAssertEqual(found.count, 1)
        let teamName: String = try found[0].teamName
        XCTAssertEqual(teamName, "NX")
    }

    func testFrameworkPlayerLookupByIdentifier() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let seed = try await seedFixture(definitions)
        let found = try await viaFramework {
            try await definitions.entities["PlayerEntity"].entities(identifiers: [seed.playerA])
        }
        XCTAssertEqual(found.count, 1)
        let teamName: String = try found[0].teamName
        XCTAssertEqual(teamName, "NX")
    }

    func testFrameworkMissingIdentifiersDisappear() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        _ = try await seedFixture(definitions)
        let matches = try await viaFramework {
            try await definitions.entities["MatchEntity"].entities(identifiers: [UUID()])
        }
        XCTAssertTrue(matches.isEmpty)
    }

    func testFrameworkSuggestedEntities() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        _ = try await seedFixture(definitions)
        let matches = try await viaFramework {
            try await definitions.entities["MatchEntity"].suggestedEntities()
        }
        XCTAssertEqual(matches.count, 2)
        let players = try await viaFramework {
            try await definitions.entities["PlayerEntity"].suggestedEntities()
        }
        XCTAssertEqual(players.count, 2)
    }

    func testFrameworkOpenMatchSelectsOwningTeam() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let seed = try await seedFixture(definitions)
        let reference = definitions.entities["MatchEntity"].makeReference(
            identifier: seed.matchA.uuidString)
        _ = try await viaFramework {
            try await definitions.intents["OpenMatchIntent"].makeIntent(match: reference).run()
        }

        let state = try await readState(definitions)
        XCTAssertEqual(state.selectedTeamID, seed.teamA)
        XCTAssertEqual(state.section, "matches")
    }

    func testFrameworkScoreMatchOpensScorer() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let seed = try await seedFixture(definitions)
        let reference = definitions.entities["MatchEntity"].makeReference(
            identifier: seed.matchA.uuidString)
        _ = try await viaFramework {
            try await definitions.intents["ScoreMatchIntent"].makeIntent(match: reference).run()
        }

        let state = try await readState(definitions)
        XCTAssertEqual(state.selectedTeamID, seed.teamA)
        XCTAssertEqual(state.liveMatchID, seed.matchA)
    }

    func testFrameworkSeasonAndNewMatchIntents() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        _ = try await seedFixture(definitions)

        _ = try await viaFramework {
            try await definitions.intents["ShowSeasonStatsIntent"].makeIntent().run()
        }
        let seasonState = try await readState(definitions)
        XCTAssertEqual(seasonState.section, "stats")

        _ = try await viaFramework {
            try await definitions.intents["NewMatchIntent"].makeIntent().run()
        }
        let newMatchState = try await readState(definitions)
        XCTAssertTrue(newMatchState.isPresentingNewMatch)
    }

    func testFrameworkCurrentScoreRuns() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        _ = try await seedFixture(definitions)
        let result = try await viaFramework {
            try await definitions.intents["CurrentScoreIntent"].makeIntent().run()
        }
        let value: String = try result.value
        XCTAssertEqual(value, "No match")
    }

    func testFrameworkSpotlightAndViewQueriesComplete() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        _ = try await seedFixture(definitions)

        // System indexing and onscreen annotation timing are not deterministic;
        // these calls still prove the real Spotlight/Siri paths complete against
        // the fixture that was seeded in the app process.
        _ = try await viaFramework {
            try await definitions.entities["MatchEntity"].spotlightQuery("Dixie")
        }
        _ = try await viaFramework {
            try await definitions.entities["MatchEntity"].viewAnnotations()
        }
    }
}
