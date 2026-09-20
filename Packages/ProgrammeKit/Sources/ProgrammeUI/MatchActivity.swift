import Foundation
import ProgrammeCore

#if os(iOS)
    import ActivityKit

    /// The active-match Live Activity.
    ///
    /// The clock is published as a date range rather than a string so the system
    /// animates it without Programme waking up once a second. That matches how
    /// the app itself keeps time: anchors, not ticks.
    public struct MatchActivityAttributes: ActivityAttributes {
        public struct ContentState: Codable, Hashable, Sendable {
            public var scoreUs: Int
            public var scoreOpponent: Int
            public var periodLabel: String
            public var isClockRunning: Bool
            /// The notional instant at which this period's clock read zero.
            public var clockStart: Date
            /// The notional instant at which it reaches the period's full length.
            public var clockEnd: Date
            public var countsDown: Bool
            /// Shown when the clock is stopped, where a live timer would be wrong.
            public var frozenClockText: String
            public var lastEventText: String?
            public var needsReviewCount: Int

            public init(
                scoreUs: Int,
                scoreOpponent: Int,
                periodLabel: String,
                isClockRunning: Bool,
                clockStart: Date,
                clockEnd: Date,
                countsDown: Bool,
                frozenClockText: String,
                lastEventText: String? = nil,
                needsReviewCount: Int = 0
            ) {
                self.scoreUs = scoreUs
                self.scoreOpponent = scoreOpponent
                self.periodLabel = periodLabel
                self.isClockRunning = isClockRunning
                self.clockStart = clockStart
                self.clockEnd = clockEnd
                self.countsDown = countsDown
                self.frozenClockText = frozenClockText
                self.lastEventText = lastEventText
                self.needsReviewCount = needsReviewCount
            }

            /// The range a system timer view should animate over.
            public var timerRange: ClosedRange<Date> {
                let start = min(clockStart, clockEnd)
                let end = max(clockStart, clockEnd)
                return start...max(end, start.addingTimeInterval(1))
            }
        }

        public var matchID: String
        public var teamName: String
        public var opponentName: String
        public var venueLabel: String

        public init(matchID: String, teamName: String, opponentName: String, venueLabel: String) {
            self.matchID = matchID
            self.teamName = teamName
            self.opponentName = opponentName
            self.venueLabel = venueLabel
        }
    }

    extension MatchActivityAttributes.ContentState {
        /// Build the published state from the authoritative match state.
        public static func make(
            snapshot: MatchSnapshot,
            clock: ClockAnchor,
            rules: MatchRules,
            lastEventText: String?,
            now: Date = Date()
        ) -> Self {
            let duration =
                rules.period(at: clock.period)?.scheduledDuration
                ?? rules.regulationPeriodDuration
            let elapsed = clock.elapsed(at: now)
            let start = now.addingTimeInterval(-elapsed)
            let end = start.addingTimeInterval(TimeInterval(duration))
            let frozen = MatchTime(period: clock.period, secondsElapsed: Int(elapsed))
                .displayText(rules: rules)
            return MatchActivityAttributes.ContentState(
                scoreUs: snapshot.score.us,
                scoreOpponent: snapshot.score.opponent,
                periodLabel: rules.period(at: clock.period)?.shortLabel ?? "",
                isClockRunning: clock.isRunning,
                clockStart: start,
                clockEnd: end,
                countsDown: rules.clockDisplay == .countDownInPeriod,
                frozenClockText: frozen,
                lastEventText: lastEventText,
                needsReviewCount: snapshot.needsReviewCount
            )
        }
    }
#endif

/// A small, self-contained view of the team's state that widgets can read
/// without opening the database.
///
/// Widgets run in a separate process, so Programme writes this file into the
/// shared container whenever a match changes. It is a cache: losing it costs a
/// widget refresh and nothing else.
/// WidgetKit kind identifiers, shared so the app targets reloads at the
/// same strings the widget extension registers.
public enum WidgetKind {
    public static let matchStatus = "com.gbyo.programme.matchStatus"
    public static let seasonRecord = "com.gbyo.programme.seasonRecord"
}

public struct ProgrammeWidgetSnapshot: Codable, Hashable, Sendable {
    public struct LiveMatch: Codable, Hashable, Sendable {
        public var matchID: String
        public var teamShortName: String
        public var opponentShortName: String
        public var scoreUs: Int
        public var scoreOpponent: Int
        public var periodLabel: String
        public var clockText: String
        public var isClockRunning: Bool
        public var needsReviewCount: Int
        public var lastEventText: String?
        /// Clock anchor plus rules for system-driven timer text. Optional
        /// so snapshots written before this field existed still decode;
        /// those fall back to the frozen `clockText`.
        public var clockAnchor: ClockAnchor?
        public var clockRules: MatchRules?

        public init(
            matchID: String, teamShortName: String, opponentShortName: String, scoreUs: Int,
            scoreOpponent: Int, periodLabel: String, clockText: String, isClockRunning: Bool,
            needsReviewCount: Int, lastEventText: String?, clockAnchor: ClockAnchor? = nil,
            clockRules: MatchRules? = nil
        ) {
            self.matchID = matchID
            self.teamShortName = teamShortName
            self.opponentShortName = opponentShortName
            self.scoreUs = scoreUs
            self.scoreOpponent = scoreOpponent
            self.periodLabel = periodLabel
            self.clockText = clockText
            self.isClockRunning = isClockRunning
            self.needsReviewCount = needsReviewCount
            self.lastEventText = lastEventText
            self.clockAnchor = clockAnchor
            self.clockRules = clockRules
        }
    }

    public struct UpcomingMatch: Codable, Hashable, Sendable {
        public var matchID: String
        public var opponentShortName: String
        public var venueLabel: String
        public var kickoff: Date

        public init(matchID: String, opponentShortName: String, venueLabel: String, kickoff: Date) {
            self.matchID = matchID
            self.opponentShortName = opponentShortName
            self.venueLabel = venueLabel
            self.kickoff = kickoff
        }
    }

    public struct RecentResult: Codable, Hashable, Sendable {
        public var matchID: String
        public var opponentShortName: String
        public var resultLetter: String
        public var scoreUs: Int
        public var scoreOpponent: Int
        public var kickoff: Date

        public init(
            matchID: String, opponentShortName: String, resultLetter: String, scoreUs: Int,
            scoreOpponent: Int, kickoff: Date
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
    public var seasonName: String?
    public var recordText: String
    public var live: LiveMatch?
    public var upcoming: UpcomingMatch?
    public var recent: [RecentResult]
    public var updatedAt: Date

    public init(
        teamName: String, teamShortName: String, seasonName: String?, recordText: String,
        live: LiveMatch?, upcoming: UpcomingMatch?, recent: [RecentResult], updatedAt: Date = Date()
    ) {
        self.teamName = teamName
        self.teamShortName = teamShortName
        self.seasonName = seasonName
        self.recordText = recordText
        self.live = live
        self.upcoming = upcoming
        self.recent = recent
        self.updatedAt = updatedAt
    }
}

/// Where the app and its widgets exchange the snapshot.
public enum ProgrammeSharedContainer {
    /// Configure an App Group in the project to let widgets read live data.
    /// Without it Programme still works completely; widgets fall back to a
    /// "no data yet" state rather than showing anything invented.
    public static let appGroupIdentifier = "group.com.gbyo.programme"

    public static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    public static var snapshotURL: URL? {
        directory?.appending(path: "ProgrammeWidgetSnapshot.json")
    }

    public static func write(_ snapshot: ProgrammeWidgetSnapshot) {
        guard let url = snapshotURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> ProgrammeWidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProgrammeWidgetSnapshot.self, from: data)
    }

    public static func clearLiveMatch() {
        guard var snapshot = read() else { return }
        snapshot.live = nil
        snapshot.updatedAt = Date()
        write(snapshot)
    }
}
