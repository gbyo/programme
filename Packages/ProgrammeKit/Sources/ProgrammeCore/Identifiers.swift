import Foundation

/// Typed identifier wrapper. Programme never uses persistence-framework object
/// identity inside the domain: every reference across an actor boundary is one
/// of these value types.
public struct TypedID<Scope>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TeamScope: Sendable {}
public enum SeasonScope: Sendable {}
public enum PlayerScope: Sendable {}
public enum MatchScope: Sendable {}
public enum EventScope: Sendable {}

public typealias TeamID = TypedID<TeamScope>
public typealias SeasonID = TypedID<SeasonScope>
public typealias PlayerID = TypedID<PlayerScope>
public typealias MatchID = TypedID<MatchScope>
public typealias EventID = TypedID<EventScope>

/// Which club an event belongs to. Programme always scores from the
/// perspective of a single tracked team.
public enum TeamSide: String, Codable, Hashable, Sendable, CaseIterable {
    case us
    case opponent

    public var opposite: TeamSide { self == .us ? .opponent : .us }
}

/// How a player is referenced by an event.
///
/// The distinction between `unidentified` and `untracked` is load-bearing:
/// `unidentified` means "our player, but the scorer could not read the number" and
/// must surface in Needs Review. `untracked` means "deliberately not attributed",
/// which is the normal state for opponent players in `.ourTeam` tracking mode and
/// is never a review item.
public enum PlayerRef: Hashable, Sendable, Codable {
    case player(PlayerID)
    case unidentified
    case untracked

    public var playerID: PlayerID? {
        if case .player(let id) = self { return id }
        return nil
    }

    public var needsAttribution: Bool { self == .unidentified }

    public var isResolved: Bool {
        if case .player = self { return true }
        return false
    }
}
