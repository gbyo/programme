import CloudKit
import Foundation
import Testing

@testable import ProgrammeCollaboration
@testable import ProgrammeCore

@Suite("Team zones isolate teams by stable identity")
struct TeamZoneTests {
    @Test("Zone names round-trip to the owning team")
    func zoneNameRoundTrips() {
        let teamID = TeamID(ProgrammeSample.id("team.ninety-six"))
        let zoneID = TeamZone.zoneID(for: teamID)
        #expect(TeamZone.teamID(forZoneName: zoneID.zoneName) == teamID)
    }

    @Test("Two teams never share a zone")
    func zonesIsolateTeams() {
        let first = TeamZone.zoneID(for: TeamID(ProgrammeSample.id("team.a")))
        let second = TeamZone.zoneID(for: TeamID(ProgrammeSample.id("team.b")))
        #expect(first.zoneName != second.zoneName)
    }

    @Test("Non-team zones do not parse")
    func foreignZonesRejected() {
        #expect(TeamZone.teamID(forZoneName: CKRecordZone.default().zoneID.zoneName) == nil)
        #expect(TeamZone.teamID(forZoneName: "team_not-a-uuid") == nil)
    }

    @Test("Record names carry UUIDs, never user-entered text")
    func recordNamesAreUUIDBased() {
        let name = TeamZone.recordName(prefix: "player", id: ProgrammeSample.id("x"))
        #expect(name.hasPrefix("player_"))
        #expect(UUID(uuidString: String(name.dropFirst("player_".count))) != nil)
    }
}

@Suite("Local values map to records and back")
struct RecordMappingTests {
    private func zoneID() -> CKRecordZone.ID {
        TeamZone.zoneID(for: TeamID(ProgrammeSample.id("team.ninety-six")))
    }

    @Test("Team round-trips with identity fields only")
    func teamRoundTrip() {
        let team = TeamRecord(
            teamID: TeamID(ProgrammeSample.id("team.ninety-six")), name: "Ninety Six",
            shortName: "NX", mascot: "Wildcats", primaryColorHex: "#003366",
            secondaryColorHex: nil, createdAt: Date(timeIntervalSinceReferenceDate: 100))
        let decoded = TeamRecord(record: team.makeRecord(in: zoneID()))
        #expect(decoded == team)
    }

    @Test("Season round-trips with its team reference")
    func seasonRoundTrip() {
        let season = SeasonRecord(
            seasonID: SeasonID(ProgrammeSample.id("season.1")),
            teamID: TeamID(ProgrammeSample.id("team.ninety-six")), name: "2026–27",
            startDate: Date(timeIntervalSinceReferenceDate: 200), endDate: nil, isCurrent: true)
        let decoded = SeasonRecord(record: season.makeRecord(in: zoneID()))
        #expect(decoded == season)
    }

    @Test("Player round-trips with roster fields and former status")
    func playerRoundTrip() {
        let snapshot = PlayerSnapshot(
            id: PlayerID(ProgrammeSample.id("player.1")), firstName: "Ava", lastName: "Bell",
            jerseyNumber: 4, position: .midfielder, classYear: "2027", isOnRoster: false)
        let player = PlayerRecord(
            playerID: snapshot.id, teamID: TeamID(ProgrammeSample.id("team.ninety-six")),
            snapshot: snapshot)
        let decoded = PlayerRecord(record: player.makeRecord(in: zoneID()))
        #expect(decoded == player)
    }

    @Test("Match round-trips source truth, never derived totals")
    func matchRoundTrip() {
        var descriptor = ProgrammeSample.descriptor(opponent: "Dixie", venue: .away)
        descriptor.location = MatchLocation(name: "Abbeville High School")
        let match = MatchRecord(
            descriptor: descriptor, phase: .scheduled,
            roster: ProgrammeSample.roster, opponentRoster: RosterSnapshot(players: []),
            clockPeriod: 2, clockElapsed: 2400)
        let record = match.makeRecord(in: zoneID())
        let keys = record.allKeys()
        #expect(!keys.contains("cachedScoreUs"))
        #expect(!keys.contains("cachedResultRaw"))
        #expect(!keys.contains("cachedEventCount"))
        #expect(!keys.contains("cachedNeedsReviewCount"))
        let decoded = MatchRecord(record: record)
        #expect(decoded == match)
    }

    @Test("Event round-trips payload, revision history, and void state")
    func eventRoundTrip() {
        let matchID = MatchID(ProgrammeSample.id("match.dixie"))
        let event = MatchEvent(
            matchID: matchID, time: MatchTime(period: 1, secondsElapsed: 300), sequence: 7,
            recordedAt: Date(timeIntervalSinceReferenceDate: 400),
            payload: .note("Captain's armband"), revision: 3,
            note: "Confirmed at halftime")
        let record = EventRecord(event: event, matchID: matchID).makeRecord(in: zoneID())
        let decoded = EventRecord(record: record)
        #expect(decoded?.event == event)
        #expect(decoded?.matchID == matchID)
    }

    @Test("Wrong types and missing fields decode as nil")
    func strictDecoding() {
        let zone = zoneID()
        let teamRecord = TeamRecord(
            teamID: TeamID(ProgrammeSample.id("team.ninety-six")), name: "Ninety Six",
            shortName: "NX", createdAt: Date()
        )
        .makeRecord(in: zone)
        #expect(SeasonRecord(record: teamRecord) == nil)
        #expect(PlayerRecord(record: teamRecord) == nil)

        teamRecord["name"] = nil as CKRecordValue?
        #expect(TeamRecord(record: teamRecord) == nil)
    }
}

@Suite("Same-ID event pairs merge deterministically")
struct EventMergeTests {
    private func event(revision: Int, note: String?) -> MatchEvent {
        MatchEvent(
            id: EventID(ProgrammeSample.id("event.1")),
            matchID: MatchID(ProgrammeSample.id("match.dixie")),
            time: .kickoff, sequence: 1,
            payload: .periodStarted(period: 1), revision: revision, note: note)
    }

    @Test("Higher revision supersedes, lower revision loses")
    func revisionWins() {
        let local = event(revision: 1, note: nil)
        let remote = event(revision: 2, note: "Corrected")
        #expect(EventMerge.reconcile(local: local, remote: remote) == .takeRemote(remote))
        #expect(EventMerge.reconcile(local: remote, remote: local) == .keepLocal)
    }

    @Test("Identical revisions with identical content are idempotent")
    func identicalIsIdempotent() {
        let local = event(revision: 2, note: "Same")
        #expect(EventMerge.reconcile(local: local, remote: local) == .keepLocal)
    }

    @Test("Same revision with different content is an explicit conflict")
    func contradictionIsConflict() {
        let local = event(revision: 2, note: "Ours")
        let remote = event(revision: 2, note: "Theirs")
        let result = EventMerge.reconcile(local: local, remote: remote)
        #expect(result == .conflict(local: local, remote: remote))
    }
}
