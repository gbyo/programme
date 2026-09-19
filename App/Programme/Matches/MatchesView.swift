import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI

struct MatchesView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MatchModel.kickoff, order: .reverse) private var matches: [MatchModel]
    @State private var searchText = ""
    @State private var matchToDelete: MatchModel?

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.matches) { match in
                        NavigationLink(value: AppRoute.match(match.matchID)) {
                            MatchRow(match: match)
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
                                    Task { await appModel.openLiveSession(matchID: match.matchID) }
                                }
                            }
                            Button("Open Match", systemImage: "info.circle") {
                                appModel.navigation.open(.match(match.matchID))
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
        .navigationTitle("Matches")
        .searchable(text: $searchText, prompt: "Opponents and competitions")
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Match", systemImage: "plus") {
                    appModel.navigation.isPresentingNewMatch = true
                }
            }
        }
        .confirmationDialog(
            "Delete this match?",
            isPresented: Binding(get: { matchToDelete != nil }, set: { if !$0 { matchToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Match", role: .destructive) {
                if let match = matchToDelete {
                    modelContext.delete(match)
                    try? modelContext.save()
                }
                matchToDelete = nil
            }
            Button("Cancel", role: .cancel) { matchToDelete = nil }
        } message: {
            if let match = matchToDelete {
                Text(
                    "\(match.venue.label) versus \(match.opponentName) and its \(match.cachedEventCount) events will be permanently removed. Export a Programme archive first if you want to keep a copy."
                )
            }
        }
    }

    private var filtered: [MatchModel] {
        guard !searchText.isEmpty else { return matches }
        let query = searchText.lowercased()
        return matches.filter {
            $0.opponentName.lowercased().contains(query)
                || ($0.competition?.lowercased().contains(query) ?? false)
        }
    }

    private struct Group {
        var title: String
        var matches: [MatchModel]
    }

    private var groups: [Group] {
        let source = filtered
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
