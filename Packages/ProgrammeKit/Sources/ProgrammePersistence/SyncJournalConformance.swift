import Foundation
import ProgrammeCollaboration
import ProgrammeCore

/// Wires the SwiftData journal into sync materialization.
///
/// Reads go through the same `MatchContext` decoding the UI uses, so the
/// applier reconciles against exactly what the scorer sees. Writes go
/// through `apply(_:to:)` — the same effect path as live scoring — and then
/// fire the match-changed notification so statistics re-derive through
/// StatEngine from the new event truth. Remote changes therefore take
/// effect exactly like locally recorded ones.
extension MatchStore: SyncJournal {
    public func readEvents(for matchID: MatchID) throws -> [MatchEvent] {
        try context(for: matchID).events
    }

    public func locateEvent(_ eventID: EventID, inTeam teamID: TeamID) throws -> MatchID? {
        // Deletions arrive without a match reference, so the match is found
        // by scan. Deletions are rare (a descope, not a steady-state write)
        // and scoped to one team, so a linear pass is proportionate.
        for item in try matches(teamID: teamID) {
            if try context(for: item.id).events.contains(where: { $0.id == eventID }) {
                return item.id
            }
        }
        return nil
    }

    public func writeEffects(_ effects: [MatchEffect], to matchID: MatchID) throws {
        try apply(effects, to: matchID)
        onMatchChanged?(matchID)
    }
}
