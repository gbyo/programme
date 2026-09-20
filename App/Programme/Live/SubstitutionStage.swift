import ProgrammeCore
import ProgrammeUI
import SwiftUI
import TipKit

/// Substitution, built around the relationship a scorer actually holds in their
/// head: **one player comes off, and one specific player comes on for them.**
///
/// The draft is a list of pairs (`SubstitutionPlan` in ProgrammeCore), not two
/// unrelated selections. Several pairs are still committed as one event at one
/// match time — high-school substitutions arrive in groups — and the pairs are
/// flattened into the event's ordered `playersOut` / `playersIn` arrays so
/// `playersOut[n]` is the player `playersIn[n]` replaced.
///
/// Two presentations, one draft:
///
/// - **Navigation** (iPhone, and any compact window): "Who is coming off?" →
///   "Coming On" → back to the list, ready for the next pair.
/// - **Columns** (regular-width iPad): Coming Off beside Coming On, where the
///   right-hand column only ever answers *for whom*.
struct SubstitutionStage: View {
    enum Presentation {
        /// A pushed flow inside a sheet. One question per screen.
        case navigation
        /// Two lists side by side, where there is room to see the field and the
        /// bench at once.
        case columns
    }

    let session: LiveMatchSession
    var presentation: Presentation
    var onCommit: (_ out: [PlayerID], _ in: [PlayerID], _ goalkeeper: PlayerID?) -> Void
    var onCancel: () -> Void

    @State private var plan = SubstitutionPlan()

    var body: some View {
        Group {
            switch presentation {
            case .navigation:
                SubstitutionNavigationStage(
                    session: session, plan: $plan, onCommit: commit, onCancel: onCancel)
            case .columns:
                SubstitutionColumnsStage(
                    session: session, plan: $plan, onCommit: commit, onCancel: onCancel)
            }
        }
        // View-state selection is a declarative fact about this screen, so the
        // feedback for it is declarative too. Recording the event stays
        // imperative in the session, where the domain meaning lives.
        .programmeSensoryFeedback(.selection, trigger: plan)
        .onAppear { Task { await MultiSubstitutionTip.didOpenSubstitution.donate() } }
    }

    /// Nothing about the live lineup has moved while the draft was assembled.
    /// It moves here, once, as a single event at the current match time.
    private func commit() {
        onCommit(
            plan.playersOut,
            plan.playersIn,
            plan.resolvedGoalkeeperAfter(currentGoalkeeper: session.snapshot.activeGoalkeeper))
    }
}

// MARK: - Shared draft vocabulary

/// The part of the draft every presentation needs, derived from live lineup
/// state rather than from the roster — which is what keeps high-school
/// re-entry working: a player substituted off ten minutes ago is on the bench
/// now, so the bench offers them again.
@MainActor
private struct SubstitutionContext {
    let onField: [PlayerSnapshot]
    let bench: [PlayerSnapshot]
    let goalkeeper: PlayerID?

    init(session: LiveMatchSession) {
        onField = session.onFieldPlayers
        bench = session.benchPlayers
        goalkeeper = session.snapshot.activeGoalkeeper
    }

    var onFieldIDs: Set<PlayerID> { Set(onField.map(\.id)) }
}

extension LiveMatchSession {
    /// "1st · 24:18" — where the batch will be recorded.
    var substitutionSubtitle: String {
        let period = clock.periodShortLabel
        return period.isEmpty ? clock.displayText : "\(period) · \(clock.displayText)"
    }

    func label(for player: PlayerID) -> String {
        roster[player]?.shortLabel ?? "Unknown"
    }
}

/// Concise enough for a toolbar, honest about how many changes are pending.
private func recordTitle(for count: Int) -> String {
    count > 1 ? "Record \(count)" : "Record"
}

extension View {
    /// Rows here state their own height, so the list must not add its default
    /// vertical padding on top of it: that is half a row again each time, and it
    /// pushes the back of the squad below the fold on a phone.
    ///
    /// This has to be applied to the row itself — the `NavigationLink` or the
    /// `Button` — because a modifier applied inside the row's *label* never
    /// reaches the list row containing it.
    fileprivate func substitutionRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

// MARK: - Rows

/// A player as one large list row: a fixed-width jersey number so names align
/// into a column the eye can run down, the name, and a quiet marker for the
/// current goalkeeper.
///
/// A row, not a card. The list draws the separators, the pressed state and the
/// hover highlight, and the whole row is the target.
struct SubstitutionPlayerRow: View {
    let player: PlayerSnapshot
    var isGoalkeeper = false
    var isSelected = false
    var situation: String
    /// Carried by the row rather than by whatever wraps it: combining the
    /// children into one accessibility element replaces the container's own,
    /// and an identifier set outside that does not reach the result.
    var identifier: String

    @ScaledMetric(relativeTo: .title3) private var jerseyWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat =
        Programme.Metrics.playerRowHeight

    var body: some View {
        HStack(spacing: 12) {
            Text(player.jerseyNumber.map(String.init) ?? "–")
                .font(.programmeJersey(22))
                .frame(minWidth: jerseyWidth, alignment: .trailing)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))

            Text(player.displaySurname)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .lineLimit(2)

            Spacer(minLength: 4)

            if isGoalkeeper {
                Text("GK")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            // Selection is never carried by colour alone.
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .contentShape(.rect)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }

    private var accessibilityLabel: String {
        var parts = [player.accessibilityLabel, situation]
        if isGoalkeeper { parts.append("goalkeeper") }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// One completed relationship: "#13 Ferrer for #11 Trotter".
///
/// The incoming player leads and carries the weight, because the thing the
/// scorer is checking is *who is now on*.
struct PendingSubstitutionRow: View {
    let incoming: PlayerSnapshot?
    let outgoing: PlayerSnapshot?
    var identifier: String

    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44

    var body: some View {
        // One run of text rather than a row of views, so it wraps and scales
        // by itself at any text size and neither player's identity can be
        // squeezed out by the other.
        (inText + forText + outText)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .contentShape(.rect)
            .hoverEffect(.highlight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(incoming?.displaySurname ?? "Unknown") replacing \(outgoing?.displaySurname ?? "Unknown")"
            )
            .accessibilityIdentifier(identifier)
    }

    /// The incoming player leads and carries the weight: what the scorer is
    /// checking is who is now on.
    private var inText: Text {
        Text(incoming?.shortLabel ?? "Unknown")
            .font(.body.weight(.semibold))
            .monospacedDigit()
    }

    private var forText: Text {
        Text(" for ")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
    }

    private var outText: Text {
        Text(outgoing?.shortLabel ?? "Unknown")
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

// MARK: - Navigation presentation (iPhone and any compact window)

/// "Who is coming off?" is the whole root screen.
///
/// Choosing someone pushes the one question that follows from it, and answering
/// that question returns here with the pair recorded in the draft — so the next
/// substitution starts immediately and there is never an "add another" tap.
private struct SubstitutionNavigationStage: View {
    let session: LiveMatchSession
    @Binding var plan: SubstitutionPlan
    var onCommit: () -> Void
    var onCancel: () -> Void

    @State private var path: [Route] = []
    private let multiSubTip = MultiSubstitutionTip()

    private enum Route: Hashable {
        case comingOn(PlayerID)
        case goalkeeper
    }

    private var lineup: SubstitutionContext { SubstitutionContext(session: session) }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationTitle("Substitution")
                .navigationSubtitle(session.substitutionSubtitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { onCancel() }
                            .accessibilityIdentifier("sub.cancel")
                    }
                    // Always rendered, never conditional. Nothing in a
                    // Programme bar appears or disappears with availability —
                    // a control that comes and goes moves the ones beside it,
                    // and a toolbar item materialising while the stack is
                    // popping is its own kind of trouble.
                    ToolbarItem(placement: .confirmationAction) {
                        Button(recordTitle(for: plan.count)) { onCommit() }
                            .programmeConfirmationTint()
                            .disabled(!plan.isReadyToRecord(currentGoalkeeper: lineup.goalkeeper))
                            .accessibilityIdentifier("sub.commit")
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .comingOn(let playerOut): comingOn(for: playerOut)
                    case .goalkeeper: goalkeeperScreen
                    }
                }
        }
    }

    private var root: some View {
        List {
            if !plan.isEmpty {
                Section("Ready") {
                    ForEach(plan.pairs) { pair in
                        Button {
                            path = [.comingOn(pair.playerOut)]
                        } label: {
                            PendingSubstitutionRow(
                                incoming: session.roster[pair.playerIn],
                                outgoing: session.roster[pair.playerOut],
                                identifier: "sub.pair.\(identifier(pair.playerOut))")
                        }
                        .buttonStyle(.plain)
                        .substitutionRowInsets()
                        .accessibilityHint("Choose a different player coming on.")
                        .swipeActions(edge: .trailing) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                plan.remove(outgoing: pair.playerOut, currentlyOnField: lineup.onFieldIDs)
                            }
                            .accessibilityIdentifier("sub.remove.\(identifier(pair.playerOut))")
                        }
                    }
                }
            }

            if plan.requiresGoalkeeperChoice(currentGoalkeeper: lineup.goalkeeper) {
                Section {
                    NavigationLink(value: Route.goalkeeper) {
                        GoalkeeperPromptRow(
                            chosen: plan.goalkeeperAfter.flatMap { session.roster[$0] })
                    }
                }
            }

            Section {
                ForEach(plan.availableOutgoing(from: lineup.onField)) { player in
                    NavigationLink(value: Route.comingOn(player.id)) {
                        SubstitutionPlayerRow(
                            player: player,
                            isGoalkeeper: lineup.goalkeeper == player.id,
                            situation: "on field",
                            identifier: "sub.out.\(identifier(player.id))")
                    }
                    .substitutionRowInsets()
                }
            } header: {
                Text(plan.isEmpty ? "Who Is Coming Off?" : "Another Player Coming Off")
            } footer: {
                if session.showsContextualTips {
                    TipView(multiSubTip)
                        .listRowInsets(EdgeInsets())
                        .padding(.top, 8)
                }
            }
        }
        .listStyle(.plain)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("sub.comingOff")
    }

    /// The second half of one relationship. Its subtitle is the relationship,
    /// so there is no way to answer it without knowing whom it is for.
    private func comingOn(for playerOut: PlayerID) -> some View {
        let candidates = plan.availableIncoming(from: lineup.bench, replacing: playerOut)
        let already = plan.pair(replacing: playerOut)?.playerIn
        return List {
            Section {
                ForEach(candidates) { player in
                    Button {
                        plan.assign(
                            out: playerOut, in: player.id, currentlyOnField: lineup.onFieldIDs)
                        advance()
                    } label: {
                        SubstitutionPlayerRow(
                            player: player,
                            isSelected: already == player.id,
                            situation: "on the bench",
                            identifier: "sub.in.\(identifier(player.id))")
                    }
                    .buttonStyle(.plain)
                    .substitutionRowInsets()
                }
                if candidates.isEmpty {
                    Text("Nobody is available on the bench.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Bench")
            }
        }
        .listStyle(.plain)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Coming On")
        .navigationSubtitle("For \(session.label(for: playerOut))")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sub.comingOn")
    }

    /// Who is in goal is a first-class question, not a row tucked under a
    /// picker. It is pushed the moment the batch takes the keeper off, because
    /// every later save is attributed from the answer.
    private var goalkeeperScreen: some View {
        List {
            Section {
                ForEach(plan.goalkeeperCandidates(onField: lineup.onField, bench: lineup.bench)) { player in
                    Button {
                        plan.setGoalkeeperAfter(player.id)
                        path = []
                    } label: {
                        GoalkeeperCandidateRow(
                            player: player,
                            isSelected: plan.goalkeeperAfter == player.id,
                            isArriving: plan.incoming.contains(player.id),
                            identifier: "sub.goalkeeper.\(identifier(player.id))")
                    }
                    .buttonStyle(.plain)
                    .substitutionRowInsets()
                }
            } header: {
                Text("On the Field After This Substitution")
            }
        }
        .listStyle(.plain)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Who Is in Goal?")
        .navigationSubtitle("\(session.label(for: lineup.goalkeeper ?? PlayerID())) is coming off")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sub.goalkeeperChoice")
    }

    /// Back to the root, unless the pair just made left Programme without a
    /// goalkeeper — in which case that is the next thing to answer.
    private func advance() {
        if plan.requiresGoalkeeperChoice(currentGoalkeeper: lineup.goalkeeper),
            plan.goalkeeperAfter == nil
        {
            path = [.goalkeeper]
        } else {
            path = []
        }
    }

    private func identifier(_ id: PlayerID) -> String {
        session.roster[id].map { $0.jerseyNumber.map(String.init) ?? $0.displaySurname } ?? "unknown"
    }
}

/// The root's standing reminder that the gloves are unaccounted for.
private struct GoalkeeperPromptRow: View {
    let chosen: PlayerSnapshot?

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Who is in goal?")
                        .font(.body.weight(.medium))
                    Text(chosen.map { "\($0.shortLabel) takes the gloves" } ?? "The goalkeeper is coming off")
                        .font(.subheadline)
                        .foregroundStyle(chosen == nil ? Programme.Palette.caution : .secondary)
                }
            } icon: {
                Image(systemName: chosen == nil ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                    .foregroundStyle(chosen == nil ? Programme.Palette.caution : Color.accentColor)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            chosen.map { "Goalkeeper after this substitution, \($0.accessibilityLabel)" }
                ?? "The goalkeeper is coming off. Choose who is in goal."
        )
        .accessibilityIdentifier("sub.goalkeeperPrompt")
    }
}

private struct GoalkeeperCandidateRow: View {
    let player: PlayerSnapshot
    let isSelected: Bool
    let isArriving: Bool
    let identifier: String

    var body: some View {
        SubstitutionPlayerRow(
            player: player,
            isGoalkeeper: player.position == .goalkeeper,
            isSelected: isSelected,
            situation: isArriving ? "coming on" : "staying on",
            identifier: identifier)
    }
}

// MARK: - Columns presentation (regular-width iPad)

/// Where the window can hold the field and the bench at once, it should — but
/// pair-aware, so the right-hand column is never a second independent list.
/// It answers one question at a time: *who comes on for the player you just
/// chose?*
private struct SubstitutionColumnsStage: View {
    let session: LiveMatchSession
    @Binding var plan: SubstitutionPlan
    var onCommit: () -> Void
    var onCancel: () -> Void

    @State private var activeOutgoing: PlayerID?
    private let multiSubTip = MultiSubstitutionTip()

    private var lineup: SubstitutionContext { SubstitutionContext(session: session) }

    private var needsGoalkeeper: Bool {
        plan.requiresGoalkeeperChoice(currentGoalkeeper: lineup.goalkeeper)
            && plan.goalkeeperAfter == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if session.showsContextualTips {
                TipView(multiSubTip)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 0) {
                comingOff
                Divider()
                comingOn
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Substitution")
                    .font(.title3.weight(.semibold))
                Text(session.substitutionSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityIdentifier("sub.cancel")
            Button(recordTitle(for: plan.count)) { onCommit() }
                .programmePrimaryAction()
                .disabled(!plan.isReadyToRecord(currentGoalkeeper: lineup.goalkeeper))
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityIdentifier("sub.commit")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// Ready and Coming Off share one list, as they do on the phone.
    ///
    /// A separate pane below the columns would need its height computed, and a
    /// `List` always fills what it is offered — so one row of pairs either
    /// stole four rows from the columns or got clipped by them. A section costs
    /// nothing and sizes itself.
    private var comingOff: some View {
        List {
            if !plan.isEmpty {
                Section {
                    ForEach(plan.pairs) { pair in
                        Button {
                            activeOutgoing = pair.playerOut
                        } label: {
                            PendingSubstitutionRow(
                                incoming: session.roster[pair.playerIn],
                                outgoing: session.roster[pair.playerOut],
                                identifier: "sub.pair.\(identifier(pair.playerOut))")
                        }
                        .buttonStyle(.plain)
                        .substitutionRowInsets()
                        .accessibilityHint("Choose a different player coming on.")
                        .swipeActions(edge: .trailing) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                if activeOutgoing == pair.playerOut { activeOutgoing = nil }
                                plan.remove(
                                    outgoing: pair.playerOut, currentlyOnField: lineup.onFieldIDs)
                            }
                            .accessibilityIdentifier("sub.remove.\(identifier(pair.playerOut))")
                        }
                    }
                } header: {
                    Text("Ready").programmeSectionHeader()
                }
            }

            Section {
                ForEach(plan.availableOutgoing(from: lineup.onField)) { player in
                    Button {
                        activeOutgoing = activeOutgoing == player.id ? nil : player.id
                    } label: {
                        SubstitutionPlayerRow(
                            player: player,
                            isGoalkeeper: lineup.goalkeeper == player.id,
                            isSelected: activeOutgoing == player.id,
                            situation: "on field",
                            identifier: "sub.out.\(identifier(player.id))")
                    }
                    .buttonStyle(.plain)
                    .substitutionRowInsets()
                    .listRowBackground(
                        activeOutgoing == player.id ? Color.accentColor.opacity(0.16) : nil
                    )
                }
            } header: {
                Text(plan.isEmpty ? "Coming Off" : "Another Player Coming Off")
                    .programmeSectionHeader()
            }
        }
        .listStyle(.plain)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("sub.comingOff")
    }

    @ViewBuilder
    private var comingOn: some View {
        if let playerOut = activeOutgoing {
            benchList(for: playerOut)
        } else if needsGoalkeeper {
            goalkeeperList
        } else {
            waiting
        }
    }

    private func benchList(for playerOut: PlayerID) -> some View {
        let candidates = plan.availableIncoming(from: lineup.bench, replacing: playerOut)
        return List {
            Section {
                ForEach(candidates) { player in
                    Button {
                        plan.assign(
                            out: playerOut, in: player.id, currentlyOnField: lineup.onFieldIDs)
                        activeOutgoing = nil
                    } label: {
                        SubstitutionPlayerRow(
                            player: player, situation: "on the bench",
                            identifier: "sub.in.\(identifier(player.id))")
                    }
                    .buttonStyle(.plain)
                    .substitutionRowInsets()
                }
                if candidates.isEmpty {
                    Text("Nobody is available on the bench.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Coming on for \(session.label(for: playerOut))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .textCase(nil)
                    .accessibilityIdentifier("sub.comingOn.header")
            }
        }
        .listStyle(.plain)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("sub.comingOn")
    }

    private var goalkeeperList: some View {
        List {
            Section {
                ForEach(plan.goalkeeperCandidates(onField: lineup.onField, bench: lineup.bench)) { player in
                    Button {
                        plan.setGoalkeeperAfter(player.id)
                    } label: {
                        GoalkeeperCandidateRow(
                            player: player,
                            isSelected: plan.goalkeeperAfter == player.id,
                            isArriving: plan.incoming.contains(player.id),
                            identifier: "sub.goalkeeper.\(identifier(player.id))")
                    }
                    .buttonStyle(.plain)
                    .substitutionRowInsets()
                }
            } header: {
                Label("Who is in goal?", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Programme.Palette.caution)
                    .textCase(nil)
            } footer: {
                Text("On the field after this substitution. Every later save is attributed from here.")
                    .font(.footnote)
            }
        }
        .listStyle(.plain)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("sub.goalkeeperChoice")
    }

    private var waiting: some View {
        VStack {
            Spacer(minLength: 0)
            ContentUnavailableView {
                Label("Choose a player coming off", systemImage: "arrow.left")
            } description: {
                Text("Then pick who comes on for them.")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("sub.comingOn.idle")
    }

    private func identifier(_ id: PlayerID) -> String {
        session.roster[id].map { $0.jerseyNumber.map(String.init) ?? $0.displaySurname } ?? "unknown"
    }
}
