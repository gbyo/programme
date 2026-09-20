import Foundation
import Observation
import ProgrammeCore

/// The visible clock, kept in its own observable object.
///
/// This is a performance decision with a user-visible consequence: because the
/// clock is not a property of `LiveMatchSession`, scorer chrome that depends
/// on clock state only recomputes when the anchor actually changes (configure,
/// start/stop, period transitions, adjustments). Advancing time itself is
/// rendered by system timer views from the anchor, so no app-owned task wakes
/// up just to move the clock.
@MainActor
@Observable
final class MatchClockModel {
    private(set) var displayText = "0:00"
    private(set) var accessibilityText = ""
    private(set) var isRunning = false
    private(set) var countsDown = true
    private(set) var periodShortLabel = ""
    private(set) var periodLongLabel = ""
    private(set) var matchTime = MatchTime.kickoff
    /// 0...1 through the scheduled period. Frozen rendering for stopped
    /// clocks; running clocks animate progress from the anchor instead.
    private(set) var periodProgress: Double = 0

    @ObservationIgnored private var anchor = ClockAnchor(period: 1)
    @ObservationIgnored private var rules = MatchRules.highSchool

    func configure(anchor: ClockAnchor, rules: MatchRules) {
        self.anchor = anchor
        self.rules = rules
        refresh()
    }

    private func refresh() {
        let now = Date()
        let time = anchor.matchTime(at: now)
        let text = time.displayText(rules: rules)
        // Only publish when something actually changed: refresh runs on
        // configure, so observation fires on state changes, never per tick.
        if text != displayText { displayText = text }
        if time != matchTime { matchTime = time }
        if anchor.isRunning != isRunning { isRunning = anchor.isRunning }
        let shouldCountDown = rules.clockDisplay == .countDownInPeriod
        if shouldCountDown != countsDown { countsDown = shouldCountDown }

        let descriptor = rules.period(at: anchor.period)
        let short = descriptor?.shortLabel ?? ""
        if short != periodShortLabel { periodShortLabel = short }
        let long = descriptor?.longLabel ?? ""
        if long != periodLongLabel { periodLongLabel = long }

        let duration = descriptor?.scheduledDuration ?? rules.regulationPeriodDuration
        let progress = duration > 0 ? min(1, Double(time.secondsElapsed) / Double(duration)) : 0
        if abs(progress - periodProgress) > 0.001 { periodProgress = progress }

        let spoken = time.accessibilityText(rules: rules)
        if spoken != accessibilityText { accessibilityText = spoken }
    }
}
