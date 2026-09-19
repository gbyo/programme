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
}
