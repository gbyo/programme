import Charts
import Foundation
import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import ProgrammeUI
import SwiftUI

/// Season statistics: a record book, not a dashboard.
/// Tab label is "Stats"; the screen title stays "Season Stats".
/// `teamID` scopes the data; `seasonID` is the viewed season (temporary UI
/// state — viewing an old season never changes the team's current season).
struct SeasonStatsView: View {
    let teamID: TeamID
    let seasonID: SeasonID?

    @Environment(AppModel.self) private var appModel
    @State private var season: SeasonStats?
    @State private var roster: RosterSnapshot = .empty
    @State private var isExporting = false
    @State private var isPreparingExport = false
    @State private var exportPayload: ExportPayload?
    @State private var preparedExportKey: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var seasons: [SeasonIdentity] = []
    @State private var teamDetails: TeamDetails?

    private var viewedSeasonID: SeasonID? {
        seasonID ?? appModel.workspace.viewedStatsSeasonID
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
        .teamWorkspaceTitle("Season Stats")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu("Season", systemImage: "calendar") {
                    ForEach(seasons) { season in
                        Button {
                            Task { await selectSeason(season.id) }
                        } label: {
                            if season.id == viewedSeasonID {
                                Label(
                                    season.isCurrent ? "\(season.name) (Current)" : season.name,
                                    systemImage: "checkmark")
                            } else {
                                Text(season.isCurrent ? "\(season.name) (Current)" : season.name)
                            }
                        }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if isPreparingExport {
                    ProgressView()
                        .accessibilityLabel("Preparing export")
                } else {
                    Button("Export", systemImage: "square.and.arrow.up") {
                        exportTask?.cancel()
                        exportTask = Task { await prepareAndPresentExport() }
                    }
                    .disabled(season?.matchesPlayed ?? 0 == 0)
                }
            }
        }
        .sheet(isPresented: $isExporting) {
            if let exportPayload {
                NavigationStack {
                    ExportSheet(
                        payload: exportPayload,
                        exporters: ProgrammeExporters.forSeason())
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .task(
            id: [
                teamID.rawValue.uuidString, viewedSeasonID?.rawValue.uuidString ?? "current",
                "\(appModel.storeRevision)",
            ]
        ) {
            await load()
        }
    }

    private func selectSeason(_ id: SeasonID) async {
        // Viewed season only; never marks the season current.
        appModel.workspace.viewedStatsSeasonID = id
        await load()
    }

    private func load() async {
        guard let store = appModel.store else { return }
        // A season change cancels any in-flight export preparation and drops
        // the prepared payload; export contexts are rebuilt on demand only.
        exportTask?.cancel()
        exportTask = nil
        exportPayload = nil
        preparedExportKey = nil
        seasons = (try? await store.seasonIdentities(teamID: teamID)) ?? []
        teamDetails = try? await store.teamDetails(teamID: teamID)
        let summaries =
            (try? await store.seasonSummaries(teamID: teamID, seasonID: viewedSeasonID)) ?? []
        season = SeasonEngine.aggregate(summaries)
        roster = (try? await store.roster(teamID: teamID, includeFormer: true)) ?? .empty
    }

    /// Builds the season export payload on demand and presents the sheet.
    /// A cached payload is reused while the team, season, and store revision
    /// are unchanged; preparation cooperatively cancels on season changes.
    private func prepareAndPresentExport() async {
        guard let store = appModel.store, let seasonID = viewedSeasonID else { return }
        let key = [
            teamID.rawValue.uuidString, seasonID.rawValue.uuidString, "\(appModel.storeRevision)",
        ].joined(separator: "#")
        if preparedExportKey == key, exportPayload != nil {
            isExporting = true
            return
        }
        isPreparingExport = true
        defer { isPreparingExport = false }
        let items = (try? await store.matches(teamID: teamID, seasonID: seasonID)) ?? []
        var loaded: [MatchContext] = []
        for item in items where item.phase == .finalized {
            if Task.isCancelled { return }
            if let context = try? await store.context(for: item.id) { loaded.append(context) }
        }
        if Task.isCancelled { return }
        loaded.sort { $0.descriptor.kickoff < $1.descriptor.kickoff }
        exportPayload = ExportPayload(
            teamName: teamDetails?.name ?? "",
            teamShortName: teamDetails?.shortName,
            seasonName: seasons.first { $0.id == seasonID }?.name,
            contexts: loaded)
        preparedExportKey = key
        isExporting = true
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

                NavigationLink {
                    SeasonAdditionalStatsTableView(season: season, roster: roster)
                } label: {
                    statisticsLink(
                        title: "Additional Statistics",
                        detail: "Corners, steals, fouls, offsides, cards and penalty kicks",
                        symbol: "tablecells")
                }

                if !season.sortedKeepers.isEmpty {
                    NavigationLink {
                        SeasonKeepersTableView(season: season, roster: roster)
                    } label: {
                        statisticsLink(
                            title: "Goalkeeping",
                            detail: "\(season.sortedKeepers.count) keepers · MIN, SV, GA, PK, SV%, GAA, SHO",
                            symbol: "hand.raised")
                    }
                }
            }

            completenessSection(season)
        }
        .listStyle(.insetGrouped)
    }

    private func header(_ season: SeasonStats) -> some View {
        // Team identity lives in the workspace switcher (sidebar, top bar, or
        // navigation title); this section carries only season information.
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(season.recordText)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("Record")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    var goals: Int? { stats.value(.goals, \.goals).countValue }
    var assists: Int? { stats.value(.assists, \.assists).countValue }
    var points: Int? { stats.value(.goals, \.points).countValue }
    var shots: Int? { stats.value(.shots, \.shots).countValue }
    var shotsOnGoal: Int? { stats.value(.shots, \.shotsOnGoal).countValue }
    var corners: Int? { stats.value(.corners, \.corners).countValue }
    var steals: Int? { stats.value(.steals, \.steals).countValue }
    var fouls: Int? { stats.value(.fouls, \.fouls).countValue }
    var offsides: Int? { stats.value(.offsides, \.offsides).countValue }
    var yellowCards: Int? { stats.value(.cards, \.yellowCards).countValue }
    var redCards: Int? { stats.value(.cards, \.redCards).countValue }
    var penaltyGoals: Int? { stats.value(.penaltyKicks, \.penaltyGoals).countValue }
    var penaltyAttempts: Int? { stats.value(.penaltyKicks, \.penaltyAttempts).countValue }
}

/// Sorts the table without collapsing Programme's tracked/untracked distinction.
///
/// Unknown or not-applicable statistics always remain after real values in both
/// sort directions. A tracked zero therefore never becomes equivalent to a
/// category the match set did not record.
private struct SeasonPlayerSortComparator: SortComparator {
    enum Field: String, CaseIterable, Identifiable, Sendable {
        case name
        case gamesPlayed
        case starts
        case minutes
        case goals
        case assists
        case points
        case shots
        case shotsOnGoal
        case corners
        case steals
        case fouls
        case offsides
        case yellowCards
        case redCards
        case penaltyGoals
        case penaltyAttempts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: "Player"
            case .gamesPlayed: "Games Played"
            case .starts: "Starts"
            case .minutes: "Minutes"
            case .goals: "Goals"
            case .assists: "Assists"
            case .points: "Points"
            case .shots: "Shots"
            case .shotsOnGoal: "Shots on Goal"
            case .corners: "Corners"
            case .steals: "Steals"
            case .fouls: "Fouls"
            case .offsides: "Offsides"
            case .yellowCards: "Yellow Cards"
            case .redCards: "Red Cards"
            case .penaltyGoals: "Penalty Goals"
            case .penaltyAttempts: "Penalty Attempts"
            }
        }

        static let compactChoices: [Self] = [.points, .goals, .assists, .minutes]
        static let additionalChoices: [Self] = [
            .corners, .steals, .fouls, .offsides, .yellowCards, .redCards,
            .penaltyGoals, .penaltyAttempts,
        ]
    }

    typealias Compared = SeasonPlayerTableRow

    var field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: SeasonPlayerTableRow, _ rhs: SeasonPlayerTableRow) -> ComparisonResult {
        switch field {
        case .name:
            return applyOrder(lhs.name.localizedStandardCompare(rhs.name))
        case .gamesPlayed:
            return compareKnown(lhs.gamesPlayed, rhs.gamesPlayed)
        case .starts:
            return compareKnown(lhs.starts, rhs.starts)
        case .minutes:
            return compareKnown(lhs.minutes, rhs.minutes)
        case .goals:
            return compareOptional(lhs.goals, rhs.goals)
        case .assists:
            return compareOptional(lhs.assists, rhs.assists)
        case .points:
            return compareOptional(lhs.points, rhs.points)
        case .shots:
            return compareOptional(lhs.shots, rhs.shots)
        case .shotsOnGoal:
            return compareOptional(lhs.shotsOnGoal, rhs.shotsOnGoal)
        case .corners:
            return compareOptional(lhs.corners, rhs.corners)
        case .steals:
            return compareOptional(lhs.steals, rhs.steals)
        case .fouls:
            return compareOptional(lhs.fouls, rhs.fouls)
        case .offsides:
            return compareOptional(lhs.offsides, rhs.offsides)
        case .yellowCards:
            return compareOptional(lhs.yellowCards, rhs.yellowCards)
        case .redCards:
            return compareOptional(lhs.redCards, rhs.redCards)
        case .penaltyGoals:
            return compareOptional(lhs.penaltyGoals, rhs.penaltyGoals)
        case .penaltyAttempts:
            return compareOptional(lhs.penaltyAttempts, rhs.penaltyAttempts)
        }
    }

    private func compareKnown<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        let result: ComparisonResult =
            if lhs < rhs {
                .orderedAscending
            } else if lhs > rhs {
                .orderedDescending
            } else {
                .orderedSame
            }
        return applyOrder(result)
    }

    private func compareOptional(_ lhs: Int?, _ rhs: Int?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, .some):
            return .orderedDescending
        case (.some, nil):
            return .orderedAscending
        case (.some(let lhs), .some(let rhs)):
            return compareKnown(lhs, rhs)
        }
    }

    private func applyOrder(_ result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedSame: return .orderedSame
        case .orderedDescending: return .orderedAscending
        }
    }
}

private struct SeasonPlayersTableView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var rows: [SeasonPlayerTableRow]
    @State private var selection: PlayerID?
    @State private var sortOrder = [
        SeasonPlayerSortComparator(field: .points, order: .reverse)
    ]
    @State private var compactSortField = SeasonPlayerSortComparator.Field.points

    init(season: SeasonStats, roster: RosterSnapshot) {
        let rows = season.players.values.map {
            SeasonPlayerTableRow(stats: $0, player: roster[$0.playerID])
        }
        let initialOrder = [
            SeasonPlayerSortComparator(field: .points, order: .reverse),
            SeasonPlayerSortComparator(field: .name),
        ]
        _rows = State(initialValue: rows.sorted(using: initialOrder))
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Player", sortUsing: SeasonPlayerSortComparator(field: .name)) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.body.weight(.medium))
                    if horizontalSizeClass == .compact {
                        Text("\(row.gamesPlayed) GP · \(row.starts) GS · \(row.minutes) MIN")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(compactProduction(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("GP", sortUsing: SeasonPlayerSortComparator(field: .gamesPlayed)) {
                Text("\($0.gamesPlayed)").monospacedDigit()
            }
            TableColumn("GS", sortUsing: SeasonPlayerSortComparator(field: .starts)) {
                Text("\($0.starts)").monospacedDigit()
            }
            TableColumn("MIN", sortUsing: SeasonPlayerSortComparator(field: .minutes)) {
                Text("\($0.minutes)").monospacedDigit()
            }
            TableColumn("G", sortUsing: SeasonPlayerSortComparator(field: .goals)) {
                StatValueText($0.stats.value(.goals, \.goals))
            }
            TableColumn("A", sortUsing: SeasonPlayerSortComparator(field: .assists)) {
                StatValueText($0.stats.value(.assists, \.assists))
            }
            TableColumn("PTS", sortUsing: SeasonPlayerSortComparator(field: .points)) {
                StatValueText($0.stats.value(.goals, \.points))
            }
            TableColumn("SH", sortUsing: SeasonPlayerSortComparator(field: .shots)) {
                StatValueText($0.stats.value(.shots, \.shots))
            }
            TableColumn("SOG", sortUsing: SeasonPlayerSortComparator(field: .shotsOnGoal)) {
                StatValueText($0.stats.value(.shots, \.shotsOnGoal))
            }
        }
        .onChange(of: sortOrder) { _, order in
            sortRows(using: order)
        }
        .onChange(of: compactSortField) { _, field in
            guard horizontalSizeClass == .compact else { return }
            sortOrder = [SeasonPlayerSortComparator(field: field, order: .reverse)]
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            guard sizeClass == .compact else { return }
            let current = sortOrder.first?.field
            compactSortField =
                SeasonPlayerSortComparator.Field.compactChoices.contains(current ?? .points)
                ? (current ?? .points)
                : .points
            sortOrder = [
                SeasonPlayerSortComparator(field: compactSortField, order: .reverse)
            ]
        }
        .navigationTitle("Player Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selection) { PlayerDetailView(playerID: $0) }
        .toolbar {
            if horizontalSizeClass == .compact {
                ToolbarItem(placement: .secondaryAction) {
                    Picker("Sort", selection: $compactSortField) {
                        ForEach(SeasonPlayerSortComparator.Field.compactChoices) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private func sortRows(using order: [SeasonPlayerSortComparator]) {
        var effectiveOrder =
            order.isEmpty
            ? [SeasonPlayerSortComparator(field: .points, order: .reverse)]
            : order
        if effectiveOrder.first?.field != .name {
            effectiveOrder.append(SeasonPlayerSortComparator(field: .name))
        }
        rows.sort(using: effectiveOrder)
    }

    private func compactProduction(_ row: SeasonPlayerTableRow) -> String {
        let stats = row.stats
        return
            "\(stats.value(.goals, \.goals).text()) G · \(stats.value(.assists, \.assists).text()) A · \(stats.value(.goals, \.points).text()) PTS · \(stats.value(.shots, \.shots).text()) SH · \(stats.value(.shots, \.shotsOnGoal).text()) SOG"
    }
}

private struct SeasonAdditionalStatsTableView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var rows: [SeasonPlayerTableRow]
    @State private var selection: PlayerID?
    @State private var sortOrder = [
        SeasonPlayerSortComparator(field: .corners, order: .reverse)
    ]
    @State private var compactSortField = SeasonPlayerSortComparator.Field.corners

    init(season: SeasonStats, roster: RosterSnapshot) {
        let rows = season.players.values.map {
            SeasonPlayerTableRow(stats: $0, player: roster[$0.playerID])
        }
        let initialOrder = [
            SeasonPlayerSortComparator(field: .corners, order: .reverse),
            SeasonPlayerSortComparator(field: .name),
        ]
        _rows = State(initialValue: rows.sorted(using: initialOrder))
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Player", sortUsing: SeasonPlayerSortComparator(field: .name)) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.body.weight(.medium))
                    if horizontalSizeClass == .compact {
                        Text(compactSummary(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("CK", sortUsing: SeasonPlayerSortComparator(field: .corners)) {
                StatValueText($0.stats.value(.corners, \.corners))
            }
            TableColumn("ST", sortUsing: SeasonPlayerSortComparator(field: .steals)) {
                StatValueText($0.stats.value(.steals, \.steals))
            }
            TableColumn("F", sortUsing: SeasonPlayerSortComparator(field: .fouls)) {
                StatValueText($0.stats.value(.fouls, \.fouls))
            }
            TableColumn("OFF", sortUsing: SeasonPlayerSortComparator(field: .offsides)) {
                StatValueText($0.stats.value(.offsides, \.offsides))
            }
            TableColumn("YC", sortUsing: SeasonPlayerSortComparator(field: .yellowCards)) {
                StatValueText($0.stats.value(.cards, \.yellowCards))
            }
            TableColumn("RC", sortUsing: SeasonPlayerSortComparator(field: .redCards)) {
                StatValueText($0.stats.value(.cards, \.redCards))
            }
            TableColumn("PKG", sortUsing: SeasonPlayerSortComparator(field: .penaltyGoals)) {
                StatValueText($0.stats.value(.penaltyKicks, \.penaltyGoals))
            }
            TableColumn("PKA", sortUsing: SeasonPlayerSortComparator(field: .penaltyAttempts)) {
                StatValueText($0.stats.value(.penaltyKicks, \.penaltyAttempts))
            }
        }
        .onChange(of: sortOrder) { _, order in
            var effective = order.isEmpty
                ? [SeasonPlayerSortComparator(field: .corners, order: .reverse)]
                : order
            if effective.first?.field != .name {
                effective.append(SeasonPlayerSortComparator(field: .name))
            }
            rows.sort(using: effective)
        }
        .onChange(of: compactSortField) { _, field in
            guard horizontalSizeClass == .compact else { return }
            sortOrder = [SeasonPlayerSortComparator(field: field, order: .reverse)]
        }
        .navigationTitle("Additional Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selection) { PlayerDetailView(playerID: $0) }
        .toolbar {
            if horizontalSizeClass == .compact {
                ToolbarItem(placement: .secondaryAction) {
                    Picker("Sort", selection: $compactSortField) {
                        ForEach(SeasonPlayerSortComparator.Field.additionalChoices) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private func compactSummary(_ row: SeasonPlayerTableRow) -> String {
        let stats = row.stats
        return [
            "\(stats.value(.corners, \.corners).text()) CK",
            "\(stats.value(.steals, \.steals).text()) ST",
            "\(stats.value(.fouls, \.fouls).text()) F",
            "\(stats.value(.offsides, \.offsides).text()) OFF",
            "\(stats.value(.cards, \.yellowCards).text()) YC",
            "\(stats.value(.cards, \.redCards).text()) RC",
            "\(stats.value(.penaltyKicks, \.penaltyGoals).text()) PKG",
            "\(stats.value(.penaltyKicks, \.penaltyAttempts).text()) PKA",
        ].joined(separator: " · ")
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
                    Text(roster[keeper.playerID]?.shortLabel ?? "—")
                        .font(.body.weight(.medium))
                    if horizontalSizeClass == .compact {
                        Text(
                            "\(keeper.matchesPlayed) GP · \(keeper.minutesPlayed) MIN · \(keeper.totals.saves) SV · \(keeper.totals.goalsAllowed) GA"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(
                            "\(penaltyValue(keeper.totals.penaltySaves).text())/\(penaltyValue(keeper.totals.penaltiesFaced).text()) PK · \(keeper.savePercentage.text()) SV% · \(keeper.goalsAgainstAverage.text()) GAA · \(keeper.totals.shutouts) SHO"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("GP") { Text("\($0.matchesPlayed)").monospacedDigit() }
            TableColumn("MIN") { Text("\($0.minutesPlayed)").monospacedDigit() }
            TableColumn("SV") { Text("\($0.totals.saves)").monospacedDigit() }
            TableColumn("GA") { Text("\($0.totals.goalsAllowed)").monospacedDigit() }
            TableColumn("PKF") { StatValueText(penaltyValue($0.totals.penaltiesFaced)) }
            TableColumn("PKSV") { StatValueText(penaltyValue($0.totals.penaltySaves)) }
            TableColumn("SV%") { StatValueText($0.savePercentage, style: .percent) }
            TableColumn("GAA") { StatValueText($0.goalsAgainstAverage, style: .decimal) }
            TableColumn("SHO") { Text("\($0.totals.shutouts)").monospacedDigit() }
        }
        .navigationTitle("Goalkeeping")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selection) { PlayerDetailView(playerID: $0) }
    }

    private func penaltyValue(_ value: Int) -> StatValue {
        (season.trackedMatches[.penaltyKicks] ?? 0) > 0 ? .count(value) : .notTracked
    }
}
