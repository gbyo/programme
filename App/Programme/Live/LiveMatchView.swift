import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// Programme's scoring workspace.
///
/// Four parts, each with one job:
///
/// - **Record** starts an event.
/// - **Lineup** preselects the player an event will belong to.
/// - **Event Composer** asks only for information that is actually missing.
/// - **Inspector** holds the statistics. **Review** holds the deferred details.
///
/// The composer is the part that used to be muddled. It is not a dashboard and
/// it does not show passive statistics; it appears when an event needs
/// completing and it gets out of the way when nothing does.
struct LiveMatchView: View {
    let session: LiveMatchSession

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The platform's own answer to "is there room for more than one pane?".
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var composer = EventComposer.idle
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

    /// In a compact window Record and Lineup are two halves of one workspace that
    /// the scorer switches between. That is a navigation choice, not a value, so
    /// on iPadOS 27 it is presented — and announced — as tabs.
    enum CompactPane: String, CaseIterable, Identifiable {
        case palette = "Record"
        case lineup = "Lineup"
        var id: String { rawValue }
    }

    /// What each column needs to do its job, as ranges rather than device widths.
    ///
    /// `ViewThatFits` picks a layout by asking whether its ideal width fits, so
    /// the ideal here *is* the minimum comfortable width and the range above it
    /// is where the layout may grow.
    ///
    /// The three-column figure is the sum of its parts, not a device lookup: a
    /// lineup wide enough for a name and a jersey number, a workspace wide enough
    /// for the substitution grid's two columns without scrolling, and the Record
    /// palette's two-across grid. Anything narrower is better served by giving
    /// the workspace the lineup's space only when it has something to ask, which
    /// is what the two-column layout does.
    private enum Column {
        static let lineupMinimum: CGFloat = 280
        static let lineupMaximum: CGFloat = 320
        static let recordMinimum: CGFloat = 340
        static let recordMaximum: CGFloat = 380
        /// What the workspace needs to hold the substitution grid's two columns
        /// side by side without scrolling — the roomiest thing it ever shows.
        static let workspaceComfortable: CGFloat = 560
        /// What it needs to ask a single question: a player grid four tiles
        /// across, or an assist picker.
        static let workspaceUsable: CGFloat = 400
        /// The narrowest window in which lineup, workspace and Record can all be
        /// permanently on screen and all be usable.
        static let threeColumnMinimum: CGFloat =
            lineupMinimum + workspaceComfortable + recordMinimum
        /// The two-column layout only has to fit the workspace when it takes the
        /// lineup's place, so it asks for less. This has to stay at or below the
        /// narrowest regular-width iPad window — an iPad mini in portrait, 744pt
        /// — because below that the system hands us a compact environment and
        /// the compact layout takes over instead.
        static let twoColumnMinimum: CGFloat = workspaceUsable + recordMinimum
    }

    /// Whether the composer takes over the screen in a sheet rather than living
    /// in a column. This is the platform's compact environment — iPhone, and an
    /// iPad window narrow enough that the system itself says one pane at a time.
    private var composerUsesSheet: Bool { horizontalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            adaptiveContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top) {
                    LiveHeader(session: session)
                }
                .overlay(alignment: .bottom) {
                    if let notice = session.notice {
                        NoticeBanner(notice: notice) { session.dismissNotice() }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: session.notice)
                .sensoryFeedback(.selection, trigger: session.armedPlayer)
                .background(Color(.systemBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
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
                        onReview: { activeSheet = .review },
                        onStats: { isShowingInspector.toggle() }
                    )
                }
        }
        // Statistics are the inspector's job, here and nowhere else. In a compact
        // environment SwiftUI presents an inspector as a sheet by itself, which
        // is the right shape there and needs no second implementation.
        .inspector(isPresented: $isShowingInspector) {
            NavigationStack {
                MatchStatsInspector(session: session) {
                    isShowingInspector = false
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
        }
        // One composer sheet, not one sheet per question. The step changes inside
        // it, so "Who scored? → Who assisted? → Where?" is a transition rather
        // than a dismiss and a re-present.
        .sheet(isPresented: composerSheetBinding) {
            ComposerSheet(title: composer.step?.title ?? "") {
                composerContent
            } onDismiss: {
                abandonComposer()
            }
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

    /// Presented only where the composer uses a sheet, and closed by finishing
    /// the step. Dismissing by gesture runs the same path.
    private var composerSheetBinding: Binding<Bool> {
        Binding(
            get: { composerUsesSheet && composer.isComposing },
            set: { isPresented in
                if !isPresented { abandonComposer() }
            })
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
            NavigationStack { ReviewView(session: session) }

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

    /// Compact is the platform's own decision, not a width Programme invents. In
    /// a regular environment the choice between three columns and two is made by
    /// what actually fits.
    @ViewBuilder
    private var adaptiveContent: some View {
        if composerUsesSheet {
            compactLayout
        } else {
            ViewThatFits(in: .horizontal) {
                threeColumnLayout
                twoColumnLayout
            }
        }
    }

    /// Wide iPad: Lineup | Event Workspace | Record, all permanent.
    private var threeColumnLayout: some View {
        // No `layoutPriority` in here, deliberately. Giving the centre priority
        // makes the stack satisfy it first and squeeze the side columns below
        // their `minWidth` — which does not shrink them, it makes the whole row
        // wider than the window and clips the lineup and the palette off both
        // edges. The side columns' maximums are what hand the centre the
        // remainder, and a maximum cannot overflow.
        HStack(spacing: 0) {
            LineupColumn(session: session, onSelect: select(player:))
                .frame(
                    minWidth: Column.lineupMinimum, idealWidth: Column.lineupMinimum,
                    maxWidth: Column.lineupMaximum)
            Divider()
            workspace
                .frame(
                    minWidth: Column.workspaceComfortable, idealWidth: Column.workspaceComfortable,
                    maxWidth: .infinity)
            Divider()
            paletteColumn
                .frame(
                    minWidth: Column.recordMinimum, idealWidth: Column.recordMinimum,
                    maxWidth: Column.recordMaximum)
        }
        .frame(
            minWidth: Column.threeColumnMinimum, idealWidth: Column.threeColumnMinimum,
            maxWidth: .infinity)
    }

    /// iPad mini and constrained landscape windows: Lineup | Record while idle.
    /// The workspace is not permanently on screen here — it takes the lineup's
    /// place only when it has something to ask, and gives it straight back.
    private var twoColumnLayout: some View {
        HStack(spacing: 0) {
            Group {
                if composer.isComposing {
                    workspace
                } else {
                    LineupColumn(session: session, onSelect: select(player:))
                }
            }
            .frame(
                minWidth: Column.workspaceUsable, idealWidth: Column.workspaceUsable,
                maxWidth: .infinity)
            Divider()
            paletteColumn
                .frame(
                    minWidth: Column.recordMinimum, idealWidth: Column.recordMinimum,
                    maxWidth: Column.recordMaximum)
        }
        .frame(
            minWidth: Column.twoColumnMinimum, idealWidth: Column.twoColumnMinimum,
            maxWidth: .infinity)
    }

    /// Compact: one pane at a time, and the composer arrives as a sheet over the
    /// top of it rather than displacing the scorer.
    private var compactLayout: some View {
        VStack(spacing: 0) {
            CompactPanePicker(selection: $compactPane)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            switch compactPane {
            case .palette: paletteColumn
            case .lineup: LineupColumn(session: session, onSelect: select(player:))
            }
        }
    }

    /// The Record column owns its own scrolling: the our-team actions scroll, the
    /// opponent's quick actions are pinned underneath them.
    private var paletteColumn: some View {
        EventPalette(
            session: session,
            onAction: handle(action:),
            onOverflow: handle(overflow:),
            onOpponentAction: handleOpponent(_:),
            onClearArmedPlayer: { session.armedPlayer = nil }
        )
    }

    // MARK: - The Event Composer

    /// The middle column in a regular environment: the composer when it has a
    /// question, and the shot map when it does not.
    @ViewBuilder
    private var workspace: some View {
        ZStack {
            if composer.isComposing {
                composerContent
            } else {
                IdleWorkspace(session: session)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: composer)
    }

    /// The composer itself, shared by the column and the sheet. One definition of
    /// each question, presented two ways.
    @ViewBuilder
    private var composerContent: some View {
        switch composer.step {
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
                onCancel: { composer.finish() }
            )

        case .penaltyOutcome(let taker):
            PenaltyOutcomeStage(
                takerName: session.context.roster.label(for: taker),
                onPick: { outcome in recordPenalty(taker: taker, outcome: outcome) },
                onCancel: { composer.finish() }
            )

        case .assist(let goalID, let scorerName, let side):
            AssistPickerStage(
                scorerName: scorerName,
                players: session.candidates(for: .assist, side: side)
                    .filter { $0.id != scorerID(of: goalID) },
                onPick: { assist in
                    // `nil` is "unassisted" and settles the goal; `.unidentified`
                    // deliberately leaves it in Review.
                    session.resolveAssist(assist, on: goalID)
                    composer.finish()
                },
                onSkip: { composer.finish() }
            )

        case .shotLocation(let shotID, let shooterName, let outcome):
            ShotLocationStage(
                shooterName: shooterName,
                outcome: outcome,
                markers: session.shotMarkers,
                onCommit: { location in
                    session.resolveShotLocation(location, on: shotID)
                    composer.finish()
                }
            )

        case .substitution:
            SubstitutionStage(
                session: session,
                onCommit: { out, incoming, keeper in
                    session.substitute(out: out, in: incoming, goalkeeperAfter: keeper)
                    composer.finish()
                },
                onCancel: { composer.finish() }
            )

        case nil:
            EmptyView()
        }
    }

    /// Leaving the composer never costs a recorded fact. The steps that could
    /// lose one are the ones where nothing has been recorded yet, and those
    /// simply drop the half-formed intent.
    private func abandonComposer() {
        composer.finish()
    }

    private func scorerID(of goalID: EventID) -> PlayerID? {
        guard let event = session.context.events.first(where: { $0.id == goalID }),
            case .shot(let shot) = event.payload
        else { return nil }
        return shot.shooter.playerID
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
        let wasArmed = session.armedPlayer == player.id
        session.armedPlayer = wasArmed ? nil : player.id

        // Player-first, in one pane: having chosen who, the scorer's next tap is
        // always an action, so Record comes forward without being asked for.
        if !wasArmed, composerUsesSheet {
            compactPane = .palette
        }
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

        if session.descriptor.tracking == .bothTeams,
            !session.context.opponentRoster.players.isEmpty
        {
            composer.ask(.choosePlayer(PlayerPrompt(action: action, side: .opponent)))
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
        composer.ask(.substitution)
    }

    /// Both interaction directions land here: a player was already armed, or the
    /// composer asks who it belongs to.
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
            composer.ask(.choosePlayer(PlayerPrompt(action: action)))
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

    /// The player is known, so the primary fact is recorded *now*. Anything still
    /// missing becomes the composer's next question, asked against an event that
    /// already exists.
    private func complete(_ action: PendingAction, side: TeamSide = .us, with ref: PlayerRef) {
        switch action {
        case .penaltyAttempt where side == .us:
            // The outcome is a primary fact, not enrichment: a penalty whose
            // outcome is unknown is a score that may or may not have happened.
            composer.ask(.penaltyOutcome(taker: ref))

        case .penaltyAttempt:
            recordShot(
                ShotEvent(side: side, shooter: ref, outcome: .goal, phase: .penaltyKick), side: side)

        case .goal(let phase):
            recordGoal(shooter: ref, phase: phase, side: side)

        case .ownGoal:
            _ = session.recordReturningID(
                .recordShot(ShotEvent(side: side, shooter: ref, outcome: .goal, isOwnGoal: true)),
                feedback: .goal)
            composer.finish()

        case .shot(let outcome):
            recordShot(ShotEvent(side: side, shooter: ref, outcome: outcome), side: side)

        case .corner:
            session.run(.recordCorner(side: side, player: ref))
            composer.finish()

        case .steal:
            session.run(.recordSteal(side: side, player: ref))
            composer.finish()

        case .foul:
            session.run(.recordFoul(side: side, player: ref))
            composer.finish()

        case .offside:
            session.run(.recordOffside(side: side, player: ref))
            composer.finish()

        case .card(let type):
            session.run(.recordCard(CardEvent(side: side, player: ref, card: type)))
            composer.finish()

        case .goalkeeper:
            session.run(.changeGoalkeeper(side: side, goalkeeper: ref))
            composer.finish()
        }
    }

    /// A goal is a goal the moment the scorer says so.
    ///
    /// The event is written, the score moves, the journal is flushed and the goal
    /// feedback fires *before* the assist question is asked. The assist is
    /// recorded as unresolved so that walking away leaves a correct goal and one
    /// Review item, rather than no goal at all.
    private func recordGoal(shooter: PlayerRef, phase: PlayPhase, side: TeamSide) {
        let asksAssist =
            session.profile.prompts.assistOnGoal
            && (side == .us || !session.candidates(for: .assist, side: side).isEmpty)

        let shot = ShotEvent(
            side: side,
            shooter: shooter,
            outcome: .goal,
            assist: asksAssist ? .unidentified : nil,
            phase: phase)

        guard let goalID = session.recordReturningID(.recordShot(shot), feedback: .goal) else {
            composer.finish()
            return
        }

        guard asksAssist else {
            composer.finish()
            return
        }
        composer.ask(
            .assist(
                goal: goalID,
                scorerName: session.context.roster(for: side).label(for: shooter),
                side: side))
    }

    /// The shot is recorded before the optional map is offered, so skipping the
    /// map — or never answering it — cannot cost the shot.
    private func recordShot(_ shot: ShotEvent, side: TeamSide) {
        guard let shotID = session.recordReturningID(.recordShot(shot), feedback: .standard) else {
            composer.finish()
            return
        }
        guard session.profile.prompts.shotLocation, side == .us else {
            composer.finish()
            return
        }
        composer.ask(
            .shotLocation(
                shot: shotID,
                shooterName: session.context.roster(for: side).label(for: shot.shooter),
                outcome: shot.outcome))
    }

    private func recordPenalty(taker: PlayerRef, outcome: ShotOutcome) {
        // A penalty goal is never assisted, so there is no assist question here.
        recordShot(
            ShotEvent(side: .us, shooter: taker, outcome: outcome, phase: .penaltyKick), side: .us)
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

/// The compact presentation of the composer: one sheet, whose content changes as
/// the composer moves between questions.
///
/// Deliberately not a popover and deliberately not one sheet per step. A scorer
/// answering "who scored, who assisted, where" should see one surface that
/// changes, not three that stack.
struct ComposerSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { onDismiss() }
                            .accessibilityIdentifier("composer.done")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("composer.sheet")
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: title)
    }
}

/// Record / Lineup in a compact window.
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

/// What the workspace shows when the composer has nothing to ask.
///
/// The shot map, where the match is recording one, and otherwise a plain
/// statement of what this area is for. Explicitly *not* a second statistics
/// panel: the numbers live in the inspector, and duplicating them here is how
/// the middle of the screen stopped having a purpose in the first place.
struct IdleWorkspace: View {
    let session: LiveMatchSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsPitch: Bool {
        session.profile.tracks(.shotLocations) || !session.shotMarkers.isEmpty
    }

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
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if showsPitch {
                PitchView(markers: session.shotMarkers)
                    .padding(.horizontal, 14)
            } else {
                idlePrompt
            }

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("live.workspace")
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.armedPlayer)
    }

    private var idlePrompt: some View {
        ContentUnavailableView {
            Label("Nothing to complete", systemImage: "checkmark.circle")
        } description: {
            Text(
                "Start an event from Record, or tap a player first. This space asks for whatever the event is missing."
            )
        }
        .frame(maxWidth: 420)
    }
}

/// A penalty attempt, after the taker is known.
///
/// Programme asks *what happened* rather than assuming a goal: a penalty is an
/// attempt, and a saved one is not a goal that failed to appear. The wording and
/// the state stay neutral until the scorer answers, and nothing is recorded until
/// then either — an outcome is a primary fact, not enrichment.
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
