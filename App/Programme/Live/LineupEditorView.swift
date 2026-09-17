import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// Which half of the editor a player is in.
enum LineupGroup: String, Hashable, Sendable, CaseIterable, Identifiable {
    case field
    case bench

    var id: String { rawValue }

    var title: String {
        switch self {
        case .field: "Starting Lineup"
        case .bench: "Bench"
        }
    }
}

/// Choosing who starts.
///
/// On a landscape iPad the two groups sit side by side, because that is the
/// question being asked: *these* eleven, and *those* substitutes. A narrow window
/// stacks them.
///
/// Every drag has a plain tap equivalent. A drag is not reachable with VoiceOver
/// or Switch Control, and setting the lineup is not an optional step.
struct LineupEditorView: View {
    let session: LiveMatchSession

    @Environment(\.dismiss) private var dismiss
    @State private var onField: [PlayerID] = []
    @State private var goalkeeper: PlayerID?
    @State private var formationID: String?
    @State private var dropTarget: LineupGroup?

    private var bench: [PlayerSnapshot] {
        session.roster.activeRoster.filter { !onField.contains($0.id) }
    }

    private var fieldPlayers: [PlayerSnapshot] {
        onField.compactMap { session.roster[$0] }
    }

    var body: some View {
        LineupReorderContainer(move: move(_:to:before:)) {
            ViewThatFits(in: .horizontal) {
                sideBySide
                stacked
            }
        }
        .safeAreaBar(edge: .top) { statusBar }
        .navigationTitle("Starting Lineup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("Fill", systemImage: "wand.and.sparkles") {
                    Button("Use Last Lineup", systemImage: "clock.arrow.circlepath") { fillFromLast() }
                        .disabled(session.snapshot.timeline.starters[.us]?.isEmpty != false)
                    Button("Fill by Jersey Number", systemImage: "number") { fillByNumber() }
                    Button("Clear", systemImage: "xmark.circle", role: .destructive) {
                        onField = []
                        goalkeeper = nil
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Confirm") { confirm() }
                    .disabled(!isValid)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("lineup.confirm")
                    .programmeConfirmationTint()
            }
        }
        .sensoryFeedback(.selection, trigger: onField)
        .sensoryFeedback(.selection, trigger: goalkeeper)
        .onAppear(perform: load)
    }

    // MARK: - Layout

    /// The landscape arrangement: both groups visible, each scrolling on its own.
    private var sideBySide: some View {
        HStack(alignment: .top, spacing: 16) {
            column(.field)
                .frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity)
            column(.bench)
                .frame(minWidth: 260, idealWidth: 260, maxWidth: .infinity)
        }
        .padding(18)
    }

    private var stacked: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                columnBody(.field)
                columnBody(.bench)
            }
            .padding(18)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.descriptor.title).font(.headline)
                Text(
                    "\(session.descriptor.kickoff.matchDayText) · \(session.rules.name) · \(session.profile.name)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Formation", selection: $formationID) {
                Text("No formation").tag(String?.none)
                ForEach(Formation.presets(playersPerSide: session.rules.playersPerSide)) { formation in
                    Text(formation.name).tag(String?.some(formation.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Formation, optional")
            Spacer()
            goalkeeperStatus
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
    }

    /// A lineup with nobody in goal cannot be confirmed, so the editor says which
    /// one thing is missing rather than leaving Confirm inexplicably dimmed.
    @ViewBuilder
    private var goalkeeperStatus: some View {
        if let keeper = goalkeeper, let player = session.roster[keeper] {
            Label("\(player.shortLabel) in goal", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("lineup.goalkeeper")
        } else {
            Label("Choose a goalkeeper", systemImage: "hand.raised")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Programme.Palette.caution)
                .accessibilityIdentifier("lineup.goalkeeper")
                .accessibilityHint(
                    "Touch and hold a player in the starting lineup, then choose Make Goalkeeper.")
        }
    }

    private func column(_ group: LineupGroup) -> some View {
        ScrollView {
            columnBody(group)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func columnBody(_ group: LineupGroup) -> some View {
        let players = group == .field ? fieldPlayers : bench
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title).programmeSectionHeader()
                Spacer()
                Text(subtitle(for: group, count: players.count))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(
                        group == .field && players.count != session.rules.playersPerSide
                            ? Programme.Palette.caution : .secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132, maximum: 200), spacing: 10)], spacing: 10
            ) {
                if #available(iOS 27.0, *) {
                    // The system's own reordering: one container, two collections,
                    // drags within and between them, and the same lift, spacing
                    // and drop behaviour as every other iPadOS 27 collection.
                    ForEach(players) { player in
                        tile(player, group: group)
                    }
                    .reorderable(collectionID: group)
                } else {
                    ForEach(players) { player in
                        tile(player, group: group)
                            .draggable(player.id.rawValue.uuidString) {
                                Text(player.shortLabel).padding(8)
                            }
                    }
                }
                if players.isEmpty {
                    Text(group == .field ? "Tap players on the bench to add them." : "Everyone is in the lineup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(dropTarget == group ? Color.accentColor : .clear, lineWidth: 2)
            )
            .animation(.snappy(duration: 0.15), value: dropTarget)
            .modifier(LegacyDropTarget(group: group, dropTarget: $dropTarget, move: move(identifiers:to:)))
        }
    }

    private func subtitle(for group: LineupGroup, count: Int) -> String {
        group == .field ? "\(count) of \(session.rules.playersPerSide)" : "\(count) available"
    }

    private func tile(_ player: PlayerSnapshot, group: LineupGroup) -> some View {
        LineupTile(
            player: player,
            isGoalkeeper: goalkeeper == player.id,
            isOnField: group == .field,
            onToggle: { toggle(player) },
            onMakeGoalkeeper: { makeGoalkeeper(player) }
        )
    }

    // MARK: - Logic

    private var isValid: Bool {
        onField.count >= session.rules.minimumPlayersPerSide
            && onField.count <= session.rules.playersPerSide
            && goalkeeper.map { onField.contains($0) } ?? false
    }

    private func load() {
        let current = session.snapshot.activeLineup
        if !current.isEmpty {
            onField = session.roster.sortedByNumber.filter { current.contains($0.id) }.map(\.id)
            goalkeeper = session.snapshot.activeGoalkeeper
        } else {
            fillByNumber()
        }
        formationID = session.context.startingFormation?.id
    }

    private func toggle(_ player: PlayerSnapshot) {
        if onField.contains(player.id) {
            remove(player.id)
        } else {
            add(player.id, before: nil)
        }
    }

    private func add(_ id: PlayerID, before: PlayerID?) {
        guard !onField.contains(id) else { return }
        guard onField.count < session.rules.playersPerSide else {
            session.show(
                notice: LiveNotice(
                    text: "That would be \(onField.count + 1) players. Remove one first.",
                    kind: .warning))
            return
        }
        if let before, let index = onField.firstIndex(of: before) {
            onField.insert(id, at: index)
        } else {
            onField.append(id)
        }
        if goalkeeper == nil, session.roster[id]?.position == .goalkeeper { goalkeeper = id }
    }

    private func remove(_ id: PlayerID) {
        onField.removeAll { $0 == id }
        if goalkeeper == id {
            // Moving the goalkeeper out leaves the lineup invalid on purpose:
            // Confirm stays disabled and the status bar asks for a replacement,
            // rather than letting a match start with nobody in goal.
            goalkeeper = nil
            session.show(
                notice: LiveNotice(
                    text: "That was your goalkeeper. Choose who takes the gloves before confirming.",
                    kind: .warning))
        }
    }

    private func makeGoalkeeper(_ player: PlayerSnapshot) {
        if !onField.contains(player.id) {
            guard onField.count < session.rules.playersPerSide else {
                session.show(
                    notice: LiveNotice(
                        text: "The lineup is full. Move someone to the bench first.", kind: .warning))
                return
            }
            onField.append(player.id)
        }
        goalkeeper = player.id
    }

    /// The iPadOS 27 reorder callback, and the shape everything else funnels into.
    private func move(_ sources: [PlayerID], to group: LineupGroup, before: PlayerID?) {
        for id in sources {
            switch group {
            case .field:
                if let index = onField.firstIndex(of: id) {
                    // A reorder inside the starting lineup.
                    onField.remove(at: index)
                    if let before, let target = onField.firstIndex(of: before) {
                        onField.insert(id, at: target)
                    } else {
                        onField.append(id)
                    }
                } else {
                    add(id, before: before)
                }
            case .bench:
                remove(id)
            }
        }
    }

    /// The iPadOS 26 drop path, which speaks in item provider strings.
    private func move(identifiers: [String], to group: LineupGroup) {
        let ids = identifiers.compactMap { UUID(uuidString: $0).map(PlayerID.init) }
        move(ids, to: group, before: nil)
    }

    private func fillByNumber() {
        let roster = session.roster.activeRoster
        let keeper = roster.first { $0.position == .goalkeeper }
        var selection = keeper.map { [$0] } ?? []
        for player in roster where player.id != keeper?.id {
            guard selection.count < session.rules.playersPerSide else { break }
            selection.append(player)
        }
        onField = selection.map(\.id)
        goalkeeper = keeper?.id ?? selection.first?.id
    }

    private func fillFromLast() {
        guard let starters = session.snapshot.timeline.starters[.us], !starters.isEmpty else { return }
        onField = session.roster.sortedByNumber.filter { starters.contains($0.id) }.map(\.id)
        goalkeeper = session.snapshot.timeline.goalkeeper(side: .us, at: .kickoff)
    }

    private func confirm() {
        session.setStartingLineup(onField, goalkeeper: goalkeeper, formationID: formationID)
        dismiss()
    }
}

/// The iPadOS 27 reorder container, isolated so no leaf view has to know the
/// platform differs.
///
/// On iPadOS 26 this is transparent and the columns fall back to
/// `draggable`/`dropDestination`, which stays in the file unchanged.
private struct LineupReorderContainer<Content: View>: View {
    let move: (_ sources: [PlayerID], _ group: LineupGroup, _ before: PlayerID?) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 27.0, *) {
            content
                .reorderContainer(for: PlayerSnapshot.self, in: LineupGroup.self) { difference in
                    switch difference.destination.position {
                    case .before(let id):
                        move(difference.sources, difference.destination.collectionID, id)
                    case .end:
                        move(difference.sources, difference.destination.collectionID, nil)
                    }
                }
        } else {
            content
        }
    }
}

/// `dropDestination` is only wired up where `reorderable` is not available, so
/// the two never compete for the same drag.
private struct LegacyDropTarget: ViewModifier {
    let group: LineupGroup
    @Binding var dropTarget: LineupGroup?
    let move: (_ identifiers: [String], _ group: LineupGroup) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content
        } else {
            content.dropDestination(for: String.self) { items, _ in
                move(items, group)
                return true
            } isTargeted: { targeted in
                dropTarget = targeted ? group : (dropTarget == group ? nil : dropTarget)
            }
        }
    }
}

struct LineupTile: View {
    let player: PlayerSnapshot
    let isGoalkeeper: Bool
    let isOnField: Bool
    var onToggle: () -> Void
    var onMakeGoalkeeper: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(player.jerseyNumber.map(String.init) ?? "–")
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .frame(minWidth: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.displaySurname)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(player.position?.abbreviation ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isGoalkeeper {
                Image(systemName: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Image(systemName: isOnField ? "minus.circle" : "plus.circle")
                .font(.title3)
                .foregroundStyle(isOnField ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 56)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .contextMenu {
            Button(
                isOnField ? "Move to Bench" : "Add to Lineup", systemImage: isOnField ? "minus.circle" : "plus.circle",
                action: onToggle)
            Button("Make Goalkeeper", systemImage: "hand.raised", action: onMakeGoalkeeper)
        }
        .accessibilityIdentifier(
            "lineup.\(player.jerseyNumber.map(String.init) ?? player.displaySurname)"
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player.accessibilityLabel)
        .accessibilityValue(isGoalkeeper ? "goalkeeper, in the lineup" : (isOnField ? "in the lineup" : "on the bench"))
        .accessibilityHint(isOnField ? "Double tap to move to the bench." : "Double tap to add to the lineup.")
        .accessibilityAction(named: "Make goalkeeper", onMakeGoalkeeper)
    }
}
