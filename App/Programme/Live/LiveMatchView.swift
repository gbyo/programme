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
    @State private var isAddingNote = false
    @State private var note = ""

    enum LiveSheet: Identifiable, Equatable {
        case eventLog
        case review
        case options
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
            case .lineup: "lineup"
            case .periodBreak: "break"
            case .finalize: "finalize"
            case .shootout: "shootout"
            case .editEvent(let id): "edit-\(id)"
            }
        }
    }

    /// In a narrow window Record and Lineup are two halves of one workspace that
    /// the scorer switches between. That is a navigation choice, not a value, so
    /// on iPadOS 27 it is presented — and announced — as tabs.
    enum CompactPane: String, CaseIterable, Identifiable {
        case palette = "Record"
        case lineup = "Lineup"
        var id: String { rawValue }
    }

    /// Design intent for the three columns, expressed as ranges rather than as
    /// device breakpoints. `ViewThatFits` picks a layout by asking whether its
    /// ideal width fits, so the ideal here *is* the minimum comfortable width and
    /// the range above it is where the layout is free to grow.
    private enum Column {
        static let lineupMinimum: CGFloat = 220
        static let lineupMaximum: CGFloat = 300
        static let recordMinimum: CGFloat = 290
        static let recordMaximum: CGFloat = 380
        static let stageMinimum: CGFloat = 340
        static let workspaceMinimum: CGFloat = 320
        /// What the three-column layout needs, independent of what the centre
        /// happens to be showing.
        static let wideMinimum: CGFloat = lineupMinimum + stageMinimum + recordMinimum
    }

    var body: some View {
        // A navigation container so both strips can be real system toolbars: the
        // match controls at the top trailing edge, the scoring controls at the
        // bottom. The scoreboard is not one of them — it is genuinely custom bar
        // content, far taller than a navigation bar and not squeezable into a
        // title — so it uses the system's custom-bar API instead, which still
        // gives it the scroll-edge treatment and the right safe area in every
        // iPad window size.
        NavigationStack {
            adaptiveContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top) {
                    LiveHeader(session: session)
                }
                // A notice is transient, floating control-layer UI, so it
                // sits above the content rather than inside either bar.
                .overlay(alignment: .bottom) {
                    if let notice = session.notice {
                        NoticeBanner(notice: notice) { session.dismissNotice() }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: session.notice)
                // Arming a player is a view-state change, so its feedback is
                // declarative. Recording an event stays imperative in the
                // session, where the domain meaning of "goal" lives.
                .sensoryFeedback(.selection, trigger: session.armedPlayer)
                .background(Color(.systemBackground))
                // The navigation bar carries the match controls and nothing
                // else: no title, and no back button, because this is the root
                // of its own stack. It stays a single row directly above the
                // scoreboard rather than becoming a second strip of chrome.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                // The bar has no background of its own, so the controls read as
                // part of the scoreboard region rather than as a second slab of
                // material stacked on top of it. The controls keep their own
                // system backgrounds; only the strip behind them goes away.
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbar {
                    MatchControlsToolbar(
                        session: session,
                        onMenu: { activeSheet = .options },
                        onToggleClock: { session.toggleClock() },
                        onEndPeriod: { endPeriod() },
                        onStartPeriod: { startPeriod() }
                    )

                    ScoringToolbar(
                        session: session,
                        onSubstitute: beginSubstitution,
                        onEdit: { editLastEvent() },
                        onLog: { activeSheet = .eventLog },
                        onReview: { activeSheet = .review }
                    )
                }
        }
        .inspector(isPresented: $isShowingInspector) {
            NavigationStack {
                MatchStatsInspector(session: session) {
                    isShowingInspector = false
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .alert("Add a note", isPresented: $isAddingNote) {
            TextField("What happened?", text: $note)
            Button("Cancel", role: .cancel) { note = "" }
            Button("Add") {
                if !note.isEmpty { session.run(.addNote(note), feedback: .silent) }
                note = ""
            }
        } message: {
            Text("Notes appear in the event log and in exported stat sheets.")
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
        .onChange(of: session.requestedAction) { _, request in
            guard let request else { return }
            session.requestedAction = nil
            perform(request)
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

    /// Three layouts, chosen by what actually fits rather than by device width.
    ///
    /// Each candidate states the narrowest width at which it is still usable; the
    /// system takes the first one that does. A window dragged continuously
    /// narrower therefore moves through them at the point where the content
    /// genuinely stops fitting, on any iPad, in any Stage Manager arrangement.
    private var adaptiveContent: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            mediumLayout
            compactLayout
        }
    }

    private var wideLayout: some View {
        // No `layoutPriority` in here, deliberately. Giving the centre priority
        // makes the stack satisfy it first and squeeze the side columns below
        // their `minWidth` — which does not shrink them, it makes the whole row
        // wider than the window and clips the lineup and the palette off both
        // edges. The side columns' maximums are what hand the centre the
        // remainder, and a maximum cannot overflow.
        HStack(spacing: 0) {
            // While an event flow is running, the lineup yields its column to the
            // stage. The stage is already asking the question the lineup would
            // answer — who was this? who is coming off? — so the column is dead
            // space, and a substitution grid squeezed into the remainder starts
            // to scroll. The Record palette never moves, which is the position
            // muscle memory actually depends on.
            if stage.isPitch {
                LineupColumn(session: session, onSelect: select(player:))
                    .frame(
                        minWidth: Column.lineupMinimum, idealWidth: Column.lineupMinimum,
                        maxWidth: Column.lineupMaximum)
                Divider()
            }
            stageView
                .frame(
                    minWidth: Column.stageMinimum, idealWidth: Column.stageMinimum,
                    maxWidth: .infinity
                )
            Divider()
            paletteColumn
                .frame(
                    minWidth: Column.recordMinimum, idealWidth: Column.recordMinimum,
                    maxWidth: Column.recordMaximum)
        }
        // The width this layout needs must not depend on what the centre is
        // showing, or `ViewThatFits` would pick a different layout the moment an
        // event flow starts and pick it back when the flow ends. Whether the
        // lineup is on screen is a decision inside this layout, not a reason to
        // change layout.
        .frame(minWidth: Column.wideMinimum, idealWidth: Column.wideMinimum, maxWidth: .infinity)
    }

    private var mediumLayout: some View {
        HStack(spacing: 0) {
            Group {
                if stage.isPitch {
                    LineupColumn(session: session, onSelect: select(player:))
                } else {
                    stageView
                }
            }
            .frame(
                minWidth: Column.workspaceMinimum, idealWidth: Column.workspaceMinimum,
                maxWidth: .infinity
            )
            Divider()
            paletteColumn
                .frame(
                    minWidth: Column.recordMinimum, idealWidth: Column.recordMinimum,
                    maxWidth: Column.recordMaximum)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            if stage.isPitch {
                CompactPanePicker(selection: $compactPane)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                switch compactPane {
                case .palette: paletteColumn
                case .lineup: LineupColumn(session: session, onSelect: select(player:))
                }
            } else {
                stageView
            }
        }
    }

    /// The Record column owns its own scrolling now: the our-team actions scroll,
    /// the opponent's quick actions are pinned underneath them.
    private var paletteColumn: some View {
        EventPalette(
            session: session,
            onAction: handle(action:),
            onOverflow: handle(overflow:),
            onOpponentAction: handleOpponent(_:),
            onClearArmedPlayer: { session.armedPlayer = nil }
        )
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
                    players: session.candidates(
                        for: prompt.action.attributionCategory, side: prompt.side),
                    goalkeeperID: prompt.side == .us ? session.snapshot.activeGoalkeeper : nil,
                    allowsUnknown: prompt.action.allowsUnknown,
                    unknownTitle: prompt.side == .us
                        ? "Player Unknown" : "\(session.descriptor.opponentShortName) — No Player",
                    unknownSubtitle: prompt.side == .us
                        ? "Record now, attribute later" : "Count it for the team only",
                    showsTips: session.showsContextualTips,
                    onPick: { complete(prompt.action, side: prompt.side, with: $0) },
                    onCancel: { stage = .pitch }
                )

            case .chooseAssist(let shot):
                AssistPickerStage(
                    scorerName: session.context.roster(for: shot.side).label(for: shot.shooter),
                    players: session.candidates(for: .assist, side: shot.side)
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
                        // A penalty is never assisted, so this goes straight to
                        // the shot regardless of the outcome.
                        finish(
                            shot: ShotEvent(
                                side: .us, shooter: taker, outcome: outcome, phase: .penaltyKick))
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
        // A player on the bench did not take that shot. Bench rows stay visible
        // and stay reachable for the things that legitimately involve them, but
        // the generic arm-then-act path is for players who are on the field.
        guard session.canArm(player) else {
            // Deliberately not silent: a tap that does nothing reads as a bug.
            session.armedPlayer = nil
            session.show(
                notice: LiveNotice(
                    text:
                        "\(player.shortLabel) is on the bench. Use Substitution to bring them on, or More for a card.",
                    kind: .warning))
            return
        }
        session.armedPlayer = session.armedPlayer == player.id ? nil : player.id
    }

    private func handle(action: PaletteAction) {
        switch action.id {
        case "save":
            session.recordSave()
            session.armedPlayer = nil
        default:
            guard let pending = action.pending else { return }
            begin(pending)
        }
    }

    private func handle(overflow: PaletteOverflow) {
        switch overflow {
        case .pending(let action):
            begin(action)
        case .opponentPenalty:
            session.run(
                .recordShot(
                    ShotEvent(
                        side: .opponent, shooter: .untracked, outcome: .goal, phase: .penaltyKick)),
                feedback: .goal)
        case .opponentCard:
            session.run(.recordCard(CardEvent(side: .opponent, player: .untracked, card: .yellow)))
        case .addNote:
            isAddingNote = true
        }
    }

    private func handleOpponent(_ quick: OpponentQuickAction) {
        let action: PendingAction =
            switch quick {
            case .goal: .goal(.openPlay)
            case .shot: .shot(.offTarget)
            case .corner: .corner
            }

        guard session.context.hasStarted else {
            session.show(
                notice: LiveNotice(text: "The match hasn't kicked off yet.", kind: .warning))
            return
        }

        // In `Both Teams` mode the opponent's players are attributed too, using
        // the same engine and the same picker. In `Our Team` mode these stay
        // single taps, which is the whole point of that mode.
        if session.descriptor.tracking == .bothTeams,
            !session.context.opponentRoster.players.isEmpty
        {
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
        guard session.context.hasStarted else {
            session.show(
                notice: LiveNotice(text: "The match hasn't kicked off yet.", kind: .warning))
            return
        }
        // An armed player is only used when they may legitimately be credited
        // with this kind of event. A card armed to a player who has come off is
        // fine; a shot is not, and falls through to the picker rather than being
        // recorded against the wrong person.
        if let armed = session.armedPlayer,
            session.allowsAttribution(of: armed, to: action.attributionCategory)
        {
            session.armedPlayer = nil
            complete(action, with: .player(armed))
        } else {
            session.armedPlayer = nil
            stage = .choosePlayer(PlayerPrompt(action: action))
        }
    }

    private func perform(_ request: LiveActionRequest) {
        switch request.kind {
        case .goal: begin(.goal(.openPlay))
        case .shotOnGoal: begin(.shot(.saved))
        case .shot: begin(.shot(.offTarget))
        case .save:
            session.recordSave()
            session.armedPlayer = nil
        case .corner: begin(.corner)
        case .substitution: beginSubstitution()
        }
    }

    private func complete(_ action: PendingAction, side: TeamSide = .us, with ref: PlayerRef) {
        switch action {
        case .penaltyAttempt where side == .us:
            // The outcome is still unknown. Nothing about this implies a goal.
            stage = .penaltyOutcome(ref)

        case .penaltyAttempt:
            finish(shot: ShotEvent(side: side, shooter: ref, outcome: .goal, phase: .penaltyKick))

        case .goal(let phase):
            let shot = ShotEvent(side: side, shooter: ref, outcome: .goal, phase: phase)
            // An opponent goal in `Our Team` mode has nobody to credit an assist to.
            if session.profile.prompts.assistOnGoal,
                side == .us || !session.candidates(for: .assist, side: side).isEmpty
            {
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

/// Record / Lineup in a narrow window.
///
/// These are two pieces of content, not two values, so on iPadOS 27 they use the
/// tabs picker style and are announced as tabs. The segmented style remains the
/// iPadOS 26 appearance, which looks much the same but reads to VoiceOver as a
/// value control.
struct CompactPanePicker: View {
    @Binding var selection: LiveMatchView.CompactPane

    var body: some View {
        Picker("Workspace", selection: $selection) {
            ForEach(LiveMatchView.CompactPane.allCases) { pane in
                Text(pane.rawValue).tag(pane)
            }
        }
        .modifier(PaneSelectionStyle())
        .accessibilityIdentifier("live.compactPane")
    }
}

private struct PaneSelectionStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.pickerStyle(.tabs)
        } else {
            content.pickerStyle(.segmented)
        }
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
                if let player = session.armedPlayerSnapshot {
                    Label("\(player.shortLabel) selected", systemImage: "hand.tap.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                }
                Button("Match Stats", systemImage: "chart.bar") { onOpenStats() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("live.matchStats")
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

/// A penalty attempt, after the taker is known.
///
/// Programme asks *what happened* rather than assuming a goal: a penalty is an
/// attempt, and a saved one is not a goal that failed to appear. The wording and
/// the state stay neutral until the scorer answers.
struct PenaltyOutcomeStage: View {
    let takerName: String
    var onPick: (ShotOutcome) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What happened?")
                        .font(.title3.weight(.semibold))
                    Text("Penalty kick · \(takerName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
            }

            VStack(spacing: 10) {
                outcomeButton("Goal", "soccerball.inverse", .goal, isGoal: true)
                outcomeButton("Saved", "hand.raised.fill", .saved, isGoal: false)
                outcomeButton("Missed", "arrow.up.forward", .offTarget, isGoal: false)
                outcomeButton("Post or Crossbar", "diamond", .woodwork, isGoal: false)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    @ViewBuilder
    private func outcomeButton(
        _ title: String, _ symbol: String, _ outcome: ShotOutcome, isGoal: Bool
    ) -> some View {
        let button = Button {
            onPick(outcome)
        } label: {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 66)
        }
        .accessibilityIdentifier("penalty.\(outcome.rawValue)")

        if isGoal {
            button
                .programmePrimaryAction()
                .buttonBorderShape(.roundedRectangle(radius: 14))
        } else {
            button.programmeTile(shape: .roundedRectangle(radius: 14))
        }
    }
}
