import Foundation

/// The current recognized-text set behind the live roster scanner.
/// VisionKit reports incremental additions, updates, and removals against
/// the full current item set (`allItems`); folding every callback through
/// that full set keeps the committed text equal to what is on screen right
/// now instead of an ever-growing append log, so repeated callbacks never
/// duplicate lines and removed items disappear. Order follows the input
/// order, so the same callbacks always produce the same text.
public struct ScannedRosterAccumulator: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public let id: UUID
        public var transcript: String

        public init(id: UUID, transcript: String) {
            self.id = id
            self.transcript = transcript
        }
    }

    private var lines: [Line] = []

    public init() {}

    /// Replaces the recognized set with the current items. Items sharing an
    /// id collapse to the first occurrence, so a duplicated callback can
    /// never repeat a line.
    public mutating func setItems(_ items: [(id: UUID, transcript: String)]) {
        var seen = Set<UUID>()
        lines = items.compactMap { item in
            guard seen.insert(item.id).inserted else { return nil }
            return Line(id: item.id, transcript: item.transcript)
        }
    }

    public var text: String {
        lines.map(\.transcript).joined(separator: "\n")
    }

    public var lineCount: Int { lines.count }

    public var isEmpty: Bool { lines.isEmpty }
}
