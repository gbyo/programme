import Foundation

/// System-timer rendering facts for the widget's live clock.
///
/// The shared widget snapshot carries the clock anchor plus rules (not a
/// frozen string), so WidgetKit animates the clock itself: no per-minute
/// timeline reloads, no tick stream, and the displayed time stays correct
/// across backgrounding and lock-screen rendering. This is the same
/// anchor technique the Live Activity and Watch companions use.
public enum WidgetClock {
    /// Count direction for a system timer view. Only `countDownInPeriod`
    /// counts down; both count-up modes count up.
    public static func countsDown(rules: MatchRules) -> Bool {
        rules.clockDisplay == .countDownInPeriod
    }

    /// Date range a system timer view should animate over, derived from
    /// the clock anchor plus rules. The period start (`runningSince -
    /// elapsedAtAnchor` while running) is invariant in `now`, so any entry
    /// date yields the same range. Cumulative display shifts the start back
    /// by prior periods so the timer reads the match total, not just this
    /// period.
    public static func timerRange(anchor: ClockAnchor, rules: MatchRules, at now: Date)
        -> ClosedRange<Date>
    {
        let duration =
            rules.period(at: anchor.period)?.scheduledDuration
            ?? rules.regulationPeriodDuration
        let elapsed = anchor.elapsed(at: now)
        let periodStart = now.addingTimeInterval(-elapsed)
        let start: Date
        if rules.clockDisplay == .countUpCumulative {
            var prior: TimeInterval = 0
            for period in 1..<max(1, anchor.period) {
                prior += TimeInterval(rules.period(at: period)?.scheduledDuration ?? 0)
            }
            start = periodStart.addingTimeInterval(-prior)
        } else {
            start = periodStart
        }
        let end = periodStart.addingTimeInterval(TimeInterval(max(0, duration)))
        let lower = min(start, end)
        let upper = max(end, lower.addingTimeInterval(1))
        return lower...upper
    }
}
