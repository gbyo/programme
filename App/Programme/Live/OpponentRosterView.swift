import ProgrammeCore
import ProgrammeExport
import ProgrammeUI
import SwiftUI

/// The opponent's players, for matches scored in `Both Teams` mode.
///
/// Kept deliberately light: a number and a name are enough to attribute an
/// opponent's goal, and a scorer will often be reading them off a programme
/// sheet minutes before kickoff. Paste a list and Programme parses it.
struct OpponentRosterView: View {
    let session: LiveMatchSession

    @Environment(\.dismiss) private var dismiss
    @State private var players: [PlayerSnapshot] = []
    @State private var newNumber = ""
    @State private var newName = ""
    @State private var pastedText = ""
    @State private var isPasting = false
    @State private var addFeedbackTrigger = 0
    @FocusState private var numberFieldIsFocused: Bool
    @FocusState private var nameFieldIsFocused: Bool

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("#", text: $newNumber)
                        .keyboardType(.numberPad)
                        .frame(width: 56)
                        .focused($numberFieldIsFocused)
                    TextField("Name", text: $newName)
                        .textInputAutocapitalization(.words)
                        .focused($nameFieldIsFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Add a player")
            } footer: {
                Text("Only a number and a name are needed to attribute an opponent's goal.")
            }

            if players.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Opponent Players", systemImage: "person.2")
                    } description: {
                        Text(
                            "Without a roster, opponent events are recorded as team totals — which is exactly what Our Team mode does."
                        )
                    } actions: {
                        Button("Paste a List") { isPasting = true }
                    }
                }
            } else {
                Section("\(session.descriptor.opponentName) · \(players.count)") {
                    ForEach(players) { player in
                        HStack(spacing: 12) {
                            Text(player.jerseyNumber.map(String.init) ?? "–")
                                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                                .frame(width: 32, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(player.fullName)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        players.remove(atOffsets: offsets)
                    }
                }
            }
        }
        .navigationTitle("\(session.descriptor.opponentShortName) Roster")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button("Paste a List", systemImage: "doc.on.clipboard") { isPasting = true }
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    session.updateOpponentRoster(RosterSnapshot(players: players))
                    dismiss()
                }
                .fontWeight(.semibold)
            }
            // The number pad has no Return key: Next advances to Name for
            // rapid entry, Done dismisses. The accessory appears only while
            // the numeric field is focused.
            if numberFieldIsFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Next") { nameFieldIsFocused = true }
                    Button("Done") { numberFieldIsFocused = false }
                }
            }
        }
        .sheet(isPresented: $isPasting) {
            NavigationStack { pasteSheet }
        }
        .onAppear {
            players = session.context.opponentRoster.sortedByNumber
            numberFieldIsFocused = players.isEmpty
        }
        .programmeSensoryFeedback(.selection, trigger: addFeedbackTrigger)
    }

    private var pasteSheet: some View {
        Form {
            Section {
                TextEditor(text: $pastedText)
                    .frame(minHeight: 220)
                    .font(.system(.footnote, design: .monospaced))
            } header: {
                Text("Paste the opponent's roster")
            } footer: {
                Text(
                    "One player per line, for example “9 Jalen Carter” or “9, Carter, Jalen”. Programme shows you the result before you save."
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Paste Roster")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    pastedText = ""
                    isPasting = false
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    // The same parser the roster importer uses, so "Last, First"
                    // and jersey-number detection behave identically.
                    let parsed = RosterImporter.preview(csv: normalized(pastedText)).players
                    players.append(contentsOf: parsed)
                    players = RosterSnapshot(players: players).sortedByNumber
                    pastedText = ""
                    isPasting = false
                }
                .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Turn "9 Jalen Carter" into something the CSV parser understands.
    private func normalized(_ text: String) -> String {
        text
            .split(separator: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains(",") || trimmed.contains("\t") { return trimmed }
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, Int(parts[0].replacingOccurrences(of: "#", with: "")) != nil
                else { return "," + trimmed }
                return "\(parts[0].replacingOccurrences(of: "#", with: "")),\(parts[1])"
            }
            .joined(separator: "\n")
    }

    private func add() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let split = RosterImportPreview.splitName(trimmed)
        players.append(
            PlayerSnapshot(
                firstName: split.first, lastName: split.last, jerseyNumber: Int(newNumber)))
        players = RosterSnapshot(players: players).sortedByNumber
        newNumber = ""
        newName = ""
        numberFieldIsFocused = true
        addFeedbackTrigger += 1
    }
}
