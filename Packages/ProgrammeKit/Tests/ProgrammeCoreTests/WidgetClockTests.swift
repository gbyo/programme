import Foundation
import Testing

@testable import ProgrammeCore

@Suite("Widget clock renders from the anchor without timeline polls")
struct WidgetClockTests {
    private var rules: MatchRules { .highSchool }

    private func countUpRules() -> MatchRules {
        MatchRules(
            name: "Count Up", regulationPeriods: 2, regulationPeriodDuration: 40 * 60,
            clockDisplay: .countUpInPeriod)
    }

    private func cumulativeRules() -> MatchRules {
        MatchRules(
            name: "Cumulative", regulationPeriods: 2, regulationPeriodDuration: 40 * 60,
            clockDisplay: .countUpCumulative)
    }

    @Test("A running countdown range spans the rest of the period")
    func countdownRange() {
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        let anchor = ClockAnchor(
            period: 1, elapsedAtAnchor: 100, runningSince: now.addingTimeInterval(-100))
        let range = WidgetClock.timerRange(anchor: anchor, rules: rules, at: now)
        // 200 seconds elapsed; a 40-minute period ends 2_200 seconds out.
        #expect(abs(range.lowerBound.timeIntervalSince(now.addingTimeInterval(-200))) < 0.001)
        #expect(abs(range.upperBound.timeIntervalSince(now.addingTimeInterval(2_200))) < 0.001)
        #expect(range.contains(now))
    }

    @Test("The range is invariant in now while the clock runs")
    func rangeInvariantWhileRunning() {
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        let anchor = ClockAnchor(
            period: 1, elapsedAtAnchor: 100, runningSince: now.addingTimeInterval(-100))
        let first = WidgetClock.timerRange(anchor: anchor, rules: rules, at: now)
        let second = WidgetClock.timerRange(
            anchor: anchor, rules: rules, at: now.addingTimeInterval(30))
        #expect(first == second)
    }

    @Test("A stopped clock freezes on its anchor")
    func stoppedClockFreezes() {
        let anchor = ClockAnchor(period: 1, elapsedAtAnchor: 200, runningSince: nil)
        let firstNow = Date(timeIntervalSinceReferenceDate: 5_000)
        let secondNow = Date(timeIntervalSinceReferenceDate: 9_999)
        let first = WidgetClock.timerRange(anchor: anchor, rules: rules, at: firstNow)
        let second = WidgetClock.timerRange(anchor: anchor, rules: rules, at: secondNow)
        // The span is the full period either way, and the frozen remaining
        // time does not advance between the two reads.
        #expect(first.upperBound.timeIntervalSince(first.lowerBound) == 2_400)
        #expect(second.upperBound.timeIntervalSince(second.lowerBound) == 2_400)
        #expect(first.upperBound.timeIntervalSince(firstNow) == 2_200)
        #expect(second.upperBound.timeIntervalSince(secondNow) == 2_200)
    }

    @Test("An overrun clock keeps a valid range pinned at the period end")
    func overrunRange() {
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        // 200 seconds past a 40-minute period, still running.
        let anchor = ClockAnchor(
            period: 1, elapsedAtAnchor: 2_400, runningSince: now.addingTimeInterval(-200))
        let range = WidgetClock.timerRange(anchor: anchor, rules: rules, at: now)
        #expect(range.lowerBound <= range.upperBound)
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) >= 1)
    }

    @Test("Only period countdown counts down")
    func countDirection() {
        #expect(WidgetClock.countsDown(rules: rules))
        #expect(!WidgetClock.countsDown(rules: countUpRules()))
        #expect(!WidgetClock.countsDown(rules: cumulativeRules()))
    }

    @Test("Cumulative display reads the match total, not just the period")
    func cumulativeRange() {
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        let anchor = ClockAnchor(
            period: 2, elapsedAtAnchor: 100, runningSince: now.addingTimeInterval(-100))
        let range = WidgetClock.timerRange(anchor: anchor, rules: cumulativeRules(), at: now)
        // 200 seconds into period 2 of 40-minute periods: the match total
        // reads 2_600, so the range starts one full period back.
        #expect(abs(range.lowerBound.timeIntervalSince(now.addingTimeInterval(-2_600))) < 0.001)
        #expect(range.contains(now))
    }
}
