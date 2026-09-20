import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI
import TipKit

/// Roster for one team. Team-level, not season-level. Scoped at fetch time
/// through the store; never reads another team's players.
struct RosterView: View {
    let teamID: TeamID

    @Environment(AppModel.self) private var appModel

    @State private var roster: RosterSnapshot = .empty
    @State private var isAddingPlayer = false
    @State private var isImporting = false
    @State private var importText: String?
    @State private var showsFormer = false
    @State private var isTargetedForDrop = false

    private let importTip = RosterImportTip()

    var body: some View {
        List {
            if !filtered.isEmpty {
                Section {
                    ForEach(filtered) { player in
                        NavigationLink(value: AppRoute.player(player.id)) {
                            PlayerRosterRow(snapshot: player)
                        }
                    }
                } header: {
                    Text(showsFormer ? "All Players" : "Roster")
                }
            }
        }
        .listStyle(.insetGrouped)
        .teamWorkspaceTitle("Roster")
        // Finding a player by name or number is the shared universal search
        // owned by the navigation shell, not a second local search field
        // here.
        .overlay {
            if roster.players.isEmpty {
                ContentUnavailableView {
                    Label("No Players Yet", systemImage: "person.3")
                } description: {
                    Text(
                        "Add players to begin preparing matches. You can type them in, import a CSV, or drag a roster file here."
                    )
                } actions: {
                    Button("Add a Player") { isAddingPlayer = true }
                        .programmePrimaryAction()
                    Button("Import a Roster") { isImporting = true }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView {
                    Label("No Current Players", systemImage: "person.3")
                } description: {
                    Text("Everyone on this team is marked as a former player.")
                } actions: {
                    Button("Show Former Players") { showsFormer = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Add Player", systemImage: "person.badge.plus") { isAddingPlayer = true }
                    Button("Import CSV or Paste", systemImage: "square.and.arrow.down") {
                        isImporting = true
                        importTip.invalidate(reason: .actionPerformed)
                    }
                }
                // Teach roster import from the control that owns the action;
                // don't reserve a second bar above the scrolling content.
                .popoverTip(importTip)
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu("View", systemImage: "line.3.horizontal.decrease.circle") {
                    Toggle("Show Former Players", isOn: $showsFormer)
                }
            }
        }
        .dropDestination(for: Data.self) { items, _ in
            guard let data = items.first, let text = String(data: data, encoding: .utf8) else { return false }
            importText = text
            return true
        } isTargeted: {
            isTargetedForDrop = $0
        }
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $isAddingPlayer) {
            NavigationStack { PlayerEditorView(teamID: teamID, player: nil) }
        }
        .sheet(isPresented: $isImporting) {
            NavigationStack { RosterImportView(teamID: teamID, initialText: nil) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(get: { importText.map(IdentifiableText.init) }, set: { importText = $0?.text })) { item in
            NavigationStack { RosterImportView(teamID: teamID, initialText: item.text) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: [teamID.rawValue.uuidString, "\(appModel.storeRevision)"]) { await reload() }
    }

    private func reload() async {
        guard let store = appModel.store else { return }
        roster = (try? await store.roster(teamID: teamID, includeFormer: true)) ?? .empty
    }

    private var filtered: [PlayerSnapshot] {
        roster.sortedByNumber
            .filter { showsFormer || $0.isOnRoster }
    }
}

struct IdentifiableText: Identifiable {
    let id = UUID()
    let text: String
}

struct PlayerRosterRow: View {
    let snapshot: PlayerSnapshot

    init(player: PlayerModel) {
        self.snapshot = player.snapshot
    }

    init(snapshot: PlayerSnapshot) {
        self.snapshot = snapshot
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(snapshot.jerseyNumber.map(String.init) ?? "–")
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(snapshot.isOnRoster ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.fullName)
                    .font(.body)
                HStack(spacing: 6) {
                    if let position = snapshot.position {
                        Text(position.label).font(.caption).foregroundStyle(.secondary)
                    }
                    if let classYear = snapshot.classYear {
                        Text(classYear).font(.caption).foregroundStyle(.tertiary)
                    }
                    if !snapshot.isOnRoster {
                        Text("Former").font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.accessibilityLabel)
    }
}

struct RosterImportTip: Tip {
    var title: Text { Text("Import a roster in one step") }
    var message: Text? {
        Text(
            "Drag a CSV onto this list, or paste a table copied from a spreadsheet. Programme shows you the columns before anything is saved."
        )
    }
    var image: Image? { Image(systemName: "square.and.arrow.down") }
}

/// Add or edit one player on an explicit team. Never uses a mutable global.
struct PlayerEditorView: View {
    let teamID: TeamID
    let existing: PlayerSnapshot?

    init(teamID: TeamID, player: PlayerModel? = nil) {
        self.teamID = teamID
        self.existing = player?.snapshot
    }

    init(teamID: TeamID, existing: PlayerSnapshot?) {
        self.teamID = teamID
        self.existing = existing
    }

    /// Snapshot-based editing for previews/tests without a model object.
    var editingSnapshot: PlayerSnapshot? { existing }

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var jerseyNumber = ""
    @State private var position: PlayerPosition?
    @State private var classYear = ""
    @State private var isOnRoster = true
    @FocusState private var focusedField: Field?

    private enum Field {
        case firstName
        case lastName
        case jerseyNumber
        case classYear
    }

    private var canSave: Bool { !firstName.isEmpty || !lastName.isEmpty }

    var body: some View {
        Form {
            Section("Name") {
                TextField("First name", text: $firstName)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .firstName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .lastName }
                TextField("Last name", text: $lastName)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .lastName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .jerseyNumber }
            }
            Section("Details") {
                TextField("Jersey number", text: $jerseyNumber)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .jerseyNumber)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .classYear }
                Picker("Position", selection: $position) {
                    Text("Not set").tag(PlayerPosition?.none)
                    ForEach(PlayerPosition.allCases) { option in
                        Text(option.label).tag(PlayerPosition?.some(option))
                    }
                }
                TextField("Class (optional)", text: $classYear)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .classYear)
                    .submitLabel(.done)
                    .onSubmit {
                        if canSave {
                            Task { await save() }
                        }
                    }
            }
            if existing != nil {
                Section {
                    Toggle("On the current roster", isOn: $isOnRoster)
                } footer: {
                    Text(
                        "Turning this off keeps every match this player appeared in intact. Programme never deletes a player who has match history."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(existing == nil ? "Add Player" : "Edit Player")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
            }
        }
        .onAppear {
            guard let snapshot = editingSnapshot else {
                // A new player starts typing immediately.
                focusedField = .firstName
                return
            }
            firstName = snapshot.firstName
            lastName = snapshot.lastName
            jerseyNumber = snapshot.jerseyNumber.map(String.init) ?? ""
            position = snapshot.position
            classYear = snapshot.classYear ?? ""
            isOnRoster = snapshot.isOnRoster
        }
    }

    private func save() async {
        guard let store = appModel.store else { return }
        let snapshot = PlayerSnapshot(
            id: existing?.id ?? PlayerID(),
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            jerseyNumber: Int(jerseyNumber),
            position: position,
            classYear: classYear.isEmpty ? nil : classYear,
            isOnRoster: isOnRoster)
        do {
            if existing == nil {
                _ = try await store.addPlayer(teamID: teamID, snapshot)
            } else {
                try await store.updatePlayer(snapshot)
            }
            dismiss()
        } catch {
            appModel.navigation.errorToShow = ProgrammeError(
                title: "Couldn't save player",
                message: "Nothing was changed. Try again.",
                underlying: error)
        }
    }
}
