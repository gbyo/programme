import CloudKit
import Foundation
import ProgrammeCore

/// Materializes fetched sync changes into the local event journal.
///
/// The applier is the only path by which remote records become local events.
/// It never edits or deletes anything on the server; it only reads fetched
/// records, reconciles them against local event truth through
/// `EventMerge`, and writes `MatchEffect`s through a `SyncJournal`. Derived
/// statistics are never merged and never written here — after effects land,
/// everything re-derives through StatEngine from event truth exactly as if
/// the local scorer had recorded them.
///
/// Every outcome is idempotent: re-applying an already-materialized change
/// reconciles to `.keptLocal` or `.ignored`, never to a duplicate event.
public struct TeamSyncApplier: Sendable {
    private let journal: any SyncJournal
    private let conflicts: any ConflictSink

    public init(journal: any SyncJournal, conflicts: any ConflictSink) {
        self.journal = journal
        self.conflicts = conflicts
    }

    /// Materializes one fetched change. Outcomes match `drain([change])`;
    /// corrupt input throws instead of landing in `failed`.
    @discardableResult
    public func apply(_ change: IncomingChange) async throws -> AppliedChange {
        let result = await drain([change])
        if let failure = result.failed.first { throw failure.error }
        return result.applied.first ?? .ignored
    }

    /// Drains buffered inbox changes in dependency order
    /// (Team → Season → Player → Match → Event) so a single fetch carrying a
    /// whole workspace materializes parents before children. Event saves and
    /// deletions group by match: local event state loads once per match,
    /// records reconcile sequentially in memory, and accepted effects
    /// persist in one journal write per match — one logical invalidation
    /// however many remote events the match carried. Returns applied
    /// outcomes alongside changes that could not materialize yet:
    /// - `deferred`: the parent is not local yet (it may arrive in a later
    ///   fetch). The caller re-buffers these; they are never dropped.
    /// - `failed`: the record is corrupt and can never materialize.
    ///   The caller surfaces the error and drops the change rather than
    ///   retrying it forever.
    public func drain(_ changes: [IncomingChange]) async -> DrainResult {
        var applied: [AppliedChange] = []
        var deferred: [IncomingChange] = []
        var failed: [(change: IncomingChange, error: Error)] = []
        var batches = EventBatches()
        for change in Self.ordered(changes) {
            if change.deleted {
                await drainDeletion(
                    change, batches: &batches, applied: &applied, failed: &failed)
            } else if change.recordType == EventRecord.recordType {
                await drainEventSave(
                    change, batches: &batches, applied: &applied, deferred: &deferred,
                    failed: &failed)
            } else {
                do {
                    let outcome = try await applySave(change)
                    applied.append(outcome)
                    if case .deferred = outcome { deferred.append(change) }
                } catch {
                    failed.append((change, error))
                }
            }
        }
        // One persist and one observer invalidation per touched match. A
        // flush failure converts only that match's write outcomes back to
        // deferred so they retry later; outcomes that wrote nothing stand.
        for matchID in batches.order {
            guard let batch = batches.batches[matchID], !batch.effects.isEmpty else { continue }
            do {
                try await journal.writeEffects(batch.effects, to: matchID)
            } catch {
                for written in batch.written {
                    applied[written.slot] = .deferred
                    deferred.append(written.change)
                }
            }
        }
        return DrainResult(applied: applied, deferred: deferred, failed: failed)
    }

    /// In-memory write batch for one match: the evolving local event list,
    /// the accumulated effects flushed once, and the `applied` slots holding
    /// write outcomes for flush-failure conversion.
    private final class EventBatch {
        var events: [MatchEvent]
        var effects: [MatchEffect] = []
        var written: [(slot: Int, change: IncomingChange)] = []

        init(events: [MatchEvent]) { self.events = events }
    }

    private struct EventBatches {
        var batches: [MatchID: EventBatch] = [:]
        var order: [MatchID] = []
    }

    /// The batch for a match, loading local event state once. Saves defer
    /// when the match is not local yet; structural records sort before
    /// events, so parents materialized earlier in the same drain are
    /// already visible here.
    private func batch(
        for matchID: MatchID, teamID: TeamID, batches: inout EventBatches
    ) async throws -> EventBatch? {
        if let existing = batches.batches[matchID] { return existing }
        guard try await journal.matchExists(matchID, inTeam: teamID) else { return nil }
        return try await openBatch(for: matchID, batches: &batches)
    }

    /// The batch for a match without the existence check. Deletions void
    /// whatever the locator found even when the match record itself has not
    /// materialized, exactly as the single-event path always has.
    private func openBatch(
        for matchID: MatchID, batches: inout EventBatches
    ) async throws -> EventBatch {
        if let existing = batches.batches[matchID] { return existing }
        let fresh = EventBatch(events: try await journal.readEvents(for: matchID))
        batches.batches[matchID] = fresh
        batches.order.append(matchID)
        return fresh
    }

    private func drainEventSave(
        _ change: IncomingChange, batches: inout EventBatches, applied: inout [AppliedChange],
        deferred: inout [IncomingChange], failed: inout [(change: IncomingChange, error: Error)]
    ) async {
        guard let teamID = TeamZone.teamID(forZoneName: change.zoneName) else {
            applied.append(.ignored)
            return
        }
        guard let data = change.archivedRecord else {
            failed.append((change, SyncApplyError.missingPayload(recordName: change.recordName)))
            return
        }
        guard
            let archived = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data),
            let incoming = EventRecord(record: archived)
        else {
            failed.append(
                (
                    change,
                    SyncApplyError.undecodable(
                        recordName: change.recordName, recordType: change.recordType)
                ))
            return
        }
        do {
            guard let batch = try await batch(for: incoming.matchID, teamID: teamID, batches: &batches)
            else {
                applied.append(.deferred)
                deferred.append(change)
                return
            }
            if let index = batch.events.firstIndex(where: { $0.id == incoming.event.id }) {
                switch EventMerge.reconcile(local: batch.events[index], remote: incoming.event) {
                case .takeRemote(let event):
                    batch.events[index] = event
                    batch.effects.append(.replaceEvent(event))
                    applied.append(.applied(event.id))
                    batch.written.append((slot: applied.count - 1, change: change))
                case .keepLocal:
                    applied.append(.keptLocal(incoming.event.id))
                case .conflict(let localEvent, let remoteEvent):
                    try await conflicts.report(
                        TeamConflict(
                            teamID: teamID,
                            matchID: incoming.matchID, eventID: localEvent.id,
                            zoneName: TeamZone.zoneName(for: teamID),
                            localRevision: localEvent.revision, remoteRevision: remoteEvent.revision,
                            receivedAt: Date()))
                    applied.append(.conflict(localEvent.id))
                }
            } else {
                batch.events.append(incoming.event)
                batch.effects.append(.appendEvent(incoming.event))
                applied.append(.applied(incoming.event.id))
                batch.written.append((slot: applied.count - 1, change: change))
            }
        } catch {
            failed.append((change, error))
        }
    }

    /// Remote event deletions descope into the match batch: the local event
    /// is voided, never removed, so history stays complete. Structural
    /// deletions stay ignored; revocations arrive as zone deletions, never
    /// tombstones.
    private func drainDeletion(
        _ change: IncomingChange, batches: inout EventBatches, applied: inout [AppliedChange],
        failed: inout [(change: IncomingChange, error: Error)]
    ) async {
        guard change.recordType == EventRecord.recordType,
            let teamID = TeamZone.teamID(forZoneName: change.zoneName),
            let eventUUID = TeamZone.uuid(fromRecordName: change.recordName, prefix: "event")
        else {
            applied.append(.ignored)
            return
        }
        let eventID = EventID(eventUUID)
        do {
            // Pending appends from earlier in this drain are visible too, so
            // a save and a deletion of the same event converge in order.
            let snapshot = batches.batches
            let pending = batches.order.lazy.compactMap { matchID -> MatchID? in
                guard
                    let batch = snapshot[matchID],
                    batch.events.contains(where: { $0.id == eventID })
                else { return nil }
                return matchID
            }.first
            let matchID: MatchID?
            if let pending {
                matchID = pending
            } else {
                matchID = try await journal.locateEvent(eventID, inTeam: teamID)
            }
            guard let matchID else {
                applied.append(.ignored)
                return
            }
            let batch = try await openBatch(for: matchID, batches: &batches)
            guard var local = batch.events.first(where: { $0.id == eventID }), local.isActive else {
                applied.append(.keptLocal(eventID))
                return
            }
            local = local.appendingRevision(kind: .voided, summary: "Removed by a collaborator", at: Date())
            local.voidedAt = Date()
            if let index = batch.events.firstIndex(where: { $0.id == eventID }) {
                batch.events[index] = local
            }
            batch.effects.append(.replaceEvent(local))
            applied.append(.voided(eventID))
            batch.written.append((slot: applied.count - 1, change: change))
        } catch {
            failed.append((change, error))
        }
    }

    private static func ordered(_ changes: [IncomingChange]) -> [IncomingChange] {
        let rank: [String: Int] = [
            TeamRecord.recordType: 0,
            SeasonRecord.recordType: 1,
            PlayerRecord.recordType: 2,
            MatchRecord.recordType: 3,
            EventRecord.recordType: 4,
        ]
        return changes.enumerated().sorted { lhs, rhs in
            let lRank = rank[lhs.element.recordType] ?? 5
            let rRank = rank[rhs.element.recordType] ?? 5
            if lRank != rRank { return lRank < rRank }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Saves

    private func applySave(_ change: IncomingChange) async throws -> AppliedChange {
        // Foreign zones (anything outside the team_ scheme) are not Programme
        // collaboration data. Ignoring them keeps sync robust when the
        // container holds unrelated zones; they are never an error.
        guard let teamID = TeamZone.teamID(forZoneName: change.zoneName) else { return .ignored }
        guard let data = change.archivedRecord else {
            throw SyncApplyError.missingPayload(recordName: change.recordName)
        }
        guard
            let archived = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
        else {
            throw SyncApplyError.undecodable(recordName: change.recordName, recordType: change.recordType)
        }
        switch change.recordType {
        case TeamRecord.recordType:
            guard let team = TeamRecord(record: archived) else {
                throw SyncApplyError.undecodable(
                    recordName: change.recordName, recordType: change.recordType)
            }
            try await journal.ensureTeam(team)
            return .appliedTeam(team.teamID)
        case SeasonRecord.recordType:
            guard let season = SeasonRecord(record: archived) else {
                throw SyncApplyError.undecodable(
                    recordName: change.recordName, recordType: change.recordType)
            }
            guard try await journal.teamExists(season.teamID) else { return .deferred }
            try await journal.ensureSeason(season)
            return .appliedSeason(season.seasonID)
        case PlayerRecord.recordType:
            guard let player = PlayerRecord(record: archived) else {
                throw SyncApplyError.undecodable(
                    recordName: change.recordName, recordType: change.recordType)
            }
            guard try await journal.teamExists(player.teamID) else { return .deferred }
            try await journal.ensurePlayer(player)
            return .appliedPlayer(player.playerID)
        case MatchRecord.recordType:
            guard let match = MatchRecord(record: archived) else {
                throw SyncApplyError.undecodable(
                    recordName: change.recordName, recordType: change.recordType)
            }
            guard try await journal.teamExists(match.descriptor.teamID) else { return .deferred }
            if let seasonID = match.descriptor.seasonID,
                !(try await journal.seasonExists(seasonID, inTeam: match.descriptor.teamID))
            {
                return .deferred
            }
            try await journal.ensureMatch(match)
            return .appliedMatch(match.descriptor.id)
        default:
            // Unknown future record types wait for their own applier.
            return .ignored
        }
    }
}

/// Outcome of materializing one fetched change.
public enum AppliedChange: Hashable, Sendable {
    /// A remote event (or correction) is now local event truth.
    case applied(EventID)
    /// A remote team upserted by stable ID.
    case appliedTeam(TeamID)
    /// A remote season upserted by stable ID.
    case appliedSeason(SeasonID)
    /// A remote player upserted by stable ID.
    case appliedPlayer(PlayerID)
    /// A remote match upserted by stable ID, with its frozen roster/config.
    case appliedMatch(MatchID)
    /// Local truth already stands; nothing was written.
    case keptLocal(EventID)
    /// Same revision, contradictory content. Both versions are preserved and
    /// a `TeamConflict` was reported; nothing was written.
    case conflict(EventID)
    /// A remote deletion became a local void. History is preserved.
    case voided(EventID)
    /// The parent record is not local yet. The caller re-buffers the change;
    /// it is never dropped.
    case deferred
    /// Not Programme data (a foreign zone, an unknown future record type, a
    /// non-event deletion, or an already-absent deletion). Never an error.
    case ignored
}

/// Result of draining a batch of fetched changes. `applied` parallels the
/// drained input in dependency order; `deferred` must be re-buffered by the
/// caller; `failed` pairs a change with the error that made it
/// unmaterializable so the caller can surface it instead of retrying
/// forever.
public struct DrainResult: Sendable {
    public var applied: [AppliedChange]
    public var deferred: [IncomingChange]
    public var failed: [(change: IncomingChange, error: Error)]

    public init(
        applied: [AppliedChange], deferred: [IncomingChange],
        failed: [(change: IncomingChange, error: Error)]
    ) {
        self.applied = applied
        self.deferred = deferred
        self.failed = failed
    }
}

/// Local event-truth surface the applier writes through. Implemented by the
/// persistence layer so ProgrammeCollaboration never depends on SwiftData;
/// trivially faked in tests.
///
/// Implementations must surface written changes to observers (the same
/// notification path local scoring uses) so statistics re-derive. All
/// `ensure` methods are idempotent upserts by stable ID: re-applying a
/// materialized record converges without duplicating it.
public protocol SyncJournal: Sendable {
    func readEvents(for matchID: MatchID) async throws -> [MatchEvent]
    func locateEvent(_ eventID: EventID, inTeam teamID: TeamID) async throws -> MatchID?
    func writeEffects(_ effects: [MatchEffect], to matchID: MatchID) async throws
    func teamExists(_ teamID: TeamID) async throws -> Bool
    func seasonExists(_ seasonID: SeasonID, inTeam teamID: TeamID) async throws -> Bool
    func playerExists(_ playerID: PlayerID, inTeam teamID: TeamID) async throws -> Bool
    func matchExists(_ matchID: MatchID, inTeam teamID: TeamID) async throws -> Bool
    func ensureTeam(_ team: TeamRecord) async throws
    func ensureSeason(_ season: SeasonRecord) async throws
    func ensurePlayer(_ player: PlayerRecord) async throws
    func ensureMatch(_ match: MatchRecord) async throws
}

/// A same-revision contradiction that needs a human. Both versions stay in
/// place (local truth untouched, remote change unapplied) until resolved.
public struct TeamConflict: Codable, Hashable, Sendable, Identifiable {
    public var id: EventID { eventID }
    public var teamID: TeamID
    public var matchID: MatchID
    public var eventID: EventID
    public var zoneName: String
    public var localRevision: Int
    public var remoteRevision: Int
    public var receivedAt: Date

    public init(
        teamID: TeamID, matchID: MatchID, eventID: EventID, zoneName: String,
        localRevision: Int, remoteRevision: Int, receivedAt: Date
    ) {
        self.teamID = teamID
        self.matchID = matchID
        self.eventID = eventID
        self.zoneName = zoneName
        self.localRevision = localRevision
        self.remoteRevision = remoteRevision
        self.receivedAt = receivedAt
    }
}

public protocol ConflictSink: Sendable {
    func report(_ conflict: TeamConflict) async throws
}

/// Strict failures. Corrupt staged data surfaces instead of dropping,
/// matching the outbox contract; foreign or not-yet-handled data is
/// `.ignored`, never an error.
public enum SyncApplyError: Error, Hashable, Sendable {
    case missingPayload(recordName: String)
    case undecodable(recordName: String, recordType: String)
}
