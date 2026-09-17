import Foundation

/// A period that was actually played, with its real length rather than its
/// scheduled one. Minutes must reflect the match that happened.
public struct PeriodSpan: Hashable, Sendable, Identifiable {
    public var period: Int
    public var kind: PeriodKind
    public var actualDuration: Int
    public var isComplete: Bool

    public var id: Int { period }
}

/// Maps `MatchTime` onto a single continuous seconds axis so that playing time
/// can be summed across period boundaries and overtime.
public struct PeriodTimeline: Hashable, Sendable {
    public var spans: [PeriodSpan]

    public init(spans: [PeriodSpan]) { self.spans = spans }

    public func span(_ period: Int) -> PeriodSpan? { spans.first { $0.period == period } }

    public var totalSecondsPlayed: Int { spans.reduce(0) { $0 + $1.actualDuration } }

    public var lastPlayedPeriod: Int? { spans.map(\.period).max() }

    /// Seconds from kickoff. Clamped into the period's real length so a stale
    /// event time can never inflate a player's minutes.
    public func absolute(_ time: MatchTime) -> Int {
        var total = 0
        for span in spans where span.period < time.period {
            total += span.actualDuration
        }
        let within: Int
        if let span = span(time.period) {
            within = min(max(0, time.secondsElapsed), span.actualDuration)
        } else {
            within = max(0, time.secondsElapsed)
        }
        return total + within
    }

    /// The inverse: turn an absolute offset back into a period and offset.
    public func matchTime(fromAbsolute absolute: Int) -> MatchTime {
        var remaining = max(0, absolute)
        for span in spans.sorted(by: { $0.period < $1.period }) {
            if remaining <= span.actualDuration {
                return MatchTime(period: span.period, secondsElapsed: remaining)
            }
            remaining -= span.actualDuration
        }
        let last = spans.map(\.period).max() ?? 1
        return MatchTime(period: last, secondsElapsed: span(last)?.actualDuration ?? remaining)
    }

    /// The end of the match on the absolute axis.
    public var matchEndAbsolute: Int { totalSecondsPlayed }
}

/// One continuous stretch of a player being on the field, or in goal.
public struct PlayingInterval: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var playerID: PlayerID
    public var side: TeamSide
    public var start: MatchTime
    public var end: MatchTime?
    public var startAbsolute: Int
    public var endAbsolute: Int

    public init(
        id: UUID = UUID(),
        playerID: PlayerID,
        side: TeamSide,
        start: MatchTime,
        end: MatchTime?,
        startAbsolute: Int,
        endAbsolute: Int
    ) {
        self.id = id
        self.playerID = playerID
        self.side = side
        self.start = start
        self.end = end
        self.startAbsolute = startAbsolute
        self.endAbsolute = endAbsolute
    }

    public var seconds: Int { max(0, endAbsolute - startAbsolute) }
    public var isOpen: Bool { end == nil }

    public func contains(absolute: Int) -> Bool {
        absolute >= startAbsolute && absolute <= endAbsolute
    }
}

/// Derived answer to "who was on the field, and when".
///
/// Everything about playing time flows from here. Programme never keeps a
/// running per-player minute counter, so editing the time of a substitution
/// recorded an hour ago simply produces a different timeline and correct totals.
public struct LineupTimeline: Hashable, Sendable {
    public var periods: PeriodTimeline
    public var fieldIntervals: [PlayingInterval]
    public var goalkeeperIntervals: [PlayingInterval]
    /// Players who started the match on the field, by side.
    public var starters: [TeamSide: Set<PlayerID>]

    public func intervals(for playerID: PlayerID) -> [PlayingInterval] {
        fieldIntervals.filter { $0.playerID == playerID }
    }

    public func secondsPlayed(_ playerID: PlayerID) -> Int {
        fieldIntervals.filter { $0.playerID == playerID }.reduce(0) { $0 + $1.seconds }
    }

    public func goalkeeperSeconds(_ playerID: PlayerID) -> Int {
        goalkeeperIntervals.filter { $0.playerID == playerID }.reduce(0) { $0 + $1.seconds }
    }

    public func onField(side: TeamSide, at time: MatchTime) -> Set<PlayerID> {
        let absolute = periods.absolute(time)
        return Set(
            fieldIntervals
                .filter { $0.side == side && $0.startAbsolute <= absolute && absolute < max($0.endAbsolute, $0.startAbsolute + 1) }
                .map(\.playerID)
        )
    }

    /// Whether a player was on the field at a given moment. A boundary counts as
    /// on-field for the outgoing player, since an event recorded at the same
    /// second as a substitution belongs to the play that caused it.
    public func wasOnField(_ playerID: PlayerID, at time: MatchTime) -> Bool {
        let absolute = periods.absolute(time)
        return fieldIntervals.contains {
            $0.playerID == playerID && $0.startAbsolute <= absolute && absolute <= $0.endAbsolute
        }
    }

    public func goalkeeper(side: TeamSide, at time: MatchTime) -> PlayerID? {
        let absolute = periods.absolute(time)
        return goalkeeperIntervals
            .filter { $0.side == side && $0.startAbsolute <= absolute && absolute <= $0.endAbsolute }
            .max { $0.startAbsolute < $1.startAbsolute }?
            .playerID
    }

    /// Players still on the field at the end of the timeline.
    public func currentlyOnField(side: TeamSide) -> Set<PlayerID> {
        Set(fieldIntervals.filter { $0.side == side && $0.isOpen }.map(\.playerID))
    }

    public func currentGoalkeeper(side: TeamSide) -> PlayerID? {
        goalkeeperIntervals
            .filter { $0.side == side && $0.isOpen }
            .max { $0.startAbsolute < $1.startAbsolute }?
            .playerID
    }

    /// All players with any recorded field time, for the box score.
    public func appearances(side: TeamSide) -> Set<PlayerID> {
        Set(fieldIntervals.filter { $0.side == side }.map(\.playerID))
    }
}

/// Builds the lineup timeline from events.
public enum LineupEngine {

    public static func periodTimeline(context: MatchContext, asOf: MatchTime) -> PeriodTimeline {
        let events = context.activeEvents
        var started: [Int: Bool] = [:]
        var ended: [Int: Int] = [:]
        for event in events {
            switch event.payload {
            case .periodStarted(let p): started[p] = true
            case .periodEnded(let p): ended[p] = event.time.secondsElapsed
            default: break
            }
        }
        let periods = started.keys.sorted()
        var spans: [PeriodSpan] = []
        for period in periods {
            let descriptor = context.rules.period(at: period)
            let kind = descriptor?.kind ?? .regulation
            let duration: Int
            let complete: Bool
            if let endSeconds = ended[period] {
                duration = endSeconds
                complete = true
            } else if asOf.period == period {
                duration = max(0, asOf.secondsElapsed)
                complete = false
            } else if asOf.period > period {
                // The period was never explicitly ended. Fall back to its
                // scheduled length; ValidationEngine surfaces the gap.
                duration = descriptor?.scheduledDuration ?? 0
                complete = false
            } else {
                duration = 0
                complete = false
            }
            spans.append(PeriodSpan(period: period, kind: kind, actualDuration: duration, isComplete: complete))
        }
        if spans.isEmpty {
            spans = [PeriodSpan(period: 1, kind: .regulation, actualDuration: 0, isComplete: false)]
        }
        return PeriodTimeline(spans: spans)
    }

    public static func build(context: MatchContext, asOf: MatchTime) -> LineupTimeline {
        let periods = periodTimeline(context: context, asOf: asOf)
        let endAbsolute = periods.absolute(asOf)

        var openField: [TeamSide: [PlayerID: (MatchTime, Int)]] = [.us: [:], .opponent: [:]]
        var openKeeper: [TeamSide: (PlayerID, MatchTime, Int)?] = [.us: nil, .opponent: nil]
        var closedField: [PlayingInterval] = []
        var closedKeeper: [PlayingInterval] = []
        var starters: [TeamSide: Set<PlayerID>] = [.us: [], .opponent: []]
        var sawLineup: Set<TeamSide> = []

        func closeField(_ side: TeamSide, _ playerID: PlayerID, at time: MatchTime) {
            guard let (start, startAbs) = openField[side]?[playerID] else { return }
            openField[side]?[playerID] = nil
            let abs = max(startAbs, periods.absolute(time))
            closedField.append(
                PlayingInterval(
                    playerID: playerID, side: side, start: start, end: time,
                    startAbsolute: startAbs, endAbsolute: abs))
        }

        func openFieldInterval(_ side: TeamSide, _ playerID: PlayerID, at time: MatchTime) {
            guard openField[side]?[playerID] == nil else { return }
            openField[side]?[playerID] = (time, periods.absolute(time))
        }

        func closeKeeper(_ side: TeamSide, at time: MatchTime) {
            guard let entry = openKeeper[side] ?? nil else { return }
            openKeeper[side] = .some(nil)
            let abs = max(entry.2, periods.absolute(time))
            closedKeeper.append(
                PlayingInterval(
                    playerID: entry.0, side: side, start: entry.1, end: time,
                    startAbsolute: entry.2, endAbsolute: abs))
        }

        func openKeeperInterval(_ side: TeamSide, _ playerID: PlayerID, at time: MatchTime) {
            if let existing = openKeeper[side] ?? nil, existing.0 == playerID { return }
            closeKeeper(side, at: time)
            openKeeper[side] = .some((playerID, time, periods.absolute(time)))
        }

        for event in context.activeEvents {
            switch event.payload {
            case .lineupSet(let lineup):
                let side = lineup.side
                let incoming = Set(lineup.onField)
                let current = Set(openField[side]?.keys ?? [:].keys)
                for player in current.subtracting(incoming) {
                    closeField(side, player, at: event.time)
                }
                for player in lineup.onField {
                    openFieldInterval(side, player, at: event.time)
                }
                if !sawLineup.contains(side) {
                    starters[side] = incoming
                    sawLineup.insert(side)
                } else {
                    // A corrected starting lineup replaces the previous starters.
                    if event.time == MatchTime.kickoff { starters[side] = incoming }
                }
                if let keeper = lineup.goalkeeper {
                    openKeeperInterval(side, keeper, at: event.time)
                }

            case .substitution(let sub):
                let side = sub.side
                for player in sub.playersOut {
                    closeField(side, player, at: event.time)
                    if let keeper = openKeeper[side] ?? nil, keeper.0 == player {
                        closeKeeper(side, at: event.time)
                    }
                }
                for player in sub.playersIn {
                    openFieldInterval(side, player, at: event.time)
                }
                if let keeper = sub.goalkeeperAfter {
                    openKeeperInterval(side, keeper, at: event.time)
                }

            case .goalkeeperChanged(let side, let ref):
                if let id = ref.playerID {
                    openFieldInterval(side, id, at: event.time)
                    openKeeperInterval(side, id, at: event.time)
                } else {
                    closeKeeper(side, at: event.time)
                }

            case .card(let card) where card.card.isDismissal:
                // A dismissed player leaves and is not replaced.
                if let id = card.player.playerID {
                    closeField(card.side, id, at: event.time)
                    if let keeper = openKeeper[card.side] ?? nil, keeper.0 == id {
                        closeKeeper(card.side, at: event.time)
                    }
                }

            default:
                break
            }
        }

        var open: [PlayingInterval] = []
        for (side, players) in openField {
            for (playerID, value) in players {
                open.append(
                    PlayingInterval(
                        playerID: playerID, side: side, start: value.0, end: nil,
                        startAbsolute: value.1, endAbsolute: max(value.1, endAbsolute)))
            }
        }
        var openK: [PlayingInterval] = []
        for (side, entry) in openKeeper {
            if let entry {
                openK.append(
                    PlayingInterval(
                        playerID: entry.0, side: side, start: entry.1, end: nil,
                        startAbsolute: entry.2, endAbsolute: max(entry.2, endAbsolute)))
            }
        }

        return LineupTimeline(
            periods: periods,
            fieldIntervals: (closedField + open).sorted { $0.startAbsolute < $1.startAbsolute },
            goalkeeperIntervals: (closedKeeper + openK).sorted { $0.startAbsolute < $1.startAbsolute },
            starters: starters
        )
    }
}
