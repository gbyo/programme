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
    @State private var seasons: [SeasonListItem] = []
    @State private var seasonFilter: SeasonFilter = .current
    @State private var searchText = ""
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
                        Button {
                            Task { await appModel.open(.match(match.id)) }
                        } label: {
                            MatchListRow(match: match)
                        }
                        .buttonStyle(.plain)
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
        .searchable(text: $searchText, prompt: "Opponents and competitions")
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
                    appModel.navigation.isPresentingNewMatch = true
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Settings", systemImage: "gearshape") {
                    appModel.navigation.isPresentingSettings = true
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
                    Button("Create a Match") { appModel.navigation.isPresentingNewMatch = true }
                        .programmePrimaryAction()
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .confirmationDialog(
            "Delete this match?",
            isPresented: Binding(get: { matchToDelete != nil }, set: { if !$0 { matchToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Match", role: .destructive) {
                if let match = matchToDelete {
                    Task {
                        try? await appModel.store?.deleteMatch(match.id)
                        await reload()
                    }
                }
                matchToDelete = nil
            }
            Button("Cancel", role: .cancel) { matchToDelete = nil }
        } message: {
            if let match = matchToDelete {
                Text(
                    "\(match.venue.label) versus \(match.opponentName) and its \(match.eventCount) events will be permanently removed. Export a Programme archive first if you want to keep a copy."
                )
            }
        }
        .task(id: [teamID.rawValue.uuidString, "\(seasonFilter)", "\(appModel.storeRevision)"]) {
            await reload()
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
        seasons = (try? await store.seasons(teamID: teamID)) ?? []
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

    private var filtered: [MatchListItem] {
        guard !searchText.isEmpty else { return matches }
        let query = searchText.lowercased()
        return matches.filter {
            $0.opponentName.lowercased().contains(query)
                || ($0.competition?.lowercased().contains(query) ?? false)
        }
    }

    private struct Group {
        var title: String
        var matches: [MatchListItem]
    }

    private var groups: [Group] {
        let source = filtered.sorted { $0.kickoff > $1.kickoff }
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
