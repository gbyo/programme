import Foundation

/// A point in a match: which period, and how many seconds of that period had
/// elapsed. Programme stores elapsed-in-period rather than a display value so
/// that changing the clock presentation never changes recorded history.
public struct MatchTime: Codable, Hashable, Sendable, Comparable {
    public var period: Int
    public var secondsElapsed: Int

    public init(period: Int, secondsElapsed: Int) {
        self.period = period
        self.secondsElapsed = max(0, secondsElapsed)
    }

    public static func period(_ p: Int, _ minutes: Int, _ seconds: Int = 0) -> MatchTime {
        MatchTime(period: p, secondsElapsed: minutes * 60 + seconds)
    }

    public static let kickoff = MatchTime(period: 1, secondsElapsed: 0)

    public static func < (lhs: MatchTime, rhs: MatchTime) -> Bool {
        (lhs.period, lhs.secondsElapsed) < (rhs.period, rhs.secondsElapsed)
    }

    public var minute: Int { secondsElapsed / 60 }
    public var second: Int { secondsElapsed % 60 }

    /// `12:04` — always two-digit seconds so the value never changes width.
    public var clockText: String {
        String(format: "%d:%02d", minute, second)
    }

    /// The value a scorer reads off the scoreboard, which depends on the
    /// display mode and, for countdown, on the scheduled period length.
    public func displayText(rules: MatchRules, priorPeriodLengths: [Int: Int] = [:]) -> String {
        switch rules.clockDisplay {
        case .countUpInPeriod:
            return clockText
        case .countDownInPeriod:
            let duration = rules.period(at: period)?.scheduledDuration ?? rules.regulationPeriodDuration
            let remaining = max(0, duration - secondsElapsed)
            return String(format: "%d:%02d", remaining / 60, remaining % 60)
        case .countUpCumulative:
            var total = secondsElapsed
            for p in 1..<max(1, period) {
                total += priorPeriodLengths[p] ?? rules.period(at: p)?.scheduledDuration ?? 0
            }
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    /// Spoken form for VoiceOver, e.g. "23 minutes 41 seconds".
    public func accessibilityText(rules: MatchRules) -> String {
        switch rules.clockDisplay {
        case .countDownInPeriod:
            let duration = rules.period(at: period)?.scheduledDuration ?? rules.regulationPeriodDuration
            let remaining = max(0, duration - secondsElapsed)
            return "\(remaining / 60) minutes \(remaining % 60) seconds remaining"
        default:
            return "\(minute) minutes \(second) seconds elapsed"
        }
    }
}

/// The durable representation of the running clock.
///
/// Programme never stores a tick counter. It stores the elapsed time at the last
/// transition plus the wall-clock date the clock was last started, and derives
/// the display from those anchors. Locking the iPad, backgrounding the app or
/// dropping animation frames therefore cannot corrupt match time.
public struct ClockAnchor: Codable, Hashable, Sendable {
    public var period: Int
    /// Seconds elapsed in the period at the moment of the anchor.
    public var elapsedAtAnchor: TimeInterval
    /// Wall clock at which the anchor was taken. `nil` means the clock is stopped.
    public var runningSince: Date?

    public init(period: Int, elapsedAtAnchor: TimeInterval = 0, runningSince: Date? = nil) {
        self.period = period
        self.elapsedAtAnchor = max(0, elapsedAtAnchor)
        self.runningSince = runningSince
    }

    public var isRunning: Bool { runningSince != nil }

    public func elapsed(at date: Date) -> TimeInterval {
        guard let runningSince else { return elapsedAtAnchor }
        return elapsedAtAnchor + max(0, date.timeIntervalSince(runningSince))
    }

    public func matchTime(at date: Date) -> MatchTime {
        MatchTime(period: period, secondsElapsed: Int(elapsed(at: date).rounded(.down)))
    }

    public func started(at date: Date) -> ClockAnchor {
        guard !isRunning else { return self }
        return ClockAnchor(period: period, elapsedAtAnchor: elapsedAtAnchor, runningSince: date)
    }

    public func stopped(at date: Date) -> ClockAnchor {
        guard isRunning else { return self }
        return ClockAnchor(period: period, elapsedAtAnchor: elapsed(at: date), runningSince: nil)
    }

    /// Move the clock to a corrected elapsed value, preserving running state.
    public func adjusted(to elapsed: TimeInterval, at date: Date) -> ClockAnchor {
        ClockAnchor(period: period, elapsedAtAnchor: max(0, elapsed), runningSince: isRunning ? date : nil)
    }

    public func movedToPeriod(_ period: Int) -> ClockAnchor {
        ClockAnchor(period: period, elapsedAtAnchor: 0, runningSince: nil)
    }
}

/// Where the match is in its lifecycle. Distinct from the clock's running state:
/// a match can be live with a stopped clock (an injury, a substitution).
public enum MatchPhase: String, Codable, Hashable, Sendable {
    /// Created, lineup possibly set, not yet kicked off.
    case scheduled
    /// A period is underway.
    case inPeriod
    /// Between periods.
    case periodBreak
    /// All periods played, awaiting finalization.
    case awaitingFinalization
    case finalized

    public var isLive: Bool { self == .inPeriod || self == .periodBreak }
}
