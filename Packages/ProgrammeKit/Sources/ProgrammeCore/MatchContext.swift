import Foundation

/// The immutable identity and configuration of a match, as a value type.
/// Where a match is played. Deliberately separate from `Venue`: home/away/
/// neutral is a match relationship, not a postal or geographic place.
///
/// Optional everywhere: a scorer can always create and score a match offline
/// without choosing a location.
public struct MatchLocation: Codable, Hashable, Sendable {
    public var name: String
    public var address: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(name: String, address: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
    }

    /// True when the location can be shown on a map or opened for directions.
    public var hasCoordinates: Bool { latitude != nil && longitude != nil }
}

public struct MatchDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: MatchID
    public var teamID: TeamID
    public var seasonID: SeasonID?
    public var teamName: String
    public var teamShortName: String
    public var opponentName: String
    public var opponentShortName: String
    public var kickoff: Date
    public var venue: Venue
    public var location: MatchLocation?
    public var rules: MatchRules
    public var statProfile: StatProfile
    public var tracking: OpponentTrackingMode
    public var competition: String?

    public init(
        id: MatchID = MatchID(),
        teamID: TeamID,
        seasonID: SeasonID? = nil,
        teamName: String,
        teamShortName: String? = nil,
        opponentName: String,
        opponentShortName: String? = nil,
        kickoff: Date,
        venue: Venue = .home,
        location: MatchLocation? = nil,
        rules: MatchRules = .highSchool,
        statProfile: StatProfile = .maxPreps,
        tracking: OpponentTrackingMode = .ourTeam,
        competition: String? = nil
    ) {
        self.id = id
        self.teamID = teamID
        self.seasonID = seasonID
        self.teamName = teamName
        self.teamShortName = teamShortName ?? teamName
        self.opponentName = opponentName
        self.opponentShortName = opponentShortName ?? opponentName
        self.kickoff = kickoff
        self.venue = venue
        self.location = location
        self.rules = rules
        self.statProfile = statProfile
        self.tracking = tracking
        self.competition = competition
    }

    public func name(for side: TeamSide) -> String {
        side == .us ? teamName : opponentName
    }

    public func shortName(for side: TeamSide) -> String {
        side == .us ? teamShortName : opponentShortName
    }

    /// "Ninety Six vs Dixie" or "Ninety Six at Dixie".
    public var title: String {
        "\(teamShortName) \(venue.shortLabel) \(opponentShortName)"
    }
}

/// Everything the engines need to derive state. A pure value, safe to hand to
/// any actor, assembled from persistence at the edges.
public struct MatchContext: Codable, Hashable, Sendable {
    public var descriptor: MatchDescriptor
    public var roster: RosterSnapshot
    public var opponentRoster: RosterSnapshot
    public var events: [MatchEvent]
    public var clock: ClockAnchor
    public var phase: MatchPhase
    public var finalizedAt: Date?

    public init(
        descriptor: MatchDescriptor,
        roster: RosterSnapshot,
        opponentRoster: RosterSnapshot = .empty,
        events: [MatchEvent] = [],
        clock: ClockAnchor = ClockAnchor(period: 1),
        phase: MatchPhase = .scheduled,
        finalizedAt: Date? = nil
    ) {
        self.descriptor = descriptor
        self.roster = roster
        self.opponentRoster = opponentRoster
        self.events = events
        self.clock = clock
        self.phase = phase
        self.finalizedAt = finalizedAt
    }

    public var rules: MatchRules { descriptor.rules }
    public var profile: StatProfile { descriptor.statProfile }
    public var activeEvents: [MatchEvent] { events.activeSorted }

    public func roster(for side: TeamSide) -> RosterSnapshot {
        side == .us ? roster : opponentRoster
    }

    /// The next sequence number, keeping ordering total and stable.
    public var nextSequence: Int { (events.map(\.sequence).max() ?? 0) + 1 }

    /// The match time "now" refers to. Derived from the clock while a period is
    /// running, and from the last completed period otherwise, so that recording
    /// during a stoppage lands at the right moment.
    public func currentTime(at date: Date = Date()) -> MatchTime {
        switch phase {
        case .scheduled:
            return MatchTime(period: 1, secondsElapsed: 0)
        case .inPeriod:
            return clock.matchTime(at: date)
        case .periodBreak, .awaitingFinalization, .finalized:
            return lastCompletedPeriodEnd ?? clock.matchTime(at: date)
        }
    }

    /// Where the most recently completed period finished.
    public var lastCompletedPeriodEnd: MatchTime? {
        activeEvents.last { if case .periodEnded = $0.payload { return true } else { return false } }?.time
    }

    public var currentPeriodIndex: Int { clock.period }

    public var currentPeriod: PeriodDescriptor? { rules.period(at: clock.period) }

    /// Periods that have been started, in order.
    public var startedPeriods: [Int] {
        activeEvents.compactMap {
            if case .periodStarted(let p) = $0.payload { return p } else { return nil }
        }
    }

    public var endedPeriods: Set<Int> {
        Set(
            activeEvents.compactMap {
                if case .periodEnded(let p) = $0.payload { return p } else { return nil }
            })
    }

    public var hasStarted: Bool { !startedPeriods.isEmpty }
}
