import AppIntents
import AppIntentsTesting
import Foundation
import XCTest

@testable import Programme

/// The same behaviors as `EntityQueryTests` and `IntentNavigationTests`,
/// executed through Apple's `AppIntentsTesting` harness instead of by calling
/// the query/intent types directly. Requires iOS 27; older systems cover the
/// same behaviors in the ungated test files.
///
/// Environment note: in the Xcode 27.0 simulator runtime Apple's own
/// `AppIntentsLiveEntityService` XPC service traps (`__XPC_API_MISUSE__` in
/// `XPCPeerRequirement.hasEntitlement`, see DiagnosticReports) as soon as a
/// test client connects — with ad-hoc and with real Apple Development
/// signing alike — so every framework call fails with a transport error.
/// Those transport failures skip loudly (below) instead of passing or
/// masking assertion failures; wherever the platform service works, these
/// tests execute for real.
@MainActor
final class AppIntentsTestingTests: XCTestCase {
    @available(iOS 27, *)
    private func definitions() -> IntentDefinitions {
        IntentDefinitions(bundleIdentifier: "org.programme.Programme")
    }

    /// Runs one framework call, converting a broken testing transport into an
    /// explicit skip. Assertion failures still fail; only the transport-level
    /// error (Apple's service crash, above) skips.
    private func viaFramework<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            if String(describing: error).contains("transportCancelled") {
                throw XCTSkip(
                    "AppIntentsTesting transport unavailable in this environment "
                        + "(Apple AppIntentsLiveEntityService crash); "
                        + "behavior is covered by EntityQueryTests/IntentNavigationTests.")
            }
            throw error
        }
    }

    func testFrameworkMatchLookupByIdentifier() async throws {
        let harness = try await IntentTestHarness.make()
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let found = try await viaFramework {
            try await definitions.entities["MatchEntity"].entities(
                identifiers: [harness.seed.matchA.rawValue])
        }
        XCTAssertEqual(found.count, 1)
    }

    func testFrameworkPlayerLookupByIdentifier() async throws {
        let harness = try await IntentTestHarness.make()
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let found = try await viaFramework {
            try await definitions.entities["PlayerEntity"].entities(
                identifiers: [harness.seed.playerA.rawValue])
        }
        XCTAssertEqual(found.count, 1)
    }

    func testFrameworkMissingIdentifiersDisappear() async throws {
        let harness = try await IntentTestHarness.make()
        _ = harness
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let matches = try await viaFramework {
            try await definitions.entities["MatchEntity"].entities(identifiers: [UUID()])
        }
        XCTAssertTrue(matches.isEmpty)
    }

    func testFrameworkSuggestedEntities() async throws {
        let harness = try await IntentTestHarness.make()
        _ = harness
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let matches = try await viaFramework { try await definitions.entities["MatchEntity"].suggestedEntities() }
        XCTAssertEqual(matches.count, 2)
        let players = try await viaFramework { try await definitions.entities["PlayerEntity"].suggestedEntities() }
        XCTAssertEqual(players.count, 2)
    }

    func testFrameworkOpenMatchSelectsOwningTeam() async throws {
        let harness = try await IntentTestHarness.make()
        await harness.selectTeamB()
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let reference = definitions.entities["MatchEntity"].makeReference(
            identifier: harness.seed.matchA.rawValue.uuidString)
        _ = try await viaFramework {
            try await definitions.intents["OpenMatchIntent"].makeIntent(match: reference).run()
        }
        XCTAssertEqual(harness.appModel.workspace.selectedTeamID, harness.seed.teamA)
        XCTAssertEqual(harness.appModel.navigation.section, .matches)
    }

    func testFrameworkScoreMatchOpensScorer() async throws {
        let harness = try await IntentTestHarness.make()
        await harness.selectTeamB()
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        let reference = definitions.entities["MatchEntity"].makeReference(
            identifier: harness.seed.matchA.rawValue.uuidString)
        _ = try await viaFramework {
            try await definitions.intents["ScoreMatchIntent"].makeIntent(match: reference).run()
        }
        XCTAssertEqual(harness.appModel.workspace.selectedTeamID, harness.seed.teamA)
        XCTAssertEqual(harness.appModel.liveSession?.matchID, harness.seed.matchA)
    }

    func testFrameworkSeasonAndNewMatchIntents() async throws {
        let harness = try await IntentTestHarness.make()
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        _ = try await viaFramework { try await definitions.intents["ShowSeasonStatsIntent"].makeIntent().run() }
        XCTAssertEqual(harness.appModel.navigation.section, .stats)
        _ = try await viaFramework { try await definitions.intents["NewMatchIntent"].makeIntent().run() }
        XCTAssertTrue(harness.appModel.navigation.isPresentingNewMatch)
    }

    func testFrameworkCurrentScoreRuns() async throws {
        let harness = try await IntentTestHarness.make()
        _ = harness
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        // With no live session this must complete with the no-match result,
        // not throw.
        _ = try await viaFramework { try await definitions.intents["CurrentScoreIntent"].makeIntent().run() }
    }

    func testFrameworkSpotlightAndViewQueriesComplete() async throws {
        let harness = try await IntentTestHarness.make()
        await harness.provider.reindexSpotlight()
        guard #available(iOS 27, *) else { throw XCTSkip("AppIntentsTesting requires iOS 27.") }
        let definitions = definitions()
        // System indexing latency means content cannot be asserted
        // deterministically; these prove the native Spotlight/Siri query paths
        // execute against the real entities without substitutes.
        _ = try await viaFramework {
            try await definitions.entities["MatchEntity"].spotlightQuery("Dixie")
        }
        _ = try await viaFramework {
            try await definitions.entities["MatchEntity"].viewAnnotations()
        }
    }
}
