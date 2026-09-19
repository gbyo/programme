import MapKit
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
    @State private var isPresentingCalendar = false
    @State private var reminderMinutes: Int?
    @State private var reminderMessage: String?
    @State private var loadFailed = false
    @Environment(\.openURL) private var openURL

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
                    Button(
                        context.phase == .finalized ? "Reopen for Corrections" : "Score This Match",
                        systemImage: context.phase == .finalized ? "lock.open" : "play.fill"
                    ) {
                        Task { await appModel.openLiveSession(matchID: matchID) }
                    }
                }
                if #available(iOS 27.0, *) {
                    ToolbarOverflowMenu {
                        secondaryActions
                    }
                } else {
                    ToolbarItem(placement: .secondaryAction) {
                        Menu("More", systemImage: "ellipsis.circle") {
                            secondaryActions
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
                            teamName: context.descriptor.teamName,
                            teamShortName: context.descriptor.teamShortName,
                            contexts: [context]),
                        exporters: ProgrammeExporters.forMatch())
                }
            }
        }
        .sheet(isPresented: $isPresentingCalendar) {
            if let context {
                SystemCalendarEditor(
                    draft: CalendarEventDraft(descriptor: context.descriptor),
                    isPresented: $isPresentingCalendar
                )
                .ignoresSafeArea()
            }
        }
        .task(id: matchID) { await load() }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Button("Export…", systemImage: "square.and.arrow.up") { isExporting = true }
        NavigationLink(value: AppRoute.eventLog(matchID)) {
            Label("Event Log", systemImage: "list.bullet")
        }
    }

    private func load() async {
        guard let store = appModel.store else { return }
        do {
            let loaded = try await store.context(for: matchID)
            let derived = StatEngine.snapshot(context: loaded)
            context = loaded
            snapshot = derived
            issues = ValidationEngine.issues(context: loaded, snapshot: derived)
            reminderMinutes = try? await store.reminderMinutesBefore(for: matchID)
        } catch {
            loadFailed = true
        }
    }

    @ViewBuilder
    private func content(context: MatchContext, snapshot: MatchSnapshot) -> some View {
        List {
            Section {
                scoreHeader(context: context, snapshot: snapshot)
                    .padding(.vertical, 8)
            }

            if let location = context.descriptor.location {
                Section("Location") {
                    LabeledContent(location.name, value: location.address ?? "")
                    Button("Open in Maps", systemImage: "map") {
                        openInMaps(location)
                    }
                    .accessibilityIdentifier("matchDetail.openInMaps")
                }
            }

            if context.phase != .finalized {
                Section {
                    EmptyHint(
                        title: statusTitle(context.phase),
                        message: statusMessage(context.phase),
                        actionTitle: "Open Scorer"
                    ) {
                        Task { await appModel.openLiveSession(matchID: matchID) }
                    }
                    if context.phase == .scheduled {
                        Button("Add to Calendar…", systemImage: "calendar.badge.plus") {
                            isPresentingCalendar = true
                        }
                        .accessibilityIdentifier("matchDetail.addToCalendar")
                        Menu {
                            ForEach(MatchReminderOption.allCases) { option in
                                Button {
                                    Task { await chooseReminder(option, context: context) }
                                } label: {
                                    if reminderMinutes == option.minutesBefore {
                                        Label(option.label, systemImage: "checkmark")
                                    } else {
                                        Text(option.label)
                                    }
                                }
                            }
                        } label: {
                            Label("Remind Me", systemImage: "bell")
                        }
                        .accessibilityIdentifier("matchDetail.remindMe")
                        if let status = reminderStatus(context: context) {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !issues.needingReview.isEmpty {
                Section("Needs Attention") {
                    ForEach(issues.needingReview) { issue in
                        IssueRow(issue: issue)
                    }
                }
            }

            Section("Team") {
                TeamComparisonTable(context: context, snapshot: snapshot)
                    .padding(.vertical, 6)
            }

            Section("Box Score") {
                BoxScoreTable(context: context, snapshot: snapshot)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("section.Box Score")
            }

            if context.profile.tracks(.goalkeeping) {
                Section("Goalkeeping") {
                    KeeperTable(context: context, snapshot: snapshot)
                        .padding(.vertical, 6)
                }
            }

            if !shotMarkers(context).isEmpty {
                Section("Shot Map") {
                    PitchView(markers: shotMarkers(context))
                        .frame(height: 300)
                        .padding(.vertical, 6)
                }
            } else if context.profile.tracks(.shotLocations) {
                Section("Shot Map") {
                    EmptyHint(
                        title: "No shot locations recorded",
                        message: "Shots were counted, but none were placed on the pitch for this match.")
                }
            }

            Section("Timeline") {
                ForEach(MatchNarrator.describeAll(context: context).reversed()) { description in
                    EventLogRow(description: description)
                }
            }

            Section {
                ForEach(TrackedStat.allCases.sorted { $0.label < $1.label }) { stat in
                    CompletenessRow(stat: stat, state: snapshot.completeness(stat))
                }
            } header: {
                Text("Stat Completeness")
                    .accessibilityIdentifier("section.Stat Completeness")
            } footer: {
                Text("A dash in an export means the category was not tracked. It is unknown, not zero.")
            }

            if !revisions(context).isEmpty {
                Section("Revision History") {
                    ForEach(revisions(context), id: \.id) { revision in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(revision.summary).font(.subheadline)
                            Text(revision.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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

    /// Explicit Remind Me choice. Permission is requested here and only
    /// here; a denial or an already-past fire time schedules nothing and
    /// persists nothing, with a plain-language explanation instead.
    private func chooseReminder(_ option: MatchReminderOption, context: MatchContext) async {
        guard let store = appModel.store else { return }
        reminderMessage = nil
        guard let minutes = option.minutesBefore else {
            try? await store.setReminderMinutesBefore(nil, for: matchID)
            reminderMinutes = nil
            await appModel.reminderCenter.cancel(matchID: matchID)
            return
        }
        guard await appModel.reminderCenter.requestAuthorization() else {
            reminderMessage =
                "Notifications are off. Turn them on in Settings to use reminders — nothing was scheduled."
            return
        }
        let descriptor = context.descriptor
        guard
            MatchReminderRequest.fireDate(kickoff: descriptor.kickoff, minutesBefore: minutes) != nil
        else {
            reminderMessage = "That reminder time has already passed — nothing was scheduled."
            return
        }
        try? await store.setReminderMinutesBefore(minutes, for: matchID)
        reminderMinutes = minutes
        await appModel.reminderCenter.sync(
            matchID: matchID, kickoff: descriptor.kickoff, minutesBefore: minutes,
            title: MatchReminderRequest.title(descriptor: descriptor),
            body: MatchReminderRequest.body(descriptor: descriptor, minutesBefore: minutes))
    }

    private func reminderStatus(context: MatchContext) -> String? {
        if let reminderMessage { return reminderMessage }
        guard let minutes = reminderMinutes else { return nil }
        if MatchReminderRequest.fireDate(
            kickoff: context.descriptor.kickoff, minutesBefore: minutes) == nil
        {
            return "Reminder time has passed."
        }
        return
            "Reminds \(MatchReminderOption.option(minutesBefore: minutes).label.lowercased()) kickoff."
    }

    private func openInMaps(_ location: MatchLocation) {
        if let latitude = location.latitude, let longitude = location.longitude {
            let item = MKMapItem(
                location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
            item.name = location.name
            item.openInMaps()
        } else if let query = (location.address ?? location.name)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "https://maps.apple.com/?q=" + query)
        {
            openURL(url)
        }
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
        Grid(horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Text(context.descriptor.teamShortName)
                    .font(.caption.weight(.semibold))
                    .gridColumnAlignment(.trailing)
                Text("")
                    .frame(maxWidth: .infinity)
                Text(context.descriptor.opponentShortName)
                    .font(.caption.weight(.semibold))
                    .gridColumnAlignment(.trailing)
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
        GridRow {
            StatValueText(context.profile.value(stat, us))
                .font(.body.weight(.medium))
                .gridColumnAlignment(.trailing)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            StatValueText(context.profile.value(stat, them))
                .font(.body.weight(.medium))
                .gridColumnAlignment(.trailing)
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
        Grid(horizontalSpacing: 12, verticalSpacing: 0) {
            headerRow
            ForEach(players) { player in
                Divider().gridCellColumns(7)
                playerRow(player)
            }
        }
    }

    private var headerRow: some View {
        GridRow {
            Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading).gridColumnAlignment(.leading)
            Text("MIN").gridColumnAlignment(.trailing)
            Text("G").gridColumnAlignment(.trailing)
            Text("A").gridColumnAlignment(.trailing)
            Text("PTS").gridColumnAlignment(.trailing)
            Text("SH").gridColumnAlignment(.trailing)
            Text("SOG").gridColumnAlignment(.trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func playerRow(_ player: PlayerSnapshot) -> some View {
        let line = snapshot.player(player.id)
        return GridRow {
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

            Text("\(line.minutesPlayed)")
            StatValueText(context.profile.value(.goals, line.goals))
            StatValueText(context.profile.value(.assists, line.assists))
            StatValueText(context.profile.value(.goals, line.points))
            StatValueText(context.profile.value(.shots, line.shots))
            StatValueText(context.profile.value(.shots, line.shotsOnGoal))
        }
        .font(.subheadline)
        .monospacedDigit()
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
        Grid(horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Text("GOALKEEPER").frame(maxWidth: .infinity, alignment: .leading).gridColumnAlignment(.leading)
                Text("MIN").gridColumnAlignment(.trailing)
                Text("SOGA").gridColumnAlignment(.trailing)
                Text("SV").gridColumnAlignment(.trailing)
                Text("GA").gridColumnAlignment(.trailing)
                Text("SV%").gridColumnAlignment(.trailing)
                Text("GAA").gridColumnAlignment(.trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            ForEach(keepers, id: \.playerID) { keeper in
                Divider().gridCellColumns(7)
                GridRow {
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

                    Text("\(keeper.minutesPlayed)")
                    Text("\(keeper.shotsOnGoalFaced)")
                    Text("\(keeper.saves)")
                    Text("\(keeper.goalsAllowed)")
                    StatValueText(
                        keeper.savePercentage.map { StatValue.rate($0) } ?? .notApplicable, style: .percent
                    )
                    StatValueText(
                        keeper.goalsAgainstAverage(regulationSeconds: context.rules.regulationLength)
                            .map { StatValue.rate($0) } ?? .notApplicable, style: .decimal
                    )
                }
                .font(.subheadline)
                .monospacedDigit()
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
