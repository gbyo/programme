import CloudKit
import Foundation
import Testing

@testable import ProgrammeCollaboration
@testable import ProgrammeCore

/// In-memory event truth for applier tests. Applies effects the way the
/// real journal does (append inserts, replace upserts by ID) without any
/// database.
private actor FakeJournal: SyncJournal {
    var eventsByMatch: [MatchID: [MatchEvent]] = [:]
    var notified: [MatchID] = []

    func seed(_ events: [MatchEvent], for matchID: MatchID) {
        eventsByMatch[matchID] = events
    }

    func readEvents(for matchID: MatchID) throws -> [MatchEvent] {
        eventsByMatch[matchID] ?? []
    }

    func locateEvent(_ eventID: EventID, inTeam teamID: TeamID) throws -> MatchID? {
        for (matchID, events) in eventsByMatch where events.contains(where: { $0.id == eventID }) {
            _ = teamID
            return matchID
        }
        return nil
    }

    func writeEffects(_ effects: [MatchEffect], to matchID: MatchID) throws {
        var events = eventsByMatch[matchID] ?? []
        for effect in effects {
            switch effect {
            case .appendEvent(let event):
                if !events.contains(where: { $0.id == event.id }) { events.append(event) }
            case .replaceEvent(let event):
                if let index = events.firstIndex(where: { $0.id == event.id }) {
                    events[index] = event
                } else {
                    events.append(event)
                }
            default: break
            }
        }
        eventsByMatch[matchID] = events
        notified.append(matchID)
    }
}

private actor FakeConflicts: ConflictSink {
    var reported: [TeamConflict] = []
    func report(_ conflict: TeamConflict) throws { reported.append(conflict) }
}

@Suite("Incoming changes materialize into event truth")
struct SyncApplierTests {
    private let teamID = TeamID(ProgrammeSample.id("team.ninety-six"))
    private let matchID = MatchID(ProgrammeSample.id("match.dixie"))

    private func zone() -> CKRecordZone.ID { TeamZone.zoneID(for: teamID) }

    private func event(id: String, revision: Int, note: String?) -> MatchEvent {
        MatchEvent(
            id: EventID(ProgrammeSample.id(id)), matchID: matchID,
            time: .kickoff, sequence: 1,
            payload: .periodStarted(period: 1), revision: revision, note: note)
    }

    private func save(_ event: MatchEvent, in zoneID: CKRecordZone.ID? = nil) throws -> IncomingChange {
        let zoneID = zoneID ?? zone()
        let record = EventRecord(event: event, matchID: event.matchID).makeRecord(in: zoneID)
        return IncomingChange(
            database: .private, zoneName: zoneID.zoneName, ownerName: zoneID.ownerName,
            recordName: record.recordID.recordName, recordType: record.recordType,
            archivedRecord: try NSKeyedArchiver.archivedData(
                withRootObject: record, requiringSecureCoding: true),
            deleted: false)
    }

    private func deletion(_ eventID: EventID) -> IncomingChange {
        let zoneID = zone()
        return IncomingChange(
            database: .private, zoneName: zoneID.zoneName, ownerName: zoneID.ownerName,
            recordName: TeamZone.recordName(prefix: "event", id: eventID.rawValue),
            recordType: EventRecord.recordType, archivedRecord: nil, deleted: true)
    }

    @Test("A new remote event appends to the journal")
    func newEventAppends() async throws {
        let journal = FakeJournal()
        let applier = TeamSyncApplier(journal: journal, conflicts: FakeConflicts())
        let outcome = try await applier.apply(try save(event(id: "event.1", revision: 1, note: nil)))
        #expect(outcome == .applied(EventID(ProgrammeSample.id("event.1"))))
        #expect(await journal.eventsByMatch[matchID]?.count == 1)
        #expect(await journal.notified == [matchID])
    }

    @Test("A higher-revision correction replaces; a lower one is ignored")
    func revisionDecides() async throws {
        let journal = FakeJournal()
        await journal.seed([event(id: "event.1", revision: 2, note: "Local")], for: matchID)
        let applier = TeamSyncApplier(journal: journal, conflicts: FakeConflicts())

        let newer = try await applier.apply(
            try save(event(id: "event.1", revision: 3, note: "Corrected")))
        #expect(newer == .applied(EventID(ProgrammeSample.id("event.1"))))
        let stored = try #require(await journal.eventsByMatch[matchID]?.first)
        #expect(stored.revision == 3 && stored.note == "Corrected")

        let older = try await applier.apply(
            try save(event(id: "event.1", revision: 1, note: "Stale")))
        #expect(older == .keptLocal(EventID(ProgrammeSample.id("event.1"))))
        #expect(try #require(await journal.eventsByMatch[matchID]?.first).revision == 3)
    }

    @Test("Re-applying the same change is idempotent")
    func replayIsIdempotent() async throws {
        let journal = FakeJournal()
        let applier = TeamSyncApplier(journal: journal, conflicts: FakeConflicts())
        let change = try save(event(id: "event.1", revision: 1, note: nil))
        _ = try await applier.apply(change)
        let replay = try await applier.apply(change)
        #expect(replay == .keptLocal(EventID(ProgrammeSample.id("event.1"))))
        #expect(await journal.eventsByMatch[matchID]?.count == 1)
    }

    @Test("Same revision with different content surfaces a conflict, never a rewrite")
    func contradictionNeedsReview() async throws {
        let journal = FakeJournal()
        await journal.seed([event(id: "event.1", revision: 2, note: "Local")], for: matchID)
        let sink = FakeConflicts()
        let applier = TeamSyncApplier(journal: journal, conflicts: sink)
        let outcome = try await applier.apply(
            try save(event(id: "event.1", revision: 2, note: "Remote")))
        #expect(outcome == .conflict(EventID(ProgrammeSample.id("event.1"))))
        // Local truth untouched.
        let stored = try #require(await journal.eventsByMatch[matchID]?.first)
        #expect(stored.note == "Local")
        let reported = try #require(await sink.reported.first)
        #expect(reported.matchID == matchID && reported.localRevision == 2 && reported.remoteRevision == 2)
    }

    @Test("A remote deletion voids locally with a strictly newer revision")
    func deletionVoids() async throws {
        let journal = FakeJournal()
        await journal.seed([event(id: "event.1", revision: 2, note: nil)], for: matchID)
        let applier = TeamSyncApplier(journal: journal, conflicts: FakeConflicts())
        let outcome = try await applier.apply(deletion(EventID(ProgrammeSample.id("event.1"))))
        #expect(outcome == .voided(EventID(ProgrammeSample.id("event.1"))))
        let stored = try #require(await journal.eventsByMatch[matchID]?.first)
        // History preserved: still present, voided, superseding revision.
        #expect(await journal.eventsByMatch[matchID]?.count == 1)
        #expect(stored.isVoided)
        #expect(stored.revision == 3)
        #expect(stored.revisions.last?.kind == .voided)
    }

    @Test("Deleting an absent event is an idempotent no-op")
    func unknownDeletionIgnored() async throws {
        let applier = TeamSyncApplier(journal: FakeJournal(), conflicts: FakeConflicts())
        let outcome = try await applier.apply(deletion(EventID(ProgrammeSample.id("event.ghost"))))
        #expect(outcome == .ignored)
    }

    @Test("Corrupt payloads throw; foreign zones and match records are ignored")
    func strictnessBoundaries() async throws {
        let applier = TeamSyncApplier(journal: FakeJournal(), conflicts: FakeConflicts())
        let zoneID = zone()
        var corrupt = try save(event(id: "event.1", revision: 1, note: nil))
        corrupt.archivedRecord = Data("not a record".utf8)
        await #expect(throws: SyncApplyError.self) { try await applier.apply(corrupt) }

        var foreign = try save(event(id: "event.1", revision: 1, note: nil))
        foreign.zoneName = "foreign_zone"
        #expect(try await applier.apply(foreign) == .ignored)

        var matchRecord = try save(event(id: "event.1", revision: 1, note: nil))
        matchRecord.recordType = MatchRecord.recordType
        #expect(try await applier.apply(matchRecord) == .ignored)
    }

    @Test("Conflicts persist across relaunch until resolved")
    func conflictStoreRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conflicts-\(UUID().uuidString).json")
        let store = try TeamConflictStore(url: url)
        let conflict = TeamConflict(
            teamID: teamID, matchID: matchID, eventID: EventID(ProgrammeSample.id("event.1")),
            zoneName: zone().zoneName, localRevision: 2, remoteRevision: 2, receivedAt: Date())
        try await store.report(conflict)
        // Re-reporting the same event replaces instead of duplicating.
        try await store.report(conflict)
        #expect(await store.unresolved(teamID: teamID).count == 1)

        let reopened = try TeamConflictStore(url: url)
        #expect(await reopened.unresolved(teamID: teamID) == [conflict])
        try await reopened.resolve(EventID(ProgrammeSample.id("event.1")), inTeam: teamID)
        #expect(await reopened.unresolved(teamID: teamID).isEmpty)
    }
}
