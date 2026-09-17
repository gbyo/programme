import Foundation

/// A finalized match reduced to just what season aggregation needs.
public struct MatchStatSummary: Hashable, Sendable {
    public var matchID: MatchID
    public var kickoff: Date
    public var opponentName: String
    public var venue: Venue
    public var rules: MatchRules
    public var score: SidePair<Int>
    public var shootoutScore: SidePair<Int>
    public var result: MatchResult?
    public var players: [PlayerID: PlayerStatLine]
    public var keepers: [PlayerID: KeeperStatLine]
    public var team: SidePair<TeamStatLine>
    public var tracked: Set<TrackedStat>
    public var isFinalized: Bool

    public init(snapshot: MatchSnapshot, tracked: Set<TrackedStat>, isFinalized: Bool) {
        self.matchID = snapshot.descriptor.id
        self.kickoff = snapshot.descriptor.kickoff
        self.opponentName = snapshot.descriptor.opponentName
        self.venue = snapshot.descriptor.venue
        self.rules = snapshot.descriptor.rules
        self.score = snapshot.score
        self.shootoutScore = snapshot.shootoutScore
        self.result = snapshot.result
        self.players = snapshot.players
        self.keepers = snapshot.keepers
        self.team = snapshot.team
        self.tracked = tracked
        self.isFinalized = isFinalized
    }

    /// "W 3–1", "L 1–2", "T 2–2".
    public var resultText: String {
        guard let result else { return "\(score.us)–\(score.opponent)" }
        return "\(result.letter) \(score.us)–\(score.opponent)"
    }
}

/// Season totals for one player, carrying how many matches actually tracked each
/// category so an untracked statistic is never presented as a zero.
public struct SeasonPlayerStats: Hashable, Sendable, Identifiable {
    public var playerID: PlayerID
    public var id: PlayerID { playerID }
    public var matchesPlayed: Int = 0
    public var starts: Int = 0
    public var secondsPlayed: Int = 0
    public var totals: PlayerStatLine
    /// Matches in which each category was being recorded.
    public var trackedMatches: [TrackedStat: Int] = [:]

    public init(playerID: PlayerID, side: TeamSide = .us) {
        self.playerID = playerID
        self.totals = PlayerStatLine(playerID: playerID, side: side)
    }

    public var minutesPlayed: Int { publishedMinutes(fromSeconds: secondsPlayed) }
    public var points: Int { totals.points }

    public func value(_ stat: TrackedStat, _ raw: KeyPath<PlayerStatLine, Int>) -> StatValue {
        guard (trackedMatches[stat] ?? 0) > 0 else { return .notTracked }
        return .count(totals[keyPath: raw])
    }

    /// How many matches contributed to a category, for the "12 of 18 matches" note.
    public func coverage(_ stat: TrackedStat) -> (tracked: Int, total: Int) {
        (trackedMatches[stat] ?? 0, matchesPlayed)
    }

    public var shotAccuracy: StatValue {
        guard (trackedMatches[.shots] ?? 0) > 0 else { return .notTracked }
        guard totals.shots > 0 else { return .notApplicable }
        return .rate(Double(totals.shotsOnGoal) / Double(totals.shots))
    }
}

public struct SeasonKeeperStats: Hashable, Sendable, Identifiable {
    public var playerID: PlayerID
    public var id: PlayerID { playerID }
    public var totals: KeeperStatLine
    public var regulationSecondsSum: Int = 0
    public var matchesPlayed: Int = 0
    public var trackedMatches: Int = 0

    public init(playerID: PlayerID, side: TeamSide = .us) {
        self.playerID = playerID
        self.totals = KeeperStatLine(playerID: playerID, side: side)
    }

    public var minutesPlayed: Int { publishedMinutes(fromSeconds: totals.secondsPlayed) }

    public var savePercentage: StatValue {
        guard trackedMatches > 0 else { return .notTracked }
        guard totals.shotsOnGoalFaced > 0 else { return .notApplicable }
        return .rate(Double(totals.saves) / Double(totals.shotsOnGoalFaced))
    }

    /// Season GAA uses each match's own regulation length, so a season that
    /// mixes formats stays correct.
    public var goalsAgainstAverage: StatValue {
        guard trackedMatches > 0 else { return .notTracked }
        guard totals.secondsPlayed > 0, regulationSecondsSum > 0, matchesPlayed > 0 else {
            return .notApplicable
        }
        let averageRegulation = Double(regulationSecondsSum) / Double(matchesPlayed)
        return .rate(Double(totals.goalsAllowed) * averageRegulation / Double(totals.secondsPlayed))
    }
}

public struct SeasonStats: Hashable, Sendable {
    public var matches: [MatchStatSummary]
    public var wins: Int = 0
    public var losses: Int = 0
    public var draws: Int = 0
    public var goalsFor: Int = 0
    public var goalsAgainst: Int = 0
    public var teamShutouts: Int = 0
    public var players: [PlayerID: SeasonPlayerStats] = [:]
    public var keepers: [PlayerID: SeasonKeeperStats] = [:]
    public var trackedMatches: [TrackedStat: Int] = [:]

    public var matchesPlayed: Int { matches.count }

    /// "12-4-2"
    public var recordText: String { "\(wins)-\(losses)-\(draws)" }

    public func completeness(_ stat: TrackedStat) -> CompletenessState {
        let count = trackedMatches[stat] ?? 0
        if count == 0 { return .notTracked }
        return count == matchesPlayed ? .complete : .needsReview
    }

    public var sortedPlayers: [SeasonPlayerStats] {
        players.values.sorted {
            if $0.points != $1.points { return $0.points > $1.points }
            return $0.secondsPlayed > $1.secondsPlayed
        }
    }

    public var sortedKeepers: [SeasonKeeperStats] {
        keepers.values.sorted { $0.totals.secondsPlayed > $1.totals.secondsPlayed }
    }
}

public enum SeasonEngine {

    /// Aggregate finalized matches into season totals.
    ///
    /// A category contributes only from matches that were tracking it, so a
    /// season in which steals were recorded for six of eighteen matches reports
    /// the six-match total and says so, rather than implying zeros elsewhere.
    public static func aggregate(_ summaries: [MatchStatSummary]) -> SeasonStats {
        var stats = SeasonStats(matches: summaries.sorted { $0.kickoff < $1.kickoff })

        for match in summaries {
            switch match.result {
            case .win: stats.wins += 1
            case .loss: stats.losses += 1
            case .draw: stats.draws += 1
            case nil: break
            }
            stats.goalsFor += match.score.us
            stats.goalsAgainst += match.score.opponent
            if match.score.opponent == 0 && match.result != nil { stats.teamShutouts += 1 }

            for stat in match.tracked {
                stats.trackedMatches[stat, default: 0] += 1
            }

            for (playerID, line) in match.players where line.side == .us {
                var season = stats.players[playerID] ?? SeasonPlayerStats(playerID: playerID)
                if line.appeared {
                    season.matchesPlayed += 1
                    season.secondsPlayed += line.secondsPlayed
                    if line.started { season.starts += 1 }
                }
                for stat in match.tracked { season.trackedMatches[stat, default: 0] += 1 }

                season.totals.secondsPlayed += line.secondsPlayed
                if match.tracked.contains(.goals) {
                    season.totals.goals += line.goals
                    season.totals.gameWinningGoals += line.gameWinningGoals
                    season.totals.ownGoals += line.ownGoals
                }
                if match.tracked.contains(.assists) { season.totals.assists += line.assists }
                if match.tracked.contains(.shots) {
                    season.totals.shots += line.shots
                    season.totals.shotsOnGoal += line.shotsOnGoal
                }
                if match.tracked.contains(.steals) { season.totals.steals += line.steals }
                if match.tracked.contains(.corners) { season.totals.corners += line.corners }
                if match.tracked.contains(.fouls) { season.totals.fouls += line.fouls }
                if match.tracked.contains(.offsides) { season.totals.offsides += line.offsides }
                if match.tracked.contains(.cards) {
                    season.totals.yellowCards += line.yellowCards
                    season.totals.redCards += line.redCards
                }
                if match.tracked.contains(.penaltyKicks) {
                    season.totals.penaltyGoals += line.penaltyGoals
                    season.totals.penaltyAttempts += line.penaltyAttempts
                }
                season.totals.shootoutGoals += line.shootoutGoals
                season.totals.shootoutAttempts += line.shootoutAttempts
                stats.players[playerID] = season
            }

            guard match.tracked.contains(.goalkeeping) else { continue }
            for (playerID, line) in match.keepers where line.side == .us && line.secondsPlayed > 0 {
                var season = stats.keepers[playerID] ?? SeasonKeeperStats(playerID: playerID)
                season.matchesPlayed += 1
                season.trackedMatches += 1
                season.regulationSecondsSum += match.rules.regulationLength
                season.totals.secondsPlayed += line.secondsPlayed
                season.totals.shotsOnGoalFaced += line.shotsOnGoalFaced
                season.totals.saves += line.saves
                season.totals.goalsAllowed += line.goalsAllowed
                season.totals.penaltiesFaced += line.penaltiesFaced
                season.totals.penaltySaves += line.penaltySaves
                season.totals.shutouts += line.shutouts
                season.totals.sharedShutouts += line.sharedShutouts
                season.totals.wins += line.wins
                season.totals.losses += line.losses
                season.totals.draws += line.draws
                stats.keepers[playerID] = season
            }
        }

        return stats
    }
}
