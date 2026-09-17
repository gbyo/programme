import Foundation

public enum PlayerPosition: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case goalkeeper, defender, midfielder, forward

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .goalkeeper: "Goalkeeper"
        case .defender: "Defender"
        case .midfielder: "Midfielder"
        case .forward: "Forward"
        }
    }

    public var abbreviation: String {
        switch self {
        case .goalkeeper: "GK"
        case .defender: "D"
        case .midfielder: "M"
        case .forward: "F"
        }
    }
}

/// A Sendable value view of a player. The domain engine only ever sees these;
/// persistent model objects never cross an actor boundary.
public struct PlayerSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: PlayerID
    public var firstName: String
    public var lastName: String
    public var jerseyNumber: Int?
    public var position: PlayerPosition?
    public var classYear: String?
    /// Whether the player is currently carried on the roster. Former players
    /// stay in the database so historical matches remain readable.
    public var isOnRoster: Bool

    public init(
        id: PlayerID = PlayerID(),
        firstName: String,
        lastName: String,
        jerseyNumber: Int? = nil,
        position: PlayerPosition? = nil,
        classYear: String? = nil,
        isOnRoster: Bool = true
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.jerseyNumber = jerseyNumber
        self.position = position
        self.classYear = classYear
        self.isOnRoster = isOnRoster
    }

    public var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What a scorer reads on a button: "Carter" is enough when the number is
    /// already shown beside it.
    public var displaySurname: String { lastName.isEmpty ? firstName : lastName }

    public var jerseyText: String { jerseyNumber.map { "#\($0)" } ?? "—" }

    /// "#9 Carter" — the canonical short form used in the event log.
    public var shortLabel: String {
        jerseyNumber.map { "#\($0) \(displaySurname)" } ?? displaySurname
    }

    /// Spoken form: "Number 9, Carter, forward".
    public var accessibilityLabel: String {
        var parts: [String] = []
        if let jerseyNumber { parts.append("Number \(jerseyNumber)") }
        parts.append(fullName)
        if let position { parts.append(position.label) }
        return parts.joined(separator: ", ")
    }
}

/// Everything the engine needs to know about the people in a match.
public struct RosterSnapshot: Codable, Hashable, Sendable {
    public var players: [PlayerSnapshot]
    private var index: [PlayerID: Int]

    public init(players: [PlayerSnapshot]) {
        self.players = players
        var index: [PlayerID: Int] = [:]
        for (offset, player) in players.enumerated() { index[player.id] = offset }
        self.index = index
    }

    public static let empty = RosterSnapshot(players: [])

    public subscript(id: PlayerID) -> PlayerSnapshot? {
        guard let offset = index[id], players.indices.contains(offset) else { return nil }
        return players[offset]
    }

    public func label(for ref: PlayerRef) -> String {
        switch ref {
        case .player(let id): self[id]?.shortLabel ?? "Unknown player"
        case .unidentified: "Player unknown"
        case .untracked: "Opponent"
        }
    }

    /// Roster order: by jersey number, then surname. Unnumbered players last.
    public var sortedByNumber: [PlayerSnapshot] {
        players.sorted {
            switch ($0.jerseyNumber, $1.jerseyNumber) {
            case let (a?, b?): a == b ? $0.displaySurname < $1.displaySurname : a < b
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): $0.displaySurname < $1.displaySurname
            }
        }
    }

    public var activeRoster: [PlayerSnapshot] { sortedByNumber.filter(\.isOnRoster) }
}

public enum Venue: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case home, away, neutral

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .home: "Home"
        case .away: "Away"
        case .neutral: "Neutral"
        }
    }

    public var shortLabel: String {
        switch self {
        case .home: "vs"
        case .away: "at"
        case .neutral: "vs"
        }
    }
}

/// How much of the opponent Programme records.
public enum OpponentTrackingMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// The default. Our players are attributed individually; opponent events are
    /// recorded only to the depth our own statistics require. This is a large
    /// reduction in workload for a lone scorer.
    case ourTeam
    /// Full rosters and player attribution for both sides, using the same engine.
    case bothTeams

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ourTeam: "Our Team"
        case .bothTeams: "Both Teams"
        }
    }

    public var detail: String {
        switch self {
        case .ourTeam: "Attribute our players individually. Record opponent events as team totals."
        case .bothTeams: "Attribute players on both teams. Requires an opponent roster."
        }
    }
}
