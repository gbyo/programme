import Charts
import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI

/// Player detail loads statistics from the player's owning team and that
/// team's current season — never from whichever workspace happens to be
/// selected, unless they coincide.
struct PlayerDetailView: View {
    let playerID: PlayerID

    @Environment(AppModel.self) private var appModel
    @State private var snapshot: PlayerSnapshot?
    @State private var ownerTeamID: TeamID?
    @State private var season: SeasonStats?
    @State private var summaries: [MatchStatSummary] = []
    @State private var isEditing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let snapshot {
                    header(snapshot)
                }
                if let season, let stats = season.players[playerID] {
                    seasonSection(stats)
                    if !matchLog.isEmpty { chartSection }
                    matchLogSection
                    if let keeper = season.keepers[playerID] { keeperSection(keeper) }
                } else if season != nil {
                    EmptyHint(
                        title: "No statistics yet",
                        message: "This player hasn't appeared in a finalized match this season."
                    )
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ProgressView()
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(snapshot?.displaySurname ?? "Player")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit", systemImage: "pencil") { isEditing = true }
                    .disabled(snapshot == nil || ownerTeamID == nil)
            }
        }
        .sheet(isPresented: $isEditing) {
            if let ownerTeamID {
                NavigationStack { PlayerEditorView(teamID: ownerTeamID, existing: snapshot) }
            }
        }
        .task(id: [playerID.rawValue.uuidString, "\(appModel.storeRevision)"]) { await load() }
    }

    private func load() async {
        guard let store = appModel.store else { return }
        // Resolve the owning team first; stats come from that team.
        guard let owner = try? await store.teamID(forPlayer: playerID) else { return }
        ownerTeamID = owner
        let roster = (try? await store.roster(teamID: owner, includeFormer: true)) ?? .empty
        snapshot = roster.players.first { $0.id == playerID }
        let currentSeason = try? await store.currentSeasonID(teamID: owner)
        summaries = (try? await store.seasonSummaries(teamID: owner, seasonID: currentSeason)) ?? []
        season = SeasonEngine.aggregate(summaries)
    }

    private func header(_ player: PlayerSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(player.jerseyNumber.map { "#\($0)" } ?? "—")
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(player.fullName).font(.largeTitle.weight(.semibold))
                Text(
                    [player.position?.label, player.classYear, player.isOnRoster ? nil : "Former player"]
                        .compactMap(\.self).joined(separator: " · ")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func seasonSection(_ stats: SeasonPlayerStats) -> some View {
        SectionBox(title: "Season") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                StatCell("Appearances", .count(stats.matchesPlayed), emphasis: true)
                StatCell("Starts", .count(stats.starts), emphasis: true)
                StatCell("Minutes", .count(stats.minutesPlayed), emphasis: true)
                StatCell("Goals", stats.value(.goals, \.goals), emphasis: true)
                StatCell("Assists", stats.value(.assists, \.assists), emphasis: true)
                StatCell("Points", stats.value(.goals, \.points), emphasis: true)
                StatCell("Shots", stats.value(.shots, \.shots))
                StatCell("Shots on Goal", stats.value(.shots, \.shotsOnGoal))
                StatCell("SOG%", stats.shotAccuracy, style: .percent)
                StatCell("Game Winners", stats.value(.goals, \.gameWinningGoals))
                StatCell("Steals", stats.value(.steals, \.steals))
                StatCell("Corners", stats.value(.corners, \.corners))
                StatCell("Yellow Cards", stats.value(.cards, \.yellowCards))
                StatCell("Red Cards", stats.value(.cards, \.redCards))
            }
            .padding(16)
        }
    }

    private var chartSection: some View {
        SectionBox(title: "Contributions by Match") {
            Chart(matchLog, id: \.matchID) { entry in
                BarMark(
                    x: .value("Match", entry.opponent),
                    y: .value("Goals", entry.goals)
                )
                .foregroundStyle(by: .value("Type", "Goals"))
                BarMark(
                    x: .value("Match", entry.opponent),
                    y: .value("Assists", entry.assists)
                )
                .foregroundStyle(by: .value("Type", "Assists"))
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 220)
            .padding(16)
            .accessibilityLabel("Goals and assists by match")
        }
    }

    private struct MatchLogEntry: Identifiable {
        var matchID: MatchID
        var opponent: String
        var date: Date
        var minutes: Int
        var goals: Int
        var assists: Int
        var shots: Int
        var shotsOnGoal: Int
        var started: Bool
        var result: MatchResult?
        var id: MatchID { matchID }
    }

    private var matchLog: [MatchLogEntry] {
        summaries
            .compactMap { summary -> MatchLogEntry? in
                guard let line = summary.players[playerID], line.appeared else { return nil }
                return MatchLogEntry(
                    matchID: summary.matchID, opponent: summary.opponentName, date: summary.kickoff,
                    minutes: line.minutesPlayed, goals: line.goals, assists: line.assists,
                    shots: line.shots, shotsOnGoal: line.shotsOnGoal, started: line.started,
                    result: summary.result)
            }
            .sorted { $0.date < $1.date }
    }

    private var matchLogSection: some View {
        SectionBox(title: "Match by Match") {
            VStack(spacing: 0) {
                ForEach(matchLog.reversed()) { entry in
                    Button {
                        Task { await appModel.open(.match(entry.matchID)) }
                    } label: {
                        HStack(spacing: 12) {
                            if let result = entry.result {
                                Text(result.letter)
                                    .font(.caption.weight(.bold))
                                    .frame(width: 22, height: 22)
                                    .background(result.tint.opacity(0.18), in: Circle())
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.opponent).font(.body)
                                Text(entry.date.matchDayText).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(entry.minutes)'")
                                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Text("\(entry.goals)G \(entry.assists)A")
                                .font(.subheadline.weight(.medium)).monospacedDigit()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if entry.id != matchLog.first?.id { Divider() }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func keeperSection(_ keeper: SeasonKeeperStats) -> some View {
        SectionBox(title: "Goalkeeping") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                StatCell("Minutes", .count(keeper.minutesPlayed), emphasis: true)
                StatCell("Saves", .count(keeper.totals.saves), emphasis: true)
                StatCell("Goals Allowed", .count(keeper.totals.goalsAllowed), emphasis: true)
                StatCell("Save %", keeper.savePercentage, style: .percent)
                StatCell("GAA", keeper.goalsAgainstAverage, style: .decimal)
                StatCell("Shutouts", .count(keeper.totals.shutouts))
                StatCell("Shared Shutouts", .count(keeper.totals.sharedShutouts))
                StatCell("Record", .count(keeper.totals.wins))
            }
            .padding(16)
        }
    }
}
