import Foundation
import ProgrammeCore

/// Durable Needs Review list for unresolved sync conflicts.
///
/// A conflict never blocks sync and never rewrites history: the local event
/// stands, the remote version stays unapplied, and this store records the
/// pair until a human resolves it. Survives relaunch like the outbox and
/// inbox. UI reads `unresolved()`; resolving happens through the normal
/// local correction path (which supersedes via a newer revision), after
/// which the entry is removed with `resolve(_:inTeam:)`.
public actor TeamConflictStore: ConflictSink {
    private let url: URL
    private var conflicts: [TeamConflict]

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            conflicts = try JSONDecoder().decode([TeamConflict].self, from: Data(contentsOf: url))
        } else {
            conflicts = []
        }
    }

    public func report(_ conflict: TeamConflict) throws {
        conflicts.removeAll { $0.eventID == conflict.eventID }
        conflicts.append(conflict)
        try persist()
    }

    /// Conflicts for one team, oldest first.
    public func unresolved(teamID: TeamID) -> [TeamConflict] {
        conflicts.filter { $0.teamID == teamID }.sorted { $0.receivedAt < $1.receivedAt }
    }

    public func resolve(_ eventID: EventID, inTeam teamID: TeamID) throws {
        conflicts.removeAll { $0.eventID == eventID && $0.teamID == teamID }
        try persist()
    }

    private func persist() throws {
        try JSONEncoder().encode(conflicts).write(to: url, options: .atomic)
    }
}
