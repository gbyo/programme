import Foundation

/// Presentation-only snapshot for a nearby read-only scoreboard.
///
/// This is display data, never truth: the scorer device derives it from
/// its live session and broadcasts it; a display renders it and can do
/// nothing else. There is deliberately no command type on this path — a
/// remote display cannot record, substitute, adjust, undo, or finalize,
/// because the wire has no vocabulary for asking.
///
/// The clock travels as an anchor, not a tick stream: the display renders
/// time locally from `clock` + `rules` (reusing the same anchor math as
/// the scorer), so no packet is needed every second and a dropped packet
/// never drifts the display.
public struct ScoreboardSnapshot: Codable, Hashable, Sendable {
    public static let protocolVersion = 1

    public var version: Int
    public var matchID: MatchID
    public var teamShortName: String
    public var opponentShortName: String
    public var scoreUs: Int
    public var scoreOpponent: Int
    public var clock: ClockAnchor
    public var rules: MatchRules
    public var phase: MatchPhase
    public var lastEventSummary: String?
    public var finalized: Bool
    public var sentAt: Date

    public init(
        matchID: MatchID, teamShortName: String, opponentShortName: String,
        scoreUs: Int, scoreOpponent: Int, clock: ClockAnchor, rules: MatchRules,
        phase: MatchPhase, lastEventSummary: String? = nil, finalized: Bool = false,
        sentAt: Date = Date()
    ) {
        self.version = Self.protocolVersion
        self.matchID = matchID
        self.teamShortName = teamShortName
        self.opponentShortName = opponentShortName
        self.scoreUs = scoreUs
        self.scoreOpponent = scoreOpponent
        self.clock = clock
        self.rules = rules
        self.phase = phase
        self.lastEventSummary = lastEventSummary
        self.finalized = finalized
        self.sentAt = sentAt
    }

    /// Builds the broadcast snapshot from live session state. Score comes
    /// from the derived match snapshot (event truth, as everywhere); the
    /// summary is the latest event description, if any.
    public static func live(
        context: MatchContext, snapshot: MatchSnapshot, clock: ClockAnchor, sentAt: Date = Date()
    ) -> ScoreboardSnapshot {
        let last = context.events.activeSorted.last.map {
            MatchNarrator.describe($0, context: context).title
        }
        return ScoreboardSnapshot(
            matchID: context.descriptor.id,
            teamShortName: context.descriptor.teamShortName,
            opponentShortName: context.descriptor.opponentShortName,
            scoreUs: snapshot.score.us, scoreOpponent: snapshot.score.opponent,
            clock: clock, rules: context.rules, phase: context.phase,
            lastEventSummary: last,
            finalized: context.phase == .finalized || context.finalizedAt != nil,
            sentAt: sentAt)
    }

    /// A display holding this snapshot is stale when no update arrived
    /// recently and the match was not final (a final score never goes
    /// stale). Staleness is display presentation ("Reconnecting…"), never
    /// scoring state — a broken display connection has zero effect on the
    /// scorer.
    public func isStale(at date: Date = Date()) -> Bool {
        !finalized && sentAt.addingTimeInterval(15) < date
    }
}

/// Length-prefixed framing for the TCP stream: 4-byte big-endian length
/// followed by one JSON snapshot. The incremental decoder tolerates TCP
/// segmentation; anything that is not exactly one well-formed current
/// snapshot is dropped, never partially applied.
public enum ScoreboardWire {
    public static let maxFrameBytes = 64 * 1024

    public static func encode(_ snapshot: ScoreboardSnapshot) throws -> Data {
        let payload = try JSONEncoder().encode(snapshot)
        precondition(payload.count <= maxFrameBytes, "Scoreboard snapshot exceeds frame budget")
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public struct Decoder: Sendable {
        private var buffer = Data()

        public init() {}

        /// Feeds newly received bytes; returns each complete snapshot.
        /// Oversized frames and undecodable or versioned-out payloads are
        /// discarded and decoding resynchronizes at the next length prefix.
        public mutating func append(_ data: Data) -> [ScoreboardSnapshot] {
            buffer.append(data)
            var snapshots: [ScoreboardSnapshot] = []
            while true {
                // Ranges stay relative: Data slices keep their original
                // indices, so fixed ranges would trap after removeFirst.
                let base = buffer.startIndex
                guard buffer.endIndex - base >= 4 else { return snapshots }
                // Byte-wise: Data storage has no alignment guarantee, so a
                // direct UInt32 load would trap on some architectures.
                let length =
                    (UInt32(buffer[base]) << 24)
                    | (UInt32(buffer[base + 1]) << 16)
                    | (UInt32(buffer[base + 2]) << 8)
                    | UInt32(buffer[base + 3])
                guard length <= maxFrameBytes else {
                    // Desynchronized or hostile: drop everything and restart.
                    buffer.removeAll()
                    return snapshots
                }
                guard buffer.endIndex - base >= 4 + Int(length) else { return snapshots }
                let payload = buffer.subdata(in: (base + 4)..<(base + 4 + Int(length)))
                buffer.removeFirst(4 + Int(length))
                if let snapshot = try? JSONDecoder().decode(ScoreboardSnapshot.self, from: payload),
                    snapshot.version == ScoreboardSnapshot.protocolVersion
                {
                    snapshots.append(snapshot)
                }
            }
        }
    }
}
