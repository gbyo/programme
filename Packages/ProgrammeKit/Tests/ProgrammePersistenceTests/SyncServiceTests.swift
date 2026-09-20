import CloudKit
import Foundation
import Testing

@testable import ProgrammeCollaboration
@testable import ProgrammeCore
@testable import ProgrammePersistence

/// The sync service replicates through staged records but never touches the
/// network here: the container factory is never evaluated, so these tests
/// prove routing, record building, hook coverage, and echo suppression
/// against an in-memory store.
@Suite("Sync stages local truth and never echoes remote truth")
struct SyncServiceTests {
    private func makeStore() throws -> MatchStore {
        let container = try ProgrammeStore.container(inMemory: true)
        return MatchStore(modelContainer: container)
    }

    private func makeService(_ store: MatchStore) throws -> TeamSyncService {
        let directory = URL.temporaryDirectory.appending(path: "programme-sync-\(UUID().uuidString)")
        return try TeamSyncService(store: store, directory: directory) {
            fatalError("No CloudKit in tests")
        }
    }

    private func makeTeamAndMatch(_ store: MatchStore) async throws -> (TeamID, MatchID) {
        let teamID = try await store.createTeam(name: "Ninety Six", shortName: nil)
        let roster = try await store.roster(teamID: teamID)
        let matchID = try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: "Dixie", opponentShortName: "Dixie",
            kickoff: ProgrammeSample.kickoff(), venue: .away, rules: .highSchool,
            statProfile: .maxPreps, tracking: .ourTeam, competition: nil, roster: roster)
        return (teamID, matchID)
    }

    @Test("Local writes report mutations; remote application stays silent")
    func hooksAndSuppression() async throws {
        let store = try makeStore()
        let (teamID, matchID) = try await makeTeamAndMatch(store)
        let received = MutationLog()
        await store.setMutationHandler { mutation in received.append(mutation) }

        let event = MatchEvent(
            matchID: matchID, time: .kickoff, sequence: 1, payload: .note("Hello"))
        try await store.apply([.appendEvent(event)], to: matchID)
        try await store.updateTeam(
            teamID, name: "Ninety Six", shortName: "NX", mascot: nil,
            primaryColorHex: nil, secondaryColorHex: nil)
        await #expect(received.contains(.events(matchID: matchID, eventIDs: [event.id])))
        await #expect(received.contains(.team(teamID)))

        // Remote application through the applier seam never echoes.
        await received.clear()
        try await store.ensureTeam(
            TeamRecord(teamID: teamID, name: "Ninety Six", shortName: "NX"))
        try await store.writeEffects([.appendEvent(event)], to: matchID)
        await #expect(received.isEmpty)
    }

    @Test("Deleting a match tombstones the match and its events")
    func deleteMatchTombstones() async throws {
        let store = try makeStore()
        let (_, matchID) = try await makeTeamAndMatch(store)
        let event = MatchEvent(
            matchID: matchID, time: .kickoff, sequence: 1, payload: .note("Hello"))
        try await store.apply([.appendEvent(event)], to: matchID)
        let received = MutationLog()
        await store.setMutationHandler { mutation in received.append(mutation) }
        try await store.deleteMatch(matchID)
        // The journal is gone, so the tombstone must carry what it needs.
        let tombstones = await received.mutations.compactMap { mutation -> (MatchID, [EventID])? in
            if case .deletedMatch(let id, _, let eventIDs) = mutation { return (id, eventIDs) }
            return nil
        }
        #expect(tombstones.count == 1)
        #expect(tombstones.first?.0 == matchID)
        #expect(tombstones.first?.1 == [event.id])
    }

    @Test("Removing a player archives or tombstones")
    func removePlayerRoutes() async throws {
        let store = try makeStore()
        let teamID = try await store.createTeam(name: "Ninety Six", shortName: nil)
        let loneID = try await store.addPlayer(
            teamID: teamID, PlayerSnapshot(firstName: "Lone", lastName: "Wolf"))
        let received = MutationLog()
        await store.setMutationHandler { mutation in received.append(mutation) }
        try await store.removePlayer(loneID)
        await #expect(received.contains(.deletedPlayers(teamID: teamID, playerIDs: [loneID])))
    }

    @Test("Mutations build staged saves in the owning zone")
    func stagedSaves() async throws {
        let store = try makeStore()
        let (teamID, matchID) = try await makeTeamAndMatch(store)
        let event = MatchEvent(
            matchID: matchID, time: .kickoff, sequence: 1, payload: .note("Hello"))
        try await store.apply([.appendEvent(event)], to: matchID)
        let service = try makeService(store)

        let events = await service.stagedChanges(
            for: .events(matchID: matchID, eventIDs: [event.id, EventID()]))
        #expect(events.count == 1)
        if case .save(let record, let scope) = events.first {
            #expect(record.recordType == EventRecord.recordType)
            #expect(record.recordID.zoneID.zoneName == TeamZone.zoneName(for: teamID))
            #expect(scope == .private)
        } else {
            Issue.record("Expected an event save")
        }

        let matches = await service.stagedChanges(for: .match(matchID))
        #expect(matches.count == 1)
        if case .save(let record, _) = matches.first {
            #expect(record.recordType == MatchRecord.recordType)
        } else {
            Issue.record("Expected a match save")
        }

        let teams = await service.stagedChanges(for: .team(teamID))
        #expect(teams.count == 1)
        if case .save(let record, _) = teams.first {
            #expect(TeamRecord(record: record)?.name == "Ninety Six")
        } else {
            Issue.record("Expected a team save")
        }

        // Unknown rows stage nothing rather than failing.
        #expect(await service.stagedChanges(for: .team(TeamID())).isEmpty)
        #expect(await service.stagedChanges(for: .match(MatchID())).isEmpty)
    }

    @Test("Event staging maps only the changed events")
    func eventStagingIsSelective() async throws {
        let store = try makeStore()
        let (teamID, matchID) = try await makeTeamAndMatch(store)
        let first = MatchEvent(matchID: matchID, time: .kickoff, sequence: 1, payload: .note("One"))
        let second = MatchEvent(matchID: matchID, time: .kickoff, sequence: 2, payload: .note("Two"))
        let third = MatchEvent(matchID: matchID, time: .kickoff, sequence: 3, payload: .note("Three"))
        try await store.apply([.appendEvent(first), .appendEvent(second), .appendEvent(third)], to: matchID)
        let service = try makeService(store)

        // One changed event stages exactly one record in the owning zone.
        let single = await service.stagedChanges(for: .events(matchID: matchID, eventIDs: [second.id]))
        #expect(single.count == 1)
        if case .save(let record, let scope) = single.first {
            #expect(record.recordType == EventRecord.recordType)
            #expect(record.recordID.zoneID.zoneName == TeamZone.zoneName(for: teamID))
            #expect(scope == .private)
            #expect(EventRecord(record: record)?.event.id == second.id)
        } else {
            Issue.record("Expected one event save")
        }

        // A correction stages the post-write state for the same record.
        var corrected = second
        corrected.payload = .note("Two corrected")
        try await store.apply([.replaceEvent(corrected)], to: matchID)
        let restaged = await service.stagedChanges(for: .events(matchID: matchID, eventIDs: [second.id]))
        #expect(restaged.count == 1)
        if case .save(let record, _) = restaged.first {
            let event = EventRecord(record: record)?.event
            #expect(event?.id == second.id)
            #expect(event?.payload == .note("Two corrected"))
        } else {
            Issue.record("Expected one corrected event save")
        }

        // A bulk mutation stages every named event and nothing else.
        let bulk = await service.stagedChanges(
            for: .events(matchID: matchID, eventIDs: [first.id, second.id, third.id]))
        #expect(bulk.count == 3)

        // Unknown event IDs and matches stage nothing rather than failing.
        #expect(
            await service.stagedChanges(for: .events(matchID: matchID, eventIDs: [EventID()])).isEmpty)
        #expect(
            await service.stagedChanges(for: .events(matchID: MatchID(), eventIDs: [second.id]))
                .isEmpty)
    }

    @Test("Accepted shares route participant writes to the shared database")
    func sharedRouting() async throws {
        let store = try makeStore()
        let (teamID, _) = try await makeTeamAndMatch(store)
        let directory = URL.temporaryDirectory.appending(path: "programme-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ownersURL = directory.appending(path: "shared-zone-owners.json")
        try JSONEncoder().encode([teamID.rawValue.uuidString: "sharerOwner"]).write(to: ownersURL)
        let service = try TeamSyncService(store: store, directory: directory) {
            fatalError("No CloudKit in tests")
        }
        let teams = await service.stagedChanges(for: .team(teamID))
        #expect(teams.count == 1)
        if case .save(let record, let scope) = teams.first {
            #expect(scope == .shared)
            #expect(record.recordID.zoneID.ownerName == "sharerOwner")
        } else {
            Issue.record("Expected a shared team save")
        }
    }

    @Test("Staging and materializing stay inert before start")
    func inertBeforeStart() async throws {
        let store = try makeStore()
        let (teamID, matchID) = try await makeTeamAndMatch(store)
        let service = try makeService(store)
        // No coordinator work happens: no throw, no crash, no container.
        await service.stage(.team(teamID))
        await service.stage(.match(matchID))
        let report = await service.materialize()
        #expect(report.applied.isEmpty && report.deferredCount == 0)
        #expect(report.structureChanged == false)
    }
}

/// Synchronous-looking mutation capture for hook tests. The store calls the
/// hook synchronously inside each mutating method, so a lock is enough —
/// no actor hop that could reorder assertions.
private final class MutationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _mutations: [OutboundMutation] = []

    var mutations: [OutboundMutation] {
        lock.withLock { _mutations }
    }

    var isEmpty: Bool { mutations.isEmpty }

    func append(_ mutation: OutboundMutation) {
        lock.withLock { _mutations.append(mutation) }
    }

    func contains(_ mutation: OutboundMutation) -> Bool {
        mutations.contains(mutation)
    }

    func clear() {
        lock.withLock { _mutations = [] }
    }
}
