import Foundation

// MARK: - Shot

public enum ShotOutcome: String, Codable, Hashable, Sendable, CaseIterable {
    /// Missed the frame. Counts as a shot, not a shot on goal.
    case offTarget
    /// Blocked by an outfield defender before reaching the keeper.
    case blocked
    /// Hit the post or crossbar. By convention not a shot on goal.
    case woodwork
    /// Reached the frame and the goalkeeper kept it out. Implies a shot on goal
    /// for the shooter and a save for the goalkeeper.
    case saved
    /// Implies a shot and a shot on goal. Never recorded separately from those.
    case goal

    /// A shot on goal is one that would have entered the goal but for the
    /// goalkeeper. Programme derives this rather than letting the scorer record
    /// a shot and a contradicting shot-on-goal flag.
    public var isOnTarget: Bool { self == .saved || self == .goal }
    public var isGoal: Bool { self == .goal }

    /// Whether this outcome can occur in the selected phase of play.
    ///
    /// A penalty kick cannot be blocked by an outfield defender because every
    /// other outfield player is behind the ball when it is taken.
    public func isValid(for phase: PlayPhase) -> Bool {
        !(phase == .penaltyKick && self == .blocked)
    }

    public var label: String {
        switch self {
        case .offTarget: "Off Target"
        case .blocked: "Blocked"
        case .woodwork: "Post / Crossbar"
        case .saved: "On Target — Saved"
        case .goal: "Goal"
        }
    }

    public var shortLabel: String {
        switch self {
        case .offTarget: "Off"
        case .blocked: "Blocked"
        case .woodwork: "Woodwork"
        case .saved: "Saved"
        case .goal: "Goal"
        }
    }
}

public enum PlayPhase: String, Codable, Hashable, Sendable, CaseIterable {
    case openPlay
    case penaltyKick
    case freeKick
    case cornerKick
    case throwIn

    public var label: String {
        switch self {
        case .openPlay: "Open Play"
        case .penaltyKick: "Penalty Kick"
        case .freeKick: "Free Kick"
        case .cornerKick: "Corner Kick"
        case .throwIn: "Throw-in"
        }
    }
}

public enum BodyPart: String, Codable, Hashable, Sendable, CaseIterable {
    case rightFoot, leftFoot, head, other

    public var label: String {
        switch self {
        case .rightFoot: "Right Foot"
        case .leftFoot: "Left Foot"
        case .head: "Head"
        case .other: "Other"
        }
    }
}

/// A location on the pitch in normalized attacking coordinates.
/// `x` runs 0 (own goal line) to 1 (attacking goal line); `y` runs 0 to 1 across
/// the width. Storing normalized values keeps shot maps correct at any size.
public struct PitchPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }

    /// Rough plain-language zone, used for accessibility descriptions.
    public var zoneDescription: String {
        let depth: String
        switch x {
        case ..<0.5: depth = "own half"
        case ..<0.75: depth = "outside the box"
        case ..<0.88: depth = "edge of the box"
        default: depth = "inside the six-yard area"
        }
        let lateral: String
        switch y {
        case ..<0.33: lateral = "left"
        case ..<0.67: lateral = "central"
        default: lateral = "right"
        }
        return "\(lateral), \(depth)"
    }
}

public struct ShotEvent: Codable, Hashable, Sendable {
    /// The team whose player struck the ball. For an own goal this is the team
    /// that *conceded*; `scoringSide` resolves who the goal counts for.
    public var side: TeamSide
    public var shooter: PlayerRef
    public var outcome: ShotOutcome
    /// `nil` means explicitly unassisted. `.unidentified` means the scorer saw an
    /// assist but could not read the number.
    public var assist: PlayerRef?
    /// The goalkeeper facing the shot, on the defending side.
    public var goalkeeper: PlayerRef?
    public var location: PitchPoint?
    public var bodyPart: BodyPart?
    public var phase: PlayPhase
    public var isOwnGoal: Bool

    public init(
        side: TeamSide,
        shooter: PlayerRef,
        outcome: ShotOutcome,
        assist: PlayerRef? = nil,
        goalkeeper: PlayerRef? = nil,
        location: PitchPoint? = nil,
        bodyPart: BodyPart? = nil,
        phase: PlayPhase = .openPlay,
        isOwnGoal: Bool = false
    ) {
        self.side = side
        self.shooter = shooter
        self.outcome = outcome
        self.assist = assist
        self.goalkeeper = goalkeeper
        self.location = location
        self.bodyPart = bodyPart
        self.phase = phase
        self.isOwnGoal = isOwnGoal
    }

    /// The side the goal counts for. Differs from `side` only on own goals.
    public var scoringSide: TeamSide { isOwnGoal ? side.opposite : side }

    /// An own goal is not credited to the scorer as a shot or a goal, and it is
    /// never assisted.
    public var creditsShooter: Bool { !isOwnGoal }
}

// MARK: - Other event payloads

public struct TeamActionEvent: Codable, Hashable, Sendable {
    public var side: TeamSide
    public var player: PlayerRef

    public init(side: TeamSide, player: PlayerRef) {
        self.side = side
        self.player = player
    }
}

public enum CardType: String, Codable, Hashable, Sendable, CaseIterable {
    case yellow
    case secondYellow
    case red

    /// A second yellow is counted as both a yellow and a dismissal.
    public var countsAsYellow: Bool { self == .yellow || self == .secondYellow }
    public var isDismissal: Bool { self == .red || self == .secondYellow }

    public var label: String {
        switch self {
        case .yellow: "Yellow Card"
        case .secondYellow: "Second Yellow"
        case .red: "Red Card"
        }
    }
}

public struct CardEvent: Codable, Hashable, Sendable {
    public var side: TeamSide
    public var player: PlayerRef
    public var card: CardType
    public var reason: String?

    public init(side: TeamSide, player: PlayerRef, card: CardType, reason: String? = nil) {
        self.side = side
        self.player = player
        self.card = card
        self.reason = reason
    }
}

public struct SubstitutionEvent: Codable, Hashable, Sendable {
    public var side: TeamSide
    public var playersOut: [PlayerID]
    public var playersIn: [PlayerID]
    /// The goalkeeper after this substitution, when it changes.
    public var goalkeeperAfter: PlayerID?

    public init(side: TeamSide, playersOut: [PlayerID], playersIn: [PlayerID], goalkeeperAfter: PlayerID? = nil) {
        self.side = side
        self.playersOut = playersOut
        self.playersIn = playersIn
        self.goalkeeperAfter = goalkeeperAfter
    }
}

public struct LineupEvent: Codable, Hashable, Sendable {
    public var side: TeamSide
    public var onField: [PlayerID]
    public var goalkeeper: PlayerID?
    public var formationID: String?

    public init(side: TeamSide, onField: [PlayerID], goalkeeper: PlayerID? = nil, formationID: String? = nil) {
        self.side = side
        self.onField = onField
        self.goalkeeper = goalkeeper
        self.formationID = formationID
    }
}

public struct ClockAdjustmentEvent: Codable, Hashable, Sendable {
    public var period: Int
    public var fromSeconds: Int
    public var toSeconds: Int
    public var reason: String?

    public init(period: Int, fromSeconds: Int, toSeconds: Int, reason: String? = nil) {
        self.period = period
        self.fromSeconds = fromSeconds
        self.toSeconds = toSeconds
        self.reason = reason
    }
}

public struct ShootoutAttemptEvent: Codable, Hashable, Sendable {
    public var side: TeamSide
    public var taker: PlayerRef
    public var goalkeeper: PlayerRef?
    public var scored: Bool
    public var order: Int

    public init(side: TeamSide, taker: PlayerRef, goalkeeper: PlayerRef? = nil, scored: Bool, order: Int) {
        self.side = side
        self.taker = taker
        self.goalkeeper = goalkeeper
        self.scored = scored
        self.order = order
    }
}

// MARK: - Payload

/// Everything Programme can know about a match is one of these.
public enum EventPayload: Codable, Hashable, Sendable {
    case lineupSet(LineupEvent)
    case periodStarted(period: Int)
    case periodEnded(period: Int)
    case clockAdjusted(ClockAdjustmentEvent)
    case shot(ShotEvent)
    case corner(TeamActionEvent)
    case steal(TeamActionEvent)
    case foul(TeamActionEvent)
    case offside(TeamActionEvent)
    case card(CardEvent)
    case substitution(SubstitutionEvent)
    case goalkeeperChanged(side: TeamSide, goalkeeper: PlayerRef)
    case shootoutAttempt(ShootoutAttemptEvent)
    case matchFinalized
    case note(String)
}

/// Coarse grouping used by the event-log filter and the palette. Deliberately
/// small: these are the categories a scorer thinks in.
public enum EventCategory: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case goal, shot, save, card, substitution, corner, steal, foul, clock, structural

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .goal: "Goals"
        case .shot: "Shots"
        case .save: "Saves"
        case .card: "Cards"
        case .substitution: "Substitutions"
        case .corner: "Corners"
        case .steal: "Steals"
        case .foul: "Fouls"
        case .clock: "Clock"
        case .structural: "Match"
        }
    }

    public var symbolName: String {
        switch self {
        case .goal: "soccerball.inverse"
        case .shot: "scope"
        case .save: "hand.raised.fill"
        case .card: "rectangle.portrait.fill"
        case .substitution: "arrow.left.arrow.right"
        case .corner: "flag.fill"
        case .steal: "shoe.2.fill"
        case .foul: "exclamationmark.triangle.fill"
        case .clock: "clock.fill"
        case .structural: "flag.checkered"
        }
    }
}

extension EventPayload {
    public var category: EventCategory {
        switch self {
        case .shot(let s):
            if s.outcome.isGoal { return .goal }
            if s.outcome == .saved { return .save }
            return .shot
        case .card: return .card
        case .substitution: return .substitution
        case .corner: return .corner
        case .steal: return .steal
        case .foul, .offside: return .foul
        case .clockAdjusted, .periodStarted, .periodEnded: return .clock
        case .lineupSet, .goalkeeperChanged, .matchFinalized, .note, .shootoutAttempt: return .structural
        }
    }

    /// The side an event belongs to, when it has one.
    public var side: TeamSide? {
        switch self {
        case .shot(let s): s.side
        case .corner(let e), .steal(let e), .foul(let e), .offside(let e): e.side
        case .card(let c): c.side
        case .substitution(let s): s.side
        case .lineupSet(let l): l.side
        case .goalkeeperChanged(let side, _): side
        case .shootoutAttempt(let a): a.side
        case .periodStarted, .periodEnded, .clockAdjusted, .matchFinalized, .note: nil
        }
    }

    /// Every player reference this payload carries. Used to detect events
    /// attributed to players who were not on the field, and to find events
    /// awaiting attribution.
    public var playerRefs: [PlayerRef] {
        switch self {
        case .shot(let s): [s.shooter, s.assist].compactMap(\.self)
        case .corner(let e), .steal(let e), .foul(let e), .offside(let e): [e.player]
        case .card(let c): [c.player]
        case .goalkeeperChanged(_, let k): [k]
        case .shootoutAttempt(let a): [a.taker]
        case .substitution(let s): (s.playersOut + s.playersIn).map(PlayerRef.player)
        case .lineupSet(let l): l.onField.map(PlayerRef.player)
        case .periodStarted, .periodEnded, .clockAdjusted, .matchFinalized, .note: []
        }
    }

    /// True when the scorer recorded the event but could not attribute it.
    /// These become the Needs Review queue.
    public var awaitsAttribution: Bool {
        playerRefs.contains { $0 == .unidentified }
    }

    /// Structural events describe the shape of the match rather than play, and
    /// are never offered for plain deletion in the event log.
    public var isStructural: Bool {
        switch self {
        case .periodStarted, .periodEnded, .lineupSet, .matchFinalized: true
        default: false
        }
    }
}

// MARK: - Revisions

public enum RevisionKind: String, Codable, Hashable, Sendable {
    case created
    case edited
    case attributed
    case timeChanged
    case voided
    case restored
}

public struct EventRevision: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var revision: Int
    public var at: Date
    public var kind: RevisionKind
    /// Human-readable audit line, e.g. "Time changed from 31:04 to 29:04".
    public var summary: String

    public init(id: UUID = UUID(), revision: Int, at: Date, kind: RevisionKind, summary: String) {
        self.id = id
        self.revision = revision
        self.at = at
        self.kind = kind
        self.summary = summary
    }
}

// MARK: - MatchEvent

/// The unit of truth. Statistics are never stored — they are derived from an
/// ordered series of these.
///
/// Events are revision-aware rather than strictly immutable: correcting a
/// mis-recorded event keeps its identity (so downstream references such as a
/// resolved attribution stay coherent) while appending an audit entry. Deletion
/// is a soft void, which makes undo trivial and keeps derived statistics
/// recomputable from a complete history.
public struct MatchEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: EventID
    public var matchID: MatchID
    public var time: MatchTime
    /// Monotonic per match. Breaks ties between events at the same match time so
    /// ordering is total and stable.
    public var sequence: Int
    /// Wall clock at which the scorer recorded this. Used by recovery to show
    /// "last event 8:17 PM", never for statistics.
    public var recordedAt: Date
    public var payload: EventPayload
    public var revision: Int
    public var voidedAt: Date?
    public var note: String?
    public var revisions: [EventRevision]

    public init(
        id: EventID = EventID(),
        matchID: MatchID,
        time: MatchTime,
        sequence: Int,
        recordedAt: Date = Date(),
        payload: EventPayload,
        revision: Int = 1,
        voidedAt: Date? = nil,
        note: String? = nil,
        revisions: [EventRevision] = []
    ) {
        self.id = id
        self.matchID = matchID
        self.time = time
        self.sequence = sequence
        self.recordedAt = recordedAt
        self.payload = payload
        self.revision = revision
        self.voidedAt = voidedAt
        self.note = note
        self.revisions = revisions.isEmpty
            ? [EventRevision(revision: 1, at: recordedAt, kind: .created, summary: "Recorded")]
            : revisions
    }

    public var isVoided: Bool { voidedAt != nil }
    public var isActive: Bool { voidedAt == nil }
    public var category: EventCategory { payload.category }
    public var awaitsAttribution: Bool { isActive && payload.awaitsAttribution }

    /// Total, stable ordering across a match.
    public var sortKey: MatchEventSortKey { MatchEventSortKey(time: time, sequence: sequence) }

    public func appendingRevision(kind: RevisionKind, summary: String, at date: Date) -> MatchEvent {
        var copy = self
        copy.revision += 1
        copy.revisions.append(EventRevision(revision: copy.revision, at: date, kind: kind, summary: summary))
        return copy
    }
}

public struct MatchEventSortKey: Comparable, Hashable, Sendable {
    public var time: MatchTime
    public var sequence: Int

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        return lhs.sequence < rhs.sequence
    }
}

extension Array where Element == MatchEvent {
    /// Chronological order, voided events excluded.
    public var activeSorted: [MatchEvent] {
        filter(\.isActive).sorted { $0.sortKey < $1.sortKey }
    }

    public var chronological: [MatchEvent] {
        sorted { $0.sortKey < $1.sortKey }
    }
}
