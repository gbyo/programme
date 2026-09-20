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

@Suite("Sync identity lookups answer from indexed rows, never snapshots")
struct SyncIdentityLookupTests {
    private func makeStore() throws -> MatchStore {
        let container = try ProgrammeStore.container(inMemory: true)
        return MatchStore(modelContainer: container)
    }

    @Test("Missing parents answer false without building anything")
    func missingParentsAreFalse() async throws {
        let store = try makeStore()
        let team = TeamID(ProgrammeSample.id("team.lookup-missing"))
        #expect(try await store.teamExists(team) == false)
        #expect(
            try await store.seasonExists(SeasonID(ProgrammeSample.id("season.missing")), inTeam: team)
                == false)
        #expect(
            try await store.playerExists(PlayerID(ProgrammeSample.id("player.missing")), inTeam: team)
                == false)
        #expect(
            try await store.matchExists(MatchID(ProgrammeSample.id("match.missing")), inTeam: team)
                == false)
        #expect(
            try await store.locateEvent(EventID(ProgrammeSample.id("event.missing")), inTeam: team)
                == nil)
    }

    @Test("Lookups stay scoped to the owning team")
    func lookupsStayTeamScoped() async throws {
        let store = try makeStore()
        let teamA = try await store.createTeam(name: "Ninety Six", shortName: nil)
        let teamB = try await store.createTeam(name: "Dixie", shortName: nil)
        let seasonA = try await store.createSeason(
            teamID: teamA, name: "Fall", startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: nil)
        let playerA = try await store.addPlayer(
            teamID: teamA,
            PlayerSnapshot(
                id: PlayerID(ProgrammeSample.id("player.lookup-a")), firstName: "Ava",
                lastName: "Adams", jerseyNumber: 7, position: .midfielder, classYear: nil,
                isOnRoster: true))
        let matchA = try await store.createMatch(
            teamID: teamA, seasonID: seasonA, opponentName: "Foe", opponentShortName: "FOE",
            kickoff: ProgrammeSample.kickoff(daysFromNow: -1), venue: .home, rules: .highSchool,
            statProfile: .maxPreps, tracking: .ourTeam, competition: nil,
            roster: ProgrammeSample.roster)

        #expect(try await store.teamExists(teamA))
        #expect(try await store.seasonExists(seasonA, inTeam: teamA))
        #expect(try await store.playerExists(playerA, inTeam: teamA))
        #expect(try await store.matchExists(matchA, inTeam: teamA))
        // Same rows, asked from the wrong team, must not resolve.
        #expect(try await store.seasonExists(seasonA, inTeam: teamB) == false)
        #expect(try await store.playerExists(playerA, inTeam: teamB) == false)
        #expect(try await store.matchExists(matchA, inTeam: teamB) == false)
    }

    @Test("Event IDs resolve to their owning team's match")
    func eventParentResolution() async throws {
        let store = try makeStore()
        let teamA = try await store.createTeam(name: "Ninety Six", shortName: nil)
        let teamB = try await store.createTeam(name: "Dixie", shortName: nil)
        let seasonA = try await store.createSeason(
            teamID: teamA, name: "Fall", startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: nil)

        var context = MatchContext(
            descriptor: ProgrammeSample.descriptor(seed: "lookup.event"),
            roster: ProgrammeSample.roster)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        for command: MatchCommand in [
            .setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven,
                    goalkeeper: ProgrammeSample.keeper)),
            .startNextPeriod,
            .recordShot(
                ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)),
        ] {
            let effects = try MatchEngine.perform(command, on: context, at: date)
            MatchEngine.apply(effects, to: &context)
            date = date.addingTimeInterval(1)
        }
        let matchID = try await store.importMatch(context, teamID: teamA, seasonID: seasonA)
        let eventID = try #require(
            context.events.first { if case .shot = $0.payload { true } else { false } }?.id)

        #expect(try await store.locateEvent(eventID, inTeam: teamA) == matchID)
        // Unknown events and other teams' events never resolve here.
        #expect(
            try await store.locateEvent(EventID(ProgrammeSample.id("event.unknown")), inTeam: teamA)
                == nil)
        #expect(try await store.locateEvent(eventID, inTeam: teamB) == nil)
    }
}

@Suite("Share scope resolves from the local ownership cache")
struct SharedZoneOwnershipCacheTests {
    private func ownersURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "programme-owners-\(UUID().uuidString)/shared-zone-owners.json")
    }

    private func makeService(_ store: MatchStore) throws -> TeamSyncService {
        let directory = URL.temporaryDirectory.appending(path: "programme-sync-\(UUID().uuidString)")
        return try TeamSyncService(store: store, directory: directory) {
            fatalError("No CloudKit in tests")
        }
    }

    @Test("Remembered owners look up, replace, and forget per team")
    func rememberReplaceForget() async throws {
        let teamA = TeamID(ProgrammeSample.id("team.owners-a"))
        let cache = try SharedZoneOwners(url: ownersURL())
        #expect(await cache.ownerName(for: teamA) == nil)
        await cache.remember([teamA: "alice"])
        #expect(await cache.ownerName(for: teamA) == "alice")
        await cache.remember([teamA: "bob"])
        #expect(await cache.ownerName(for: teamA) == "bob")
        await cache.forget(teamID: teamA)
        #expect(await cache.ownerName(for: teamA) == nil)
    }

    @Test("Ownership survives relaunch; reset clears every team")
    func persistsAndResets() async throws {
        let url = ownersURL()
        let teamA = TeamID(ProgrammeSample.id("team.owners-a"))
        let teamB = TeamID(ProgrammeSample.id("team.owners-b"))
        let first = try SharedZoneOwners(url: url)
        await first.remember([teamA: "alice", teamB: "bob"])
        let second = try SharedZoneOwners(url: url)
        #expect(await second.ownerName(for: teamA) == "alice")
        #expect(await second.ownerName(for: teamB) == "bob")
        await second.reset()
        #expect(await second.ownerName(for: teamA) == nil)
        let third = try SharedZoneOwners(url: url)
        #expect(await third.ownerName(for: teamB) == nil)
    }

    @Test("Cached scope reads never touch CloudKit and clear on sign-out")
    func cachedReadsStayLocal() async throws {
        let container = try ProgrammeStore.container(inMemory: true)
        let service = try makeService(MatchStore(modelContainer: container))
        let teamA = TeamID(ProgrammeSample.id("team.owners-a"))
        let teamB = TeamID(ProgrammeSample.id("team.owners-b"))
        // Fresh cache answers unknown — and the fatalError container
        // factory above proves no CloudKit call was attempted to ask.
        #expect(await service.cachedOwnerName(for: teamA) == nil)
        await service.owners.remember([teamA: "alice", teamB: "bob"])
        #expect(await service.cachedOwnerName(for: teamA) == "alice")
        // Sign-out drops every team, so a new account never inherits
        // the previous account's scopes.
        await service.handleAccountChange(.signOut(previousUser: CKRecord.ID(recordName: "u")))
        #expect(await service.cachedOwnerName(for: teamA) == nil)
        #expect(await service.cachedOwnerName(for: teamB) == nil)
    }
}
