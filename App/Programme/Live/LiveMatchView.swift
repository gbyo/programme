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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// The platform's own answer to "is there room for more than one pane?".
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var composer = EventComposer.idle
    /// The sole presentation state. Programme never stacks presentations, and
    /// routing every one through a single value makes a transition between
    /// two of them a content swap rather than a dismiss-and-present race.
    /// Two cases render outside `.sheet` — the note alert and the stats
    /// inspector column — because those are the platform-idiomatic shapes
    /// for a quick text entry and a stats column, but the router still owns
    /// them: no other presentation Bool exists.
    @State private var activeSheet: LiveSheet?
    @State private var compactPane: CompactPane = .palette
    /// Compact layouts show the newly recorded event briefly above the toolbar
    /// instead of making passive status compete with the toolbar's controls.
    @State private var compactLastEventID: EventID?
    @State private var note = ""
    @AppStorage(ScreenAwakePolicy.preferenceKey) private var keepScreenAwake = true

    enum LiveSheet: Identifiable, Equatable {
        /// The Event Composer itself. Its *content* lives in `composer`; this
        /// case only says that a compact window presents it as a sheet, so
        /// Programme still has exactly one presentation owner.
        case composer
        case eventLog
        case review
        case lineup
        case opponentRoster
        case adjustClock
        case periodBreak
        case finalize
        case shootout
        case editEvent(EventID)
        case nearbyDisplay
        case addNote
        case statsInspector

        var id: String {
            switch self {
            // Deliberately stable across composer steps: "Who scored? → Who
            // assisted? → Where?" changes the content inside one sheet rather
            // than dismissing and presenting three.
            case .composer: "composer"
            case .eventLog: "log"
            case .review: "review"
            case .lineup: "lineup"
            case .opponentRoster: "opponent-roster"
            case .adjustClock: "adjust-clock"
            case .periodBreak: "break"
            case .finalize: "finalize"
            case .shootout: "shootout"
            case .editEvent(let id): "edit-\(id)"
            case .nearbyDisplay: "nearby-display"
            case .addNote: "add-note"
            case .statsInspector: "stats-inspector"
            }
        }

        /// Whether this case renders inside the `.sheet` modifier. The note
        /// alert and the inspector column are owned by the same state but
        /// rendered by their own platform modifiers below.
        var isSheet: Bool {
            switch self {
            case .addNote, .statsInspector: false
            default: true
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
        /// What the workspace needs to hold Substitution's two lists —
        /// Coming Off beside Coming On — side by side with a name and a jersey
        /// number legible in each. The roomiest thing it ever shows.
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

    /// Whatever the hardware, a compact environment gets Programme's compact
    /// scoring layout and anything regular gets the columns. Keeping this as
    /// one space-driven rule means the composer and the bottom toolbar adapt
    /// at the same point instead of inventing separate width thresholds for
    /// each feature — and a regular-width phone uses the richer layout its
    /// environment can hold.
    private var usesCompactScoringLayout: Bool {
        horizontalSizeClass == .compact
    }

    /// Whether the composer takes over the screen in a sheet rather than living
    /// in a column.
    ///
    /// A compact environment uses the sheet, where the substitution flow is a
    /// pushed navigation stack. A regular environment — a wide iPad window, or
    /// a phone reporting regular width — keeps the columns. The composer step
    /// itself is presentation-independent, so a size-class transition
    /// re-routes the same pending question instead of losing it.
    private var composerUsesSheet: Bool {
        usesCompactScoringLayout
    }

    var body: some View {
        NavigationStack {
            adaptiveContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top) {
                    LiveHeader(session: session)
                }
                .overlay(alignment: .bottom) {
                    Group {
                        if let notice = session.notice {
                            NoticeBanner(notice: notice) { session.dismissNotice() }
                                .transition(
                                    LiveMotion.temporaryStatusTransition(
                                        reduceMotion: reduceMotion))
                        } else if usesCompactScoringLayout,
                            compactLastEventID == session.lastEventDescription?.id
                        {
                            CompactLastEventConfirmation(session: session)
                                .transition(
                                    LiveMotion.temporaryStatusTransition(
                                        reduceMotion: reduceMotion))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .programmeSensoryFeedback(.selection, trigger: session.armedPlayer)
                .background(Color(.systemBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbar {
                    MatchControlsToolbar(
                        session: session,
                        onClose: closeScorer,
                        onShowStats: { activeSheet = .statsInspector },
                        onEditLineup: { activeSheet = .lineup },
                        onEditOpponentRoster: { activeSheet = .opponentRoster },
                        onAdjustClock: { activeSheet = .adjustClock },
                        supportsScoreboardWindow: supportsMultipleWindows,
                        onOpenScoreboard: {
                            guard supportsMultipleWindows else { return }
                            openWindow(id: ProgrammeScene.scoreboard.rawValue)
                        },
                        onConnectDisplay: { activeSheet = .nearbyDisplay },
                        onShootout: { activeSheet = .shootout },
                        onFinalize: { activeSheet = .finalize },
                        onToggleClock: { session.toggleClock() },
                        onEndPeriod: { endPeriod() },
                        onStartPeriod: { startPeriod() }
                    )

                    ScoringToolbar(
                        session: session,
                        showsInlineLastEvent: !usesCompactScoringLayout,
                        onSubstitute: beginSubstitution,
                        onEdit: { editLastEvent() },
                        onLog: { activeSheet = .eventLog },
                        onReview: { activeSheet = .review },
                        onStats: {
                            activeSheet =
                                (activeSheet == .statsInspector) ? nil : .statsInspector
                        }
                    )
                }
        }
        // Statistics are the inspector's job, here and nowhere else. In a compact
        // environment SwiftUI presents an inspector as a sheet by itself, which
        // is the right shape there and needs no second implementation.
        .inspector(isPresented: inspectorPresented) {
            NavigationStack {
                MatchStatsInspector(session: session) {
                    if activeSheet == .statsInspector { activeSheet = nil }
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
        }
        // Exactly one `.sheet` in the whole workspace. The composer is a route
        // through the same router as everything else, so two presentations can
        // never race each other, and moving between composer questions is a
        // content change inside one sheet rather than a dismiss and a
        // re-present.
        .sheet(item: presentedSheet) { sheet in
            sheetContent(sheet)
        }
        .alert("Add a note", isPresented: notePresented) {
            TextField("What happened?", text: $note)
            Button("Cancel", role: .cancel) {
                note = ""
                if activeSheet == .addNote { activeSheet = nil }
            }
            Button("Add") {
                if !note.isEmpty { session.run(.addNote(note), feedback: .silent) }
                note = ""
                if activeSheet == .addNote { activeSheet = nil }
            }
        } message: {
            Text("Notes appear in the event log and in exported stat sheets.")
        }
        .task {
            publishScoreboard()
        }
        .onChange(of: session.context) { _, _ in
            publishScoreboard()
        }
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .periodBreak, .awaitingFinalization:
                // The composer owns the sheet while it has a question, so a
                // period ending has to put it away before asking for one.
                // A half-written note is put away the same way.
                abandonComposer()
                if activeSheet == .addNote { note = "" }
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
        .onChange(of: session.lastEventDescription?.id) { oldID, newID in
            guard usesCompactScoringLayout, let newID, newID != oldID else { return }
            compactLastEventID = newID
        }
        .onChange(of: usesCompactScoringLayout) { _, isCompact in
            if !isCompact { compactLastEventID = nil }
        }
        .task(id: compactLastEventID) {
            guard compactLastEventID != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            compactLastEventID = nil
        }
        .onAppear {
            if !session.hasStartingLineup { activeSheet = .lineup }
            // The scorer is visibly active: keep the display awake only while
            // the preference is enabled. The controller re-evaluates the
            // policy, so this never leaves the global setting behind.
            appModel.screenAwake.isScorerVisible = true
            appModel.screenAwake.preferenceEnabled = keepScreenAwake
            appModel.screenAwake.refresh()
        }
        .onDisappear {
            // Leaving the scorer — closing, finalizing, or navigating away —
            // restores normal idle behavior immediately.
            appModel.screenAwake.isScorerVisible = false
            appModel.screenAwake.refresh()
        }
        .onChange(of: keepScreenAwake) { _, enabled in
            // Disabling the setting mid-match restores normal sleep at once.
            appModel.screenAwake.preferenceEnabled = enabled
            appModel.screenAwake.refresh()
        }
    }

    /// The single source of "what is presented".
    ///
    /// The composer wins while it has a question, because in a compact window it
    /// is the thing the scorer is looking at; everything else is reached from a
    /// toolbar that is behind it. Anything that needs to interrupt the composer
    /// — a period ending — abandons it first, so this never hides a request.
    private var presentedSheet: Binding<LiveSheet?> {
        Binding(
            get: {
                if composerUsesSheet && composer.isComposing { return .composer }
                guard let sheet = activeSheet, sheet.isSheet else { return nil }
                return sheet
            },
            set: { sheet in
                guard sheet == nil else {
                    activeSheet = sheet
                    return
                }
                if composerUsesSheet && composer.isComposing {
                    abandonComposer()
                } else {
                    activeSheet = nil
                }
            })
    }

    /// Derived bindings, not stored state: the alert and the inspector
    /// column answer to the same router as the sheet.
    private var notePresented: Binding<Bool> {
        Binding(
            get: { activeSheet == .addNote },
            set: { showing in
                if !showing {
                    note = ""
                    if activeSheet == .addNote { activeSheet = nil }
                }
            })
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: {
                guard activeSheet == .statsInspector else { return false }
                // The composer wins while it has a question: in a compact
                // window the system would present the inspector as a second
                // sheet over the composer's. Its toolbar is behind that
                // sheet, so this is unreachable from the UI either way.
                return !(composerUsesSheet && composer.isComposing)
            },
            set: { showing in
                if !showing, activeSheet == .statsInspector { activeSheet = nil }
            })
    }

    @ViewBuilder
    private func sheetContent(_ sheet: LiveSheet) -> some View {
        switch sheet {
        case .composer:
            ComposerSheet(step: composer.step) {
                composerContent
            } onDismiss: {
                abandonComposer()
            }

        case .eventLog:
            NavigationStack {
                EventLogView(session: session)
            }

        case .review:
            NavigationStack { ReviewView(session: session) }

        case .lineup:
            NavigationStack { LineupEditorView(session: session) }

        case .opponentRoster:
            NavigationStack { OpponentRosterView(session: session) }

        case .adjustClock:
            NavigationStack { ClockAdjustmentView(session: session) }

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

        case .nearbyDisplay:
            NearbyAdvertiseSheet()
                .environment(appModel.nearby)

        case .addNote, .statsInspector:
            // Never rendered here: the alert and inspector modifiers above
            // own these cases. The switch stays exhaustive so a new case
            // cannot slip past the router silently.
            EmptyView()
        }
    }

    /// Broadcasts the current presentation snapshot when advertising.
    /// Cheap struct copy off the scoring path; sending is fire-and-forget.
    private func publishScoreboard() {
        guard appModel.nearby.advertising != .off else { return }
        appModel.nearby.publish(
            ScoreboardSnapshot.live(
                context: session.context, snapshot: session.snapshot,
                clock: session.context.clock))
    }

    private func closeScorer() {
        activeSheet = nil
        Task { await appModel.closeLiveSession() }
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
            ZStack {
                if composer.isComposing {
                    composerContent
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
            onOpponentPending: beginOpponent(_:),
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
        .clipped()
    }

    /// The composer itself, shared by the column and the sheet. One definition of
    /// each question, presented two ways.
    @ViewBuilder
    private var composerContent: some View {
        if let step = composer.step {
            ComposerStepContainer(step: step) {
                composerStepContent
            }
            .transition(LiveMotion.composerPresenceTransition(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private var composerStepContent: some View {
        switch composer.step {
        case .choosePlayer(let prompt):
            PlayerPickerStage(
                title: prompt.title,
                players: session.candidates(
                    for: prompt.action.attributionCategory, side: prompt.side),
                goalkeeperID: prompt.side == .us ? session.snapshot.activeGoalkeeper : nil,
                allowsUnknown: prompt.action.allowsUnknown,
                unknownTitle:
                    prompt.side == .us || session.descriptor.tracking == .bothTeams
                    ? "Player Unknown"
                    : "\(session.descriptor.opponentShortName) — No Player",
                unknownSubtitle:
                    prompt.side == .us || session.descriptor.tracking == .bothTeams
                    ? "Record now, attribute later"
                    : "Count it for the team only",
                showsTips: session.showsContextualTips,
                onPick: { complete(prompt.action, side: prompt.side, with: $0) },
                onCancel: { composer.finish() }
            )

        case .shotOutcome(let shooter, let side, let context):
            ShotOutcomeStage(
                shooterName: session.context.roster(for: side).label(for: shooter),
                context: context,
                onPick: { outcome in
                    resolve(outcome: outcome, shooter: shooter, side: side, context: context)
                },
                onCancel: { composer.finish() }
            )

        case .assist(let goalID, let scorerName, let side):
            AssistPickerStage(
                scorerName: scorerName,
                players: session.candidates(for: .assist, side: side)
                    .filter { $0.id != scorerID(of: goalID) },
                onPick: { assist in
                    // `nil` is "unassisted" and settles the goal; `.unidentified`
                    // deliberately leaves it in Review. Either way, the goal
                    // still has optional enrichment left, starting with where
                    // it was struck.
                    session.resolveAssist(assist, on: goalID)
                    continueAfterAssist(goalID: goalID, side: side)
                },
                onSkip: {
                    // Deferring the assist must not suppress the remaining
                    // optional enrichment. The goal stays in Review while the
                    // scorer can keep filling in Advanced detail.
                    continueAfterAssist(goalID: goalID, side: side)
                }
            )

        case .shotLocation(let shotID, let shooterName, let outcome):
            ShotLocationStage(
                shooterName: shooterName,
                outcome: outcome,
                markers: session.shotMarkers,
                presentation: composerUsesSheet ? .compactSheet : .inline,
                onCommit: { location in
                    session.resolveShotLocation(location, on: shotID)
                    continueShotEnrichment(shotID: shotID, after: .location)
                }
            )

        case .shotBodyPart(let shotID, let shooterName, let outcome):
            ShotBodyPartStage(
                shooterName: shooterName,
                outcome: outcome,
                onCommit: { bodyPart in
                    session.resolveShotBodyPart(bodyPart, on: shotID)
                    continueShotEnrichment(shotID: shotID, after: .bodyPart)
                }
            )

        case .shotPhase(let shotID, let shooterName, let outcome, let currentPhase):
            ShotPhaseStage(
                shooterName: shooterName,
                outcome: outcome,
                currentPhase: currentPhase,
                onCommit: { phase in
                    session.resolveShotPhase(phase, on: shotID)
                    composer.finish()
                }
            )

        case .cardReason(let cardID, let playerName, let type):
            CardReasonStage(
                playerName: playerName,
                type: type,
                onCommit: { reason in
                    session.resolveCardReason(reason, on: cardID)
                    composer.finish()
                }
            )

        case .substitution:
            SubstitutionStage(
                session: session,
                presentation: composerUsesSheet ? .navigation : .columns,
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
            recordShot(
                ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved),
                side: .opponent)
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
            recordGoal(shooter: .untracked, phase: .penaltyKick, side: .opponent)
        case .opponentCard:
            complete(.card(.yellow), side: .opponent, with: .untracked)
        case .addNote:
            activeSheet = .addNote
        }
    }

    private func handleOpponent(_ quick: OpponentQuickAction) {
        let action: PendingAction =
            switch quick {
            case .goal:
                .goal(.openPlay)
            case .shot:
                // Our Team keeps its one-tap team-total shortcut. Both Teams
                // asks for the player and the real outcome.
                session.descriptor.tracking == .bothTeams
                    ? .shotAttempt(.openPlay)
                    : .shot(.offTarget)
            case .corner:
                .corner
            }
        beginOpponent(action)
    }

    /// The opponent uses the same action -> player -> event composer as our side.
    /// Both Teams never silently degrades to team totals when its roster is
    /// missing; that would create data that contradicts the selected mode.
    private func beginOpponent(_ action: PendingAction) {
        guard session.context.hasStarted else {
            session.show(
                notice: LiveNotice(text: "The match hasn't kicked off yet.", kind: .warning))
            return
        }

        guard session.descriptor.tracking == .bothTeams else {
            complete(action, side: .opponent, with: .untracked)
            return
        }

        guard !session.context.opponentRoster.players.isEmpty else {
            session.show(
                notice: LiveNotice(
                    text: "Add the opponent roster before recording player-level opponent events.",
                    kind: .warning))
            return
        }

        composer.ask(.choosePlayer(PlayerPrompt(action: action, side: .opponent)))
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
        case .shot: begin(.shotAttempt(.openPlay))
        case .save:
            recordShot(
                ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved),
                side: .opponent)
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
        case .shotAttempt(let phase):
            // The outcome is a primary fact, not enrichment: a shot whose
            // outcome is unknown is a score that may or may not have happened.
            // Nothing is recorded until the scorer answers.
            composer.ask(
                .shotOutcome(shooter: ref, side: side, context: ShotOutcomeContext(phase: phase)))

        case .goal(let phase):
            recordGoal(shooter: ref, phase: phase, side: side)

        case .ownGoal:
            let shot = ShotEvent(side: side, shooter: ref, outcome: .goal, isOwnGoal: true)
            guard let shotID = session.recordReturningID(.recordShot(shot), feedback: .goal) else {
                composer.finish()
                return
            }
            offerShotEnrichment(for: shot, id: shotID, side: side)

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
            guard
                let cardID = session.recordReturningID(
                    .recordCard(CardEvent(side: side, player: ref, card: type)))
            else {
                composer.finish()
                return
            }
            composer.offerCardReason(
                card: cardID,
                playerName: session.context.roster(for: side).label(for: ref),
                type: type,
                profile: session.profile)

        case .goalkeeper:
            session.run(.changeGoalkeeper(side: side, goalkeeper: ref))
            composer.finish()
        }
    }

    /// The scorer answered *what happened?*, and there is exactly one path from
    /// here for each answer.
    ///
    /// A goal is a goal however the scorer arrived at it. Choosing Goal here goes
    /// through the same `recordGoal` the Goal button uses — same event, same
    /// score, same feedback, same assist handling — rather than appending a
    /// second kind of goal that happens to look like one.
    private func resolve(
        outcome: ShotOutcome, shooter: PlayerRef, side: TeamSide, context: ShotOutcomeContext
    ) {
        guard outcome.isGoal else {
            recordShot(
                ShotEvent(side: side, shooter: shooter, outcome: outcome, phase: context.phase),
                side: side)
            return
        }
        recordGoal(shooter: shooter, phase: context.phase, side: side)
    }

    /// A goal is a goal the moment the scorer says so.
    ///
    /// The event is written, the score moves, the journal is flushed and the goal
    /// feedback fires *before* the assist question is asked. The assist is
    /// recorded as unresolved so that walking away leaves a correct goal and one
    /// Review item, rather than no goal at all.
    private func recordGoal(shooter: PlayerRef, phase: PlayPhase, side: TeamSide) {
        // A penalty goal is never assisted, so Programme does not ask.
        let asksAssist =
            phase != .penaltyKick
            && session.profile.prompts.assistOnGoal
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
            // Nothing to attribute, so the optional map is the only thing left
            // worth offering — the same enrichment every other shot gets.
            offerShotEnrichment(for: shot, id: goalID, side: side)
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
        offerShotEnrichment(for: shot, id: shotID, side: side)
    }

    /// Optional enrichment on an event that already exists. Walking away from
    /// any of these questions leaves the primary shot intact.
    private func offerShotEnrichment(
        for shot: ShotEvent,
        id: EventID,
        side: TeamSide,
        startingAt step: ShotEnrichmentStep = .location
    ) {
        composer.offerShotEnrichment(
            shot: id,
            shooterName: session.context.roster(for: side).label(for: shot.shooter),
            outcome: shot.outcome,
            currentPhase: shot.phase,
            side: side,
            tracking: session.descriptor.tracking,
            profile: session.profile,
            startingAt: step)
    }

    private func continueShotEnrichment(shotID: EventID, after step: ShotEnrichmentStep) {
        guard
            let event = session.context.events.first(where: { $0.id == shotID }),
            case .shot(let shot) = event.payload
        else {
            composer.finish()
            return
        }

        let next: ShotEnrichmentStep
        switch step {
        case .location: next = .bodyPart
        case .bodyPart: next = .playPhase
        case .playPhase:
            composer.finish()
            return
        }
        offerShotEnrichment(for: shot, id: shotID, side: shot.side, startingAt: next)
    }

    /// Assist attribution is only the first optional detail on an Advanced goal.
    private func continueAfterAssist(goalID: EventID, side: TeamSide) {
        guard
            let event = session.context.events.first(where: { $0.id == goalID }),
            case .shot(let shot) = event.payload
        else {
            composer.finish()
            return
        }
        offerShotEnrichment(for: shot, id: goalID, side: side)
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
    let step: ComposerStep?
    @ViewBuilder var content: Content
    var onDismiss: () -> Void

    var body: some View {
        Group {
            if step?.providesOwnNavigation == true {
                // A step that is a flow rather than a question brings its own
                // `NavigationStack`, title, subtitle and actions. Wrapping it in
                // a second stack here would nest one inside the other and turn
                // its pushes into a broken back stack.
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle(step?.title ?? "")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            if step?.ownsSheetActions != true {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { onDismiss() }
                                        .accessibilityIdentifier("composer.done")
                                }
                            }
                        }
                }
            }
        }
        // A real system page presentation rather than a panel floating in the
        // middle of the screen. On a phone `.page` is the full-width, full-height
        // sheet; on a regular-width window the system still insets it sensibly.
        .presentationSizing(.page)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("composer.sheet")
    }
}

/// Shared Composer-step host for the regular workspace and the compact sheet.
///
/// The first question uses the restrained Composer presence transition owned by
/// its parent. Once the host is present, changing its semantic step moves the
/// new question in from the trailing edge and the previous question out toward
/// the leading edge. The host's state keeps that distinction without delaying
/// any Composer state change.
private struct ComposerStepContainer<Content: View>: View {
    let step: ComposerStep
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    init(step: ComposerStep, @ViewBuilder content: () -> Content) {
        self.step = step
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .id(step.transitionID)
                .transition(
                    hasAppeared
                        ? LiveMotion.composerStepTransition(reduceMotion: reduceMotion)
                        : .identity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear { hasAppeared = true }
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
                        .id(player.id)
                        .transition(
                            LiveMotion.acknowledgementTransition(
                                reduceMotion: reduceMotion))
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
