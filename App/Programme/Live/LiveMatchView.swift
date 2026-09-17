import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// Programme's scoring workspace.
///
/// Everything a scorer needs during play is reachable without leaving this view:
/// the score, the clock, the active lineup, the action palette, the last event
/// and undo. Event entry happens in the centre panel rather than in a sheet, so
/// the score and clock never disappear behind a modal.
struct LiveMatchView: View {
    let session: LiveMatchSession

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: LiveStage = .pitch
    @State private var isShowingInspector = false
    /// One sheet at a time. Programme never stacks them, and routing every
    /// presentation through a single item makes a transition between two of them
    /// a content swap rather than a dismiss-and-present race.
    @State private var activeSheet: LiveSheet?
    @State private var compactPane: CompactPane = .palette

    enum LiveSheet: Identifiable, Equatable {
        case eventLog
        case review
        case options
        case more
        case lineup
        case periodBreak
        case finalize
        case shootout
        case editEvent(EventID)

        var id: String {
            switch self {
            case .eventLog: "log"
            case .review: "review"
            case .options: "options"
            case .more: "more"
            case .lineup: "lineup"
            case .periodBreak: "break"
            case .finalize: "finalize"
            case .shootout: "shootout"
            case .editEvent(let id): "edit-\(id)"
            }
        }
    }

    private enum CompactPane: String, CaseIterable, Identifiable {
        case palette = "Record"
        case lineup = "Lineup"
        var id: String { rawValue }
    }

    private enum LayoutMode {
        case wide
        case medium
        case compact
    }

    var body: some View {
        GeometryReader { proxy in
            let mode = layoutMode(for: proxy.size.width)
            VStack(spacing: 0) {
                LiveHeader(
                    session: session,
                    isCompact: mode == .compact,
                    onMenu: { activeSheet = .options },
                    onToggleClock: { session.toggleClock() },
                    onEndPeriod: { endPeriod() },
                    onStartPeriod: { startPeriod() }
                )

                content(mode: mode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ScoringBar(
                    session: session,
                    onEdit: { editLastEvent() },
                    onLog: { activeSheet = .eventLog },
                    onReview: { activeSheet = .review }
                )
            }
        }
        .background(Color(.systemBackground))
        .inspector(isPresented: $isShowingInspector) {
            MatchStatsInspector(session: session)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .periodBreak, .awaitingFinalization:
                activeSheet = .periodBreak
            case .inPeriod:
                // Undoing the end of a period puts the scorer straight back into
                // the match rather than leaving the break sheet stranded.
                if activeSheet == .periodBreak { activeSheet = nil }
            default:
                break
            }
        }
        .onAppear {
            if !session.hasStartingLineup { activeSheet = .lineup }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: LiveSheet) -> some View {
        switch sheet {
        case .eventLog:
            NavigationStack {
                EventLogView(session: session) { event in
                    activeSheet = .editEvent(event.id)
                }
            }

        case .review:
            NavigationStack { ReviewView(session: session, stage: $stage) }

        case .options:
            NavigationStack {
                MatchOptionsSheet(
                    session: session,
                    onEditLineup: { activeSheet = .lineup },
                    onShootout: { activeSheet = .shootout },
                    onFinalize: { activeSheet = .finalize },
                    onClose: {
                        activeSheet = nil
                        Task { await appModel.closeLiveSession() }
                    },
                    onShowStats: {
                        activeSheet = nil
                        isShowingInspector = true
                    }
                )
            }

        case .more:
            NavigationStack {
                MoreActionsSheet(session: session) { action in
                    activeSheet = nil
                    begin(action)
                }
            }

        case .lineup:
            NavigationStack { LineupEditorView(session: session) }

        case .periodBreak:
            NavigationStack {
                PeriodBreakView(
                    session: session,
                    onReview: { activeSheet = .review },
                    onContinue: {
                        activeSheet = nil
                        startPeriod()
                    },
                    onShootout: { activeSheet = .shootout },
                    onFinalize: { activeSheet = .finalize })
            }

        case .shootout:
            NavigationStack { ShootoutView(session: session) }

        case .finalize:
            NavigationStack {
                FinalizeView(session: session) {
                    activeSheet = nil
                    Task { await appModel.closeLiveSession() }
                }
            }

        case .editEvent(let id):
            if let event = session.context.events.first(where: { $0.id == id }) {
                NavigationStack { EventEditView(session: session, event: event) }
            }
        }
    }

    // MARK: - Layout

    private func layoutMode(for width: CGFloat) -> LayoutMode {
        if width >= 960 { return .wide }
        if width >= 680 { return .medium }
        return .compact
    }

    @ViewBuilder
    private func content(mode: LayoutMode) -> some View {
        switch mode {
        case .wide:
            HStack(spacing: 0) {
                LineupColumn(session: session, onSelect: select(player:), onSubstitute: beginSubstitution)
                    .frame(width: 250)
                Divider()
                stageView
                    .frame(maxWidth: .infinity)
                Divider()
                paletteScroll
                    .frame(width: 330)
            }

        case .medium:
            HStack(spacing: 0) {
                if stage.isPitch {
                    LineupColumn(session: session, onSelect: select(player:), onSubstitute: beginSubstitution)
                        .frame(maxWidth: .infinity)
                } else {
                    stageView
                        .frame(maxWidth: .infinity)
                }
                Divider()
                paletteScroll
                    .frame(width: 340)
            }

        case .compact:
            VStack(spacing: 0) {
                if stage.isPitch {
                    Picker("View", selection: $compactPane) {
                        ForEach(CompactPane.allCases) { pane in
                            Text(pane.rawValue).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    switch compactPane {
                    case .palette: paletteScroll
                    case .lineup:
                        LineupColumn(
                            session: session, onSelect: select(player:), onSubstitute: beginSubstitution)
                    }
                } else {
                    stageView
                }
            }
        }
    }

    private var paletteScroll: some View {
        ScrollView {
            EventPalette(
                session: session,
                isCompact: false,
                onAction: handle(action:),
                onOpponentAction: handleOpponent(_:),
                onMore: { activeSheet = .more }
            )
            .padding(14)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var stageView: some View {
        ZStack {
            switch stage {
            case .pitch:
                PitchPanel(session: session, onOpenStats: { isShowingInspector.toggle() })

            case .choosePlayer(let prompt):
                PlayerPickerStage(
                    title: prompt.title,
                    players: players(for: prompt),
                    goalkeeperID: prompt.side == .us ? session.snapshot.activeGoalkeeper : nil,
                    allowsUnknown: prompt.action.allowsUnknown,
                    unknownTitle: prompt.side == .us
                        ? "Player Unknown" : "\(session.descriptor.opponentShortName) — No Player",
                    unknownSubtitle: prompt.side == .us
                        ? "Record now, attribute later" : "Count it for the team only",
                    onPick: { complete(prompt.action, side: prompt.side, with: $0) },
                    onCancel: { stage = .pitch }
                )

            case .chooseAssist(let shot):
                AssistPickerStage(
                    scorerName: session.context.roster(for: shot.side).label(for: shot.shooter),
                    players: assistCandidates(for: shot.side)
                        .filter { $0.id != shot.shooter.playerID },
                    onPick: { assist in
                        var shot = shot
                        shot.assist = assist
                        finish(shot: shot)
                    },
                    onCancel: { stage = .pitch }
                )

            case .penaltyOutcome(let taker):
                PenaltyOutcomeStage(
                    takerName: session.context.roster.label(for: taker),
                    onPick: { outcome in
                        let shot = ShotEvent(
                            side: .us, shooter: taker, outcome: outcome, phase: .penaltyKick)
                        if outcome.isGoal && session.profile.prompts.assistOnGoal {
                            // A penalty is never assisted.
                            finish(shot: shot)
                        } else {
                            finish(shot: shot)
                        }
                    },
                    onCancel: { stage = .pitch }
                )

            case .placeShotLocation(let shot):
                ShotLocationStage(
                    shot: shot,
                    shooterName: session.context.roster.label(for: shot.shooter),
                    markers: session.shotMarkers,
                    onCommit: { location in
                        var shot = shot
                        shot.location = location
                        record(shot: shot)
                    }
                )

            case .substitution:
                SubstitutionStage(
                    session: session,
                    onCommit: { out, incoming, keeper in
                        session.substitute(out: out, in: incoming, goalkeeperAfter: keeper)
                        stage = .pitch
                    },
                    onCancel: { stage = .pitch }
                )
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: stage)
    }

    // MARK: - Interaction

    private func select(player: PlayerSnapshot) {
        Haptics.selectionChanged()
        if session.armedPlayer == player.id {
            session.armedPlayer = nil
        } else {
            session.armedPlayer = player.id
        }
    }

    private func handle(action: PaletteAction) {
        switch action.id {
        case "save":
            session.recordSave()
            session.armedPlayer = nil
        case "sub":
            beginSubstitution()
        default:
            guard let pending = action.pending else { return }
            begin(pending)
        }
    }

    private func handleOpponent(_ quick: OpponentQuickAction) {
        let action: PendingAction =
            switch quick {
            case .goal: .goal(.openPlay)
            case .shot: .shot(.offTarget)
            case .corner: .corner
            }

        // In `Both Teams` mode the opponent's players are attributed too, using
        // the same engine and the same picker. In `Our Team` mode these stay
        // single taps, which is the whole point of that mode.
        if session.descriptor.tracking == .bothTeams, !session.context.opponentRoster.players.isEmpty {
            stage = .choosePlayer(PlayerPrompt(action: action, side: .opponent))
        } else {
            complete(action, side: .opponent, with: .untracked)
        }
    }

    private func beginSubstitution() {
        session.armedPlayer = nil
        guard session.context.hasStarted else {
            session.show(
                notice: LiveNotice(text: "Substitutions start once the match kicks off.", kind: .warning))
            return
        }
        stage = .substitution
    }

    /// Both interaction directions land here: a player was already armed, or the
    /// action asks who it belongs to.
    private func begin(_ action: PendingAction) {
        guard session.context.hasStarted || isPreMatchAllowed(action) else {
            session.show(
                notice: LiveNotice(text: "The match hasn't kicked off yet.", kind: .warning))
            return
        }
        if let armed = session.armedPlayer {
            session.armedPlayer = nil
            complete(action, with: .player(armed))
        } else {
            stage = .choosePlayer(PlayerPrompt(action: action))
        }
    }

    private func isPreMatchAllowed(_ action: PendingAction) -> Bool { false }

    private func complete(_ action: PendingAction, side: TeamSide = .us, with ref: PlayerRef) {
        switch action {
        case .goal(.penaltyKick) where side == .us:
            stage = .penaltyOutcome(ref)

        case .goal(let phase):
            let shot = ShotEvent(side: side, shooter: ref, outcome: .goal, phase: phase)
            // An opponent goal in `Our Team` mode has nobody to credit an assist to.
            if session.profile.prompts.assistOnGoal, side == .us || !assistCandidates(for: side).isEmpty {
                stage = .chooseAssist(shot)
            } else {
                finish(shot: shot)
            }

        case .ownGoal:
            record(shot: ShotEvent(side: side, shooter: ref, outcome: .goal, isOwnGoal: true))

        case .shot(let outcome):
            finish(shot: ShotEvent(side: side, shooter: ref, outcome: outcome))

        case .corner:
            session.run(.recordCorner(side: side, player: ref))
            stage = .pitch

        case .steal:
            session.run(.recordSteal(side: side, player: ref))
            stage = .pitch

        case .foul:
            session.run(.recordFoul(side: side, player: ref))
            stage = .pitch

        case .offside:
            session.run(.recordOffside(side: side, player: ref))
            stage = .pitch

        case .card(let type):
            session.run(.recordCard(CardEvent(side: side, player: ref, card: type)))
            stage = .pitch

        case .goalkeeper:
            session.run(.changeGoalkeeper(side: side, goalkeeper: ref))
            stage = .pitch
        }
    }

    /// Who can be credited with an assist for a given side.
    private func assistCandidates(for side: TeamSide) -> [PlayerSnapshot] {
        side == .us ? session.onFieldPlayers : session.context.opponentRoster.sortedByNumber
    }

    /// Offer the optional shot map only when the match's profile asks for it.
    private func finish(shot: ShotEvent) {
        if session.profile.prompts.shotLocation && shot.location == nil {
            stage = .placeShotLocation(shot)
        } else {
            record(shot: shot)
        }
    }

    private func record(shot: ShotEvent) {
        session.run(.recordShot(shot), feedback: shot.outcome.isGoal ? .goal : .standard)
        stage = .pitch
    }

    private func players(for prompt: PlayerPrompt) -> [PlayerSnapshot] {
        guard prompt.side == .us else {
            // Programme does not track opponent lineups, so the whole opponent
            // roster is offered.
            return session.context.opponentRoster.sortedByNumber
        }
        return prompt.action.picksFromFullRoster ? session.roster.activeRoster : session.onFieldPlayers
    }

    private func startPeriod() {
        guard session.hasStartingLineup else {
            activeSheet = .lineup
            return
        }
        session.startNextPeriod()
    }

    private func endPeriod() {
        session.endCurrentPeriod()
    }

    private func editLastEvent() {
        guard let id = session.lastEventDescription?.id else { return }
        activeSheet = .editEvent(id)
    }
}

/// The default centre panel: the shot map, plus the small amount of context that
/// earns the space when no shots have locations yet.
struct PitchPanel: View {
    let session: LiveMatchSession
    var onOpenStats: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(session.clock.periodLongLabel.isEmpty ? "Match" : session.clock.periodLongLabel)
                    .programmeSectionHeader()
                Spacer()
                if let armed = session.armedPlayer, let player = session.roster[armed] {
                    Label("\(player.shortLabel) selected", systemImage: "hand.tap.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                }
                Button("Match Stats", systemImage: "chart.bar") { onOpenStats() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show match statistics")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if session.profile.tracks(.shotLocations) || !session.shotMarkers.isEmpty {
                PitchView(markers: session.shotMarkers)
                    .padding(.horizontal, 14)
            } else {
                LiveSummaryPanel(session: session)
            }

            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.armedPlayer)
    }
}

/// When the match is not tracking shot locations the centre is not left as
/// decoration: it carries the live team comparison instead.
struct LiveSummaryPanel: View {
    let session: LiveMatchSession

    var body: some View {
        VStack(spacing: 0) {
            comparisonRow(
                "Shots", session.profile.value(.shots, session.snapshot.team.us.shots),
                session.profile.value(.shots, session.snapshot.team.opponent.shots))
            Divider()
            comparisonRow(
                "Shots on Goal", session.profile.value(.shots, session.snapshot.team.us.shotsOnGoal),
                session.profile.value(.shots, session.snapshot.team.opponent.shotsOnGoal))
            Divider()
            comparisonRow(
                "Corners", session.profile.value(.corners, session.snapshot.team.us.corners),
                session.profile.value(.corners, session.snapshot.team.opponent.corners))
            Divider()
            comparisonRow(
                "Saves", session.profile.value(.goalkeeping, session.snapshot.team.us.saves),
                session.profile.value(.goalkeeping, session.snapshot.team.opponent.saves))
            Divider()
            comparisonRow(
                "Steals", session.profile.value(.steals, session.snapshot.team.us.steals),
                session.profile.value(.steals, session.snapshot.team.opponent.steals))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .frame(maxWidth: 560)
    }

    private func comparisonRow(_ label: String, _ us: StatValue, _ them: StatValue) -> some View {
        HStack {
            StatValueText(us)
                .font(.title3.weight(.semibold))
                .frame(width: 54, alignment: .leading)
            Spacer()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            StatValueText(them)
                .font(.title3.weight(.semibold))
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label). \(session.descriptor.teamShortName) \(us.accessibilityText), \(session.descriptor.opponentShortName) \(them.accessibilityText)"
        )
    }
}

/// Penalties have three real outcomes, and the scorer should not have to route
/// through the generic shot flow to record one.
struct PenaltyOutcomeStage: View {
    let takerName: String
    var onPick: (ShotOutcome) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Penalty kick")
                        .font(.title3.weight(.semibold))
                    Text(takerName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
            }

            VStack(spacing: 10) {
                outcomeButton("Scored", "soccerball.inverse", .goal, tint: .accentColor)
                outcomeButton("Saved", "hand.raised.fill", .saved, tint: .secondary)
                outcomeButton("Missed", "arrow.up.forward", .offTarget, tint: .secondary)
                outcomeButton("Post or Crossbar", "diamond", .woodwork, tint: .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func outcomeButton(_ title: String, _ symbol: String, _ outcome: ShotOutcome, tint: Color)
        -> some View
    {
        Button {
            onPick(outcome)
        } label: {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 66)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint == .accentColor ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        .background(
            tint == .accentColor
                ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color(.secondarySystemFill)),
            in: RoundedRectangle(cornerRadius: 14))
    }
}
