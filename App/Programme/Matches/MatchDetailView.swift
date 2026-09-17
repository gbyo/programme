import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI

/// Everything about one match, once it is no longer being scored.
struct MatchDetailView: View {
    let matchID: MatchID

    @Environment(AppModel.self) private var appModel
    @State private var context: MatchContext?
    @State private var snapshot: MatchSnapshot?
    @State private var issues: [ValidationIssue] = []
    @State private var isExporting = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let context, let snapshot {
                content(context: context, snapshot: snapshot)
            } else if loadFailed {
                ContentUnavailableView(
                    "Match Not Available",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Programme couldn't load this match. Your other matches are unaffected."))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle(context?.descriptor.title ?? "Match")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let context {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Actions", systemImage: "ellipsis.circle") {
                        if context.phase != .finalized {
                            Button("Score This Match", systemImage: "play.fill") {
                                Task { await appModel.openLiveSession(matchID: matchID) }
                            }
                        } else {
                            Button("Reopen for Corrections", systemImage: "lock.open") {
                                Task { await appModel.openLiveSession(matchID: matchID) }
                            }
                        }
                        Button("Export…", systemImage: "square.and.arrow.up") { isExporting = true }
                        Button("Event Log", systemImage: "list.bullet") {
                            appModel.navigation.open(.eventLog(matchID))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isExporting) {
            if let context {
                NavigationStack {
                    ExportSheet(
                        payload: ExportPayload(
                            teamName: appModel.teamName, teamShortName: appModel.teamShortName,
                            contexts: [context]),
                        exporters: ProgrammeExporters.forMatch())
                }
            }
        }
        .task(id: matchID) { await load() }
    }

    private func load() async {
        guard let store = appModel.store else { return }
        do {
            let loaded = try await store.context(for: matchID)
            let derived = StatEngine.snapshot(context: loaded)
            context = loaded
            snapshot = derived
            issues = ValidationEngine.issues(context: loaded, snapshot: derived)
        } catch {
            loadFailed = true
        }
    }

    @ViewBuilder
    private func content(context: MatchContext, snapshot: MatchSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                scoreHeader(context: context, snapshot: snapshot)

                if context.phase != .finalized {
                    EmptyHint(
                        title: statusTitle(context.phase),
                        message: statusMessage(context.phase),
                        actionTitle: "Open Scorer"
                    ) {
                        Task { await appModel.openLiveSession(matchID: matchID) }
                    }
                    .background(
                        Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }

                if !issues.needingReview.isEmpty {
                    SectionBox(title: "Needs Attention") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(issues.needingReview) { issue in
                                IssueRow(issue: issue) {}
                            }
                        }
                        .padding(16)
                    }
                }

                SectionBox(title: "Team") {
                    TeamComparisonTable(context: context, snapshot: snapshot)
                        .padding(16)
                }

                SectionBox(title: "Box Score") {
                    BoxScoreTable(context: context, snapshot: snapshot)
                        .padding(.vertical, 6)
                }

                if context.profile.tracks(.goalkeeping) {
                    SectionBox(title: "Goalkeeping") {
                        KeeperTable(context: context, snapshot: snapshot)
                            .padding(.vertical, 6)
                    }
                }

                if !shotMarkers(context).isEmpty {
                    SectionBox(title: "Shot Map") {
                        PitchView(markers: shotMarkers(context))
                            .frame(height: 300)
                            .padding(14)
                    }
                } else if context.profile.tracks(.shotLocations) {
                    SectionBox(title: "Shot Map") {
                        EmptyHint(
                            title: "No shot locations recorded",
                            message: "Shots were counted, but none were placed on the pitch for this match.")
                    }
                }

                SectionBox(title: "Timeline") {
                    VStack(spacing: 0) {
                        ForEach(MatchNarrator.describeAll(context: context).reversed()) { description in
                            EventLogRow(description: description)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.vertical, 8)
                }

                SectionBox(title: "Stat Completeness") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(TrackedStat.allCases.sorted { $0.label < $1.label }) { stat in
                            CompletenessRow(stat: stat, state: snapshot.completeness(stat))
                        }
                        Text("A dash in an export means the category was not tracked. It is unknown, not zero.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(16)
                }

                if !revisions(context).isEmpty {
                    SectionBox(title: "Revision History") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(revisions(context), id: \.id) { revision in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(revision.summary).font(.subheadline)
                                    Text(revision.at.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func scoreHeader(context: MatchContext, snapshot: MatchSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(context.descriptor.teamShortName).font(.title2.weight(.semibold))
                Text("\(snapshot.score.us)–\(snapshot.score.opponent)")
                    .font(.programmeScore(42))
                Text(context.descriptor.opponentShortName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let result = snapshot.result {
                    Text(result.letter)
                        .font(.headline)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(result.tint.opacity(0.18), in: Capsule())
                }
            }
            Text(
                [
                    context.descriptor.kickoff.matchDayText,
                    context.descriptor.kickoff.matchTimeText,
                    context.descriptor.venue.label,
                    context.descriptor.competition,
                    context.rules.name,
                    context.profile.name,
                    context.startingFormation?.name,
                ].compactMap(\.self).joined(separator: " · ")
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusTitle(_ phase: MatchPhase) -> String {
        switch phase {
        case .scheduled: "Not started"
        case .inPeriod: "Match in progress"
        case .periodBreak: "Between periods"
        case .awaitingFinalization: "Awaiting finalization"
        case .finalized: "Final"
        }
    }

    private func statusMessage(_ phase: MatchPhase) -> String {
        switch phase {
        case .scheduled: "Confirm the starting lineup and kick off when you're ready."
        case .inPeriod, .periodBreak: "Everything recorded is saved. Resume when you're back at the field."
        case .awaitingFinalization: "Run the final check to publish statistics for this match."
        case .finalized: ""
        }
    }

    private func shotMarkers(_ context: MatchContext) -> [ShotMarker] {
        context.activeEvents.compactMap { event in
            guard case .shot(let shot) = event.payload, let location = shot.location else { return nil }
            return ShotMarker(
                id: event.id, point: location, outcome: shot.outcome, side: shot.side,
                label: MatchNarrator.describe(event, context: context).oneLine)
        }
    }

    private func revisions(_ context: MatchContext) -> [EventRevision] {
        context.events
            .flatMap(\.revisions)
            .filter { $0.kind != .created }
            .sorted { $0.at > $1.at }
    }
}

struct TeamComparisonTable: View {
    let context: MatchContext
    let snapshot: MatchSnapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(context.descriptor.teamShortName)
                    .font(.caption.weight(.semibold))
                    .frame(width: 60, alignment: .leading)
                Spacer()
                Text(context.descriptor.opponentShortName)
                    .font(.caption.weight(.semibold))
                    .frame(width: 60, alignment: .trailing)
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)

            row("Goals", .goals, snapshot.team.us.goals, snapshot.team.opponent.goals)
            row("Shots", .shots, snapshot.team.us.shots, snapshot.team.opponent.shots)
            row("Shots on Goal", .shots, snapshot.team.us.shotsOnGoal, snapshot.team.opponent.shotsOnGoal)
            row("Saves", .goalkeeping, snapshot.team.us.saves, snapshot.team.opponent.saves)
            row("Corners", .corners, snapshot.team.us.corners, snapshot.team.opponent.corners)
            row("Steals", .steals, snapshot.team.us.steals, snapshot.team.opponent.steals)
            row("Fouls", .fouls, snapshot.team.us.fouls, snapshot.team.opponent.fouls)
            row("Yellow Cards", .cards, snapshot.team.us.yellowCards, snapshot.team.opponent.yellowCards)
            row("Red Cards", .cards, snapshot.team.us.redCards, snapshot.team.opponent.redCards)
        }
    }

    private func row(_ label: String, _ stat: TrackedStat, _ us: Int, _ them: Int) -> some View {
        HStack {
            StatValueText(context.profile.value(stat, us))
                .font(.body.weight(.medium))
                .frame(width: 60, alignment: .leading)
            Spacer()
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            StatValueText(context.profile.value(stat, them))
                .font(.body.weight(.medium))
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label). \(context.descriptor.teamShortName) \(context.profile.value(stat, us).accessibilityText), \(context.descriptor.opponentShortName) \(context.profile.value(stat, them).accessibilityText)"
        )
    }
}

struct BoxScoreTable: View {
    let context: MatchContext
    let snapshot: MatchSnapshot

    private var players: [PlayerSnapshot] {
        context.roster.sortedByNumber.filter { snapshot.player($0.id).appeared }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            ForEach(players) { player in
                Divider()
                playerRow(player)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading)
            Text("MIN").frame(width: 44, alignment: .trailing)
            Text("G").frame(width: 34, alignment: .trailing)
            Text("A").frame(width: 34, alignment: .trailing)
            Text("PTS").frame(width: 40, alignment: .trailing)
            Text("SH").frame(width: 38, alignment: .trailing)
            Text("SOG").frame(width: 42, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func playerRow(_ player: PlayerSnapshot) -> some View {
        let line = snapshot.player(player.id)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(player.shortLabel).font(.subheadline)
                if line.started {
                    Text("GS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if line.gameWinningGoals > 0 {
                    Text("GWG")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(line.minutesPlayed)").frame(width: 44, alignment: .trailing)
            StatValueText(context.profile.value(.goals, line.goals)).frame(width: 34, alignment: .trailing)
            StatValueText(context.profile.value(.assists, line.assists)).frame(width: 34, alignment: .trailing)
            StatValueText(context.profile.value(.goals, line.points)).frame(width: 40, alignment: .trailing)
            StatValueText(context.profile.value(.shots, line.shots)).frame(width: 38, alignment: .trailing)
            StatValueText(context.profile.value(.shots, line.shotsOnGoal)).frame(width: 42, alignment: .trailing)
        }
        .font(.subheadline)
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct KeeperTable: View {
    let context: MatchContext
    let snapshot: MatchSnapshot

    private var keepers: [KeeperStatLine] {
        snapshot.keepers.values
            .filter { $0.side == .us && $0.secondsPlayed > 0 }
            .sorted { $0.secondsPlayed > $1.secondsPlayed }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("GOALKEEPER").frame(maxWidth: .infinity, alignment: .leading)
                Text("MIN").frame(width: 44, alignment: .trailing)
                Text("SOGA").frame(width: 50, alignment: .trailing)
                Text("SV").frame(width: 36, alignment: .trailing)
                Text("GA").frame(width: 36, alignment: .trailing)
                Text("SV%").frame(width: 56, alignment: .trailing)
                Text("GAA").frame(width: 52, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            ForEach(keepers, id: \.playerID) { keeper in
                Divider()
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text(context.roster[keeper.playerID]?.shortLabel ?? "Goalkeeper")
                            .font(.subheadline)
                        if keeper.shutouts > 0 {
                            Text("SHO").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                        } else if keeper.sharedShutouts > 0 {
                            Text("SHO (shared)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(keeper.minutesPlayed)").frame(width: 44, alignment: .trailing)
                    Text("\(keeper.shotsOnGoalFaced)").frame(width: 50, alignment: .trailing)
                    Text("\(keeper.saves)").frame(width: 36, alignment: .trailing)
                    Text("\(keeper.goalsAllowed)").frame(width: 36, alignment: .trailing)
                    StatValueText(
                        keeper.savePercentage.map { StatValue.rate($0) } ?? .notApplicable, style: .percent
                    )
                    .frame(width: 56, alignment: .trailing)
                    StatValueText(
                        keeper.goalsAgainstAverage(regulationSeconds: context.rules.regulationLength)
                            .map { StatValue.rate($0) } ?? .notApplicable, style: .decimal
                    )
                    .frame(width: 52, alignment: .trailing)
                }
                .font(.subheadline)
                .monospacedDigit()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The event log reached from a match rather than from the live scorer.
struct MatchEventLogScreen: View {
    let matchID: MatchID
    @Environment(AppModel.self) private var appModel
    @State private var context: MatchContext?

    var body: some View {
        Group {
            if let context {
                List {
                    ForEach(MatchNarrator.describeAll(context: context).reversed()) { description in
                        EventLogRow(description: description)
                    }
                }
                .listStyle(.plain)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Event Log")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            context = try? await appModel.store?.context(for: matchID)
        }
    }
}
