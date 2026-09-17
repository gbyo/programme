import Foundation

/// A category of statistic that a match either was or was not tracking.
///
/// Programme records this per match so that a statistic nobody was watching is
/// never silently reported as zero. A zero means zero. Not tracked means unknown.
public enum TrackedStat: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case goals
    case assists
    case shots
    case goalkeeping
    case corners
    case steals
    case cards
    case fouls
    case offsides
    case penaltyKicks
    case shotLocations

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .goals: "Goals"
        case .assists: "Assists"
        case .shots: "Shots"
        case .goalkeeping: "Goalkeeping"
        case .corners: "Corner Kicks"
        case .steals: "Steals"
        case .cards: "Cards"
        case .fouls: "Fouls"
        case .offsides: "Offsides"
        case .penaltyKicks: "Penalty Kicks"
        case .shotLocations: "Shot Locations"
        }
    }

    public var detail: String {
        switch self {
        case .goals: "Goals and the score."
        case .assists: "Assist credit on goals."
        case .shots: "Shots and shots on goal."
        case .goalkeeping: "Saves, goals allowed and goalkeeper minutes."
        case .corners: "Corner kicks taken."
        case .steals: "Steals and takeaways."
        case .cards: "Yellow and red cards."
        case .fouls: "Fouls committed."
        case .offsides: "Offside calls."
        case .penaltyKicks: "Penalty kick attempts and conversions."
        case .shotLocations: "Where on the pitch each shot was struck."
        }
    }

    /// Minutes are always derived from lineup intervals, so they are never
    /// optional and never appear in a profile.
    public static let alwaysTracked: Set<TrackedStat> = [.goals]
}

/// Which follow-up questions the scorer is asked after a primary action.
/// Keeping these out of the default MaxPreps flow is what makes recording a
/// shot two taps rather than five.
public struct DetailPrompts: Codable, Hashable, Sendable {
    public var assistOnGoal: Bool
    public var shotLocation: Bool
    public var bodyPart: Bool
    public var playPhase: Bool
    public var cardReason: Bool

    public init(
        assistOnGoal: Bool = true,
        shotLocation: Bool = false,
        bodyPart: Bool = false,
        playPhase: Bool = false,
        cardReason: Bool = false
    ) {
        self.assistOnGoal = assistOnGoal
        self.shotLocation = shotLocation
        self.bodyPart = bodyPart
        self.playPhase = playPhase
        self.cardReason = cardReason
    }

    public static let minimal = DetailPrompts(assistOnGoal: false)
    public static let maxPreps = DetailPrompts(assistOnGoal: true)
    public static let standard = DetailPrompts(assistOnGoal: true, shotLocation: true)
    public static let advanced = DetailPrompts(
        assistOnGoal: true, shotLocation: true, bodyPart: true, playPhase: true, cardReason: true
    )
}

public struct StatProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var tracked: Set<TrackedStat>
    public var prompts: DetailPrompts

    public init(id: String, name: String, detail: String, tracked: Set<TrackedStat>, prompts: DetailPrompts) {
        self.id = id
        self.name = name
        self.detail = detail
        self.tracked = tracked.union(TrackedStat.alwaysTracked)
        self.prompts = prompts
    }

    public func tracks(_ stat: TrackedStat) -> Bool { tracked.contains(stat) }

    /// Wrap a raw count in the tracked/not-tracked distinction.
    public func value(_ stat: TrackedStat, _ count: Int) -> StatValue {
        tracks(stat) ? .count(count) : .notTracked
    }
}

extension StatProfile {
    public static let scoreOnly = StatProfile(
        id: "score-only",
        name: "Score Only",
        detail: "Goals, score, cards and match state. The fastest possible scoring.",
        tracked: [.goals, .cards],
        prompts: .minimal
    )

    /// Programme's default. Exactly the categories a high-school stat keeper
    /// publishes, and nothing else.
    public static let maxPreps = StatProfile(
        id: "maxpreps",
        name: "MaxPreps",
        detail: "Everything needed to publish high-school soccer statistics.",
        tracked: [.goals, .assists, .shots, .goalkeeping, .corners, .steals, .cards, .penaltyKicks],
        prompts: .maxPreps
    )

    public static let standard = StatProfile(
        id: "standard",
        name: "Standard",
        detail: "MaxPreps plus fouls, offsides and shot locations.",
        tracked: [
            .goals, .assists, .shots, .goalkeeping, .corners, .steals, .cards,
            .penaltyKicks, .fouls, .offsides, .shotLocations,
        ],
        prompts: .standard
    )

    public static let advanced = StatProfile(
        id: "advanced",
        name: "Advanced",
        detail: "Every category, with body part and phase of play on each shot.",
        tracked: Set(TrackedStat.allCases),
        prompts: .advanced
    )

    public static let presets: [StatProfile] = [.scoreOnly, .maxPreps, .standard, .advanced]

    public static func preset(id: String) -> StatProfile? { presets.first { $0.id == id } }
}

/// A statistic's value, carrying the tracked/untracked distinction all the way
/// through season aggregation and export.
public enum StatValue: Hashable, Sendable {
    case count(Int)
    case rate(Double)
    /// Nobody was recording this category during the match.
    case notTracked
    /// Tracked, but undefined for this input — a save percentage with no shots faced.
    case notApplicable

    public var isTracked: Bool { self != .notTracked }

    public var countValue: Int? {
        if case .count(let v) = self { return v }
        return nil
    }

    public var rateValue: Double? {
        if case .rate(let v) = self { return v }
        return nil
    }

    /// Display text. Never renders an untracked statistic as "0".
    public func text(fractionDigits: Int = 1) -> String {
        switch self {
        case .count(let v): "\(v)"
        case .rate(let v): String(format: "%.\(fractionDigits)f", v)
        case .notTracked: "—"
        case .notApplicable: "–"
        }
    }

    public var accessibilityText: String {
        switch self {
        case .count(let v): "\(v)"
        case .rate(let v): String(format: "%.2f", v)
        case .notTracked: "not tracked"
        case .notApplicable: "not applicable"
        }
    }

    /// Percentage text for ratios stored 0...1.
    public var percentText: String {
        switch self {
        case .rate(let v): String(format: "%.1f%%", v * 100)
        case .count(let v): "\(v)"
        case .notTracked: "—"
        case .notApplicable: "–"
        }
    }
}
