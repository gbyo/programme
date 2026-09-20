import Foundation
import Testing

@testable import ProgrammeCore

@Suite("Watch snapshots select glanceable state deterministically")
struct WatchSnapshotTests {
    private func ref(
        _ name: String, kickoff: TimeInterval, phase: MatchPhase,
        result: String = "", us: Int = 0, op: Int = 0
    ) -> WatchMatchRef {
        WatchMatchRef(
            id: MatchID(ProgrammeSample.id("match.\(name)")),
            opponentShortName: name, venueLabel: "Away", kickoff: Date(timeIntervalSinceReferenceDate: kickoff),
            phase: phase, resultLetter: result, scoreUs: us, scoreOpponent: op)
    }

    @Test("Upcoming is the next kickoff; recent is finished, newest first")
    func selection() {
        let matches = [
            ref("old", kickoff: 100, phase: .finalized, result: "W", us: 3, op: 1),
            ref("new", kickoff: 200, phase: .finalized, result: "L", us: 0, op: 2),
            ref("next", kickoff: 10_000, phase: .scheduled),
            ref("later", kickoff: 20_000, phase: .scheduled),
        ]
        let (upcoming, recent) = WatchSelection.select(
            from: matches, at: Date(timeIntervalSinceReferenceDate: 1000))
        #expect(upcoming?.opponentShortName == "next")
        #expect(recent.map(\.opponentShortName) == ["new", "old"])
    }

    @Test("Live-phase matches are neither upcoming nor recent")
    func liveExcluded() {
        let matches = [ref("live", kickoff: 900, phase: .inPeriod)]
        let (upcoming, recent) = WatchSelection.select(
            from: matches, at: Date(timeIntervalSinceReferenceDate: 1000))
        #expect(upcoming == nil)
        #expect(recent.isEmpty)
    }

    @Test("A recently-started match still counts as upcoming")
    func gracePeriod() {
        let matches = [ref("justStarted", kickoff: 500, phase: .scheduled)]
        let (upcoming, _) = WatchSelection.select(
            from: matches, at: Date(timeIntervalSinceReferenceDate: 1000))
        #expect(upcoming?.opponentShortName == "justStarted")
    }

    @Test("Recent caps at four")
    func recentCap() {
        let matches = (0..<6).map {
            ref("m\($0)", kickoff: TimeInterval(100 + $0), phase: .finalized, result: "W", us: 1, op: 0)
        }
        let (_, recent) = WatchSelection.select(
            from: matches, at: Date(timeIntervalSinceReferenceDate: 1000))
        #expect(recent.count == 4)
        #expect(recent.first?.opponentShortName == "m5")
    }

    @Test("Snapshots encode for application context")
    func contextCoding() throws {
        let snapshot = WatchSnapshot(
            teamName: "Ninety Six", teamShortName: "NX", recordText: "3-1-0",
            live: WatchSnapshot.Live(
                matchID: MatchID(ProgrammeSample.id("match.dixie")),
                teamShortName: "NX", opponentShortName: "Dixie",
                scoreUs: 2, scoreOpponent: 1,
                clock: ClockAnchor(period: 2, elapsedAtAnchor: 300, runningSince: nil),
                rules: .highSchool, phase: .inPeriod, needsReviewCount: 1,
                lastEventText: "Goal — Carter"),
            upcoming: nil, recent: [], reviewCount: 2,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1000))
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test("Timer range derives from the anchor for count-down clocks")
    func timerRangeCountDown() {
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        let runningSince = base
        let live = WatchSnapshot.Live(
            matchID: MatchID(ProgrammeSample.id("match.dixie")),
            teamShortName: "NX", opponentShortName: "Dixie",
            scoreUs: 2, scoreOpponent: 1,
            clock: ClockAnchor(period: 1, elapsedAtAnchor: 300, runningSince: runningSince),
            rules: .highSchool, phase: .inPeriod, needsReviewCount: 0,
            lastEventText: nil)
        let now = base.addingTimeInterval(45)
        // Elapsed 345; period start is invariant: runningSince - elapsedAtAnchor.
        let expectedStart = base.addingTimeInterval(-300)
        let expectedEnd = expectedStart.addingTimeInterval(2400)
        #expect(live.countsDown == true)
        #expect(live.timerRange(at: now) == expectedStart...expectedEnd)
        // Same range from any entry date while running.
        #expect(live.timerRange(at: now.addingTimeInterval(17)) == expectedStart...expectedEnd)
        #expect(live.clockText(at: now) == "34:15 1st")
    }

    @Test("Timer counts up within the period")
    func timerRangeCountUp() {
        let base = Date(timeIntervalSinceReferenceDate: 2000)
        let rules = MatchRules(
            name: "Test Up", regulationPeriods: 2, regulationPeriodDuration: 2400,
            clockDisplay: .countUpInPeriod)
        let live = WatchSnapshot.Live(
            matchID: MatchID(ProgrammeSample.id("match.dixie")),
            teamShortName: "NX", opponentShortName: "Dixie",
            scoreUs: 0, scoreOpponent: 0,
            clock: ClockAnchor(period: 1, elapsedAtAnchor: 100, runningSince: base),
            rules: rules, phase: .inPeriod, needsReviewCount: 0,
            lastEventText: nil)
        let now = base.addingTimeInterval(25)
        let expectedStart = base.addingTimeInterval(-100)
        #expect(live.countsDown == false)
        #expect(live.timerRange(at: now) == expectedStart...expectedStart.addingTimeInterval(2400))
        #expect(live.clockText(at: now) == "2:05 1st")
    }

    @Test("Cumulative timer reads the match total, not just the period")
    func timerRangeCumulative() {
        let base = Date(timeIntervalSinceReferenceDate: 3000)
        let live = WatchSnapshot.Live(
            matchID: MatchID(ProgrammeSample.id("match.dixie")),
            teamShortName: "NX", opponentShortName: "Dixie",
            scoreUs: 1, scoreOpponent: 1,
            clock: ClockAnchor(period: 2, elapsedAtAnchor: 60, runningSince: base),
            rules: .professional, phase: .inPeriod, needsReviewCount: 0,
            lastEventText: nil)
        let now = base.addingTimeInterval(30)
        // Period 2 of professional: prior period contributes 45:00.
        let periodStart = base.addingTimeInterval(-60)
        let expectedStart = periodStart.addingTimeInterval(-2700)
        let expectedEnd = periodStart.addingTimeInterval(2700)
        #expect(live.countsDown == false)
        #expect(live.timerRange(at: now) == expectedStart...expectedEnd)
        // System elapsed matches the displayed total: 90 + 2700 = 2790 -> 46:30.
        #expect(now.timeIntervalSince(live.timerRange(at: now).lowerBound) == 2790)
        #expect(live.clockText(at: now) == "46:30 2nd")
    }

    @Test("Stale snapshots freeze at the update time")
    func staleFreeze() {
        let base = Date(timeIntervalSinceReferenceDate: 4000)
        let snapshot = WatchSnapshot(
            teamName: "Ninety Six", teamShortName: "NX", recordText: "3-1-0",
            live: WatchSnapshot.Live(
                matchID: MatchID(ProgrammeSample.id("match.dixie")),
                teamShortName: "NX", opponentShortName: "Dixie",
                scoreUs: 2, scoreOpponent: 1,
                clock: ClockAnchor(period: 1, elapsedAtAnchor: 300, runningSince: base),
                rules: .highSchool, phase: .inPeriod, needsReviewCount: 0,
                lastEventText: nil),
            updatedAt: base)
        let live = snapshot.live!
        #expect(snapshot.liveStaleAt == base.addingTimeInterval(120))
        #expect(snapshot.liveStaleTransitionAt == base.addingTimeInterval(121))
        #expect(snapshot.liveTimelineEntries == [base, base.addingTimeInterval(121)])
        #expect(snapshot.isLiveStale(now: base) == false)
        #expect(snapshot.isLiveStale(now: snapshot.liveStaleTransitionAt) == true)
        // The anchor keeps advancing, but presentation must not follow it.
        let staleDate = base.addingTimeInterval(1000)
        #expect(snapshot.isLiveStale(now: staleDate) == true)
        #expect(live.clockText(at: staleDate) != live.clockText(at: base))
        #expect(live.clockText(at: base) == "35:00 1st")
    }

    @Test("Stale live snapshots read stale; timeless sections never do")
    func liveStaleness() {
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        func live(at updatedAt: Date) -> WatchSnapshot {
            WatchSnapshot(
                teamName: "Ninety Six", teamShortName: "NX", recordText: "3-1-0",
                live: WatchSnapshot.Live(
                    matchID: MatchID(ProgrammeSample.id("match.dixie")),
                    teamShortName: "NX", opponentShortName: "Dixie",
                    scoreUs: 2, scoreOpponent: 1,
                    clock: ClockAnchor(period: 2, elapsedAtAnchor: 300, runningSince: nil),
                    rules: .highSchool, phase: .inPeriod, needsReviewCount: 1,
                    lastEventText: nil),
                updatedAt: updatedAt)
        }
        #expect(live(at: base).isLiveStale(now: base.addingTimeInterval(60)) == false)
        #expect(live(at: base).isLiveStale(now: base.addingTimeInterval(121)) == true)
        let timeless = WatchSnapshot(
            teamName: "Ninety Six", teamShortName: "NX", recordText: "3-1-0",
            updatedAt: base)
        #expect(timeless.isLiveStale(now: base.addingTimeInterval(99999)) == false)
    }
}
