import Foundation
import Testing

@testable import ProgrammeCore

@Suite("Nearby scoreboard snapshots are presentation-only")
struct NearbyScoreboardTests {
    private func snapshot() -> ScoreboardSnapshot {
        ScoreboardSnapshot(
            matchID: MatchID(ProgrammeSample.id("match.dixie")),
            teamShortName: "NX", opponentShortName: "Dixie",
            scoreUs: 2, scoreOpponent: 1,
            clock: ClockAnchor(period: 2, elapsedAtAnchor: 300, runningSince: nil),
            rules: .highSchool, phase: .inPeriod, lastEventSummary: "Goal — Carter",
            sentAt: Date(timeIntervalSinceReferenceDate: 1000))
    }

    @Test("Snapshots round-trip through the wire exactly")
    func roundTrip() throws {
        let decoded = try ScoreboardWire.Decoder.decodeAll(ScoreboardWire.encode(snapshot()))
        #expect(decoded == [snapshot()])
    }

    @Test("Segmented TCP delivery reassembles; trailing bytes wait")
    func segmentation() throws {
        let frame = try ScoreboardWire.encode(snapshot())
        var decoder = ScoreboardWire.Decoder()
        let first = decoder.append(frame.prefix(frame.count / 2))
        #expect(first.isEmpty)
        let rest = decoder.append(frame.suffix(from: frame.count / 2))
        #expect(rest == [snapshot()])
    }

    @Test("Back-to-back frames decode in order")
    func coalesced() throws {
        var first = snapshot()
        first.scoreUs = 1
        let data = try ScoreboardWire.encode(first) + ScoreboardWire.encode(snapshot())
        #expect(try ScoreboardWire.Decoder.decodeAll(data) == [first, snapshot()])
    }

    @Test("Garbage, truncation, and future versions decode to nothing")
    func hostileInput() throws {
        #expect(try ScoreboardWire.Decoder.decodeAll(Data("hello".utf8)).isEmpty)
        let frame = try ScoreboardWire.encode(snapshot())
        #expect(try ScoreboardWire.Decoder.decodeAll(frame.prefix(frame.count - 3)).isEmpty)
        var future = snapshot()
        future.version = ScoreboardSnapshot.protocolVersion + 1
        #expect(try ScoreboardWire.Decoder.decodeAll(ScoreboardWire.encode(future)).isEmpty)
    }

    @Test("Live matches go stale without updates; final scores never do")
    func staleness() {
        let live = snapshot()
        #expect(live.isStale(at: Date(timeIntervalSinceReferenceDate: 1000 + 14)) == false)
        #expect(live.isStale(at: Date(timeIntervalSinceReferenceDate: 1000 + 16)) == true)
        var final = snapshot()
        final.finalized = true
        #expect(final.isStale(at: Date(timeIntervalSinceReferenceDate: 99999)) == false)
    }

    @Test("Link freshness is receiver-local: heartbeat receipts keep the display fresh")
    func receiverLocalFreshness() {
        let live = snapshot()
        let receivedAt = Date(timeIntervalSinceReferenceDate: 2000)
        // A heartbeat 10s later keeps the link fresh even though the wire
        // sentAt never moved.
        #expect(live.isLinkStale(lastReceivedAt: receivedAt, now: receivedAt.addingTimeInterval(10)) == false)
        // A real gap goes stale.
        #expect(live.isLinkStale(lastReceivedAt: receivedAt, now: receivedAt.addingTimeInterval(16)) == true)
        // No frame yet means waiting, not reconnecting.
        #expect(live.isLinkStale(lastReceivedAt: nil, now: receivedAt.addingTimeInterval(999)) == false)
        // Final scores never go stale, however old the last receipt.
        var final = snapshot()
        final.finalized = true
        #expect(final.isLinkStale(lastReceivedAt: receivedAt, now: receivedAt.addingTimeInterval(99999)) == false)
    }

    @Test("Oversized snapshots throw instead of crashing the scorer")
    func oversizedFailsHarmlessly() {
        var huge = snapshot()
        huge.lastEventSummary = String(repeating: "Goal! ", count: 20_000)
        #expect(throws: ScoreboardWireError.self) { try ScoreboardWire.encode(huge) }
        // And a normal snapshot still encodes fine afterwards.
        #expect(throws: Never.self) { try ScoreboardWire.encode(snapshot()) }
    }

    @Test("There is no command vocabulary on the display path")
    func readOnlyByConstruction() throws {
        // The wire decodes exactly one type. Anything else — including a
        // hypothetical command payload — decodes to nothing.
        let command = Data(
            """
            {"version":1,"command":"recordGoal","scorer":"Carter"}
            """.utf8)
        var prefixed = Data()
        var length = UInt32(command.count).bigEndian
        withUnsafeBytes(of: &length) { prefixed.append(contentsOf: $0) }
        prefixed.append(command)
        #expect(try ScoreboardWire.Decoder.decodeAll(prefixed).isEmpty)
    }
}

extension ScoreboardWire.Decoder {
    static func decodeAll(_ data: Data) throws -> [ScoreboardSnapshot] {
        var decoder = Self()
        return decoder.append(data)
    }
}
