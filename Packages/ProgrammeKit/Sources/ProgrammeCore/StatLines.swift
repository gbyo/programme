import Foundation

/// A value held once per side. Avoids optional lookups on `[TeamSide: T]`.
public struct SidePair<Value: Hashable & Sendable>: Hashable, Sendable {
    public var us: Value
    public var opponent: Value

    public init(us: Value, opponent: Value) {
        self.us = us
        self.opponent = opponent
    }

    public init(repeating value: Value) {
        self.us = value
        self.opponent = value
    }

    public subscript(side: TeamSide) -> Value {
        get { side == .us ? us : opponent }
        set { if side == .us { us = newValue } else { opponent = newValue } }
    }
}

extension SidePair: Codable where Value: Codable {}

/// Rounding for published minutes. MaxPreps and paper scorebooks both want whole
/// minutes; Programme keeps seconds internally and rounds only for display.
public func publishedMinutes(fromSeconds seconds: Int) -> Int {
    Int((Double(seconds) / 60.0).rounded())
}

public struct PlayerStatLine: Hashable, Sendable, Codable {
    public var playerID: PlayerID
    public var side: TeamSide
    public var secondsPlayed: Int = 0
    public var started: Bool = false
    public var appeared: Bool = false
    public var goals: Int = 0
    public var assists: Int = 0
    public var shots: Int = 0
    public var shotsOnGoal: Int = 0
    public var steals: Int = 0
    public var corners: Int = 0
    public var fouls: Int = 0
    public var offsides: Int = 0
    public var yellowCards: Int = 0
    public var redCards: Int = 0
    public var penaltyGoals: Int = 0
    public var penaltyAttempts: Int = 0
    public var gameWinningGoals: Int = 0
    public var ownGoals: Int = 0
    public var shootoutGoals: Int = 0
    public var shootoutAttempts: Int = 0

    public init(playerID: PlayerID, side: TeamSide) {
        self.playerID = playerID
        self.side = side
    }

    public var minutesPlayed: Int { publishedMinutes(fromSeconds: secondsPlayed) }

    /// MaxPreps soccer scoring: a goal is worth two points, an assist one.
    public var points: Int { goals * 2 + assists }

    /// Shots on goal as a share of shots. Undefined with no shots — never 0%.
    public var shotAccuracy: Double? {
        shots > 0 ? Double(shotsOnGoal) / Double(shots) : nil
    }

    public var hasAnyContribution: Bool {
        goals + assists + shots + steals + corners + fouls + offsides + yellowCards + redCards > 0
    }
}

public struct KeeperStatLine: Hashable, Sendable, Codable {
    public var playerID: PlayerID
    public var side: TeamSide
    public var secondsPlayed: Int = 0
    /// Opponent shots on goal faced while this keeper was in goal. Equals
    /// `saves + goalsAllowed` by construction, because Programme derives a shot
    /// on goal from the shot's outcome rather than storing it separately.
    public var shotsOnGoalFaced: Int = 0
    public var saves: Int = 0
    public var goalsAllowed: Int = 0
    public var penaltiesFaced: Int = 0
    public var penaltySaves: Int = 0
    public var shutouts: Int = 0
    /// A clean sheet shared with another goalkeeper. Reported separately so a
    /// split shutout never inflates an individual season total.
    public var sharedShutouts: Int = 0
    public var wins: Int = 0
    public var losses: Int = 0
    public var draws: Int = 0

    public init(playerID: PlayerID, side: TeamSide) {
        self.playerID = playerID
        self.side = side
    }

    public var minutesPlayed: Int { publishedMinutes(fromSeconds: secondsPlayed) }

    /// Saves divided by shots on goal faced. Undefined when untested.
    public var savePercentage: Double? {
        shotsOnGoalFaced > 0 ? Double(saves) / Double(shotsOnGoalFaced) : nil
    }

    /// Goals allowed per regulation match length. Undefined with no minutes.
    public func goalsAgainstAverage(regulationSeconds: Int) -> Double? {
        guard secondsPlayed > 0, regulationSeconds > 0 else { return nil }
        return Double(goalsAllowed) * Double(regulationSeconds) / Double(secondsPlayed)
    }
}

public struct TeamStatLine: Hashable, Sendable, Codable {
    public var side: TeamSide
    public var goals: Int = 0
    public var shots: Int = 0
    public var shotsOnGoal: Int = 0
    public var corners: Int = 0
    public var steals: Int = 0
    public var fouls: Int = 0
    public var offsides: Int = 0
    public var yellowCards: Int = 0
    public var redCards: Int = 0
    public var penaltyGoals: Int = 0
    public var penaltyAttempts: Int = 0
    public var saves: Int = 0
    public var ownGoalsConceded: Int = 0
    public var shootoutGoals: Int = 0
    public var shootoutAttempts: Int = 0

    public init(side: TeamSide) { self.side = side }

    public var shotAccuracy: Double? {
        shots > 0 ? Double(shotsOnGoal) / Double(shots) : nil
    }
}

public enum MatchResult: String, Codable, Hashable, Sendable {
    case win, loss, draw

    public var letter: String {
        switch self {
        case .win: "W"
        case .loss: "L"
        case .draw: "T"
        }
    }

    public var label: String {
        switch self {
        case .win: "Win"
        case .loss: "Loss"
        case .draw: "Draw"
        }
    }
}
