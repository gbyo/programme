import Foundation
import ProgrammeCore
import SwiftData

// MARK: - Team

@Model
public final class TeamModel {
    #Index<TeamModel>([\.identifier])
    #Unique<TeamModel>([\.identifier])

    public var identifier: UUID = UUID()
    public var name: String = ""
    public var shortName: String = ""
    public var mascot: String?
    /// Stored as a hex string so the schema has no platform colour dependency.
    public var primaryColorHex: String?
    public var secondaryColorHex: String?
    public var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \PlayerModel.team)
    public var players: [PlayerModel] = []

    @Relationship(deleteRule: .cascade, inverse: \SeasonModel.team)
    public var seasons: [SeasonModel] = []

    public init(
        identifier: UUID = UUID(),
        name: String,
        shortName: String? = nil,
        mascot: String? = nil,
        primaryColorHex: String? = nil,
        secondaryColorHex: String? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.shortName = shortName ?? name
        self.mascot = mascot
        self.primaryColorHex = primaryColorHex
        self.secondaryColorHex = secondaryColorHex
        self.createdAt = Date()
    }

    public var teamID: TeamID { TeamID(identifier) }
}

// MARK: - Season

@Model
public final class SeasonModel {
    #Index<SeasonModel>([\.identifier])
    #Unique<SeasonModel>([\.identifier])

    public var identifier: UUID = UUID()
    public var name: String = ""
    public var startDate: Date = Date()
    public var endDate: Date?
    public var isCurrent: Bool = false
    public var team: TeamModel?

    @Relationship(deleteRule: .cascade, inverse: \MatchModel.season)
    public var matches: [MatchModel] = []

    public init(
        identifier: UUID = UUID(),
        name: String,
        startDate: Date = Date(),
        endDate: Date? = nil,
        isCurrent: Bool = true
    ) {
        self.identifier = identifier
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.isCurrent = isCurrent
    }

    public var seasonID: SeasonID { SeasonID(identifier) }
}

// MARK: - Player

@Model
public final class PlayerModel {
    #Index<PlayerModel>([\.identifier], [\.jerseyNumber])
    #Unique<PlayerModel>([\.identifier])

    public var identifier: UUID = UUID()
    public var firstName: String = ""
    public var lastName: String = ""
    public var jerseyNumber: Int?
    /// Stored as the raw value so an unknown future position cannot fail to load.
    public var positionRaw: String?
    public var classYear: String?
    /// Former players stay in the database so historical matches stay readable.
    public var isOnRoster: Bool = true
    public var createdAt: Date = Date()
    public var team: TeamModel?

    public init(
        identifier: UUID = UUID(),
        firstName: String,
        lastName: String,
        jerseyNumber: Int? = nil,
        position: PlayerPosition? = nil,
        classYear: String? = nil,
        isOnRoster: Bool = true
    ) {
        self.identifier = identifier
        self.firstName = firstName
        self.lastName = lastName
        self.jerseyNumber = jerseyNumber
        self.positionRaw = position?.rawValue
        self.classYear = classYear
        self.isOnRoster = isOnRoster
        self.createdAt = Date()
    }

    public var playerID: PlayerID { PlayerID(identifier) }

    public var position: PlayerPosition? {
        get { positionRaw.flatMap(PlayerPosition.init(rawValue:)) }
        set { positionRaw = newValue?.rawValue }
    }

    public var snapshot: PlayerSnapshot {
        PlayerSnapshot(
            id: playerID,
            firstName: firstName,
            lastName: lastName,
            jerseyNumber: jerseyNumber,
            position: position,
            classYear: classYear,
            isOnRoster: isOnRoster
        )
    }
}

// MARK: - Match

@Model
public final class MatchModel {
    #Index<MatchModel>([\.identifier], [\.kickoff])
    #Unique<MatchModel>([\.identifier])

    public var identifier: UUID = UUID()
    public var teamIdentifier: UUID = UUID()
    public var opponentName: String = ""
    public var opponentShortName: String = ""
    public var kickoff: Date = Date()
    public var venueRaw: String = Venue.home.rawValue
    public var competition: String?
    public var trackingRaw: String = OpponentTrackingMode.ourTeam.rawValue
    public var phaseRaw: String = MatchPhase.scheduled.rawValue
    public var finalizedAt: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    /// Configuration is versioned JSON rather than a wide set of columns, so a
    /// new rule or profile field never requires a store migration.
    public var rulesData: Data = Data()
    public var statProfileData: Data = Data()

    /// The roster as it stood for this match. Frozen so that renaming or
    /// removing a player later never rewrites a played match.
    public var rosterData: Data = Data()
    public var opponentRosterData: Data = Data()

    /// Clock anchors. Programme stores the anchor, never a tick count.
    public var clockPeriod: Int = 1
    public var clockElapsed: Double = 0
    public var clockRunningSince: Date?

    /// Denormalised for fast list rendering; always re-derived on write and
    /// never treated as authoritative.
    public var cachedScoreUs: Int = 0
    public var cachedScoreOpponent: Int = 0
    public var cachedResultRaw: String?
    public var cachedEventCount: Int = 0
    public var cachedNeedsReviewCount: Int = 0

    public var season: SeasonModel?

    @Relationship(deleteRule: .cascade, inverse: \MatchEventModel.match)
    public var events: [MatchEventModel] = []

    public init(
        identifier: UUID = UUID(),
        teamIdentifier: UUID,
        opponentName: String,
        opponentShortName: String? = nil,
        kickoff: Date,
        venue: Venue = .home,
        competition: String? = nil,
        tracking: OpponentTrackingMode = .ourTeam
    ) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.opponentName = opponentName
        self.opponentShortName = opponentShortName ?? opponentName
        self.kickoff = kickoff
        self.venueRaw = venue.rawValue
        self.competition = competition
        self.trackingRaw = tracking.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var matchID: MatchID { MatchID(identifier) }
    public var venue: Venue { Venue(rawValue: venueRaw) ?? .home }
    public var tracking: OpponentTrackingMode { OpponentTrackingMode(rawValue: trackingRaw) ?? .ourTeam }
    public var phase: MatchPhase {
        get { MatchPhase(rawValue: phaseRaw) ?? .scheduled }
        set { phaseRaw = newValue.rawValue }
    }
    public var result: MatchResult? { cachedResultRaw.flatMap(MatchResult.init(rawValue:)) }

    /// A match that was started and never finalized. Detected on launch so no
    /// unfinished match is ever silently discarded.
    public var isInterrupted: Bool {
        phase == .inPeriod || phase == .periodBreak || phase == .awaitingFinalization
    }

    public var clockAnchor: ClockAnchor {
        get { ClockAnchor(period: clockPeriod, elapsedAtAnchor: clockElapsed, runningSince: clockRunningSince) }
        set {
            clockPeriod = newValue.period
            clockElapsed = newValue.elapsedAtAnchor
            clockRunningSince = newValue.runningSince
        }
    }
}

// MARK: - Event

@Model
public final class MatchEventModel {
    #Index<MatchEventModel>([\.identifier], [\.sequence])
    #Unique<MatchEventModel>([\.identifier])

    public var identifier: UUID = UUID()
    public var matchIdentifier: UUID = UUID()
    public var period: Int = 1
    public var secondsElapsed: Int = 0
    public var sequence: Int = 0
    public var recordedAt: Date = Date()
    public var revision: Int = 1
    public var voidedAt: Date?
    public var note: String?
    /// Denormalised for filtering without decoding every payload.
    public var categoryRaw: String = EventCategory.structural.rawValue
    public var awaitsAttribution: Bool = false

    /// The payload is versioned JSON. Keeping it opaque to the store means a new
    /// event kind is a code change, not a schema migration, and an archive
    /// written by an older build still round-trips.
    public var payloadData: Data = Data()
    public var revisionsData: Data = Data()

    public var match: MatchModel?

    public init(event: MatchEvent) throws {
        self.identifier = event.id.rawValue
        self.matchIdentifier = event.matchID.rawValue
        self.period = event.time.period
        self.secondsElapsed = event.time.secondsElapsed
        self.sequence = event.sequence
        self.recordedAt = event.recordedAt
        self.revision = event.revision
        self.voidedAt = event.voidedAt
        self.note = event.note
        self.categoryRaw = event.category.rawValue
        self.awaitsAttribution = event.payload.awaitsAttribution
        self.payloadData = try ProgrammeCoding.encoder.encode(event.payload)
        self.revisionsData = try ProgrammeCoding.encoder.encode(event.revisions)
    }

    public func update(from event: MatchEvent) throws {
        period = event.time.period
        secondsElapsed = event.time.secondsElapsed
        sequence = event.sequence
        recordedAt = event.recordedAt
        revision = event.revision
        voidedAt = event.voidedAt
        note = event.note
        categoryRaw = event.category.rawValue
        awaitsAttribution = event.payload.awaitsAttribution
        payloadData = try ProgrammeCoding.encoder.encode(event.payload)
        revisionsData = try ProgrammeCoding.encoder.encode(event.revisions)
    }

    /// Convert back to the domain value type. Persistent objects never cross an
    /// actor boundary; these values do.
    public func domainEvent() throws -> MatchEvent {
        let payload = try ProgrammeCoding.decoder.decode(EventPayload.self, from: payloadData)
        let revisions =
            (try? ProgrammeCoding.decoder.decode([EventRevision].self, from: revisionsData)) ?? []
        return MatchEvent(
            id: EventID(identifier),
            matchID: MatchID(matchIdentifier),
            time: MatchTime(period: period, secondsElapsed: secondsElapsed),
            sequence: sequence,
            recordedAt: recordedAt,
            payload: payload,
            revision: revision,
            voidedAt: voidedAt,
            note: note,
            revisions: revisions
        )
    }
}

// MARK: - Coding

public enum ProgrammeCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Pretty-printed, for archives a person might open in a text editor.
    public static let archiveEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()
}
