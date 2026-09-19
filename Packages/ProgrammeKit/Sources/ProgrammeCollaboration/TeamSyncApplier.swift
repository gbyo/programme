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

    /// Drains buffered inbox changes in order. Order within one fetch is the
    /// server's delivery order; reconciliation is per-event so replay order
    /// between different events does not affect the result.
    public func drain(_ changes: [IncomingChange]) async throws -> [AppliedChange] {
        var outcomes: [AppliedChange] = []
        outcomes.reserveCapacity(changes.count)
        for change in changes { outcomes.append(try await apply(change)) }
        return outcomes
    }

    // MARK: - Saves

    private func applySave(_ change: IncomingChange) async throws -> AppliedChange {
        // Foreign zones (anything outside the team_ scheme) are not Programme
        // collaboration data. Ignoring them keeps sync robust when the
        // container holds unrelated zones; they are never an error.
        guard TeamZone.teamID(forZoneName: change.zoneName) != nil else { return .ignored }
        // Match and roster materialization is later work. Event truth first:
        // anything that is not an event record waits for its own applier.
        guard change.recordType == EventRecord.recordType else { return .ignored }
        guard let data = change.archivedRecord else {
            throw SyncApplyError.missingPayload(recordName: change.recordName)
        }
        guard let archived = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data),
            let incoming = EventRecord(record: archived)
        else {
            throw SyncApplyError.undecodable(recordName: change.recordName, recordType: change.recordType)
        }
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
                    teamID: TeamZone.teamID(forZoneName: change.zoneName)!,
                    matchID: incoming.matchID, eventID: localEvent.id,
                    zoneName: change.zoneName,
                    localRevision: localEvent.revision, remoteRevision: remoteEvent.revision,
                    receivedAt: Date()))
            return .conflict(localEvent.id)
        }
    }

    // MARK: - Deletions

    /// A remote deletion is a descope: the local event is voided, never
    /// removed, so history stays complete and derived statistics stay
    /// recomputable. The tombstone carries a strictly newer revision than
    /// whatever it supersedes, so both sides converge on voided through the
    /// normal merge rule without wall-clock comparisons.
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
    /// Local truth already stands; nothing was written.
    case keptLocal(EventID)
    /// Same revision, contradictory content. Both versions are preserved and
    /// a `TeamConflict` was reported; nothing was written.
    case conflict(EventID)
    /// A remote deletion became a local void. History is preserved.
    case voided(EventID)
    /// Not Programme event data (foreign zone, match/roster record awaiting
    /// its own applier, or an already-absent deletion). Never an error.
    case ignored
}

/// Local event-truth surface the applier writes through. Implemented by the
/// persistence layer so ProgrammeCollaboration never depends on SwiftData;
/// trivially faked in tests.
///
/// Implementations must surface written changes to observers (the same
/// notification path local scoring uses) so statistics re-derive.
public protocol SyncJournal: Sendable {
    func readEvents(for matchID: MatchID) async throws -> [MatchEvent]
    func locateEvent(_ eventID: EventID, inTeam teamID: TeamID) async throws -> MatchID?
    func writeEffects(_ effects: [MatchEffect], to matchID: MatchID) async throws
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
