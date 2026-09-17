import Foundation

public enum PeriodKind: String, Codable, Hashable, Sendable {
    case regulation
    case overtime
    case shootout
}

/// A concrete period in a match, derived from `MatchRules`.
public struct PeriodDescriptor: Codable, Hashable, Sendable, Identifiable {
    /// 1-based index across the entire match, including overtime.
    public var index: Int
    public var kind: PeriodKind
    /// Scheduled length in seconds. Zero for a shootout, which has no clock.
    public var scheduledDuration: Int
    public var shortLabel: String
    public var longLabel: String

    public var id: Int { index }

    public init(index: Int, kind: PeriodKind, scheduledDuration: Int, shortLabel: String, longLabel: String) {
        self.index = index
        self.kind = kind
        self.scheduledDuration = scheduledDuration
        self.shortLabel = shortLabel
        self.longLabel = longLabel
    }
}

/// How the clock is presented. This is purely a display concern — the stored
/// truth is always seconds elapsed within a period.
public enum ClockDisplayMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// 40:00 → 0:00 within each period. The high-school norm.
    case countDownInPeriod
    /// 0:00 → 40:00 within each period.
    case countUpInPeriod
    /// 0:00 → 90:00 across the whole match. The broadcast norm.
    case countUpCumulative

    public var label: String {
        switch self {
        case .countDownInPeriod: "Count down each period"
        case .countUpInPeriod: "Count up each period"
        case .countUpCumulative: "Count up cumulatively"
        }
    }
}

public enum ReEntryRule: String, Codable, Hashable, Sendable, CaseIterable {
    /// A player may leave and return any number of times. High-school soccer.
    case unlimited
    /// A player may not return once substituted out.
    case none
    /// A player may return, but not in the same period they left.
    case oncePerPeriod

    public var label: String {
        switch self {
        case .unlimited: "Unlimited re-entry"
        case .none: "No re-entry"
        case .oncePerPeriod: "Re-entry in a later period"
        }
    }
}

/// The competition format. Programme never hard-codes one soccer ruleset; a
/// match stores the rules it was played under so derived statistics that depend
/// on match length (goals-against average, most notably) stay correct forever.
public struct MatchRules: Codable, Hashable, Sendable {
    public var name: String
    public var regulationPeriods: Int
    public var regulationPeriodDuration: Int
    public var overtimePeriods: Int
    public var overtimePeriodDuration: Int
    public var overtimeIsSuddenDeath: Bool
    public var shootoutAvailable: Bool
    public var clockDisplay: ClockDisplayMode
    /// When true the clock keeps running through stoppages, as in professional
    /// soccer. When false the scorer stops it for injuries and substitutions.
    public var clockRunsContinuously: Bool
    public var reEntry: ReEntryRule
    public var playersPerSide: Int
    /// Below this, the match cannot legally continue.
    public var minimumPlayersPerSide: Int

    public init(
        name: String,
        regulationPeriods: Int,
        regulationPeriodDuration: Int,
        overtimePeriods: Int = 0,
        overtimePeriodDuration: Int = 0,
        overtimeIsSuddenDeath: Bool = false,
        shootoutAvailable: Bool = false,
        clockDisplay: ClockDisplayMode = .countDownInPeriod,
        clockRunsContinuously: Bool = true,
        reEntry: ReEntryRule = .unlimited,
        playersPerSide: Int = 11,
        minimumPlayersPerSide: Int = 7
    ) {
        self.name = name
        self.regulationPeriods = regulationPeriods
        self.regulationPeriodDuration = regulationPeriodDuration
        self.overtimePeriods = overtimePeriods
        self.overtimePeriodDuration = overtimePeriodDuration
        self.overtimeIsSuddenDeath = overtimeIsSuddenDeath
        self.shootoutAvailable = shootoutAvailable
        self.clockDisplay = clockDisplay
        self.clockRunsContinuously = clockRunsContinuously
        self.reEntry = reEntry
        self.playersPerSide = playersPerSide
        self.minimumPlayersPerSide = minimumPlayersPerSide
    }

    /// Scheduled regulation length in seconds. Used by rate statistics such as GAA.
    public var regulationLength: Int { regulationPeriods * regulationPeriodDuration }

    /// Every period this ruleset can produce, in order.
    public var periods: [PeriodDescriptor] {
        var result: [PeriodDescriptor] = []
        for i in 1...max(1, regulationPeriods) {
            result.append(
                PeriodDescriptor(
                    index: i,
                    kind: .regulation,
                    scheduledDuration: regulationPeriodDuration,
                    shortLabel: Self.regulationShortLabel(i, of: regulationPeriods),
                    longLabel: Self.regulationLongLabel(i, of: regulationPeriods)
                )
            )
        }
        if overtimePeriods > 0 {
            for i in 1...overtimePeriods {
                let index = regulationPeriods + i
                let short = overtimePeriods == 1 ? "OT" : "\(i)OT"
                let long = overtimePeriods == 1 ? "Overtime" : "Overtime \(i)"
                result.append(
                    PeriodDescriptor(
                        index: index,
                        kind: .overtime,
                        scheduledDuration: overtimePeriodDuration,
                        shortLabel: short,
                        longLabel: long
                    )
                )
            }
        }
        if shootoutAvailable {
            result.append(
                PeriodDescriptor(
                    index: regulationPeriods + overtimePeriods + 1,
                    kind: .shootout,
                    scheduledDuration: 0,
                    shortLabel: "PK",
                    longLabel: "Shootout"
                )
            )
        }
        return result
    }

    public func period(at index: Int) -> PeriodDescriptor? {
        periods.first { $0.index == index }
    }

    /// The last period that can be played under these rules.
    public var finalPeriodIndex: Int { periods.last?.index ?? regulationPeriods }

    private static func regulationShortLabel(_ i: Int, of total: Int) -> String {
        if total == 2 { return i == 1 ? "1st" : "2nd" }
        return ordinal(i)
    }

    private static func regulationLongLabel(_ i: Int, of total: Int) -> String {
        if total == 2 { return i == 1 ? "First Half" : "Second Half" }
        if total == 4 { return "\(ordinal(i)) Quarter" }
        return "\(ordinal(i)) Period"
    }

    static func ordinal(_ i: Int) -> String {
        switch i {
        case 1: "1st"
        case 2: "2nd"
        case 3: "3rd"
        default: "\(i)th"
        }
    }
}

extension MatchRules {
    /// NFHS-style high-school soccer: two 40-minute halves, two 10-minute
    /// sudden-victory overtime periods, unlimited re-entry, running clock.
    public static let highSchool = MatchRules(
        name: "High School",
        regulationPeriods: 2,
        regulationPeriodDuration: 40 * 60,
        overtimePeriods: 2,
        overtimePeriodDuration: 10 * 60,
        overtimeIsSuddenDeath: true,
        shootoutAvailable: true,
        clockDisplay: .countDownInPeriod,
        clockRunsContinuously: true,
        reEntry: .unlimited
    )

    /// High-school regular season where a draw simply stands.
    public static let highSchoolNoOvertime = MatchRules(
        name: "High School (No Overtime)",
        regulationPeriods: 2,
        regulationPeriodDuration: 40 * 60,
        clockDisplay: .countDownInPeriod,
        reEntry: .unlimited
    )

    public static let college = MatchRules(
        name: "College",
        regulationPeriods: 2,
        regulationPeriodDuration: 45 * 60,
        overtimePeriods: 2,
        overtimePeriodDuration: 10 * 60,
        overtimeIsSuddenDeath: true,
        shootoutAvailable: true,
        clockDisplay: .countDownInPeriod,
        reEntry: .unlimited
    )

    public static let professional = MatchRules(
        name: "Professional",
        regulationPeriods: 2,
        regulationPeriodDuration: 45 * 60,
        overtimePeriods: 2,
        overtimePeriodDuration: 15 * 60,
        shootoutAvailable: true,
        clockDisplay: .countUpCumulative,
        clockRunsContinuously: true,
        reEntry: .none
    )

    public static let middleSchool = MatchRules(
        name: "Middle School",
        regulationPeriods: 2,
        regulationPeriodDuration: 30 * 60,
        clockDisplay: .countDownInPeriod,
        reEntry: .unlimited
    )

    public static let youthQuarters = MatchRules(
        name: "Youth (Quarters)",
        regulationPeriods: 4,
        regulationPeriodDuration: 15 * 60,
        clockDisplay: .countDownInPeriod,
        reEntry: .unlimited,
        playersPerSide: 9,
        minimumPlayersPerSide: 6
    )

    public static let presets: [MatchRules] = [
        .highSchool, .highSchoolNoOvertime, .college, .professional, .middleSchool, .youthQuarters,
    ]
}
