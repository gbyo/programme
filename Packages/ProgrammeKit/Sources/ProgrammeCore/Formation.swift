import Foundation

/// A shape a team lined up in.
///
/// Programme records the formation because a coach wants to know what they
/// played, and it never requires one: a match is completely scoreable with the
/// formation left unset. Positional placement of individual players on the pitch
/// is deliberately out of scope — Programme is a scorebook, not a tactics board.
public struct Formation: Codable, Hashable, Sendable, Identifiable {
    /// "4-4-2". Also the display name.
    public var id: String
    /// Outfield lines from the back, excluding the goalkeeper.
    public var outfieldLines: [Int]

    public init(id: String, outfieldLines: [Int]) {
        self.id = id
        self.outfieldLines = outfieldLines
    }

    public var name: String { id }

    /// Total players including the goalkeeper.
    public var playerCount: Int { outfieldLines.reduce(1, +) }

    public func suits(playersPerSide: Int) -> Bool { playerCount == playersPerSide }

    /// A rough label for each line, used when grouping a lineup by shape.
    public var lineLabels: [String] {
        switch outfieldLines.count {
        case 2: ["Defence", "Attack"]
        case 3: ["Defence", "Midfield", "Attack"]
        case 4: ["Defence", "Midfield", "Attacking Midfield", "Attack"]
        default: outfieldLines.indices.map { "Line \($0 + 1)" }
        }
    }

    public static let elevenASide: [Formation] = [
        Formation(id: "4-4-2", outfieldLines: [4, 4, 2]),
        Formation(id: "4-3-3", outfieldLines: [4, 3, 3]),
        Formation(id: "4-2-3-1", outfieldLines: [4, 2, 3, 1]),
        Formation(id: "3-5-2", outfieldLines: [3, 5, 2]),
        Formation(id: "5-3-2", outfieldLines: [5, 3, 2]),
        Formation(id: "4-5-1", outfieldLines: [4, 5, 1]),
        Formation(id: "3-4-3", outfieldLines: [3, 4, 3]),
    ]

    public static let nineASide: [Formation] = [
        Formation(id: "3-3-2", outfieldLines: [3, 3, 2]),
        Formation(id: "3-2-3", outfieldLines: [3, 2, 3]),
        Formation(id: "2-4-2", outfieldLines: [2, 4, 2]),
    ]

    /// The formations that fit a ruleset.
    public static func presets(playersPerSide: Int) -> [Formation] {
        (elevenASide + nineASide).filter { $0.suits(playersPerSide: playersPerSide) }
    }

    public static func preset(id: String?) -> Formation? {
        guard let id else { return nil }
        return (elevenASide + nineASide).first { $0.id == id }
    }
}

extension MatchContext {
    /// The formation the tracked team started in, if one was recorded.
    public var startingFormation: Formation? {
        for event in activeEvents {
            if case .lineupSet(let lineup) = event.payload, lineup.side == .us {
                return Formation.preset(id: lineup.formationID)
            }
        }
        return nil
    }
}
