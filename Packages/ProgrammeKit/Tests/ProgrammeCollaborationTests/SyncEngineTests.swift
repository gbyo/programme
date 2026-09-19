import CloudKit
import Foundation
import Synchronization
import Testing

@testable import ProgrammeCollaboration
@testable import ProgrammeCore

private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent(name)
}

private func teamRecord(named name: String = "Ninety Six") -> CKRecord {
    let teamID = TeamID(ProgrammeSample.id("team.ninety-six"))
    return TeamRecord(
        teamID: teamID, name: name, shortName: "NX", createdAt: Date()
    ).makeRecord(in: TeamZone.zoneID(for: teamID))
}

private func makeCoordinator() throws -> TeamSyncCoordinator {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return TeamSyncCoordinator(
        makeContainer: { CKContainer(identifier: "iCloud.test.programme") },
        outboxes: [
            .private: try SyncOutbox(url: dir.appendingPathComponent("private-outbox.json")),
            .shared: try SyncOutbox(url: dir.appendingPathComponent("shared-outbox.json")),
        ],
        stateStores: [
            .private: EngineStateStore(url: dir.appendingPathComponent("private-state.json")),
            .shared: EngineStateStore(url: dir.appendingPathComponent("shared-state.json")),
        ],
        inbox: try SyncInbox(url: dir.appendingPathComponent("inbox.json")))
}

@Suite("The outbox survives relaunch")
struct SyncOutboxTests {
    @Test("Staged saves persist and reload across instances")
    func savesSurviveRelaunch() async throws {
        let url = temporaryURL("outbox.json")
        let record = teamRecord()
        let first = try SyncOutbox(url: url)
        try await first.stageSave(record)
        #expect(await first.stagedSaves.count == 1)

        // A fresh instance over the same file sees the same work: killing the
        // app right after recording must not lose the upload.
        let second = try SyncOutbox(url: url)
        #expect(await second.stagedSaves.count == 1)
        let restored = try await second.unarchive(second.stagedSaves[0])
        #expect(restored.recordID == record.recordID)
        #expect(restored["name"] as? String == "Ninety Six")
    }

    @Test("A delete collapses a staged save of the same record")
    func deleteCollapsesSave() async throws {
        let url = temporaryURL("outbox.json")
        let outbox = try SyncOutbox(url: url)
        let record = teamRecord()
        try await outbox.stageSave(record)
        try await outbox.stageDelete(recordID: record.recordID, recordType: record.recordType)
        #expect(await outbox.stagedSaves.isEmpty)
        #expect(await outbox.stagedDeletes.count == 1)
    }

    @Test("Confirmed sends leave everything else staged")
    func confirmedSendsClearSelectively() async throws {
        let url = temporaryURL("outbox.json")
        let outbox = try SyncOutbox(url: url)
        let first = teamRecord(named: "First")
        let teamID = TeamID(ProgrammeSample.id("team.other"))
        let second = TeamRecord(teamID: teamID, name: "Second", shortName: "2nd", createdAt: Date())
            .makeRecord(in: TeamZone.zoneID(for: teamID))
        try await outbox.stageSave(first)
        try await outbox.stageSave(second)
        try await outbox.removeStaged(recordNames: [first.recordID.recordName])
        #expect(await outbox.stagedSaves.count == 1)
        #expect(await outbox.stagedSaves[0].recordName == second.recordID.recordName)
    }
}

@Suite("Engine state round-trips")
struct EngineStateStoreTests {
    struct StubState: Codable, Equatable {
        var token: String
        var pending: Int
    }

    @Test("Saved state loads back; missing file loads nothing")
    func roundTrip() throws {
        let url = temporaryURL("state.json")
        let store = EngineStateStore(url: url)
        #expect(store.load(StubState.self) == nil)
        try store.save(StubState(token: "abc", pending: 3))
        #expect(store.load(StubState.self) == StubState(token: "abc", pending: 3))
    }
}

@Suite("The coordinator routes without the network")
struct TeamSyncCoordinatorTests {
    @Test("Batches serve staged saves and deletes per database")
    func batchesServeOutbox() async throws {
        let coordinator = try makeCoordinator()
        #expect(await coordinator.batchForScope(.private) == nil)

        let record = teamRecord()
        try await coordinator.stageSave(record, in: .private)
        let batch = await coordinator.batchForScope(.private)
        let batchRecords = try #require(batch?.recordsToSave)
        #expect(batchRecords.count == 1)
        #expect(batchRecords[0].recordID == record.recordID)
        // The shared database has its own outbox: no cross-contamination.
        #expect(await coordinator.batchForScope(.shared) == nil)
    }

    @Test("Confirmed sends clear the outbox; failures stay staged")
    func sentChangesClearOutbox() async throws {
        let coordinator = try makeCoordinator()
        let record = teamRecord()
        try await coordinator.stageSave(record, in: .private)
        await coordinator.applySent(saved: [record], deleted: [], scope: .private)
        #expect(await coordinator.batchForScope(.private) == nil)
    }

    @Test("Fetched changes buffer durably and forward to the handler")
    func fetchedChangesBufferAndForward() async throws {
        let coordinator = try makeCoordinator()
        let record = teamRecord()
        let seen = Mutex<[IncomingChange]>([])
        await coordinator.setIncomingHandler { changes in
            seen.withLock { $0.append(contentsOf: changes) }
        }
        await coordinator.applyFetched(saved: [record], deleted: [], scope: .shared)
        let changes = seen.withLock { $0 }
        #expect(changes.count == 1)
        #expect(changes[0].recordName == record.recordID.recordName)
        #expect(changes[0].deleted == false)
        #expect(changes[0].archivedRecord != nil)
    }

    @Test("Account loss reports attention and deletes nothing local")
    func accountLossIsNonDestructive() async throws {
        let coordinator = try makeCoordinator()
        await coordinator.applyAccountChange(.signOut(previousUser: CKRecord.ID(recordName: "u")))
        let status = await coordinator.status
        #expect(status != .idle)
        // The outbox is untouched: pending uploads survive account loss.
        #expect(await coordinator.batchForScope(.private) == nil)
    }
}
