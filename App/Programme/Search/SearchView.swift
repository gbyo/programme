import ProgrammeCore
import ProgrammePersistence
import SwiftUI

/// Global search across matches, players, teams, and seasons, integrated as
/// the TabView's search tab rather than a separate navigation scheme.
///
/// Results reuse the existing entity rows and route through the same
/// navigation model as every other entry point: same-team matches and
/// players push in place, cross-team results go through
/// `AppModel.open(_:)`, which selects the owning team first. Team results
/// select the workspace; season results open Stats at that season.
struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case currentTeam = "Current Team"
        case allTeams = "All Teams"

        var id: String { rawValue }
    }

    struct ScopedMatch: Identifiable {
        let teamID: TeamID
        let match: MatchListItem
        var id: MatchID { match.id }
    }

    struct ScopedPlayer: Identifiable {
        let teamID: TeamID
        let teamShortName: String
        let player: PlayerSnapshot
        var id: PlayerID { player.id }
    }

    struct ScopedSeason: Identifiable {
        let teamID: TeamID
        let teamShortName: String
        let season: SeasonListItem
        var id: SeasonID { season.id }
    }

    @Environment(AppModel.self) private var appModel
    @State private var query = ""
    @State private var scope: Scope = .currentTeam
    @State private var matches: [ScopedMatch] = []
    @State private var players: [ScopedPlayer] = []
    @State private var teams: [TeamListItem] = []
    @State private var seasons: [ScopedSeason] = []

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var isAllTeams: Bool { scope == .allTeams }

    private var shownMatches: [ScopedMatch] {
        guard !trimmedQuery.isEmpty else {
            // Useful before text is entered: the current team's recent matches.
            return
                matches
                .filter { $0.teamID == appModel.workspace.selectedTeamID }
                .sorted { $0.match.kickoff > $1.match.kickoff }
                .prefix(5)
                .map(\.self)
        }
        let needle = trimmedQuery.lowercased()
        return matches.filter {
            $0.match.opponentName.lowercased().contains(needle)
                || ($0.match.competition?.lowercased().contains(needle) ?? false)
        }
    }

    private var shownPlayers: [ScopedPlayer] {
        guard !trimmedQuery.isEmpty else { return [] }
        let needle = trimmedQuery.lowercased()
        return players.filter {
            $0.player.firstName.lowercased().contains(needle)
                || $0.player.lastName.lowercased().contains(needle)
                || ($0.player.jerseyNumber.map { "\($0)" } ?? "").contains(needle)
        }
    }

    private var shownTeams: [TeamListItem] {
        guard !trimmedQuery.isEmpty else { return teams }
        let needle = trimmedQuery.lowercased()
        return teams.filter { $0.name.lowercased().contains(needle) }
    }

    private var shownSeasons: [ScopedSeason] {
        guard !trimmedQuery.isEmpty else { return [] }
        let needle = trimmedQuery.lowercased()
        return seasons.filter { $0.season.name.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            if !shownMatches.isEmpty {
                Section(trimmedQuery.isEmpty ? "Recent Matches" : "Matches") {
                    ForEach(shownMatches) { result in
                        matchRow(result)
                    }
                }
            }
            if !shownPlayers.isEmpty {
                Section("Players") {
                    ForEach(shownPlayers) { result in
                        playerRow(result)
                    }
                }
            }
            if !shownTeams.isEmpty {
                Section("Teams") {
                    ForEach(shownTeams) { team in
                        Button {
                            Task { await appModel.selectTeam(team.id) }
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
                    }
                }
            }
            if !shownSeasons.isEmpty {
                Section("Seasons") {
                    ForEach(shownSeasons) { result in
                        Button {
                            Task {
                                if result.teamID != appModel.workspace.selectedTeamID {
                                    await appModel.selectTeam(result.teamID)
                                }
                                await appModel.open(.season(result.season.id))
                            }
                        } label: {
                            HStack {
                                Text(result.season.name).font(.body)
                                Spacer()
                                Text(result.teamShortName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if trimmedQuery.isEmpty && shownMatches.isEmpty && shownTeams.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .listStyle(.insetGrouped)
        .teamWorkspaceTitle("Search")
        .searchable(text: $query, prompt: "Matches, players, teams, seasons")
        .searchScopes($scope) {
            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
        }
        .task(id: reloadKey) { await reload() }
        .accessibilityIdentifier("search.content")
    }

    private var reloadKey: String {
        [
            scope.rawValue,
            appModel.workspace.selectedTeamID?.rawValue.uuidString ?? "none",
            "\(appModel.storeRevision)",
        ].joined(separator: "#")
    }

    private var scopedTeamIDs: [TeamID] {
        if isAllTeams {
            teams.map(\.id)
        } else if let selected = appModel.workspace.selectedTeamID {
            [selected]
        } else {
            []
        }
    }

    private func reload() async {
        guard let store = appModel.store else { return }
        teams = (try? await store.teams()) ?? []
        var loadedMatches: [ScopedMatch] = []
        var loadedPlayers: [ScopedPlayer] = []
        var loadedSeasons: [ScopedSeason] = []
        let teamNames = Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0.shortName) })
        for teamID in scopedTeamIDs {
            let teamMatches = (try? await store.matches(teamID: teamID)) ?? []
            loadedMatches += teamMatches.map { ScopedMatch(teamID: teamID, match: $0) }
            let roster = (try? await store.roster(teamID: teamID)) ?? .empty
            loadedPlayers += roster.sortedByNumber.map {
                ScopedPlayer(
                    teamID: teamID, teamShortName: teamNames[teamID] ?? "",
                    player: $0)
            }
            let teamSeasons = (try? await store.seasons(teamID: teamID)) ?? []
            loadedSeasons += teamSeasons.map {
                ScopedSeason(
                    teamID: teamID, teamShortName: teamNames[teamID] ?? "",
                    season: $0)
            }
        }
        matches = loadedMatches
        players = loadedPlayers
        seasons = loadedSeasons
    }

    @ViewBuilder
    private func matchRow(_ result: ScopedMatch) -> some View {
        if result.teamID == appModel.workspace.selectedTeamID {
            NavigationLink(value: AppRoute.match(result.match.id)) {
                MatchRowContent(match: result.match)
            }
        } else {
            Button {
                Task { await appModel.open(.match(result.match.id)) }
            } label: {
                MatchRowContent(match: result.match)
            }
            .badge(shortName(for: result.teamID))
        }
    }

    @ViewBuilder
    private func playerRow(_ result: ScopedPlayer) -> some View {
        if result.teamID == appModel.workspace.selectedTeamID {
            NavigationLink(value: AppRoute.player(result.player.id)) {
                PlayerRosterRow(snapshot: result.player)
            }
        } else {
            Button {
                Task { await appModel.open(.player(result.player.id)) }
            } label: {
                PlayerRosterRow(snapshot: result.player)
            }
            .badge(result.teamShortName)
        }
    }

    private func shortName(for teamID: TeamID) -> String {
        teams.first { $0.id == teamID }?.shortName ?? ""
    }
}
