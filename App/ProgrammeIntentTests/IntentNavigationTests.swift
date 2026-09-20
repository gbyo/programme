import Foundation
import XCTest

@testable import Programme

/// Navigation and read-only intent behavior through the real
/// `ProgrammeIntentProvider` and the real `AppModel.open(_:)` path. Runs on
/// every deployment target.
///
/// The intent structs (`OpenMatchIntent`, `ScoreMatchIntent`, …) resolve their
/// provider via `@Dependency`, which the system only satisfies inside the
/// intent perform flow; calling `perform()` directly in-process traps. Each
/// `perform()` body is a one-line delegate to the provider method exercised
/// here, and the iOS 27-gated `AppIntentsTestingTests` runs the structs
/// themselves through Apple's testing framework.
@MainActor
final class IntentNavigationTests: XCTestCase {
    func testOpenMatchSelectsOwningTeamFirst() async throws {
        let harness = try await IntentTestHarness.make()
        await harness.selectTeamB()
        XCTAssertEqual(harness.appModel.workspace.selectedTeamID, harness.seed.teamB)

        await harness.provider.open(.match(harness.seed.matchA))

        XCTAssertEqual(harness.appModel.workspace.selectedTeamID, harness.seed.teamA)
        XCTAssertEqual(harness.appModel.navigation.section, .matches)
        XCTAssertEqual(harness.appModel.navigation.matchesPath.count, 1)
    }

    func testOpenReviewSelectsOwningTeamFirst() async throws {
        let harness = try await IntentTestHarness.make()
        await harness.selectTeamB()

        await harness.provider.open(.review(harness.seed.matchA))

        XCTAssertEqual(harness.appModel.workspace.selectedTeamID, harness.seed.teamA)
        XCTAssertEqual(harness.appModel.navigation.section, .matches)
        XCTAssertEqual(harness.appModel.navigation.matchesPath.count, 1)
    }

    func testOpenPlayerSelectsOwningTeamFirst() async throws {
        let harness = try await IntentTestHarness.make()
        await harness.selectTeamB()

        await harness.provider.open(.player(harness.seed.playerA))

        XCTAssertEqual(harness.appModel.workspace.selectedTeamID, harness.seed.teamA)
        XCTAssertEqual(harness.appModel.navigation.section, .roster)
        XCTAssertEqual(harness.appModel.navigation.rosterPath.count, 1)
    }

    func testScoreMatchOpensOwningTeamAndScorer() async throws {
        let harness = try await IntentTestHarness.make()
        await harness.selectTeamB()

        await harness.provider.startScoring(matchID: harness.seed.matchA)

        XCTAssertEqual(harness.appModel.workspace.selectedTeamID, harness.seed.teamA)
        XCTAssertEqual(harness.appModel.liveSession?.matchID, harness.seed.matchA)
        XCTAssertTrue(harness.appModel.navigation.isShowingLiveMatch)
    }

    func testShowSeasonStatsUsesSelectedTeamSeason() async throws {
        let harness = try await IntentTestHarness.make()
        // Harness selects team A; its current season must be the context.
        XCTAssertEqual(
            harness.appModel.workspace.currentSeasonID, harness.seed.seasonA)

        await harness.provider.open(.season(nil))

        XCTAssertEqual(harness.appModel.navigation.section, .stats)
        XCTAssertEqual(harness.appModel.workspace.selectedTeamID, harness.seed.teamA)
        XCTAssertEqual(
            harness.appModel.workspace.currentSeasonID, harness.seed.seasonA)
    }

    func testViewingHistoricalSeasonNeverMarksItCurrent() async throws {
        let harness = try await IntentTestHarness.make()
        guard let store = harness.appModel.store else { return XCTFail("no store") }
        let oldSeason = try await store.createSeason(
            teamID: harness.seed.teamA, name: "2025–26",
            startDate: Date(timeIntervalSince1970: 1_750_000_000), endDate: nil,
            makeCurrent: false)

        await harness.provider.open(.season(oldSeason))

        XCTAssertEqual(harness.appModel.navigation.section, .stats)
        XCTAssertEqual(harness.appModel.workspace.viewedStatsSeasonID, oldSeason)
        XCTAssertEqual(harness.appModel.workspace.currentSeasonID, harness.seed.seasonA)
    }

    func testNewMatchRemainsSelectedTeamScoped() async throws {
        let harness = try await IntentTestHarness.make()
        await harness.selectTeamB()

        harness.provider.presentNewMatch()

        XCTAssertTrue(harness.appModel.navigation.isPresentingNewMatch)
        // Presenting the composer must not move the workspace.
        XCTAssertEqual(harness.appModel.workspace.selectedTeamID, harness.seed.teamB)
    }

    func testCurrentScoreWithNoLiveSession() async throws {
        let harness = try await IntentTestHarness.make()
        // `CurrentScoreIntent` reports this nil as its no-match result.
        XCTAssertNil(harness.provider.liveScoreSummary())
    }

    func testCurrentScoreDuringLiveSession() async throws {
        let harness = try await IntentTestHarness.make()
        guard let store = harness.appModel.store else { return XCTFail("no store") }
        guard let journal = harness.appModel.journal else { return XCTFail("no journal") }
        let context = try await store.context(for: harness.seed.matchA)
        harness.appModel.liveSession = LiveMatchSession(
            context: context, store: store, journal: journal, appModel: harness.appModel)

        let value = try XCTUnwrap(harness.provider.liveScoreSummary())
        // The summary names the live score and period, derived from the engine.
        XCTAssertTrue(value.contains("NX"))
        XCTAssertTrue(value.contains("DIX"))
    }
}
