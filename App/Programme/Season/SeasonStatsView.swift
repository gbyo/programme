import Charts
import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import ProgrammeUI
import SwiftUI

struct SeasonStatsView: View {
    let seasonID: SeasonID?

    @Environment(AppModel.self) private var appModel
    @State private var season: SeasonStats?
    @State private var roster: RosterSnapshot = .empty
    @State private var isExporting = false
    @State private var contexts: [MatchContext] = []

    var body: some View {
        Group {
            if let season, season.matchesPlayed > 0 {
                content(season)
            } else if season != nil {
                ContentUnavailableView {
                    Label("No Finalized Matches", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("Season statistics appear once you finalize a match.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Season Stats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export", systemImage: "square.and.arrow.up") { isExporting = true }
                    .disabled(contexts.isEmpty)
            }
        }
        .sheet(isPresented: $isExporting) {
            NavigationStack {
                ExportSheet(
                    payload: ExportPayload(
                        teamName: appModel.teamName, teamShortName: appModel.teamShortName,
                        contexts: contexts),
                    exporters: ProgrammeExporters.forSeason())
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let store = appModel.store, let teamID = appModel.teamID else { return }
        let summaries =
            (try? await store.seasonSummaries(
                teamID: teamID, seasonID: seasonID ?? appModel.seasonID)) ?? []
        season = SeasonEngine.aggregate(summaries)
        roster = (try? await store.roster(teamID: teamID, includeFormer: true)) ?? .empty

        let items =
            (try? await store.matches(teamID: teamID, seasonID: seasonID ?? appModel.seasonID)) ?? []
        var loaded: [MatchContext] = []
        for item in items where item.phase == .finalized {
            if let context = try? await store.context(for: item.id) { loaded.append(context) }
        }
        contexts = loaded.sorted { $0.descriptor.kickoff < $1.descriptor.kickoff }
    }

    private func content(_ season: SeasonStats) -> some View {
        List {
            Section {
                header(season).padding(.vertical, 8)
            }
            resultsChart(season)
            leadersSection(season)

            Section("Statistics") {
                NavigationLink {
                    SeasonPlayersTableView(season: season, roster: roster)
                } label: {
                    statisticsLink(
                        title: "Player Statistics",
                        detail: "\(season.players.count) players · GP, MIN, G, A, PTS, SH, SOG",
                        symbol: "person.3")
                }
                if !season.sortedKeepers.isEmpty {
                    NavigationLink {
                        SeasonKeepersTableView(season: season, roster: roster)
                    } label: {
                        statisticsLink(
                            title: "Goalkeeping",
                            detail: "\(season.sortedKeepers.count) keepers · MIN, SV, GA, SV%, GAA, SHO",
                            symbol: "hand.raised")
                    }
                }
            }
            completenessSection(season)
        }
        .listStyle(.insetGrouped)
    }

    private func header(_ season: SeasonStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appModel.teamName).font(.largeTitle.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(season.recordText).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("Record").font(.caption).foregroundStyle(.secondary)
                }
                StatCell("Goals For", .count(season.goalsFor), emphasis: true)
                StatCell("Goals Against", .count(season.goalsAgainst), emphasis: true)
                StatCell("Shutouts", .count(season.teamShutouts), emphasis: true)
                StatCell("Matches", .count(season.matchesPlayed), emphasis: true)
            }
        }
    }

    private func resultsChart(_ season: SeasonStats) -> some View {
        Section("Goals by Match") {
            Chart {
                ForEach(season.matches, id: \.matchID) { match in
                    BarMark(x: .value("Match", match.opponentName), y: .value("Goals For", match.score.us))
                        .foregroundStyle(by: .value("Side", "For"))
                        .position(by: .value("Side", "For"))
                    BarMark(
                        x: .value("Match", match.opponentName),
                        y: .value("Goals Against", match.score.opponent)
                    )
                    .foregroundStyle(by: .value("Side", "Against"))
                    .position(by: .value("Side", "Against"))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 230)
            .padding(.vertical, 8)
            .accessibilityLabel("Goals for and against, by match")
        }
    }

    private func leadersSection(_ season: SeasonStats) -> some View {
        Section("Leaders") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                leaderGroup("Points", season.sortedPlayers.prefix(3).map { ($0.playerID, "\($0.points)") })
                leaderGroup(
                    "Goals",
                    season.players.values.sorted { $0.totals.goals > $1.totals.goals }.prefix(3).map {
                        ($0.playerID, "\($0.totals.goals)")
                    })
                leaderGroup(
                    "Assists",
                    season.players.values.sorted { $0.totals.assists > $1.totals.assists }.prefix(3).map {
                        ($0.playerID, "\($0.totals.assists)")
                    })
                leaderGroup(
                    "Minutes",
                    season.players.values.sorted { $0.secondsPlayed > $1.secondsPlayed }.prefix(3).map {
                        ($0.playerID, "\($0.minutesPlayed)")
                    })
            }
            .padding(.vertical, 8)
        }
    }

    private func leaderGroup(_ title: String, _ entries: [(PlayerID, String)]) -> some View {
        GroupBox {
            VStack(spacing: 8) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(roster[entry.0]?.shortLabel ?? "—").font(.subheadline).lineLimit(1)
                        Spacer()
                        Text(entry.1).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
                if entries.isEmpty { Text("No data").font(.caption).foregroundStyle(.secondary) }
            }
        } label: {
            Text(title)
        }
    }

    private func statisticsLink(title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }

    private func completenessSection(_ season: SeasonStats) -> some View {
        Section {
            ForEach(TrackedStat.allCases.sorted { $0.label < $1.label }) { stat in
                HStack {
                    CompletenessRow(stat: stat, state: season.completeness(stat))
                    if season.completeness(stat) == .needsReview {
                        Text("\(season.trackedMatches[stat] ?? 0) of \(season.matchesPlayed) matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("What This Season Tracked")
        } footer: {
            Text(
                "Totals only include matches that were tracking a category. A category no match tracked stays unknown rather than being reported as zero."
            )
        }
    }
}

private struct SeasonPlayerTableRow: Identifiable {
    let stats: SeasonPlayerStats
    let player: PlayerSnapshot?

    var id: PlayerID { stats.playerID }
    var name: String { player?.shortLabel ?? "—" }
    var gamesPlayed: Int { stats.matchesPlayed }
    var starts: Int { stats.starts }
    var minutes: Int { stats.minutesPlayed }
    var goals: Int { stats.value(.goals, \.goals).countValue ?? Int.min }
    var assists: Int { stats.value(.assists, \.assists).countValue ?? Int.min }
    var points: Int { stats.value(.goals, \.points).countValue ?? Int.min }
    var shots: Int { stats.value(.shots, \.shots).countValue ?? Int.min }
    var shotsOnGoal: Int { stats.value(.shots, \.shotsOnGoal).countValue ?? Int.min }
}

private struct SeasonPlayersTableView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var rows: [SeasonPlayerTableRow]
    @State private var selection: PlayerID?
    @State private var sortOrder = [KeyPathComparator(\SeasonPlayerTableRow.points, order: .reverse)]

    init(season: SeasonStats, roster: RosterSnapshot) {
        let rows = season.players.values.map {
            SeasonPlayerTableRow(stats: $0, player: roster[$0.playerID])
        }
        _rows = State(initialValue: rows.sorted { $0.points > $1.points })
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Player", value: \.name) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.body.weight(.medium))
                    if horizontalSizeClass == .compact {
                        Text("\(row.gamesPlayed) GP · \(row.starts) GS · \(row.minutes) MIN")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(compactProduction(row)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("GP", value: \.gamesPlayed) { Text("\($0.gamesPlayed)").monospacedDigit() }
            TableColumn("GS", value: \.starts) { Text("\($0.starts)").monospacedDigit() }
            TableColumn("MIN", value: \.minutes) { Text("\($0.minutes)").monospacedDigit() }
            TableColumn("G", value: \.goals) { StatValueText($0.stats.value(.goals, \.goals)) }
            TableColumn("A", value: \.assists) { StatValueText($0.stats.value(.assists, \.assists)) }
            TableColumn("PTS", value: \.points) { StatValueText($0.stats.value(.goals, \.points)) }
            TableColumn("SH", value: \.shots) { StatValueText($0.stats.value(.shots, \.shots)) }
            TableColumn("SOG", value: \.shotsOnGoal) { StatValueText($0.stats.value(.shots, \.shotsOnGoal)) }
        }
        .onChange(of: sortOrder) { _, order in rows.sort(using: order) }
        .navigationTitle("Player Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selection) { PlayerDetailView(playerID: $0) }
    }

    private func compactProduction(_ row: SeasonPlayerTableRow) -> String {
        let stats = row.stats
        return
            "\(stats.value(.goals, \.goals).text()) G · \(stats.value(.assists, \.assists).text()) A · \(stats.value(.goals, \.points).text()) PTS · \(stats.value(.shots, \.shots).text()) SH · \(stats.value(.shots, \.shotsOnGoal).text()) SOG"
    }
}

private struct SeasonKeepersTableView: View {
    let season: SeasonStats
    let roster: RosterSnapshot

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: PlayerID?

    var body: some View {
        Table(season.sortedKeepers, selection: $selection) {
            TableColumn("Goalkeeper") { keeper in
                VStack(alignment: .leading, spacing: 2) {
                    Text(roster[keeper.playerID]?.shortLabel ?? "—").font(.body.weight(.medium))
                    if horizontalSizeClass == .compact {
                        Text(
                            "\(keeper.matchesPlayed) GP · \(keeper.minutesPlayed) MIN · \(keeper.totals.saves) SV · \(keeper.totals.goalsAllowed) GA"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Text(
                            "\(keeper.savePercentage.text()) SV% · \(keeper.goalsAgainstAverage.text()) GAA · \(keeper.totals.shutouts) SHO"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("GP") { Text("\($0.matchesPlayed)").monospacedDigit() }
            TableColumn("MIN") { Text("\($0.minutesPlayed)").monospacedDigit() }
            TableColumn("SV") { Text("\($0.totals.saves)").monospacedDigit() }
            TableColumn("GA") { Text("\($0.totals.goalsAllowed)").monospacedDigit() }
            TableColumn("SV%") { StatValueText($0.savePercentage, style: .percent) }
            TableColumn("GAA") { StatValueText($0.goalsAgainstAverage, style: .decimal) }
            TableColumn("SHO") { Text("\($0.totals.shutouts)").monospacedDigit() }
        }
        .navigationTitle("Goalkeeping")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selection) { PlayerDetailView(playerID: $0) }
    }
}
