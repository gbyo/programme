import Foundation
import ProgrammeCollaboration
import ProgrammeCore

/// A derived surface that can refresh independently of the rest of the app.
///
/// Views subscribe to exactly the scopes they read, so a roster write in Team
/// B never refetches Team A's matches. Anything the typed mutations cannot
/// describe (derived-cache writes, reminder preferences, out-of-band edits)
/// still lands through the debounced global revision in `AppModel`.
enum InvalidationScope: Hashable, Sendable {
    /// Team lists, workspace selection, Manage Teams.
    case teams
    /// One team's roster list.
    case roster(TeamID)
    /// One player's detail.
    case player(PlayerID)
    /// One team's match list and home surfaces.
    case matches(TeamID)
    /// One team's event-derived surfaces: list scores, season stats, search.
    case teamEvents(TeamID)
    /// One team's season lists and stats-season browsing.
    case seasons(TeamID)
    /// Universal search reads matches and players across teams.
    case search
}

/// One scope's revision counter.
///
/// A stable reference per scope, cached by `AppModel`. Views read `count`
/// through the cached object, so observation tracks only their own scope:
/// a dictionary of counters on `AppModel` would re-notify every reader on
/// every bump. Main-actor confined in practice; every reader and writer runs
/// on the main actor.
@Observable
final class ScopeRevision: @unchecked Sendable {
    var count = 0
}

/// What a persisted mutation means for derived surfaces.
struct StoreInvalidationImpact: Sendable {
    /// Scopes that must refetch now.
    var scopes: Set<InvalidationScope>
    /// Teams whose widget snapshot may have changed.
    var widgetTeamIDs: Set<TeamID>
    /// Whether searchable match/player entities may have changed. Pure
    /// in-match event writes skip this: they change scores, not the indexed
    /// entity set, and the debounced observer pass still reindexes bursts.
    var refreshSpotlight: Bool
    /// Whether interrupted-match recovery candidates may have changed.
    /// Roster, season, and team-profile writes cannot create candidates.
    var refreshRecovery: Bool
}

/// Pure mapping from persisted mutations to derived-surface impact.
///
/// The store reports every save through one funnel (`MatchStore.noteMutation`),
/// including suppressed remote applies, so this mapping sees local edits,
/// second-window writes, archive imports, and synced changes alike.
/// `teamID` is resolved by the caller for match-scoped mutations; `nil`
/// means the match row is already gone, which is treated conservatively.
enum StoreInvalidation {
    static func impact(of mutation: OutboundMutation, teamID: TeamID?) -> StoreInvalidationImpact {
        switch mutation {
        case .team(let id):
            return StoreInvalidationImpact(
                scopes: [.teams, .search],
                widgetTeamIDs: [id],
                refreshSpotlight: true,
                refreshRecovery: false)
        case .season(let teamID, _):
            return StoreInvalidationImpact(
                scopes: [.seasons(teamID), .matches(teamID), .search],
                widgetTeamIDs: [teamID],
                refreshSpotlight: true,
                refreshRecovery: false)
        case .players(let teamID, let playerIDs), .deletedPlayers(let teamID, let playerIDs):
            var scopes: Set<InvalidationScope> = [.roster(teamID), .search]
            scopes.formUnion(playerIDs.map(InvalidationScope.player))
            return StoreInvalidationImpact(
                scopes: scopes,
                widgetTeamIDs: [teamID],
                refreshSpotlight: true,
                refreshRecovery: false)
        case .match:
            guard let teamID else { return conservativeFallback() }
            return StoreInvalidationImpact(
                scopes: [.matches(teamID), .teamEvents(teamID), .search],
                widgetTeamIDs: [teamID],
                refreshSpotlight: true,
                refreshRecovery: true)
        case .events:
            guard let teamID else { return conservativeFallback() }
            return StoreInvalidationImpact(
                scopes: [.teamEvents(teamID), .matches(teamID), .search],
                widgetTeamIDs: [teamID],
                refreshSpotlight: false,
                refreshRecovery: true)
        case .deletedMatch(_, let teamID, _):
            return StoreInvalidationImpact(
                scopes: [.matches(teamID), .teamEvents(teamID), .seasons(teamID), .search],
                widgetTeamIDs: [teamID],
                refreshSpotlight: true,
                refreshRecovery: true)
        }
    }

    /// The match row is gone and its team cannot be resolved: refresh the
    /// cross-team surfaces and run every side refresh rather than risk a
    /// missed external delete.
    private static func conservativeFallback() -> StoreInvalidationImpact {
        StoreInvalidationImpact(
            scopes: [.search],
            widgetTeamIDs: [],
            refreshSpotlight: true,
            refreshRecovery: true)
    }
}
