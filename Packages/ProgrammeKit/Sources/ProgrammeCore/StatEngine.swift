import Foundation

/// Whether a statistic can be trusted for this match.
public enum CompletenessState: String, Hashable, Sendable, Codable {
    /// Tracked, with nothing outstanding.
    case complete
    /// Tracked, but at least one event still awaits attribution or contradicts another.
    case needsReview
    /// Nobody was recording this category. It is unknown, not zero.
    case notTracked

    public var label: String {
        switch self {
        case .complete: "Complete"
        case .needsReview: "Needs Review"
        case .notTracked: "Not tracked"
        }
    }
}

/// The complete derived state of a match at a point in time.
///
/// Nothing here is stored. Recording an event produces a new snapshot; editing
/// or voiding an event produces a corrected one. There is no path by which a
/// statistic can drift away from the events that justify it.
public struct MatchSnapshot: Hashable, Sendable {
    public var descriptor: MatchDescriptor
    public var asOf: MatchTime
    public var phase: MatchPhase
    public var score: SidePair<Int>
    public var shootoutScore: SidePair<Int>
    public var timeline: LineupTimeline
    public var team: SidePair<TeamStatLine>
    public var players: [PlayerID: PlayerStatLine]
    public var keepers: [PlayerID: KeeperStatLine]
    public var completeness: [TrackedStat: CompletenessState]
    public var eventsNeedingReview: [MatchEvent]
    public var recentEvents: [MatchEvent]
    public var result: MatchResult?
    public var gameWinningGoalEventID: EventID?
    public var totalEventCount: Int

    public func player(_ id: PlayerID) -> PlayerStatLine {
        players[id] ?? PlayerStatLine(playerID: id, side: .us)
    }

    public func keeper(_ id: PlayerID) -> KeeperStatLine {
        keepers[id] ?? KeeperStatLine(playerID: id, side: .us)
    }

    /// "2 – 1", with the tracked team first.
    public var scoreText: String { "\(score.us) – \(score.opponent)" }

    public var needsReviewCount: Int { eventsNeedingReview.count }

    /// Players currently on the field for the tracked team.
    public var activeLineup: Set<PlayerID> { timeline.currentlyOnField(side: .us) }
    public var activeGoalkeeper: PlayerID? { timeline.currentGoalkeeper(side: .us) }

    public func completeness(_ stat: TrackedStat) -> CompletenessState {
        completeness[stat] ?? .notTracked
    }
}

/// Derives every statistic Programme reports. Pure: same events in, same
/// numbers out, no persistence and no UI.
public enum StatEngine {

    public static func snapshot(context: MatchContext, at date: Date = Date()) -> MatchSnapshot {
        let asOf = context.currentTime(at: date)
        let timeline = LineupEngine.build(context: context, asOf: asOf)
        let events = context.activeEvents
        let profile = context.profile

        var team = SidePair(us: TeamStatLine(side: .us), opponent: TeamStatLine(side: .opponent))
        var players: [PlayerID: PlayerStatLine] = [:]
        var keepers: [PlayerID: KeeperStatLine] = [:]
        var score = SidePair(repeating: 0)
        var shootout = SidePair(repeating: 0)
        var goalEventsByScoringSide = SidePair<[MatchEvent]>(us: [], opponent: [])

        func playerLine(_ id: PlayerID, _ side: TeamSide) -> PlayerStatLine {
            players[id] ?? PlayerStatLine(playerID: id, side: side)
        }

        func keeperLine(_ id: PlayerID, _ side: TeamSide) -> KeeperStatLine {
            keepers[id] ?? KeeperStatLine(playerID: id, side: side)
        }

        for event in events {
            switch event.payload {

            case .shot(let shot):
                let scoringSide = shot.scoringSide
                let defendingSide = scoringSide.opposite

                if shot.outcome.isGoal {
                    score[scoringSide] += 1
                    team[scoringSide].goals += 1
                    goalEventsByScoringSide[scoringSide].append(event)
                    if shot.isOwnGoal {
                        team[shot.side].ownGoalsConceded += 1
                        if let id = shot.shooter.playerID {
                            var line = playerLine(id, shot.side)
                            line.ownGoals += 1
                            players[id] = line
                        }
                    }
                }

                if shot.creditsShooter {
                    team[shot.side].shots += 1
                    if shot.outcome.isOnTarget { team[shot.side].shotsOnGoal += 1 }
                    if shot.phase == .penaltyKick {
                        team[shot.side].penaltyAttempts += 1
                        if shot.outcome.isGoal { team[shot.side].penaltyGoals += 1 }
                    }
                    if let id = shot.shooter.playerID {
                        var line = playerLine(id, shot.side)
                        line.shots += 1
                        if shot.outcome.isOnTarget { line.shotsOnGoal += 1 }
                        if shot.outcome.isGoal { line.goals += 1 }
                        if shot.phase == .penaltyKick {
                            line.penaltyAttempts += 1
                            if shot.outcome.isGoal { line.penaltyGoals += 1 }
                        }
                        players[id] = line
                    }
                    if shot.outcome.isGoal, let assistID = shot.assist?.playerID {
                        var line = playerLine(assistID, shot.side)
                        line.assists += 1
                        players[assistID] = line
                    }
                }

                // Goalkeeper accounting. An own goal is treated as a shot on
                // goal faced that was not saved, so that
                // saves + goals allowed == shots on goal faced always holds and
                // save percentage stays coherent.
                let keeperID =
                    shot.goalkeeper?.playerID
                    ?? timeline.goalkeeper(side: defendingSide, at: event.time)
                if shot.outcome.isOnTarget || shot.isOwnGoal {
                    if shot.outcome == .saved { team[defendingSide].saves += 1 }
                    if let keeperID {
                        var line = keeperLine(keeperID, defendingSide)
                        line.shotsOnGoalFaced += 1
                        if shot.outcome == .saved {
                            line.saves += 1
                            if shot.phase == .penaltyKick { line.penaltySaves += 1 }
                        } else if shot.outcome.isGoal {
                            line.goalsAllowed += 1
                        }
                        if shot.phase == .penaltyKick && !shot.isOwnGoal {
                            line.penaltiesFaced += 1
                        }
                        keepers[keeperID] = line
                    }
                }

            case .corner(let action):
                team[action.side].corners += 1
                if let id = action.player.playerID {
                    var line = playerLine(id, action.side)
                    line.corners += 1
                    players[id] = line
                }

            case .steal(let action):
                team[action.side].steals += 1
                if let id = action.player.playerID {
                    var line = playerLine(id, action.side)
                    line.steals += 1
                    players[id] = line
                }

            case .foul(let action):
                team[action.side].fouls += 1
                if let id = action.player.playerID {
                    var line = playerLine(id, action.side)
                    line.fouls += 1
                    players[id] = line
                }

            case .offside(let action):
                team[action.side].offsides += 1
                if let id = action.player.playerID {
                    var line = playerLine(id, action.side)
                    line.offsides += 1
                    players[id] = line
                }

            case .card(let card):
                if card.card.countsAsYellow { team[card.side].yellowCards += 1 }
                if card.card.isDismissal { team[card.side].redCards += 1 }
                if let id = card.player.playerID {
                    var line = playerLine(id, card.side)
                    if card.card.countsAsYellow { line.yellowCards += 1 }
                    if card.card.isDismissal { line.redCards += 1 }
                    players[id] = line
                }

            case .shootoutAttempt(let attempt):
                team[attempt.side].shootoutAttempts += 1
                if attempt.scored {
                    team[attempt.side].shootoutGoals += 1
                    shootout[attempt.side] += 1
                }
                if let id = attempt.taker.playerID {
                    var line = playerLine(id, attempt.side)
                    line.shootoutAttempts += 1
                    if attempt.scored { line.shootoutGoals += 1 }
                    players[id] = line
                }
                if let keeperID = attempt.goalkeeper?.playerID {
                    var line = keeperLine(keeperID, attempt.side.opposite)
                    line.penaltiesFaced += 1
                    if !attempt.scored { line.penaltySaves += 1 }
                    keepers[keeperID] = line
                }

            case .lineupSet, .substitution, .goalkeeperChanged, .periodStarted, .periodEnded,
                .clockAdjusted, .matchFinalized, .note:
                break
            }
        }

        // Playing time, appearances and starts come entirely from the timeline.
        for side in TeamSide.allCases {
            for playerID in timeline.appearances(side: side) {
                var line = playerLine(playerID, side)
                line.secondsPlayed = timeline.secondsPlayed(playerID)
                line.appeared = true
                line.started = timeline.starters[side]?.contains(playerID) ?? false
                line.side = side
                players[playerID] = line
            }
            for interval in timeline.goalkeeperIntervals where interval.side == side {
                var line = keeperLine(interval.playerID, side)
                line.secondsPlayed = timeline.goalkeeperSeconds(interval.playerID)
                line.side = side
                keepers[interval.playerID] = line
            }
        }

        // Result, game-winning goal and goalkeeper decisions are only meaningful
        // once the match has actually finished.
        let matchIsOver = context.phase == .finalized || context.phase == .awaitingFinalization
        var result: MatchResult?
        var gwgEventID: EventID?

        if matchIsOver {
            let decided: MatchResult
            if score.us > score.opponent {
                decided = .win
            } else if score.us < score.opponent {
                decided = .loss
            } else if shootout.us != shootout.opponent {
                decided = shootout.us > shootout.opponent ? .win : .loss
            } else {
                decided = .draw
            }
            result = decided

            // The game-winning goal is the one that put the winner ahead to
            // stay: the (loser's final total + 1)-th goal scored by the winner.
            if score.us != score.opponent {
                let winningSide: TeamSide = score.us > score.opponent ? .us : .opponent
                let loserGoals = score[winningSide.opposite]
                let winnerGoals = goalEventsByScoringSide[winningSide]
                if winnerGoals.indices.contains(loserGoals) {
                    let event = winnerGoals[loserGoals]
                    gwgEventID = event.id
                    if case .shot(let shot) = event.payload,
                        !shot.isOwnGoal,
                        let id = shot.shooter.playerID
                    {
                        var line = playerLine(id, shot.side)
                        line.gameWinningGoals += 1
                        players[id] = line
                    }
                }
            }

            for side in TeamSide.allCases {
                let sideResult: MatchResult? =
                    side == .us
                    ? result
                    : result.map { $0 == .win ? .loss : ($0 == .loss ? .win : .draw) }
                let sideKeepers = keepers.values
                    .filter { $0.side == side && $0.secondsPlayed > 0 }
                    .sorted { $0.playerID.rawValue.uuidString < $1.playerID.rawValue.uuidString }
                guard !sideKeepers.isEmpty else { continue }

                // The decision goes to the goalkeeper with the most minutes. Ties
                // go to whoever finished the match in goal, and beyond that to a
                // stable ordering by identifier — the same events must always
                // produce the same numbers, so no result may depend on the order
                // a dictionary happens to enumerate in.
                let finishingKeeper = timeline.currentGoalkeeper(side: side)
                let primaryKeeper = sideKeepers.max { first, second in
                    if first.secondsPlayed != second.secondsPlayed {
                        return first.secondsPlayed < second.secondsPlayed
                    }
                    if (first.playerID == finishingKeeper) != (second.playerID == finishingKeeper) {
                        return second.playerID == finishingKeeper
                    }
                    return first.playerID.rawValue.uuidString < second.playerID.rawValue.uuidString
                }
                if let sideResult, let primary = primaryKeeper {
                    var line = keepers[primary.playerID] ?? primary
                    switch sideResult {
                    case .win: line.wins += 1
                    case .loss: line.losses += 1
                    case .draw: line.draws += 1
                    }
                    keepers[primary.playerID] = line
                }

                // A clean sheet earned across the whole match is an individual
                // shutout. One shared between goalkeepers is recorded as shared,
                // so season totals never overstate either keeper.
                if score[side.opposite] == 0 {
                    let fullMatch = timeline.periods.totalSecondsPlayed
                    let cleanKeepers = sideKeepers
                        .filter { $0.goalsAllowed == 0 }
                        .sorted { $0.playerID.rawValue.uuidString < $1.playerID.rawValue.uuidString }
                    for keeper in cleanKeepers {
                        var line = keepers[keeper.playerID] ?? keeper
                        if cleanKeepers.count == 1 && abs(keeper.secondsPlayed - fullMatch) <= 60 {
                            line.shutouts += 1
                        } else {
                            line.sharedShutouts += 1
                        }
                        keepers[keeper.playerID] = line
                    }
                }
            }
        }

        let needingReview = events.filter(\.awaitsAttribution)
        let completeness = completenessMap(
            profile: profile,
            events: events,
            needingReview: needingReview
        )

        return MatchSnapshot(
            descriptor: context.descriptor,
            asOf: asOf,
            phase: context.phase,
            score: score,
            shootoutScore: shootout,
            timeline: timeline,
            team: team,
            players: players,
            keepers: keepers,
            completeness: completeness,
            eventsNeedingReview: needingReview,
            recentEvents: Array(events.suffix(12).reversed()),
            result: result,
            gameWinningGoalEventID: gwgEventID,
            totalEventCount: context.events.count
        )
    }

    /// Maps each statistic to complete / needs review / not tracked.
    /// A category the match never tracked must never be reported as zero.
    static func completenessMap(
        profile: StatProfile,
        events: [MatchEvent],
        needingReview: [MatchEvent]
    ) -> [TrackedStat: CompletenessState] {
        var map: [TrackedStat: CompletenessState] = [:]
        let unresolvedCategories = Set(needingReview.map(\.category))

        for stat in TrackedStat.allCases {
            guard profile.tracks(stat) else {
                map[stat] = .notTracked
                continue
            }
            let affected: Bool
            switch stat {
            case .goals: affected = unresolvedCategories.contains(.goal)
            case .assists: affected = unresolvedCategories.contains(.goal)
            case .shots:
                affected = unresolvedCategories.contains(.shot) || unresolvedCategories.contains(.goal)
                    || unresolvedCategories.contains(.save)
            case .goalkeeping: affected = unresolvedCategories.contains(.save)
            case .corners: affected = unresolvedCategories.contains(.corner)
            case .steals: affected = unresolvedCategories.contains(.steal)
            case .cards: affected = unresolvedCategories.contains(.card)
            case .fouls, .offsides: affected = unresolvedCategories.contains(.foul)
            case .penaltyKicks:
                affected = unresolvedCategories.contains(.goal) || unresolvedCategories.contains(.shot)
            case .shotLocations: affected = false
            }
            map[stat] = affected ? .needsReview : .complete
        }
        return map
    }
}
