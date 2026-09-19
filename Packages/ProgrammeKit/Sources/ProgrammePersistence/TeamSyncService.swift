import CloudKit
import Foundation
import ProgrammeCollaboration
import ProgrammeCore

/// Runs sync production: owns the coordinator, applier, and durable sync
/// stores, stages outbound mutations reported by `MatchStore`, and
/// materializes inbound fetches.
///
/// Lives in Persistence (not Collaboration) because it holds the concrete
/// `MatchStore`: Collaboration never depends on SwiftData, and the service
/// is orchestration over both. CloudKit stays replication, never the
/// live-scoring critical path — when sync is off, broken, or unstarted,
/// every method here is a safe no-op and local truth is untouched.
///
/// The container factory is evaluated only in `start()` and `accept(_:)`,
/// so tests (and iCloud-off launches) can build and exercise record
/// staging without ever touching CloudKit.
public actor TeamSyncService: Sendable {
    /// One staged outbound write: a record save or a record tombstone, with
    /// the database it replicates into.
    public enum StagedChange: Sendable {
        case save(CKRecord, SyncDatabase)
        case delete(CKRecord.ID, String, SyncDatabase)
    }

    public struct MaterializeReport: Sendable {
        public var applied: [AppliedChange]
        public var deferredCount: Int
        public var failedMessages: [String]
        /// A team, season, player, or match arrived: the workspace lists
        /// must reload.
        public var structureChanged: Bool
    }

    private let store: MatchStore
    private let makeContainer: @Sendable () -> CKContainer
    private let coordinator: TeamSyncCoordinator
    private let shareCoordinator: TeamShareCoordinator
    private let applier: TeamSyncApplier
    private let conflicts: TeamConflictStore
    private let owners: SharedZoneOwners
    private var started = false
    private var ensuredZones: Set<String> = []

    /// Called after inbound structure lands so the workspace lists reload.
    /// Event-only changes already fan out through the store's own
    /// change notification.
    public var onWorkspaceChanged: (@Sendable () -> Void)?
    /// Human-readable staging failures (e.g. the outbox directory is
    /// unwritable). Local truth is always safe; the mutation simply did
    /// not stage.
    public var onStagingFailed: (@Sendable (String) -> Void)?

    public func setWorkspaceChangedHandler(_ handler: (@Sendable () -> Void)?) {
        onWorkspaceChanged = handler
    }

    public func setStagingFailedHandler(_ handler: (@Sendable (String) -> Void)?) {
        onStagingFailed = handler
    }

    public init(store: MatchStore, directory: URL, makeContainer: @Sendable @escaping () -> CKContainer) throws {
        self.store = store
        self.makeContainer = makeContainer
        let outboxes = try [
            SyncDatabase.private: SyncOutbox(url: directory.appendingPathComponent("outbox-private.json")),
            SyncDatabase.shared: SyncOutbox(url: directory.appendingPathComponent("outbox-shared.json")),
        ]
        let states = [
            SyncDatabase.private: EngineStateStore(
                url: directory.appendingPathComponent("engine-state-private.json")),
            SyncDatabase.shared: EngineStateStore(
                url: directory.appendingPathComponent("engine-state-shared.json")),
        ]
        let inbox = try SyncInbox(url: directory.appendingPathComponent("inbox.json"))
        let conflicts = try TeamConflictStore(
            url: directory.appendingPathComponent("conflicts.json"))
        self.conflicts = conflicts
        self.owners = try SharedZoneOwners(
            url: directory.appendingPathComponent("shared-zone-owners.json"))
        self.coordinator = TeamSyncCoordinator(
            makeContainer: makeContainer, outboxes: outboxes, stateStores: states, inbox: inbox)
        self.shareCoordinator = TeamShareCoordinator(
            makeContainer: makeContainer,
            sharedZones: try SharedZoneStore(
                url: directory.appendingPathComponent("shared-zones.json")))
        self.applier = TeamSyncApplier(journal: store, conflicts: conflicts)
    }

    // MARK: - Lifecycle

    /// Starts both engines and ensures private zones for local teams.
    /// Idempotent. Safe offline: engines report through status events and
    /// the outbox keeps everything staged.
    public func start() async {
        guard !started else { return }
        started = true
        await coordinator.setIncomingHandler { [weak self] _ in
            Task { await self?.materialize() }
        }
        await coordinator.setZoneDeletedHandler { [weak self] _, _ in
            Task { await self?.zoneDeleted() }
        }
        for team in (try? await store.teams()) ?? [] {
            await ensureZone(for: team.id)
        }
        await coordinator.start()
    }

    /// Accepts an invitation, then refreshes accepted-zone routing so
    /// participant writes land in the sharer's zone.
    public func accept(_ metadata: CKShare.Metadata) async throws {
        try await shareCoordinator.accept(metadata)
        await refreshOwners()
    }

    /// The engines' current status for lightweight UI state. `.idle` before
    /// `start()` (sync is inert, local truth authoritative as always).
    public func engineStatus() async -> TeamSyncCoordinator.Status {
        guard started else { return .idle }
        return await coordinator.status
    }

    /// Teams visible in the shared database mapped to their zone owner
    /// names. Lets share resolution distinguish teams this device owns
    /// (private database) from teams shared with it — without inventing
    /// another ownership store.
    public func sharedZoneOwners() async -> [TeamID: String] {
        await coordinator.sharedZoneOwners()
    }

    /// Unresolved same-revision contradictions for a team, oldest first.
    /// Readable offline: conflicts are local records, not CloudKit state.
    public func unresolvedConflicts(teamID: TeamID) async -> [TeamConflict] {
        await conflicts.unresolved(teamID: teamID)
    }

    /// Keeps the local version and drops the review entry. The local event
    /// already stands (nothing was ever overwritten); editing the event
    /// instead supersedes the remote version everywhere with a newer
    /// revision.
    public func resolveConflict(eventID: EventID, inTeam teamID: TeamID) async throws {
        try await conflicts.resolve(eventID, inTeam: teamID)
    }

    // MARK: - Outbound

    /// Stages one local mutation for replication. No-op before `start()`.
    /// Reads current values back from the store, so what replicates is
    /// always the post-write state; mutations for missing rows stage
    /// nothing.
    public func stage(_ mutation: OutboundMutation) async {
        guard started else { return }
        await ensureZoneIfNeeded(for: mutation)
        for change in await stagedChanges(for: mutation) {
            switch change {
            case .save(let record, let scope):
                do { try await coordinator.stageSave(record, in: scope) } catch {
                    onStagingFailed?(
                        "A change could not be staged for sync. Your matches are safe on this device.")
                }
            case .delete(let id, let recordType, let scope):
                do { try await coordinator.stageDelete(recordID: id, recordType: recordType, in: scope) } catch {
                    onStagingFailed?(
                        "A deletion could not be staged for sync. Your matches are safe on this device.")
                }
            }
        }
    }

    /// Pure record building for a mutation: no engines, no container, no
    /// network. The offline-testable core of outbound staging.
    func stagedChanges(for mutation: OutboundMutation) async -> [StagedChange] {
        switch mutation {
        case .events(let matchID, let eventIDs):
            guard let context = try? await store.context(for: matchID) else { return [] }
            let zone = await zone(for: context.descriptor.teamID)
            let wanted = Set(eventIDs)
            return context.events.filter { wanted.contains($0.id) }.map {
                .save(EventRecord(event: $0, matchID: matchID).makeRecord(in: zone.id), zone.scope)
            }
        case .match(let matchID):
            guard let context = try? await store.context(for: matchID) else { return [] }
            let zone = await zone(for: context.descriptor.teamID)
            let record = MatchRecord(
                descriptor: context.descriptor, phase: context.phase,
                finalizedAt: context.finalizedAt, roster: context.roster,
                opponentRoster: context.opponentRoster, clockPeriod: context.clock.period,
                clockElapsed: context.clock.elapsedAtAnchor,
                clockRunningSince: context.clock.runningSince)
            return [.save(record.makeRecord(in: zone.id), zone.scope)]
        case .team(let teamID):
            guard let team = try? await store.teamRecord(for: teamID) else { return [] }
            let zone = await zone(for: teamID)
            return [.save(team.makeRecord(in: zone.id), zone.scope)]
        case .season(let teamID, let seasonID):
            guard let item = try? await store.seasons(teamID: teamID),
                let season = item.first(where: { $0.id == seasonID })
            else { return [] }
            let zone = await zone(for: teamID)
            let record = SeasonRecord(
                seasonID: seasonID, teamID: teamID, name: season.name,
                startDate: season.startDate, endDate: season.endDate, isCurrent: season.isCurrent)
            return [.save(record.makeRecord(in: zone.id), zone.scope)]
        case .players(let teamID, let playerIDs):
            guard let roster = try? await store.roster(teamID: teamID, includeFormer: true) else {
                return []
            }
            let zone = await zone(for: teamID)
            let wanted = Set(playerIDs)
            return roster.players.filter { wanted.contains($0.id) }.map {
                .save(PlayerRecord(playerID: $0.id, teamID: teamID, snapshot: $0).makeRecord(in: zone.id), zone.scope)
            }
        case .deletedMatch(let matchID, let teamID, let eventIDs):
            let zone = await zone(for: teamID)
            var changes: [StagedChange] = [
                .delete(
                    CKRecord.ID(
                        recordName: TeamZone.recordName(prefix: "match", id: matchID.rawValue),
                        zoneID: zone.id),
                    MatchRecord.recordType, zone.scope)
            ]
            changes += eventIDs.map {
                .delete(
                    CKRecord.ID(
                        recordName: TeamZone.recordName(prefix: "event", id: $0.rawValue),
                        zoneID: zone.id),
                    EventRecord.recordType, zone.scope)
            }
            return changes
        case .deletedPlayers(let teamID, let playerIDs):
            let zone = await zone(for: teamID)
            return playerIDs.map {
                .delete(
                    CKRecord.ID(
                        recordName: TeamZone.recordName(prefix: "player", id: $0.rawValue),
                        zoneID: zone.id),
                    PlayerRecord.recordType, zone.scope)
            }
        }
    }

    // MARK: - Inbound

    /// Drains fetched changes through the applier. Structural arrivals
    /// trigger the workspace callback; failures are reported as messages
    /// (the caller surfaces them; corrupt changes are dropped, deferred
    /// ones are already re-buffered by the coordinator).
    @discardableResult
    public func materialize() async -> MaterializeReport {
        guard started else {
            return MaterializeReport(applied: [], deferredCount: 0, failedMessages: [], structureChanged: false)
        }
        let result = await coordinator.materialize(with: applier)
        let structureChanged = result.applied.contains {
            switch $0 {
            case .appliedTeam, .appliedSeason, .appliedPlayer, .appliedMatch: return true
            default: return false
            }
        }
        if structureChanged { onWorkspaceChanged?() }
        return MaterializeReport(
            applied: result.applied, deferredCount: result.deferred.count,
            failedMessages: result.failed.map {
                "\($0.change.recordType) \($0.change.recordName): \($0.error.localizedDescription)"
            },
            structureChanged: structureChanged)
    }

    // MARK: - Zones and routing

    private struct Zone: Sendable {
        var id: CKRecordZone.ID
        var scope: SyncDatabase
    }

    /// Owner writes replicate into the private database; participant writes
    /// into the sharer's zone in the shared database.
    private func zone(for teamID: TeamID) async -> Zone {
        if let owner = await owners.ownerName(for: teamID) {
            return Zone(
                id: CKRecordZone.ID(zoneName: TeamZone.zoneName(for: teamID), ownerName: owner),
                scope: .shared)
        }
        return Zone(id: TeamZone.zoneID(for: teamID), scope: .private)
    }

    private func ensureZoneIfNeeded(for mutation: OutboundMutation) async {
        let teamID: TeamID? =
            switch mutation {
            case .events(let matchID, _):
                try? await store.teamID(forMatch: matchID)
            case .match(let matchID):
                try? await store.teamID(forMatch: matchID)
            case .team(let id): id
            case .season(let id, _): id
            case .players(let id, _): id
            case .deletedMatch(_, let id, _): id
            case .deletedPlayers(let id, _): id
            }
        guard let teamID, await owners.ownerName(for: teamID) == nil else { return }
        await ensureZone(for: teamID)
    }

    private func ensureZone(for teamID: TeamID) async {
        let name = TeamZone.zoneName(for: teamID)
        guard !ensuredZones.contains(name) else { return }
        ensuredZones.insert(name)
        await coordinator.ensureTeamZone(CKRecordZone(zoneID: TeamZone.zoneID(for: teamID)), in: .private)
    }

    private func refreshOwners() async {
        await owners.remember(await coordinator.sharedZoneOwners())
    }

    private func zoneDeleted() async {
        await refreshOwners()
        onWorkspaceChanged?()
    }
}

/// Which accepted-share zones route to the shared database, by owner name.
/// Owner teams have no entry and stay on the private database. Refreshed
/// from the shared database's zone list (so acceptance on any device
/// heals routing here); revoked shares disappear on the next refresh or
/// zone-deletion event.
public actor SharedZoneOwners: Sendable {
    private let url: URL
    /// Owner zone names by team UUID string. Keyed by string because
    /// `TypedID` encodes as a single value, which JSON cannot use as a
    /// dictionary key.
    private var owners: [String: String]

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            owners = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        } else {
            owners = [:]
        }
    }

    public func ownerName(for teamID: TeamID) -> String? { owners[teamID.rawValue.uuidString] }

    public func remember(_ owners: [TeamID: String]) {
        for (teamID, owner) in owners { self.owners[teamID.rawValue.uuidString] = owner }
        try? persist()
    }

    public func forget(teamID: TeamID) {
        owners.removeValue(forKey: teamID.rawValue.uuidString)
        try? persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try JSONEncoder().encode(owners).write(to: url, options: .atomic)
    }
}
