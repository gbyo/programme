import CloudKit
import Foundation
import ProgrammeCore

/// The CloudKit container for team collaboration. Provisioning it is a
/// Developer Portal + Xcode capability step (see docs/ARCHITECTURE.md):
/// until then the coordinator stays unavailable and everything local works.
public enum CollaborationEnvironment {
    public static let containerIdentifier = "iCloud.org.programme.Programme"
}

/// Which CloudKit database an intent belongs to. One sync engine per
/// database — never two engines competing over the same one.
public enum SyncDatabase: String, Codable, Hashable, Sendable {
    case `private`
    case shared
}

/// A fetched change, archived at the boundary so it stays Sendable and
/// survives the applier running on another actor. The applier (next item)
/// unarchives, decodes through `Records.swift`, merges, and writes through
/// MatchStore — then re-derives via StatEngine. Nothing here interprets
/// match content.
public struct IncomingChange: Codable, Hashable, Sendable {
    public var database: SyncDatabase
    public var zoneName: String
    public var ownerName: String
    public var recordName: String
    public var recordType: String
    public var archivedRecord: Data?
    public var deleted: Bool
}

/// Durable buffer for fetched changes awaiting the applier. Server tokens
/// advance in engine state once fetched, so an unprocessed fetch would be
/// lost on relaunch without this file.
public actor SyncInbox {
    private let url: URL
    private var buffered: [IncomingChange]

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            buffered = try JSONDecoder().decode([IncomingChange].self, from: Data(contentsOf: url))
        } else {
            buffered = []
        }
    }

    public func append(_ changes: [IncomingChange]) throws {
        buffered.append(contentsOf: changes)
        try persist()
    }

    public func drain() throws -> [IncomingChange] {
        let changes = buffered
        buffered = []
        try persist()
        return changes
    }

    public var count: Int { buffered.count }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: nil)
        try JSONEncoder().encode(buffered).write(to: url, options: .atomic)
    }
}

/// Owns one `CKSyncEngine` per database and routes events.
///
/// - Outbound: staged in the per-database `SyncOutbox` (durable), served to
///   the engine in `nextRecordZoneChangeBatch`, cleared on confirmed send.
///   Transient errors, rate limits, and retries belong to the engine; no
///   custom retry loop, no polling.
/// - Inbound: fetched changes archived into the `SyncInbox` and forwarded to
///   `onIncoming`; the applier drains and materializes them.
/// - State: every `stateUpdate` persists the engine serialization for the
///   next launch. Account loss updates `status` and never deletes local data.
/// - Zones: created through pending database changes (`ensureTeamZone`); a
///   deleted zone surfaces through `onZoneDeleted` for the sharing work.
public actor TeamSyncCoordinator: CKSyncEngineDelegate {
    public enum Status: Hashable, Sendable {
        case idle
        case syncing
        case unavailable(String)
        case attentionNeeded(String)
    }

    /// Container factory, evaluated only in `start()`. Merely constructing a
    /// `CKContainer` traps where no CloudKit environment exists, so tests
    /// (and offline composition) must be able to hold a coordinator without
    /// ever evaluating it.
    private let makeContainer: @Sendable () -> CKContainer
    private let outboxes: [SyncDatabase: SyncOutbox]
    private let stateStores: [SyncDatabase: EngineStateStore]
    private let inbox: SyncInbox
    private var engines: [SyncDatabase: CKSyncEngine] = [:]

    public private(set) var status: Status = .idle
    /// Called on the coordinator's executor with freshly fetched changes.
    /// The default archives nothing extra: fetches are already in the inbox.
    private var onIncoming: (@Sendable ([IncomingChange]) -> Void)?
    private var onZoneDeleted: (@Sendable (SyncDatabase, CKRecordZone.ID) -> Void)?
    private var onStatusChange: (@Sendable (Status) -> Void)?

    public func setIncomingHandler(_ handler: (@Sendable ([IncomingChange]) -> Void)?) {
        onIncoming = handler
    }

    public func setZoneDeletedHandler(
        _ handler: (@Sendable (SyncDatabase, CKRecordZone.ID) -> Void)?
    ) {
        onZoneDeleted = handler
    }

    public func setStatusHandler(_ handler: (@Sendable (Status) -> Void)?) {
        onStatusChange = handler
    }

    public init(
        makeContainer: @Sendable @escaping () -> CKContainer,
        outboxes: [SyncDatabase: SyncOutbox],
        stateStores: [SyncDatabase: EngineStateStore], inbox: SyncInbox
    ) {
        self.makeContainer = makeContainer
        self.outboxes = outboxes
        self.stateStores = stateStores
        self.inbox = inbox
    }

    private func setStatus(_ status: Status) {
        self.status = status
        onStatusChange?(status)
    }

    private func database(for scope: SyncDatabase, in container: CKContainer) -> CKDatabase {
        switch scope {
        case .private: container.privateCloudDatabase
        case .shared: container.sharedCloudDatabase
        }
    }

    private func scope(of engine: CKSyncEngine) -> SyncDatabase? {
        if engine === engines[.private] { return .private }
        if engine === engines[.shared] { return .shared }
        return nil
    }

    /// Creates both engines (idempotent) and performs an initial fetch.
    /// Safe to call while offline: the engines simply report errors through
    /// events and the outbox keeps everything staged.
    public func start() async {
        let container = makeContainer()
        for scope in [SyncDatabase.private, .shared] as [SyncDatabase] {
            if engines[scope] == nil {
                let configuration = CKSyncEngine.Configuration(
                    database: database(for: scope, in: container),
                    stateSerialization: stateStores[scope]?.load(),
                    delegate: self)
                engines[scope] = CKSyncEngine(configuration)
            }
        }
        await fetchNow()
    }

    public func fetchNow() async {
        for engine in engines.values {
            try? await engine.fetchChanges()
        }
    }

    public func sendNow() async {
        for engine in engines.values {
            try? await engine.sendChanges()
        }
    }

    /// Stages a record save durably, then tells the engine new work exists.
    public func stageSave(_ record: CKRecord, in scope: SyncDatabase) async throws {
        guard let outbox = outboxes[scope] else { return }
        try await outbox.stageSave(record)
        engines[scope]?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        await sendNow()
    }

    public func stageDelete(
        recordID: CKRecord.ID, recordType: String, in scope: SyncDatabase
    ) async throws {
        guard let outbox = outboxes[scope] else { return }
        try await outbox.stageDelete(recordID: recordID, recordType: recordType)
        engines[scope]?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        await sendNow()
    }

    /// Creates the team's custom zone on first share/sync.
    public func ensureTeamZone(_ zone: CKRecordZone, in scope: SyncDatabase) async {
        engines[scope]?.state.add(pendingDatabaseChanges: [.saveZone(zone)])
        await sendNow()
    }

    /// Drains fetched changes through the applier and re-buffers whatever
    /// deferred (parents not local yet). The single consumption point for
    /// the inbox: fetched server state advances in engine serializations,
    /// so only this method may drain.
    public func materialize(with applier: TeamSyncApplier) async -> DrainResult {
        let changes: [IncomingChange]
        do {
            changes = try await inbox.drain()
        } catch {
            return DrainResult(applied: [], deferred: [], failed: [])
        }
        let result = await applier.drain(changes)
        if !result.deferred.isEmpty {
            try? await inbox.append(result.deferred)
        }
        return result
    }

    /// Team zones visible in the shared database, mapped to their owning
    /// team and owner name. Lets the sync service route participant writes
    /// into the sharer's zone instead of a same-named private zone — and
    /// self-heals across devices, since acceptance on any device shows up
    /// here rather than in a local-only pointer.
    public func sharedZoneOwners() async -> [TeamID: String] {
        let zones = (try? await makeContainer().sharedCloudDatabase.allRecordZones()) ?? []
        var owners: [TeamID: String] = [:]
        for zone in zones {
            if let teamID = TeamZone.teamID(forZoneName: zone.zoneID.zoneName) {
                owners[teamID] = zone.zoneID.ownerName
            }
        }
        return owners
    }

    // MARK: - CKSyncEngineDelegate

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let scope = scope(of: engine) else { return nil }
        return await batchForScope(scope)
    }

    /// Batch content without the engine: directly testable, and the single
    /// place where staged intents become wire records.
    func batchForScope(_ scope: SyncDatabase) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let outbox = outboxes[scope] else { return nil }
        do {
            let saves = try await outbox.stagedSaves.asyncMap { try await outbox.unarchive($0) }
            let deletes = await outbox.stagedDeletes.map {
                CKRecord.ID(
                    recordName: $0.recordName,
                    zoneID: CKRecordZone.ID(zoneName: $0.zoneName, ownerName: $0.ownerName))
            }
            guard !saves.isEmpty || !deletes.isEmpty else { return nil }
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: saves, recordIDsToDelete: deletes)
        } catch {
            setStatus(
                .attentionNeeded(
                    "A staged sync change could not be read. Your matches are safe on this device."))
            return nil
        }
    }

    public func handleEvent(
        _ event: CKSyncEngine.Event, syncEngine engine: CKSyncEngine
    ) async {
        let scope: SyncDatabase = scope(of: engine) ?? .private
        switch event {
        case .stateUpdate(let update):
            applyStateUpdate(update.stateSerialization, for: scope)
        case .accountChange(let change):
            applyAccountChange(change.changeType)
            await fetchNow()
        case .fetchedRecordZoneChanges(let fetched):
            await applyFetched(
                saved: fetched.modifications.map(\.record),
                deleted: fetched.deletions.map { ($0.recordID, $0.recordType) },
                scope: scope)
        case .sentRecordZoneChanges(let sent):
            await applySent(
                saved: sent.savedRecords, deleted: sent.deletedRecordIDs, scope: scope)
        case .sentDatabaseChanges(let sent):
            if !sent.failedZoneSaves.isEmpty {
                setStatus(
                    .attentionNeeded(
                        "A team sync zone could not be created. Your matches stay on this device."))
            }
        case .fetchedDatabaseChanges(let fetched):
            for deletion in fetched.deletions
            where deletion.zoneID.zoneName.hasPrefix("team_") {
                onZoneDeleted?(scope, deletion.zoneID)
            }
        case .willSendChanges, .willFetchChanges, .willFetchRecordZoneChanges:
            setStatus(.syncing)
        case .didSendChanges, .didFetchChanges, .didFetchRecordZoneChanges:
            if case .syncing = status { setStatus(.idle) }
        @unknown default:
            break
        }
    }

    func applyStateUpdate(
        _ serialization: CKSyncEngine.State.Serialization, for scope: SyncDatabase
    ) {
        try? stateStores[scope]?.save(serialization)
    }

    func applyAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch change {
        case .signIn:
            setStatus(.idle)
        case .signOut, .switchAccounts:
            // Local scoring data is never touched by account events.
            setStatus(
                .attentionNeeded(
                    "The iCloud account changed. Your matches stay on this device."))
        @unknown default:
            setStatus(
                .attentionNeeded(
                    "The iCloud account changed. Your matches stay on this device."))
        }
    }

    func applyFetched(
        saved: [CKRecord], deleted: [(CKRecord.ID, String)], scope: SyncDatabase
    ) async {
        var incoming: [IncomingChange] = []
        for record in saved {
            incoming.append(
                IncomingChange(
                    database: scope, zoneName: record.recordID.zoneID.zoneName,
                    ownerName: record.recordID.zoneID.ownerName,
                    recordName: record.recordID.recordName, recordType: record.recordType,
                    archivedRecord: try? NSKeyedArchiver.archivedData(
                        withRootObject: record, requiringSecureCoding: true),
                    deleted: false))
        }
        for (id, recordType) in deleted {
            incoming.append(
                IncomingChange(
                    database: scope, zoneName: id.zoneID.zoneName,
                    ownerName: id.zoneID.ownerName,
                    recordName: id.recordName, recordType: recordType,
                    archivedRecord: nil, deleted: true))
        }
        try? await inbox.append(incoming)
        onIncoming?(incoming)
    }

    func applySent(saved: [CKRecord], deleted: [CKRecord.ID], scope: SyncDatabase) async {
        let confirmed = Set(
            saved.map(\.recordID.recordName) + deleted.map(\.recordName))
        try? await outboxes[scope]?.removeStaged(recordNames: confirmed)
    }
}

extension TeamSyncCoordinator {
    /// Availability gate for composition: with no iCloud account there are
    /// no engines, no polling, and no errors — staging still works, local
    /// scoring is unaffected.
    public static func availability(
        in container: CKContainer
    ) async -> Status {
        do {
            switch try await container.accountStatus() {
            case .available: return .idle
            case .noAccount:
                return .unavailable("Sign in to iCloud to share teams. Local scoring is unaffected.")
            case .restricted:
                return .unavailable("iCloud is restricted on this device. Local scoring is unaffected.")
            case .couldNotDetermine:
                return .unavailable("iCloud status is unknown. Local scoring is unaffected.")
            case .temporarilyUnavailable:
                return .unavailable("iCloud is temporarily unavailable. Local scoring is unaffected.")
            @unknown default:
                return .unavailable("iCloud is unavailable. Local scoring is unaffected.")
            }
        } catch {
            return .unavailable("iCloud could not be reached. Local scoring is unaffected.")
        }
    }
}

extension Array {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { try await result.append(transform(element)) }
        return result
    }
}
