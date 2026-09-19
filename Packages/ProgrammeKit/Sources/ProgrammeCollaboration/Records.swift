import CloudKit
import Foundation
import ProgrammeCore

/// Local ↔ CloudKit record mapping for one team's zone.
///
/// These structs carry source truth only — everything needed to reconstruct
/// Programme state, and nothing derived. Score, results, cached counts, and
/// device-local preferences (reminder choice) are never record fields; the
/// applier rebuilds derived output through StatEngine after merging.
///
/// Relationships are stored as record-name strings inside the same zone, so
/// they stay resolvable without `CKRecord.Reference` graphs.
///
/// Every `init(record:)` is strict: wrong type, unparsable identity, or a
/// missing required field returns nil rather than a half-materialized value.
public struct TeamRecord: Hashable, Sendable {
    public static let recordType = "Team"

    public var teamID: TeamID
    public var name: String
    public var shortName: String
    public var mascot: String?
    public var primaryColorHex: String?
    public var secondaryColorHex: String?
    public var createdAt: Date

    public init(
        teamID: TeamID, name: String, shortName: String, mascot: String? = nil,
        primaryColorHex: String? = nil, secondaryColorHex: String? = nil, createdAt: Date = Date()
    ) {
        self.teamID = teamID
        self.name = name
        self.shortName = shortName
        self.mascot = mascot
        self.primaryColorHex = primaryColorHex
        self.secondaryColorHex = secondaryColorHex
        self.createdAt = createdAt
    }

    public func makeRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(
                recordName: TeamZone.recordName(prefix: "team", id: teamID.rawValue),
                zoneID: zoneID))
        record["name"] = name as CKRecordValue
        record["shortName"] = shortName as CKRecordValue
        record.setOptional(mascot, forKey: "mascot")
        record.setOptional(primaryColorHex, forKey: "primaryColorHex")
        record.setOptional(secondaryColorHex, forKey: "secondaryColorHex")
        record["createdAt"] = createdAt as CKRecordValue
        return record
    }

    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
            let teamID = TeamZone.uuid(fromRecordName: record.recordID.recordName, prefix: "team"),
            let name = record["name"] as? String,
            let shortName = record["shortName"] as? String,
            let createdAt = record["createdAt"] as? Date
        else { return nil }
        self.init(
            teamID: TeamID(teamID), name: name, shortName: shortName,
            mascot: record["mascot"] as? String,
            primaryColorHex: record["primaryColorHex"] as? String,
            secondaryColorHex: record["secondaryColorHex"] as? String,
            createdAt: createdAt)
    }
}

public struct SeasonRecord: Hashable, Sendable {
    public static let recordType = "Season"

    public var seasonID: SeasonID
    public var teamID: TeamID
    public var name: String
    public var startDate: Date
    public var endDate: Date?
    public var isCurrent: Bool

    public init(
        seasonID: SeasonID, teamID: TeamID, name: String, startDate: Date,
        endDate: Date? = nil, isCurrent: Bool = false
    ) {
        self.seasonID = seasonID
        self.teamID = teamID
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.isCurrent = isCurrent
    }

    public func makeRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(
                recordName: TeamZone.recordName(prefix: "season", id: seasonID.rawValue),
                zoneID: zoneID))
        record["teamRef"] = TeamZone.recordName(prefix: "team", id: teamID.rawValue) as CKRecordValue
        record["name"] = name as CKRecordValue
        record["startDate"] = startDate as CKRecordValue
        record.setOptional(endDate, forKey: "endDate")
        record["isCurrent"] = (isCurrent ? 1 : 0) as CKRecordValue
        return record
    }

    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
            let seasonUUID = TeamZone.uuid(
                fromRecordName: record.recordID.recordName, prefix: "season"),
            let teamRef = record["teamRef"] as? String,
            let teamID = TeamZone.uuid(fromRecordName: teamRef, prefix: "team"),
            let name = record["name"] as? String,
            let startDate = record["startDate"] as? Date,
            let isCurrent = record["isCurrent"] as? Int64
        else { return nil }
        self.init(
            seasonID: SeasonID(seasonUUID), teamID: TeamID(teamID), name: name,
            startDate: startDate, endDate: record["endDate"] as? Date,
            isCurrent: isCurrent != 0)
    }
}

public struct PlayerRecord: Hashable, Sendable {
    public static let recordType = "Player"

    public var playerID: PlayerID
    public var teamID: TeamID
    public var snapshot: PlayerSnapshot

    public init(playerID: PlayerID, teamID: TeamID, snapshot: PlayerSnapshot) {
        self.playerID = playerID
        self.teamID = teamID
        self.snapshot = snapshot
    }

    public func makeRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(
                recordName: TeamZone.recordName(prefix: "player", id: playerID.rawValue),
                zoneID: zoneID))
        record["teamRef"] = TeamZone.recordName(prefix: "team", id: teamID.rawValue) as CKRecordValue
        record["firstName"] = snapshot.firstName as CKRecordValue
        record["lastName"] = snapshot.lastName as CKRecordValue
        record.setOptional(snapshot.jerseyNumber.map { Int64($0) }, forKey: "jerseyNumber")
        record.setOptional(snapshot.position?.rawValue, forKey: "positionRaw")
        record.setOptional(snapshot.classYear, forKey: "classYear")
        record["isOnRoster"] = (snapshot.isOnRoster ? 1 : 0) as CKRecordValue
        return record
    }

    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
            let playerUUID = TeamZone.uuid(
                fromRecordName: record.recordID.recordName, prefix: "player"),
            let teamRef = record["teamRef"] as? String,
            let teamID = TeamZone.uuid(fromRecordName: teamRef, prefix: "team"),
            let firstName = record["firstName"] as? String,
            let lastName = record["lastName"] as? String,
            let isOnRoster = record["isOnRoster"] as? Int64
        else { return nil }
        let snapshot = PlayerSnapshot(
            id: PlayerID(playerUUID), firstName: firstName, lastName: lastName,
            jerseyNumber: (record["jerseyNumber"] as? Int64).map(Int.init),
            position: (record["positionRaw"] as? String).flatMap(PlayerPosition.init(rawValue:)),
            classYear: record["classYear"] as? String,
            isOnRoster: isOnRoster != 0)
        self.init(playerID: PlayerID(playerUUID), teamID: TeamID(teamID), snapshot: snapshot)
    }
}

public struct MatchRecord: Hashable, Sendable {
    public static let recordType = "Match"

    public var descriptor: MatchDescriptor
    public var phase: MatchPhase
    public var finalizedAt: Date?
    public var roster: RosterSnapshot
    public var opponentRoster: RosterSnapshot
    public var clockPeriod: Int
    public var clockElapsed: Double
    public var clockRunningSince: Date?

    public init(
        descriptor: MatchDescriptor, phase: MatchPhase, finalizedAt: Date? = nil,
        roster: RosterSnapshot, opponentRoster: RosterSnapshot,
        clockPeriod: Int = 1, clockElapsed: Double = 0, clockRunningSince: Date? = nil
    ) {
        self.descriptor = descriptor
        self.phase = phase
        self.finalizedAt = finalizedAt
        self.roster = roster
        self.opponentRoster = opponentRoster
        self.clockPeriod = clockPeriod
        self.clockElapsed = clockElapsed
        self.clockRunningSince = clockRunningSince
    }

    public func makeRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let d = descriptor
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(
                recordName: TeamZone.recordName(prefix: "match", id: d.id.rawValue),
                zoneID: zoneID))
        record["teamRef"] = TeamZone.recordName(prefix: "team", id: d.teamID.rawValue) as CKRecordValue
        record.setOptional(
            d.seasonID.map { TeamZone.recordName(prefix: "season", id: $0.rawValue) },
            forKey: "seasonRef")
        record["teamName"] = d.teamName as CKRecordValue
        record["teamShortName"] = d.teamShortName as CKRecordValue
        record["opponentName"] = d.opponentName as CKRecordValue
        record["opponentShortName"] = d.opponentShortName as CKRecordValue
        record["kickoff"] = d.kickoff as CKRecordValue
        record["venueRaw"] = d.venue.rawValue as CKRecordValue
        record.setOptional(d.location.flatMap(RecordCoding.encode), forKey: "locationData")
        record.setOptional(d.competition, forKey: "competition")
        record["rulesData"] = RecordCoding.encode(d.rules) ?? Data()
        record["statProfileData"] = RecordCoding.encode(d.statProfile) ?? Data()
        record["trackingRaw"] = d.tracking.rawValue as CKRecordValue
        record["rosterData"] = RecordCoding.encode(roster) ?? Data()
        record["opponentRosterData"] = RecordCoding.encode(opponentRoster) ?? Data()
        record["clockPeriod"] = Int64(clockPeriod) as CKRecordValue
        record["clockElapsed"] = clockElapsed as CKRecordValue
        record.setOptional(clockRunningSince, forKey: "clockRunningSince")
        record["phaseRaw"] = phase.rawValue as CKRecordValue
        record.setOptional(finalizedAt, forKey: "finalizedAt")
        return record
    }

    /// Corrupt embedded JSON decodes as nil rather than a half-materialized
    /// match. Cached scores/results/counts are never fields: the applier
    /// rebuilds derived output through StatEngine after merging.
    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
            let matchUUID = TeamZone.uuid(
                fromRecordName: record.recordID.recordName, prefix: "match"),
            let teamRef = record["teamRef"] as? String,
            let teamUUID = TeamZone.uuid(fromRecordName: teamRef, prefix: "team"),
            let teamName = record["teamName"] as? String,
            let teamShortName = record["teamShortName"] as? String,
            let opponentName = record["opponentName"] as? String,
            let opponentShortName = record["opponentShortName"] as? String,
            let kickoff = record["kickoff"] as? Date,
            let venueRaw = record["venueRaw"] as? String,
            let venue = Venue(rawValue: venueRaw),
            let rulesData = record["rulesData"] as? Data,
            let rules = RecordCoding.decode(MatchRules.self, from: rulesData),
            let statProfileData = record["statProfileData"] as? Data,
            let statProfile = RecordCoding.decode(StatProfile.self, from: statProfileData),
            let trackingRaw = record["trackingRaw"] as? String,
            let tracking = OpponentTrackingMode(rawValue: trackingRaw),
            let rosterData = record["rosterData"] as? Data,
            let roster = RecordCoding.decode(RosterSnapshot.self, from: rosterData),
            let opponentRosterData = record["opponentRosterData"] as? Data,
            let opponentRoster = RecordCoding.decode(RosterSnapshot.self, from: opponentRosterData),
            let clockPeriod = record["clockPeriod"] as? Int64,
            let clockElapsed = record["clockElapsed"] as? Double,
            let phaseRaw = record["phaseRaw"] as? String,
            let phase = MatchPhase(rawValue: phaseRaw)
        else { return nil }
        let seasonID: SeasonID? = (record["seasonRef"] as? String).flatMap {
            TeamZone.uuid(fromRecordName: $0, prefix: "season")
        }.map(SeasonID.init)
        let location: MatchLocation? = (record["locationData"] as? Data).flatMap {
            RecordCoding.decode(MatchLocation.self, from: $0)
        }
        self.init(
            descriptor: MatchDescriptor(
                id: MatchID(matchUUID), teamID: TeamID(teamUUID), seasonID: seasonID,
                teamName: teamName, teamShortName: teamShortName, opponentName: opponentName,
                opponentShortName: opponentShortName, kickoff: kickoff, venue: venue,
                location: location, rules: rules, statProfile: statProfile, tracking: tracking,
                competition: record["competition"] as? String),
            phase: phase, finalizedAt: record["finalizedAt"] as? Date,
            roster: roster, opponentRoster: opponentRoster,
            clockPeriod: Int(clockPeriod), clockElapsed: clockElapsed,
            clockRunningSince: record["clockRunningSince"] as? Date)
    }
}

public struct EventRecord: Hashable, Sendable {
    public static let recordType = "MatchEvent"

    public var event: MatchEvent
    public var matchID: MatchID

    public init(event: MatchEvent, matchID: MatchID) {
        self.event = event
        self.matchID = matchID
    }

    public func makeRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let e = event
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(
                recordName: TeamZone.recordName(prefix: "event", id: e.id.rawValue),
                zoneID: zoneID))
        record["matchRef"] = TeamZone.recordName(prefix: "match", id: matchID.rawValue) as CKRecordValue
        record["period"] = Int64(e.time.period) as CKRecordValue
        record["secondsElapsed"] = Int64(e.time.secondsElapsed) as CKRecordValue
        record["sequence"] = Int64(e.sequence) as CKRecordValue
        record["recordedAt"] = e.recordedAt as CKRecordValue
        record["payloadData"] = RecordCoding.encode(e.payload) ?? Data()
        record["revision"] = Int64(e.revision) as CKRecordValue
        record.setOptional(e.voidedAt, forKey: "voidedAt")
        record.setOptional(e.note, forKey: "note")
        record["revisionsData"] = RecordCoding.encode(e.revisions) ?? Data()
        return record
    }

    /// Corrupt payload decodes as nil rather than a half-materialized event.
    /// Category and attribution state derive from the payload on decode, so
    /// they are never separate fields that could disagree with it.
    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
            let eventUUID = TeamZone.uuid(
                fromRecordName: record.recordID.recordName, prefix: "event"),
            let matchRef = record["matchRef"] as? String,
            let matchUUID = TeamZone.uuid(fromRecordName: matchRef, prefix: "match"),
            let period = record["period"] as? Int64,
            let secondsElapsed = record["secondsElapsed"] as? Int64,
            let sequence = record["sequence"] as? Int64,
            let recordedAt = record["recordedAt"] as? Date,
            let payloadData = record["payloadData"] as? Data,
            let payload = RecordCoding.decode(EventPayload.self, from: payloadData),
            let revision = record["revision"] as? Int64,
            let revisionsData = record["revisionsData"] as? Data,
            let revisions = RecordCoding.decode([EventRevision].self, from: revisionsData)
        else { return nil }
        let event = MatchEvent(
            id: EventID(eventUUID), matchID: MatchID(matchUUID),
            time: MatchTime(period: Int(period), secondsElapsed: Int(secondsElapsed)),
            sequence: Int(sequence), recordedAt: recordedAt, payload: payload,
            revision: Int(revision), voidedAt: record["voidedAt"] as? Date,
            note: record["note"] as? String, revisions: revisions)
        self.init(event: event, matchID: MatchID(matchUUID))
    }
}

extension TeamZone {
    static func uuid(fromRecordName name: String, prefix: String) -> UUID? {
        guard name.hasPrefix(prefix + "_") else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count + 1)))
    }
}

extension CKRecord {
    /// Sets an optional field, skipping nils so absent optionals stay absent
    /// (and distinguishable from explicit values). Takes `Any?` because
    /// Swift value types bridge to the ObjC `CKRecordValue` protocol only
    /// through a cast, never through a generic constraint.
    fileprivate func setOptional(_ value: Any?, forKey key: String) {
        if let value = value as? CKRecordValue { self[key] = value }
    }
}
