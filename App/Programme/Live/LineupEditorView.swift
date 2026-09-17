import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// Choosing who starts.
///
/// Drag and drop works between the two columns, and every drag has a plain tap
/// equivalent, because a drag is not reachable with VoiceOver or Switch Control
/// and this is not an optional step.
struct LineupEditorView: View {
    let session: LiveMatchSession

    @Environment(\.dismiss) private var dismiss
    @State private var onField: [PlayerID] = []
    @State private var goalkeeper: PlayerID?
    @State private var formationID: String?
    @State private var dropTargetIsField = false

    private var bench: [PlayerSnapshot] {
        session.roster.activeRoster.filter { !onField.contains($0.id) }
    }

    private var fieldPlayers: [PlayerSnapshot] {
        onField.compactMap { session.roster[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    column(
                        title: "Starting Lineup",
                        subtitle: "\(onField.count) of \(session.rules.playersPerSide)",
                        players: fieldPlayers,
                        isField: true)
                    column(
                        title: "Bench",
                        subtitle: "\(bench.count) available",
                        players: bench,
                        isField: false)
                }
                .padding(18)
            }
        }
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
            }
        }
        .onAppear(perform: load)
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
            if let keeper = goalkeeper, let player = session.roster[keeper] {
                Label("\(player.shortLabel) in goal", systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Label("Choose a goalkeeper", systemImage: "hand.raised")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Programme.Palette.caution)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func column(title: String, subtitle: String, players: [PlayerSnapshot], isField: Bool)
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).programmeSectionHeader()
                Spacer()
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(
                        isField && players.count != session.rules.playersPerSide
                            ? Programme.Palette.caution : .secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 200), spacing: 10)], spacing: 10) {
                ForEach(players) { player in
                    LineupTile(
                        player: player,
                        isGoalkeeper: goalkeeper == player.id,
                        isOnField: isField,
                        onToggle: { toggle(player) },
                        onMakeGoalkeeper: { makeGoalkeeper(player) }
                    )
                    .draggable(player.id.rawValue.uuidString) {
                        Text(player.shortLabel).padding(8)
                    }
                }
                if players.isEmpty {
                    Text(isField ? "Tap players below to add them." : "Everyone is in the lineup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isField && dropTargetIsField ? Color.accentColor : .clear, lineWidth: 2)
            )
            .dropDestination(for: String.self) { items, _ in
                move(identifiers: items, toField: isField)
                return true
            } isTargeted: { targeted in
                if isField { dropTargetIsField = targeted }
            }
        }
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
        Haptics.selectionChanged()
        if let index = onField.firstIndex(of: player.id) {
            onField.remove(at: index)
            if goalkeeper == player.id { goalkeeper = nil }
        } else {
            guard onField.count < session.rules.playersPerSide else {
                session.show(
                    notice: LiveNotice(
                        text: "That would be \(onField.count + 1) players. Remove one first.",
                        kind: .warning))
                return
            }
            onField.append(player.id)
            if goalkeeper == nil && player.position == .goalkeeper { goalkeeper = player.id }
        }
    }

    private func makeGoalkeeper(_ player: PlayerSnapshot) {
        if !onField.contains(player.id) {
            guard onField.count < session.rules.playersPerSide else { return }
            onField.append(player.id)
        }
        goalkeeper = player.id
        Haptics.selectionChanged()
    }

    private func move(identifiers: [String], toField: Bool) {
        for identifier in identifiers {
            guard let uuid = UUID(uuidString: identifier) else { continue }
            let id = PlayerID(uuid)
            if toField {
                guard !onField.contains(id), onField.count < session.rules.playersPerSide else { continue }
                onField.append(id)
                if goalkeeper == nil, session.roster[id]?.position == .goalkeeper { goalkeeper = id }
            } else {
                onField.removeAll { $0 == id }
                if goalkeeper == id { goalkeeper = nil }
            }
        }
        Haptics.selectionChanged()
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
            Button(isOnField ? "Move to Bench" : "Add to Lineup", systemImage: isOnField ? "minus.circle" : "plus.circle", action: onToggle)
            Button("Make Goalkeeper", systemImage: "hand.raised", action: onMakeGoalkeeper)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player.accessibilityLabel)
        .accessibilityValue(isGoalkeeper ? "goalkeeper, in the lineup" : (isOnField ? "in the lineup" : "on the bench"))
        .accessibilityHint(isOnField ? "Double tap to move to the bench." : "Double tap to add to the lineup.")
        .accessibilityAction(named: "Make goalkeeper", onMakeGoalkeeper)
    }
}
