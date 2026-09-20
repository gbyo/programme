import ProgrammeCore
import ProgrammePersistence
import SwiftUI

/// The two workspace scopes for Programme-wide search.
///
/// Current Team searches only the selected team's matches, players, and
/// seasons. All Teams searches every team and routes cross-team results
/// through the team-aware `AppModel.open(_:)` logic.
enum UniversalSearchScope: String, CaseIterable, Identifiable {
    case currentTeam = "Current Team"
    case allTeams = "All Teams"

    var id: String { rawValue }
}

/// The single source of truth for Programme-wide Search.
///
/// Owns the query, the scope, the programmatic presentation state, and the
/// loaded lightweight snapshots. Data loads once per scope/team/revision
/// change; text matching always filters those snapshots in memory, never by
/// re-reading the store per keystroke. A generation counter keeps stale
/// async reloads (team switch, scope change, store update racing each
/// other) from overwriting newer state.
@MainActor
@Observable
final class UniversalSearchModel {
    struct ScopedMatch: Identifiable {
        let teamID: TeamID
        let match: MatchListItem
        /// Normalized once at load so keystrokes filter in-memory values.
        let searchKey: String
        var id: MatchID { match.id }

        init(teamID: TeamID, match: MatchListItem) {
            self.teamID = teamID
            self.match = match
            self.searchKey =
                "\(match.opponentName) \(match.competition ?? "")".lowercased()
        }
    }

    struct ScopedPlayer: Identifiable {
        let teamID: TeamID
        let teamShortName: String
        let player: PlayerSnapshot
        /// Normalized once at load so keystrokes filter in-memory values.
        let searchKey: String
        var id: PlayerID { player.id }

        init(teamID: TeamID, teamShortName: String, player: PlayerSnapshot) {
            self.teamID = teamID
            self.teamShortName = teamShortName
            self.player = player
            self.searchKey =
                "\(player.firstName) \(player.lastName) \(player.jerseyNumber.map { "\($0)" } ?? "")"
                .lowercased()
        }
    }

    struct ScopedSeason: Identifiable {
        let teamID: TeamID
        let teamShortName: String
        let season: SeasonIdentity
        /// Normalized once at load so keystrokes filter in-memory values.
        let searchKey: String
        var id: SeasonID { season.id }

        init(teamID: TeamID, teamShortName: String, season: SeasonIdentity) {
            self.teamID = teamID
            self.teamShortName = teamShortName
            self.season = season
            self.searchKey = season.name.lowercased()
        }
    }

    var query = ""
    var scope: UniversalSearchScope = .currentTeam
    /// Programmatic search presentation, shared by every section's search
    /// field. Powers the conventional ⌘F command through the native
    /// `searchable(text:isPresented:)` API rather than custom focus state.
    var isPresented = false

    var matches: [ScopedMatch] = []
    var players: [ScopedPlayer] = []
    var teams: [TeamListItem] = []
    var seasons: [ScopedSeason] = []
    /// Normalized team names, computed once per reload alongside `teams`.
    private(set) var teamSearchKeys: [TeamID: String] = [:]

    private var generation = 0
    /// Scope/team/revision key of the last player/season detail load. Cleared
    /// by every reload so a scope, team, or store change refetches details.
    private var detailsKey: String?

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Leaving search — selecting a result or cancelling — dismisses the
    /// field and clears the query, so another section never inherits a
    /// hidden stale query.
    func completeSelection() {
        isPresented = false
        query = ""
    }

    /// Loads the empty-query dataset: teams plus the matches actually
    /// displayed before typing. Player and season snapshots stay unloaded
    /// until a nonempty query first needs them (see `ensureDetailsLoaded`).
    func reload(store: MatchStore, selectedTeamID: TeamID?, revision: Int) async {
        generation &+= 1
        let current = generation
        let scope = scope
        let teams = (try? await store.teams()) ?? []
        guard !Task.isCancelled, current == generation else { return }
        let teamIDs =
            switch scope {
            case .currentTeam: selectedTeamID.map { [$0] } ?? []
            case .allTeams: teams.map(\.id)
            }
        var loadedMatches: [ScopedMatch] = []
        for teamID in teamIDs {
            let teamMatches = (try? await store.matches(teamID: teamID)) ?? []
            loadedMatches += teamMatches.map { ScopedMatch(teamID: teamID, match: $0) }
        }
        guard !Task.isCancelled, current == generation else { return }
        self.teams = teams
        self.teamSearchKeys = Dictionary(
            uniqueKeysWithValues: teams.map { ($0.id, $0.name.lowercased()) })
        self.matches = loadedMatches
        // Any scope, team, or store change invalidates the detail snapshots.
        self.players = []
        self.seasons = []
        detailsKey = nil
        // A reload landing while a query is active must rehydrate details.
        await ensureDetailsLoaded(store: store, selectedTeamID: selectedTeamID, revision: revision)
    }

    /// Lazily loads player/season searchable snapshots the first time a
    /// nonempty query needs them. Cached per scope/team/revision until the
    /// next reload; the generation guard still drops stale results.
    func ensureDetailsLoaded(store: MatchStore, selectedTeamID: TeamID?, revision: Int) async {
        guard !trimmedQuery.isEmpty else { return }
        let key = [
            scope.rawValue, selectedTeamID?.rawValue.uuidString ?? "none",
            "\(revision)",
        ].joined(separator: "#")
        guard detailsKey != key else { return }
        let current = generation
        let scope = scope
        let teams = teams
        let teamNames = Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0.shortName) })
        let teamIDs =
            switch scope {
            case .currentTeam: selectedTeamID.map { [$0] } ?? []
            case .allTeams: teams.map(\.id)
            }
        var loadedPlayers: [ScopedPlayer] = []
        var loadedSeasons: [ScopedSeason] = []
        for teamID in teamIDs {
            let roster = (try? await store.roster(teamID: teamID)) ?? .empty
            loadedPlayers += roster.sortedByNumber.map {
                ScopedPlayer(
                    teamID: teamID, teamShortName: teamNames[teamID] ?? "",
                    player: $0)
            }
            let teamSeasons = (try? await store.seasonIdentities(teamID: teamID)) ?? []
            loadedSeasons += teamSeasons.map {
                ScopedSeason(
                    teamID: teamID, teamShortName: teamNames[teamID] ?? "",
                    season: $0)
            }
        }
        guard !Task.isCancelled, current == generation else { return }
        self.players = loadedPlayers
        self.seasons = loadedSeasons
        detailsKey = key
    }

    // MARK: - Filtering

    /// Current-Team results are guarded at read time as well as load time,
    /// so a team switch can never leak the previous team's snapshots into
    /// a query before the reload lands.
    private func inScope<T>(_ values: [(TeamID, T)], selectedTeamID: TeamID?) -> [T] {
        guard scope == .currentTeam else { return values.map(\.1) }
        return values.filter { $0.0 == selectedTeamID }.map(\.1)
    }

    func shownMatches(selectedTeamID: TeamID?) -> [ScopedMatch] {
        let scoped = inScope(matches.map { ($0.teamID, $0) }, selectedTeamID: selectedTeamID)
        guard !trimmedQuery.isEmpty else {
            // Restrained before typing: the current team's recent matches.
            return
                scoped
                .filter { $0.teamID == selectedTeamID }
                .sorted { $0.match.kickoff > $1.match.kickoff }
                .prefix(5)
                .map(\.self)
        }
        let needle = trimmedQuery.lowercased()
        return scoped.filter { $0.searchKey.contains(needle) }
    }

    func shownPlayers(selectedTeamID: TeamID?) -> [ScopedPlayer] {
        guard !trimmedQuery.isEmpty else { return [] }
        let needle = trimmedQuery.lowercased()
        return inScope(players.map { ($0.teamID, $0) }, selectedTeamID: selectedTeamID).filter {
            $0.searchKey.contains(needle)
        }
    }

    func shownTeams() -> [TeamListItem] {
        guard !trimmedQuery.isEmpty else { return teams }
        let needle = trimmedQuery.lowercased()
        return teams.filter { teamSearchKeys[$0.id]?.contains(needle) ?? false }
    }

    func shownSeasons(selectedTeamID: TeamID?) -> [ScopedSeason] {
        guard !trimmedQuery.isEmpty else { return [] }
        let needle = trimmedQuery.lowercased()
        return inScope(seasons.map { ($0.teamID, $0) }, selectedTeamID: selectedTeamID).filter {
            $0.searchKey.contains(needle)
        }
    }
}

/// The one shared Programme-wide result presentation, shown in place of the
/// current section's root while its search field is active.
///
/// Renders matches, players, teams, and seasons with the existing
/// Programme-native rows. Every result routes through the canonical,
/// team-aware destinations — `AppModel.open(_:)` for matches, players, and
/// seasons (which selects the owning team first), `selectTeam(_:)` for
/// teams — so search acts as a launcher, never as its own navigation
/// universe.
struct UniversalSearchResults: View {
    @Bindable var search: UniversalSearchModel
    /// The owning section: search acts on its content, so the results keep
    /// its navigation title instead of renaming the destination "Search".
    let section: AppSection

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        let selectedTeamID = appModel.workspace.selectedTeamID
        let matches = search.shownMatches(selectedTeamID: selectedTeamID)
        let players = search.shownPlayers(selectedTeamID: selectedTeamID)
        let teams = search.shownTeams()
        let seasons = search.shownSeasons(selectedTeamID: selectedTeamID)

        List {
            if !matches.isEmpty {
                Section(search.trimmedQuery.isEmpty ? "Recent Matches" : "Matches") {
                    ForEach(matches) { result in
                        matchRow(result)
                    }
                }
            }
            if !players.isEmpty {
                Section("Players") {
                    ForEach(players) { result in
                        playerRow(result)
                    }
                }
            }
            if !teams.isEmpty {
                Section("Teams") {
                    ForEach(teams) { team in
                        teamRow(team)
                    }
                }
            }
            if !seasons.isEmpty {
                Section("Seasons") {
                    ForEach(seasons) { result in
                        seasonRow(result)
                    }
                }
            }
            if matches.isEmpty && players.isEmpty && teams.isEmpty && seasons.isEmpty {
                ContentUnavailableView.search(text: search.query)
            }
        }
        .listStyle(.insetGrouped)
        .teamWorkspaceTitle(section.rootTitle)
        .task(id: reloadKey) {
            guard let store = appModel.store else { return }
            await search.reload(
                store: store, selectedTeamID: selectedTeamID,
                revision: appModel.storeRevision)
        }
        .task(id: search.trimmedQuery.isEmpty) {
            guard let store = appModel.store else { return }
            await search.ensureDetailsLoaded(
                store: store, selectedTeamID: selectedTeamID,
                revision: appModel.storeRevision)
        }
        .accessibilityIdentifier("search.content")
    }

    private var reloadKey: String {
        [
            search.scope.rawValue,
            appModel.workspace.selectedTeamID?.rawValue.uuidString ?? "none",
            "\(appModel.storeRevision)",
        ].joined(separator: "#")
    }

    // MARK: - Rows

    /// Same-team rows keep the native row accessibility untouched;
    /// cross-team rows carry the owning team in the spoken label instead of
    /// relying on the visual badge alone.
    @ViewBuilder
    private func matchRow(_ result: UniversalSearchModel.ScopedMatch) -> some View {
        if result.teamID == appModel.workspace.selectedTeamID {
            Button {
                openMatch(result.match.id)
            } label: {
                MatchRowContent(match: result.match)
            }
            .accessibilityIdentifier("match.\(result.match.opponentName)")
        } else {
            Button {
                openMatch(result.match.id)
            } label: {
                MatchRowContent(match: result.match)
            }
            .accessibilityIdentifier("match.\(result.match.opponentName)")
            .accessibilityLabel(
                "\(result.match.venue.label) versus \(result.match.opponentName), \(teamName(for: result.teamID))"
            )
            .badge(teamShortName(for: result.teamID))
        }
    }

    @ViewBuilder
    private func playerRow(_ result: UniversalSearchModel.ScopedPlayer) -> some View {
        if result.teamID == appModel.workspace.selectedTeamID {
            Button {
                openPlayer(result.player.id)
            } label: {
                PlayerRosterRow(snapshot: result.player)
            }
            .accessibilityIdentifier("search.player.\(result.player.lastName)")
        } else {
            Button {
                openPlayer(result.player.id)
            } label: {
                PlayerRosterRow(snapshot: result.player)
            }
            .accessibilityIdentifier("search.player.\(result.player.lastName)")
            .accessibilityLabel(
                "\(result.player.accessibilityLabel), \(result.teamShortName)"
            )
            .badge(result.teamShortName)
        }
    }

    @ViewBuilder
    private func teamRow(_ team: TeamListItem) -> some View {
        Button {
            selectTeam(team.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name).font(.body)
                    Text("\(team.playerCount) players · \(team.seasonCount) seasons")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if team.id == appModel.workspace.selectedTeamID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Selected team")
                }
            }
        }
        .accessibilityIdentifier("search.team.\(team.name)")
    }

    @ViewBuilder
    private func seasonRow(_ result: UniversalSearchModel.ScopedSeason) -> some View {
        Button {
            openSeason(result.season.id)
        } label: {
            HStack {
                Text(result.season.name).font(.body)
                Spacer()
                Text(result.teamShortName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("search.season.\(result.season.name)")
    }

    private func teamName(for teamID: TeamID) -> String {
        search.teams.first { $0.id == teamID }?.name ?? ""
    }

    private func teamShortName(for teamID: TeamID) -> String {
        search.teams.first { $0.id == teamID }?.shortName ?? ""
    }

    // MARK: - Routing

    /// Every selection dismisses search, clears the query, and routes into
    /// the canonical stack — Matches for matches, Roster for players, Stats
    /// for seasons — even when search was opened from another section.
    private func openMatch(_ id: MatchID) {
        search.completeSelection()
        dismissSearch()
        Task { await appModel.open(.match(id)) }
    }

    private func openPlayer(_ id: PlayerID) {
        search.completeSelection()
        dismissSearch()
        Task { await appModel.open(.player(id)) }
    }

    private func openSeason(_ id: SeasonID) {
        search.completeSelection()
        dismissSearch()
        Task { await appModel.open(.season(id)) }
    }

    private func selectTeam(_ id: TeamID) {
        search.completeSelection()
        dismissSearch()
        Task { await appModel.selectTeam(id) }
    }
}
