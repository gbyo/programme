import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// Choosing the starters, their goalkeeper, and an optional formation.
///
/// The roster stays in jersey-number order. Selection is deliberately the
/// system List interaction rather than an ordering or tactics-board gesture:
/// Programme does not assign players to individual formation positions.
struct LineupEditorView: View {
    let session: LiveMatchSession

    @Environment(\.dismiss) private var dismiss
    @State var starters: Set<PlayerID> = []
    @State private var goalkeeper: PlayerID?
    @State private var formationID: String?

    private var roster: [PlayerSnapshot] { session.roster.activeRoster }

    private var selectedPlayers: [PlayerSnapshot] {
        roster.filter { starters.contains($0.id) }
    }

    var body: some View {
        List(selection: $starters) {
            Section("Setup") {
                goalkeeperPicker
                formationPicker
            }

            Section("Players") {
                ForEach(roster) { player in
                    playerRow(player)
                        .tag(player.id)
                        .selectionDisabled(
                            starters.count >= session.rules.playersPerSide
                                && !starters.contains(player.id)
                        )
                        .accessibilityIdentifier(
                            "lineup.\(player.jerseyNumber.map(String.init) ?? player.displaySurname)"
                        )
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .navigationTitle("Starting Lineup")
        .navigationSubtitle("\(starters.count) of \(session.rules.playersPerSide) selected")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sensoryFeedback(.selection, trigger: starters)
        .sensoryFeedback(.selection, trigger: goalkeeper)
        .onChange(of: starters, updateGoalkeeperAfterSelection)
        .onAppear(perform: load)
    }

    private var goalkeeperPicker: some View {
        Picker("Goalkeeper", selection: $goalkeeper) {
            Text("Choose Goalkeeper").tag(PlayerID?.none)
            ForEach(selectedPlayers) { player in
                Text(player.shortLabel).tag(PlayerID?.some(player.id))
            }
        } currentValueLabel: {
            if let goalkeeper, let player = session.roster[goalkeeper] {
                Text(player.shortLabel)
            } else {
                Text("Choose")
                    .foregroundStyle(Programme.Palette.caution)
            }
        }
        .pickerStyle(.navigationLink)
        .disabled(starters.isEmpty)
        .accessibilityIdentifier("lineup.goalkeeper")
    }

    private var formationPicker: some View {
        Picker("Formation", selection: $formationID) {
            Text("None").tag(String?.none)
            ForEach(Formation.presets(playersPerSide: session.rules.playersPerSide)) { formation in
                Text(formation.name).tag(String?.some(formation.id))
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Formation, optional")
    }

    private func playerRow(_ player: PlayerSnapshot) -> some View {
        HStack(spacing: 12) {
            Text(player.jerseyNumber.map(String.init) ?? "–")
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(minWidth: 28, alignment: .trailing)

            Text(player.displaySurname)
                .lineLimit(1)

            Spacer(minLength: 12)

            Text(goalkeeper == player.id ? "GK" : (player.position?.abbreviation ?? "—"))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player.accessibilityLabel)
        .accessibilityValue(accessibilityValue(for: player))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }

        if #available(iOS 27.0, *) {
            ToolbarOverflowMenu { secondaryActions }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .topBarPinnedTrailing) {
                confirmButton
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    secondaryActions
                } label: {
                    Label("Lineup Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("lineup.actions")
            }

            ToolbarItem(placement: .confirmationAction) {
                confirmButton
            }
        }
    }

    private var confirmButton: some View {
        Button("Confirm", action: confirm)
            .disabled(!isValid)
            .accessibilityIdentifier("lineup.confirm")
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Button(
            "Restore Saved Starters", systemImage: "arrow.counterclockwise",
            action: restoreSavedStarters
        )
        .disabled(savedStarters.isEmpty)
        Button("Fill by Jersey Number", systemImage: "number", action: fillByNumber)
        Button("Clear", systemImage: "xmark.circle", role: .destructive, action: clear)
            .disabled(starters.isEmpty)
    }

    private var savedStarters: Set<PlayerID> {
        session.snapshot.timeline.starters[.us] ?? []
    }

    private var isValid: Bool {
        starters.count >= session.rules.minimumPlayersPerSide
            && starters.count <= session.rules.playersPerSide
            && goalkeeper.map { starters.contains($0) } ?? false
    }

    private func accessibilityValue(for player: PlayerSnapshot) -> String {
        guard starters.contains(player.id) else { return "Not selected" }
        return goalkeeper == player.id ? "Selected, goalkeeper" : "Selected"
    }

    private func load() {
        guard session.hasStartingLineup else {
            formationID = nil
            return
        }

        starters = session.snapshot.activeLineup
        goalkeeper = session.snapshot.activeGoalkeeper
        formationID = session.context.startingFormation?.id
    }

    private func updateGoalkeeperAfterSelection(
        oldValue: Set<PlayerID>, newValue: Set<PlayerID>
    ) {
        if let goalkeeper, !newValue.contains(goalkeeper) {
            self.goalkeeper = nil
            return
        }

        guard goalkeeper == nil else { return }
        let newlySelected = newValue.subtracting(oldValue)
        self.goalkeeper =
            roster.first {
                newlySelected.contains($0.id) && $0.position == .goalkeeper
            }?.id
    }

    private func fillByNumber() {
        let designatedGoalkeeper = roster.first { $0.position == .goalkeeper }
        var filledStarters = designatedGoalkeeper.map { Set([$0.id]) } ?? []
        for player in roster where filledStarters.count < session.rules.playersPerSide {
            filledStarters.insert(player.id)
        }
        starters = filledStarters
        goalkeeper = designatedGoalkeeper?.id
    }

    private func restoreSavedStarters() {
        starters = savedStarters
        goalkeeper = session.snapshot.timeline.goalkeeper(side: .us, at: .kickoff)
        formationID = session.context.startingFormation?.id
    }

    private func clear() {
        starters = []
        goalkeeper = nil
    }

    private func confirm() {
        let orderedStarters = roster.filter { starters.contains($0.id) }.map(\.id)
        session.setStartingLineup(
            orderedStarters, goalkeeper: goalkeeper, formationID: formationID)
        dismiss()
    }
}
