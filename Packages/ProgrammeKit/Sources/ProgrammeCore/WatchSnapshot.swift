import Foundation

/// Glanceable read-only state for the Apple Watch companion.
///
/// Like the nearby snapshot, this is presentation data with no command
/// vocabulary — the Watch never scores, edits, or finalizes. The live
/// clock travels as an anchor and renders on-watch, so companionship
/// needs application-context delivery on state changes, never
/// second-by-second streaming.
public struct WatchSnapshot: Codable, Hashable, Sendable {
    public struct Live: Codable, Hashable, Sendable {
        public var matchID: MatchID
        public var teamShortName: String
        public var opponentShortName: String
        public var scoreUs: Int
        public var scoreOpponent: Int
        public var clock: ClockAnchor
        public var rules: MatchRules
        public var phase: MatchPhase
        public var needsReviewCount: Int
        public var lastEventText: String?

        public init(
            matchID: MatchID, teamShortName: String, opponentShortName: String,
            scoreUs: Int, scoreOpponent: Int, clock: ClockAnchor, rules: MatchRules,
            phase: MatchPhase, needsReviewCount: Int, lastEventText: String? = nil
        ) {
            self.matchID = matchID
            self.teamShortName = teamShortName
            self.opponentShortName = opponentShortName
            self.scoreUs = scoreUs
            self.scoreOpponent = scoreOpponent
            self.clock = clock
            self.rules = rules
            self.phase = phase
            self.needsReviewCount = needsReviewCount
            self.lastEventText = lastEventText
        }
    }

    public struct Upcoming: Codable, Hashable, Sendable {
        public var matchID: MatchID
        public var opponentShortName: String
        public var venueLabel: String
        public var kickoff: Date

        public init(matchID: MatchID, opponentShortName: String, venueLabel: String, kickoff: Date) {
            self.matchID = matchID
            self.opponentShortName = opponentShortName
            self.venueLabel = venueLabel
            self.kickoff = kickoff
        }
    }

    public struct Recent: Codable, Hashable, Sendable {
        public var matchID: MatchID
        public var opponentShortName: String
        public var resultLetter: String
        public var scoreUs: Int
        public var scoreOpponent: Int
        public var kickoff: Date

        public init(
            matchID: MatchID, opponentShortName: String, resultLetter: String,
            scoreUs: Int, scoreOpponent: Int, kickoff: Date
        ) {
            self.matchID = matchID
            self.opponentShortName = opponentShortName
            self.resultLetter = resultLetter
            self.scoreUs = scoreUs
            self.scoreOpponent = scoreOpponent
            self.kickoff = kickoff
        }
    }

    public var teamName: String
    public var teamShortName: String
    public var recordText: String
    public var live: Live?
    public var upcoming: Upcoming?
    public var recent: [Recent]
    /// Unresolved review items team-wide (sync contradictions plus the
    /// live match's attribution count).
    public var reviewCount: Int
    public var updatedAt: Date

    public init(
        teamName: String, teamShortName: String, recordText: String,
        live: Live? = nil, upcoming: Upcoming? = nil, recent: [Recent] = [],
        reviewCount: Int = 0, updatedAt: Date = Date()
    ) {
        self.teamName = teamName
        self.teamShortName = teamShortName
        self.recordText = recordText
        self.live = live
        self.upcoming = upcoming
        self.recent = recent
        self.reviewCount = reviewCount
        self.updatedAt = updatedAt
    }

    /// Seconds without a fresh snapshot before a live Watch presentation
    /// reads stale. Pushes happen on session changes and workspace reloads,
    /// not on a timer, so the window is generous: brief event gaps stay
    /// LIVE, a truly silent phone does not.
    public static let liveStaleAfter: TimeInterval = 120

    /// Whether a live presentation built from this snapshot is too old to
    /// present as unquestionably current. Recent and upcoming sections are
    /// timeless; only the ticking live clock can lie.
    public func isLiveStale(now: Date = Date()) -> Bool {
        guard live != nil else { return false }
        return updatedAt.addingTimeInterval(Self.liveStaleAfter) < now
    }
}

/// Minimal match facts for glanceable selection. The app maps its list
/// items onto these; selection itself stays pure and testable here.
public struct WatchMatchRef: Hashable, Sendable {
    public var id: MatchID
    public var opponentShortName: String
    public var venueLabel: String
    public var kickoff: Date
    public var phase: MatchPhase
    public var resultLetter: String
    public var scoreUs: Int
    public var scoreOpponent: Int

    public init(
        id: MatchID, opponentShortName: String, venueLabel: String, kickoff: Date,
        phase: MatchPhase, resultLetter: String = "", scoreUs: Int = 0, scoreOpponent: Int = 0
    ) {
        self.id = id
        self.opponentShortName = opponentShortName
        self.venueLabel = venueLabel
        self.kickoff = kickoff
        self.phase = phase
        self.resultLetter = resultLetter
        self.scoreUs = scoreUs
        self.scoreOpponent = scoreOpponent
    }
}

public enum WatchSelection {
    /// Next scheduled kickoff (tolerating a recently-started match whose
    /// phase has not flipped yet), plus the latest finished results.
    public static func select(
        from matches: [WatchMatchRef], at date: Date = Date()
    ) -> (upcoming: WatchSnapshot.Upcoming?, recent: [WatchSnapshot.Recent]) {
        let upcoming =
            matches
            .filter { $0.phase == .scheduled && $0.kickoff > date.addingTimeInterval(-7_200) }
            .sorted { $0.kickoff < $1.kickoff }
            .first
            .map {
                WatchSnapshot.Upcoming(
                    matchID: $0.id, opponentShortName: $0.opponentShortName,
                    venueLabel: $0.venueLabel, kickoff: $0.kickoff)
            }
        let recent =
            matches
            .filter { $0.phase == .finalized }
            .sorted { $0.kickoff > $1.kickoff }
            .prefix(4)
            .map {
                WatchSnapshot.Recent(
                    matchID: $0.id, opponentShortName: $0.opponentShortName,
                    resultLetter: $0.resultLetter, scoreUs: $0.scoreUs,
                    scoreOpponent: $0.scoreOpponent, kickoff: $0.kickoff)
            }
        return (upcoming, Array(recent))
    }
}
