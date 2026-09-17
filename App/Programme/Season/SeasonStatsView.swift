import Charts
import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI

/// Season statistics: a record book, not a dashboard.
struct SeasonStatsView: View {
    let seasonID: SeasonID?

    @Environment(AppModel.self) private var appModel
    @State private var season: SeasonStats?
    @State private var roster: RosterSnapshot = .empty
    @State private var isExporting = false
    @State private var contexts: [MatchContext] = []
    @State private var sortField: SortField = .points

    enum SortField: String, CaseIterable, Identifiable {
        case points = "Points"
        case goals = "Goals"
        case assists = "Assists"
        case minutes = "Minutes"
        var id: String { rawValue }
    }

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
        let summaries = (try? await store.seasonSummaries(teamID: teamID, seasonID: seasonID ?? appModel.seasonID)) ?? []
        season = SeasonEngine.aggregate(summaries)
        roster = (try? await store.roster(teamID: teamID, includeFormer: true)) ?? .empty

        let items = (try? await store.matches(teamID: teamID, seasonID: seasonID ?? appModel.seasonID)) ?? []
        var loaded: [MatchContext] = []
        for item in items where item.phase == .finalized {
            if let context = try? await store.context(for: item.id) { loaded.append(context) }
        }
        contexts = loaded.sorted { $0.descriptor.kickoff < $1.descriptor.kickoff }
    }

    private func content(_ season: SeasonStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header(season)
                resultsChart(season)
                leadersSection(season)
                skatersTable(season)
                if !season.sortedKeepers.isEmpty { keeperTable(season) }
                completenessSection(season)
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ season: SeasonStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appModel.teamName).font(.largeTitle.weight(.semibold))
            HStack(spacing: 18) {
                StatCell("Record", .count(season.wins), emphasis: true)
                    .overlay(alignment: .topLeading) {
                        Text(season.recordText)
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                            .background(Color(.systemBackground))
                    }
                StatCell("Goals For", .count(season.goalsFor), emphasis: true)
                StatCell("Goals Against", .count(season.goalsAgainst), emphasis: true)
                StatCell("Shutouts", .count(season.teamShutouts), emphasis: true)
                StatCell("Matches", .count(season.matchesPlayed), emphasis: true)
            }
        }
    }

    private func resultsChart(_ season: SeasonStats) -> some View {
        SectionBox(title: "Goals by Match") {
            Chart {
                ForEach(season.matches, id: \.matchID) { match in
                    BarMark(
                        x: .value("Match", match.opponentName),
                        y: .value("Goals For", match.score.us)
                    )
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
            .padding(16)
            .accessibilityLabel("Goals for and against, by match")
        }
    }

    private func leadersSection(_ season: SeasonStats) -> some View {
        SectionBox(title: "Leaders") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                leaderCard("Points", season.sortedPlayers.prefix(3).map { ($0.playerID, "\($0.points)") })
                leaderCard(
                    "Goals",
                    season.players.values.sorted { $0.totals.goals > $1.totals.goals }.prefix(3).map {
                        ($0.playerID, "\($0.totals.goals)")
                    })
                leaderCard(
                    "Assists",
                    season.players.values.sorted { $0.totals.assists > $1.totals.assists }.prefix(3).map {
                        ($0.playerID, "\($0.totals.assists)")
                    })
                leaderCard(
                    "Minutes",
                    season.players.values.sorted { $0.secondsPlayed > $1.secondsPlayed }.prefix(3).map {
                        ($0.playerID, "\($0.minutesPlayed)")
                    })
            }
            .padding(16)
        }
    }

    private func leaderCard(_ title: String, _ entries: [(PlayerID, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).programmeSectionHeader()
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack {
                    Text(roster[entry.0]?.shortLabel ?? "—")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.1)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if entries.isEmpty {
                Text("No data").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func skatersTable(_ season: SeasonStats) -> some View {
        SectionBox(title: "Players") {
            VStack(spacing: 0) {
                Picker("Sort by", selection: $sortField) {
                    ForEach(SortField.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(16)

                HStack(spacing: 0) {
                    Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading)
                    Text("GP").frame(width: 34, alignment: .trailing)
                    Text("GS").frame(width: 34, alignment: .trailing)
                    Text("MIN").frame(width: 48, alignment: .trailing)
                    Text("G").frame(width: 32, alignment: .trailing)
                    Text("A").frame(width: 32, alignment: .trailing)
                    Text("PTS").frame(width: 40, alignment: .trailing)
                    Text("SH").frame(width: 38, alignment: .trailing)
                    Text("SOG").frame(width: 42, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

                ForEach(sortedPlayers(season)) { stats in
                    Divider()
                    Button {
                        appModel.navigation.open(.player(stats.playerID))
                    } label: {
                        HStack(spacing: 0) {
                            Text(roster[stats.playerID]?.shortLabel ?? "—")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(stats.matchesPlayed)").frame(width: 34, alignment: .trailing)
                            Text("\(stats.starts)").frame(width: 34, alignment: .trailing)
                            Text("\(stats.minutesPlayed)").frame(width: 48, alignment: .trailing)
                            StatValueText(stats.value(.goals, \.goals)).frame(width: 32, alignment: .trailing)
                            StatValueText(stats.value(.assists, \.assists)).frame(width: 32, alignment: .trailing)
                            StatValueText(stats.value(.goals, \.points)).frame(width: 40, alignment: .trailing)
                            StatValueText(stats.value(.shots, \.shots)).frame(width: 38, alignment: .trailing)
                            StatValueText(stats.value(.shots, \.shotsOnGoal)).frame(width: 42, alignment: .trailing)
                        }
                        .font(.subheadline)
                        .monospacedDigit()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func sortedPlayers(_ season: SeasonStats) -> [SeasonPlayerStats] {
        let players = Array(season.players.values)
        switch sortField {
        case .points: return players.sorted { $0.points > $1.points }
        case .goals: return players.sorted { $0.totals.goals > $1.totals.goals }
        case .assists: return players.sorted { $0.totals.assists > $1.totals.assists }
        case .minutes: return players.sorted { $0.secondsPlayed > $1.secondsPlayed }
        }
    }

    private func keeperTable(_ season: SeasonStats) -> some View {
        SectionBox(title: "Goalkeeping") {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("GOALKEEPER").frame(maxWidth: .infinity, alignment: .leading)
                    Text("GP").frame(width: 34, alignment: .trailing)
                    Text("MIN").frame(width: 52, alignment: .trailing)
                    Text("SV").frame(width: 38, alignment: .trailing)
                    Text("GA").frame(width: 38, alignment: .trailing)
                    Text("SV%").frame(width: 56, alignment: .trailing)
                    Text("GAA").frame(width: 52, alignment: .trailing)
                    Text("SHO").frame(width: 42, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ForEach(season.sortedKeepers) { keeper in
                    Divider()
                    HStack(spacing: 0) {
                        Text(roster[keeper.playerID]?.shortLabel ?? "—")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(keeper.matchesPlayed)").frame(width: 34, alignment: .trailing)
                        Text("\(keeper.minutesPlayed)").frame(width: 52, alignment: .trailing)
                        Text("\(keeper.totals.saves)").frame(width: 38, alignment: .trailing)
                        Text("\(keeper.totals.goalsAllowed)").frame(width: 38, alignment: .trailing)
                        StatValueText(keeper.savePercentage, style: .percent).frame(width: 56, alignment: .trailing)
                        StatValueText(keeper.goalsAgainstAverage, style: .decimal).frame(width: 52, alignment: .trailing)
                        Text("\(keeper.totals.shutouts)").frame(width: 42, alignment: .trailing)
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func completenessSection(_ season: SeasonStats) -> some View {
        SectionBox(title: "What This Season Tracked") {
            VStack(alignment: .leading, spacing: 8) {
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
                Text(
                    "Totals only include matches that were tracking a category. A category no match tracked stays unknown rather than being reported as zero."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .padding(16)
        }
    }
}
