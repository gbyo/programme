import Foundation
import ProgrammeCollaboration
import ProgrammeCore
import ProgrammePersistence
import Testing

@testable import Programme

/// Records index writes without a live Spotlight database.
private actor FakeSpotlightClient: SpotlightIndexClient {
    var indexedMatches: [MatchEntity] = []
    var indexedPlayers: [PlayerEntity] = []
    var deletedMatches: [UUID] = []
    var deletedPlayers: [UUID] = []

    func indexMatches(_ entities: [MatchEntity]) async throws {
        indexedMatches += entities
    }

    func indexPlayers(_ entities: [PlayerEntity]) async throws {
        indexedPlayers += entities
    }

    func deleteMatchIdentifiers(_ ids: [UUID]) async throws {
        deletedMatches += ids
    }

    func deletePlayerIdentifiers(_ ids: [UUID]) async throws {
        deletedPlayers += ids
    }

    func reset() {
        indexedMatches = []
        indexedPlayers = []
        deletedMatches = []
        deletedPlayers = []
    }
}

@Suite("Spotlight indexing is mutation-driven")
@MainActor
struct SpotlightIndexingTests {
    private func harnessWithFake() async throws -> (IntentTestHarness, FakeSpotlightClient) {
        let harness = try await IntentTestHarness.make()
        let fake = FakeSpotlightClient()
        harness.provider.spotlightClient = fake
        return (harness, fake)
    }

    @Test("Widget refreshes and team switches do not touch the index")
    func refreshDoesNotIndex() async throws {
        let (harness, fake) = try await harnessWithFake()
        await harness.appModel.refreshWidgetSnapshot()
        await harness.appModel.selectTeam(harness.seed.teamB)
        await harness.appModel.refreshWidgetSnapshot()
        #expect(await fake.indexedMatches.isEmpty)
        #expect(await fake.indexedPlayers.isEmpty)
        #expect(await fake.deletedMatches.isEmpty)
        #expect(await fake.deletedPlayers.isEmpty)
    }

    @Test("A match mutation indexes only that match")
    func matchMutationIndexesScopely() async throws {
        let (harness, fake) = try await harnessWithFake()
        harness.provider.noteMutation(.match(harness.seed.matchA))
        await harness.provider.flushSpotlight()
        let indexed = await fake.indexedMatches
        #expect(indexed.map(\.id) == [harness.seed.matchA.rawValue])
        #expect(await fake.indexedPlayers.isEmpty)
    }

    @Test("Repeated mutations for one match coalesce into one entity")
    func mutationsCoalesce() async throws {
        let (harness, fake) = try await harnessWithFake()
        harness.provider.noteMutation(
            .events(matchID: harness.seed.matchA, eventIDs: [EventID()]))
        harness.provider.noteMutation(.match(harness.seed.matchA))
        harness.provider.noteMutation(
            .events(matchID: harness.seed.matchA, eventIDs: [EventID()]))
        await harness.provider.flushSpotlight()
        #expect(await fake.indexedMatches.map(\.id) == [harness.seed.matchA.rawValue])
    }

    @Test("A deleted match removes its identifier instead of indexing")
    func deletionRemovesIdentifier() async throws {
        let (harness, fake) = try await harnessWithFake()
        harness.provider.noteMutation(
            .deletedMatch(matchID: harness.seed.matchA, teamID: harness.seed.teamA, eventIDs: []))
        await harness.provider.flushSpotlight()
        #expect(await fake.indexedMatches.isEmpty)
        #expect(await fake.deletedMatches == [harness.seed.matchA.rawValue])
    }

    @Test("Player mutations index only those players")
    func playerMutationIndexesScopely() async throws {
        let (harness, fake) = try await harnessWithFake()
        harness.provider.noteMutation(
            .players(teamID: harness.seed.teamA, playerIDs: [harness.seed.playerA]))
        await harness.provider.flushSpotlight()
        let indexed = await fake.indexedPlayers
        #expect(indexed.map(\.id) == [harness.seed.playerA.rawValue])
        #expect(indexed.first?.name.contains("Bell") == true)
        #expect(await fake.indexedMatches.isEmpty)
    }

    @Test("A full rebuild still indexes the whole library")
    func fullRebuildRemains() async throws {
        let (harness, fake) = try await harnessWithFake()
        await harness.provider.reindexSpotlight()
        #expect(await fake.indexedMatches.count == 2)
        #expect(await fake.indexedPlayers.count == 2)
    }
}
