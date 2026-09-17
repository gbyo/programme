import Foundation
import Observation
import ProgrammeCore

/// The visible clock, kept in its own observable object.
///
/// This is a performance decision with a user-visible consequence: because the
/// clock is not a property of `LiveMatchSession`, a second ticking over
/// invalidates only the views that actually read the time. The lineup, the event
/// palette and the pitch do not recompute once a second while the scorer is
/// trying to tap them.
@MainActor
@Observable
final class MatchClockModel {
    private(set) var displayText = "0:00"
    private(set) var accessibilityText = ""
    private(set) var isRunning = false
    private(set) var periodShortLabel = ""
    private(set) var periodLongLabel = ""
    private(set) var matchTime = MatchTime.kickoff
    /// 0...1 through the scheduled period. Drives the thin progress rule only.
    private(set) var periodProgress: Double = 0

    @ObservationIgnored private var anchor = ClockAnchor(period: 1)
    @ObservationIgnored private var rules = MatchRules.highSchool
    @ObservationIgnored private var ticker: Task<Void, Never>?

    deinit { ticker?.cancel() }

    func configure(anchor: ClockAnchor, rules: MatchRules) {
        self.anchor = anchor
        self.rules = rules
        refresh()
        updateTicker()
    }

    private func updateTicker() {
        if anchor.isRunning {
            guard ticker == nil else { return }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    // Sampled rather than counted: the displayed value always
                    // comes from the anchor, so a missed wake-up cannot drift.
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self else { return }
                    self.refresh()
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func refresh() {
        let now = Date()
        let time = anchor.matchTime(at: now)
        let text = time.displayText(rules: rules)
        // Only publish when something actually changed, so observation fires at
        // most once a second rather than five times.
        if text != displayText { displayText = text }
        if time != matchTime { matchTime = time }
        if anchor.isRunning != isRunning { isRunning = anchor.isRunning }

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
