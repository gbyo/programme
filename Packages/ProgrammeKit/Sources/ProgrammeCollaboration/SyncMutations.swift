import Foundation
import ProgrammeCore

/// A local truth change that must replicate to the team zone.
///
/// MatchStore reports these through its mutation hook; the sync service
/// turns them into staged record saves. Carries IDs only — the service
/// reads current values back from the store, so what replicates is always
/// the post-write state. Device-local state (reminder preferences, derived
/// caches) never appears here.
public enum OutboundMutation: Hashable, Sendable {
    /// Events appended or replaced in a match. The service reconciles by ID
    /// against the journal, so repeats converge.
    case events(matchID: MatchID, eventIDs: [EventID])
    /// A match's structural state changed (created, phase/clock/finalized,
    /// roster, config). Frozen roster and config replicate whole.
    case match(MatchID)
    case team(TeamID)
    case season(teamID: TeamID, seasonID: SeasonID)
    case players(teamID: TeamID, playerIDs: [PlayerID])
    /// A whole match deleted locally. Tombstones the match record and every
    /// event record so collaborators descope the same history. Team and
    /// event IDs ride along because the local journal is gone by the time
    /// the service stages the tombstones.
    case deletedMatch(matchID: MatchID, teamID: TeamID, eventIDs: [EventID])
    /// Players fully deleted locally (no match history referenced them, so
    /// they were removed rather than archived). Archived players report as
    /// `.players` because their record still exists.
    case deletedPlayers(teamID: TeamID, playerIDs: [PlayerID])
}
