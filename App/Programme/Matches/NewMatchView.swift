import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI

/// Creating a match should take under a minute, and produce something that is
/// ready to score.
struct NewMatchView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var opponent = ""
    @State private var opponentShort = ""
    @State private var kickoff = Date().addingTimeInterval(3_600)
    @State private var venue: Venue = .home
    @State private var competition = ""
    @State private var rulesPresetName = MatchRules.highSchool.name
    @State private var profileID = StatProfile.maxPreps.id
    @State private var tracking: OpponentTrackingMode = .ourTeam
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var rules: MatchRules {
        MatchRules.presets.first { $0.name == rulesPresetName } ?? .highSchool
    }

    private var profile: StatProfile {
        StatProfile.preset(id: profileID) ?? .maxPreps
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Opponent") {
                    TextField("Opponent", text: $opponent)
                        .textInputAutocapitalization(.words)
                    TextField("Short name (optional)", text: $opponentShort)
                        .textInputAutocapitalization(.words)
                    Picker("Venue", selection: $venue) {
                        ForEach(Venue.allCases) { venue in
                            Text(venue.label).tag(venue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Kickoff") {
                    DatePicker("Date and time", selection: $kickoff)
                    TextField("Competition (optional)", text: $competition)
                }

                Section {
                    Picker("Match format", selection: $rulesPresetName) {
                        ForEach(MatchRules.presets, id: \.name) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                    LabeledContent("Periods") {
                        Text(
                            "\(rules.regulationPeriods) × \(rules.regulationPeriodDuration / 60) min"
                                + (rules.overtimePeriods > 0
                                    ? ", \(rules.overtimePeriods) × \(rules.overtimePeriodDuration / 60) min OT" : "")
                        )
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Format")
                } footer: {
                    Text("Programme stores the format with the match, so rate statistics like goals-against average stay correct even if you change formats later.")
                }

                Section {
                    Picker("Stat profile", selection: $profileID) {
                        ForEach(StatProfile.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    Text(profile.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    trackedSummary
                } header: {
                    Text("What to Track")
                } footer: {
                    Text("Categories you don't track are reported as unknown rather than zero — in this match, in season totals, and in every export.")
                }

                Section {
                    Picker("Opponent tracking", selection: $tracking) {
                        ForEach(OpponentTrackingMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    Text(tracking.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Programme.Palette.critical)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(opponent.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var trackedSummary: some View {
        let tracked = TrackedStat.allCases.filter { profile.tracks($0) }
        let untracked = TrackedStat.allCases.filter { !profile.tracks($0) }
        return VStack(alignment: .leading, spacing: 6) {
            if !tracked.isEmpty {
                Label(tracked.map(\.label).joined(separator: ", "), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Programme.Palette.confirmed)
            }
            if !untracked.isEmpty {
                Label("Not tracked: " + untracked.map(\.label).joined(separator: ", "), systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func create() async {
        guard let store = appModel.store, let teamID = appModel.teamID else {
            errorMessage = "Create a team first."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let roster = try await store.roster(teamID: teamID)
            guard !roster.players.isEmpty else {
                errorMessage = "Add players to your roster before creating a match."
                return
            }
            let trimmed = opponent.trimmingCharacters(in: .whitespaces)
            let matchID = try await store.createMatch(
                teamID: teamID,
                seasonID: appModel.seasonID,
                opponentName: trimmed,
                opponentShortName: opponentShort.isEmpty ? nil : opponentShort,
                kickoff: kickoff,
                venue: venue,
                rules: rules,
                statProfile: profile,
                tracking: tracking,
                competition: competition.isEmpty ? nil : competition,
                roster: roster)
            await appModel.refreshWidgetSnapshot()
            dismiss()
            appModel.navigation.open(.match(matchID))
        } catch {
            errorMessage = "Programme couldn't create that match. Nothing was changed. Try again."
        }
    }
}

/// Creating the team. Kept to the few things Programme genuinely needs.
struct TeamSetupView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var shortName = ""
    @State private var mascot = ""
    @State private var seasonName = String(Calendar.current.component(.year, from: Date()))
    @State private var primaryColor = Color.accentColor
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Team") {
                TextField("Team name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Short name for the scoreboard", text: $shortName)
                    .textInputAutocapitalization(.words)
                TextField("Mascot (optional)", text: $mascot)
                    .textInputAutocapitalization(.words)
            }
            Section {
                ColorPicker("Team colour", selection: $primaryColor, supportsOpacity: false)
            } footer: {
                Text("Used as a small accent. Programme keeps the scoring screen high-contrast rather than tinting it.")
            }
            Section("Season") {
                TextField("Season name", text: $seasonName)
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Programme.Palette.critical)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Team")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { Task { await create() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .fontWeight(.semibold)
            }
        }
    }

    private func create() async {
        guard let store = appModel.store else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let teamID = try await store.createTeam(
                name: name.trimmingCharacters(in: .whitespaces),
                shortName: shortName.isEmpty ? nil : shortName,
                mascot: mascot.isEmpty ? nil : mascot,
                primaryColorHex: Programme.hex(from: primaryColor),
                secondaryColorHex: nil)
            _ = try await store.createSeason(
                teamID: teamID, name: seasonName, startDate: Date(), endDate: nil)
            await appModel.reloadTeamContext()
            dismiss()
        } catch {
            errorMessage = "Programme couldn't create that team. Try again."
        }
    }
}

/// Look at a recovered match before resuming it.
struct RecoveryReviewView: View {
    let candidate: RecoverableMatch
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var context: MatchContext?

    var body: some View {
        NavigationStack {
            Group {
                if let context {
                    List {
                        Section("Recovered") {
                            LabeledContent("Match", value: context.descriptor.title)
                            LabeledContent("Events", value: "\(context.events.count)")
                            LabeledContent(
                                "Score",
                                value: "\(StatEngine.snapshot(context: context).score.us)–\(StatEngine.snapshot(context: context).score.opponent)"
                            )
                            LabeledContent(
                                "Period",
                                value: context.currentPeriod?.longLabel ?? "Not started")
                        }
                        Section("Events") {
                            ForEach(MatchNarrator.describeAll(context: context).reversed()) { description in
                                EventLogRow(description: description)
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Review Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resume") {
                        dismiss()
                        Task { await appModel.openLiveSession(matchID: candidate.matchID) }
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                if let store = appModel.store, (try? await store.matchExists(candidate.matchID)) == true {
                    context = try? await store.context(for: candidate.matchID)
                }
            }
        }
    }
}
