import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI

/// Matches for one team. Defaults to the team's current season; a native
/// season filter offers a specific older season or all seasons without
/// changing which season is current.
struct MatchesView: View {
    let teamID: TeamID

    @Environment(AppModel.self) private var appModel
    @State private var matches: [MatchListItem] = []
    @State private var seasons: [SeasonIdentity] = []
    @State private var seasonFilter: SeasonFilter = .current
    @State private var matchToDelete: MatchListItem?

    enum SeasonFilter: Hashable {
        case current
        case season(SeasonID)
        case all
    }

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.matches) { match in
                        NavigationLink(value: AppRoute.match(match.id)) {
                            MatchRowContent(match: match)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                matchToDelete = match
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            if match.isInterrupted || match.phase == .scheduled {
                                Button("Score This Match", systemImage: "play.fill") {
                                    Task { await appModel.openLiveSession(matchID: match.id) }
                                }
                            }
                            Button("Open Match", systemImage: "info.circle") {
                                Task { await appModel.open(.match(match.id)) }
                            }
                            Divider()
                            Button("Delete Match", systemImage: "trash", role: .destructive) {
                                matchToDelete = match
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .teamWorkspaceTitle("Matches")
        // Finding across matches, players, teams, and seasons is the shared
        // universal search owned by the navigation shell, not a second local
        // search field here.
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu("Season", systemImage: "calendar") {
                    Button("Current Season") { seasonFilter = .current }
                    ForEach(seasons) { season in
                        Button {
                            seasonFilter = .season(season.id)
                        } label: {
                            if activeSeasonID == season.id {
                                Label(season.name, systemImage: "checkmark")
                            } else {
                                Text(season.name)
                            }
                        }
                    }
                    Divider()
                    Button("All Seasons") { seasonFilter = .all }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Match", systemImage: "plus") {
                    appModel.navigation.presentedSheet = .newMatch
                }
            }
        }
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView {
                    Label("No Matches Yet", systemImage: "calendar")
                } description: {
                    Text("Create a match to prepare a lineup and start scoring.")
                } actions: {
                    Button("Create a Match") { appModel.navigation.presentedSheet = .newMatch }
                        .programmePrimaryAction()
                }
            }
        }
        .confirmationDialog(
            "Delete this match?",
            item: $matchToDelete,
            titleVisibility: .visible
        ) { match in
            Button("Delete Match", role: .destructive) {
                Task {
                    do {
                        try await appModel.store?.deleteMatch(match.id)
                        Haptics.success()
                    } catch {
                        Haptics.error()
                        appModel.navigation.errorToShow = ProgrammeError(
                            title: "Couldn't delete match",
                            message: "Nothing was changed. Try again.",
                            underlying: error)
                    }
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { match in
            Text(
                "\(match.venue.label) versus \(match.opponentName) and its \(match.eventCount) events will be permanently removed. Export a Programme archive first if you want to keep a copy."
            )
        }
        .task(id: [teamID.rawValue.uuidString, "\(seasonFilter)", "\(appModel.storeRevision)"]) {
            await reload()
        }
        .onChange(of: teamID) {
            // A specific season of the old team is meaningless for the new
            // one, and a pending delete belongs to it too. The shell no
            // longer resets our identity on team switches, so team-relative
            // state resets here where it lives.
            seasonFilter = .current
            matchToDelete = nil
        }
    }

    private var activeSeasonID: SeasonID? {
        switch seasonFilter {
        case .current: appModel.workspace.currentSeasonID
        case .season(let id): id
        case .all: nil
        }
    }

    private func reload() async {
        guard let store = appModel.store else { return }
        seasons = (try? await store.seasonIdentities(teamID: teamID)) ?? []
        // Fetch scoped to this team at fetch time; season filtering narrows it.
        switch seasonFilter {
        case .current:
            let current = appModel.workspace.currentSeasonID
            matches = (try? await store.matches(teamID: teamID, seasonID: current)) ?? []
        case .season(let id):
            matches = (try? await store.matches(teamID: teamID, seasonID: id)) ?? []
        case .all:
            matches = (try? await store.matches(teamID: teamID)) ?? []
        }
    }

    private struct Group {
        var title: String
        var matches: [MatchListItem]
    }

    private var groups: [Group] {
        let source = matches.sorted { $0.kickoff > $1.kickoff }
        var result: [Group] = []
        let live = source.filter(\.isInterrupted)
        if !live.isEmpty { result.append(Group(title: "In Progress", matches: live)) }
        let upcoming = source.filter { $0.phase == .scheduled }.sorted { $0.kickoff < $1.kickoff }
        if !upcoming.isEmpty { result.append(Group(title: "Scheduled", matches: upcoming)) }
        let played = source.filter { $0.phase == .finalized }
        if !played.isEmpty { result.append(Group(title: "Played", matches: played)) }
        return result
    }
}
