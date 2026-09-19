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

    @discardableResult
    public func apply(_ change: IncomingChange) async throws -> AppliedChange {
        if change.deleted { return try await applyDeletion(change) }
        return try await applySave(change)
    }

    /// Drains buffered inbox changes in dependency order
    /// (Team → Season → Player → Match → Event) so a single fetch carrying a
    /// whole workspace materializes parents before children. Returns applied
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
        for change in Self.ordered(changes) {
            do {
                let outcome = try await apply(change)
                applied.append(outcome)
                if case .deferred = outcome { deferred.append(change) }
            } catch {
                failed.append((change, error))
            }
        }
        return DrainResult(applied: applied, deferred: deferred, failed: failed)
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
        case EventRecord.recordType:
            guard let incoming = EventRecord(record: archived) else {
                throw SyncApplyError.undecodable(
                    recordName: change.recordName, recordType: change.recordType)
            }
            return try await applyEvent(incoming, teamID: teamID)
        default:
            // Unknown future record types wait for their own applier.
            return .ignored
        }
    }

    /// Events remain truth for statistics, but they still need their match:
    /// an event whose match has not materialized yet defers like any other
    /// child record instead of failing the drain.
    private func applyEvent(_ incoming: EventRecord, teamID: TeamID) async throws -> AppliedChange {
        guard try await journal.matchExists(incoming.matchID, inTeam: teamID) else { return .deferred }
        let local = try await journal.readEvents(for: incoming.matchID).first { $0.id == incoming.event.id }
        guard let local else {
            try await journal.writeEffects([.appendEvent(incoming.event)], to: incoming.matchID)
            return .applied(incoming.event.id)
        }
        switch EventMerge.reconcile(local: local, remote: incoming.event) {
        case .takeRemote(let event):
            try await journal.writeEffects([.replaceEvent(event)], to: incoming.matchID)
            return .applied(event.id)
        case .keepLocal:
            return .keptLocal(local.id)
        case .conflict(let localEvent, let remoteEvent):
            try await conflicts.report(
                TeamConflict(
                    teamID: teamID,
                    matchID: incoming.matchID, eventID: localEvent.id,
                    zoneName: TeamZone.zoneName(for: teamID),
                    localRevision: localEvent.revision, remoteRevision: remoteEvent.revision,
                    receivedAt: Date()))
            return .conflict(localEvent.id)
        }
    }

    // MARK: - Deletions

    /// Only event deletions materialize. A remote event deletion is a
    /// descope: the local event is voided, never removed, so history stays
    /// complete and derived statistics stay
    /// recomputable. Structural deletions (team, season, player, match) are
    /// ignored: removing shared structure is an explicit local action, never
    /// a sync side effect. A revoked share arrives as a zone deletion
    /// through the coordinator, not as record tombstones. The tombstone
    /// carries a strictly newer revision than whatever it supersedes, so
    /// both sides converge on voided through the normal merge rule without
    /// wall-clock comparisons.
    private func applyDeletion(_ change: IncomingChange) async throws -> AppliedChange {
        guard change.recordType == EventRecord.recordType else { return .ignored }
        guard let teamID = TeamZone.teamID(forZoneName: change.zoneName),
            let eventUUID = TeamZone.uuid(fromRecordName: change.recordName, prefix: "event")
        else { return .ignored }
        let eventID = EventID(eventUUID)
        guard let matchID = try await journal.locateEvent(eventID, inTeam: teamID) else {
            // Already absent locally (or never received). Idempotent no-op.
            return .ignored
        }
        let local = try await journal.readEvents(for: matchID).first { $0.id == eventID }
        guard var local, local.isActive else { return .keptLocal(eventID) }
        local = local.appendingRevision(kind: .voided, summary: "Removed by a collaborator", at: Date())
        local.voidedAt = Date()
        try await journal.writeEffects([.replaceEvent(local)], to: matchID)
        return .voided(eventID)
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
