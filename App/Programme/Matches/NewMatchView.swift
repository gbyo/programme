import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI

/// Creating a match should take under a minute, and produce something that is
/// ready to score.
///
/// Almost everything here except the opponent is the same every Tuesday, so the
/// scoring configuration is remembered between matches and collapsed into one
/// summary row. It is not hidden — the row states exactly what this match will
/// record, and opens the full configuration — but it is not five pickers the
/// scorer re-confirms before every kickoff either.
struct NewMatchView: View {
    /// Captured at open time so a background workspace change cannot redirect
    /// the new match to another team.
    let teamID: TeamID

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var opponent = ""
    @State private var opponentShort = ""
    @State private var kickoff = Date().addingTimeInterval(3_600)
    @State private var venue: Venue = .home
    @State private var location: MatchLocation?
    @State private var competition = ""
    @State private var rulesPresetName = MatchRules.highSchool.name
    @State private var profileID = StatProfile.maxPreps.id
    @State private var tracking: OpponentTrackingMode = .ourTeam
    /// What the form was loaded from. Creating a match persists only
    /// explicit user changes against this — untouched managed suggestions
    /// are never written into the team's stored defaults.
    @State private var loadedDefaults: TeamMatchDefaults.LoadedDefaults?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var rules: MatchRules {
        MatchRules.presets.first { $0.name == rulesPresetName } ?? .highSchool
    }

    private var profile: StatProfile {
        StatProfile.preset(id: profileID) ?? .maxPreps
    }

    private var canCreate: Bool {
        !opponent.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
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
                    LocationSearchField(selection: $location)
                }

                Section("Kickoff") {
                    DatePicker("Date and time", selection: $kickoff)
                    TextField("Competition (optional)", text: $competition)
                }

                Section {
                    NavigationLink {
                        MatchScoringSettings(
                            rulesPresetName: $rulesPresetName,
                            profileID: $profileID,
                            tracking: $tracking)
                    } label: {
                        LabeledContent("Scoring") {
                            Text(scoringSummary)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .accessibilityIdentifier("newMatch.scoring")
                    .accessibilityLabel("Scoring. \(scoringSummary)")
                } footer: {
                    Text(
                        "Programme remembers this for your next match. Categories you don't track are reported as unknown rather than zero — in this match, in season totals, and in every export."
                    )
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
                    // The next thing a scorer does after creating a match is
                    // always the lineup, so that is what the primary action does.
                    // It never starts the clock.
                    Button("Create & Set Lineup") { Task { await create(openingScorer: true) } }
                        .disabled(!canCreate)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("newMatch.create")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Create Only", systemImage: "calendar.badge.plus") {
                        Task { await create(openingScorer: false) }
                    }
                    .disabled(!canCreate)
                }
            }
            .onAppear(perform: loadDefaults)
        }
    }

    private var scoringSummary: String {
        [rules.name, profile.name, tracking.label].joined(separator: " · ")
    }

    private func loadDefaults() {
        let saved = TeamMatchDefaults.load(
            teamID: teamID, managed: appModel.managed.configuration)
        rulesPresetName = saved.rulesName
        profileID = saved.profileID
        tracking = saved.tracking
        loadedDefaults = saved
    }

    private func create(openingScorer: Bool) async {
        guard let store = appModel.store else {
            errorMessage = "Create a team first."
            return
        }
        let currentSeasonID =
            appModel.workspace.selectedTeamID == teamID
            ? appModel.workspace.currentSeasonID
            : try? await store.currentSeasonID(teamID: teamID)
        guard let seasonID = currentSeasonID else {
            errorMessage = "This team has no current season yet. Add a season before creating a match."
            return
        }
        isSaving = true
        defer { isSaving = false }
        ProgrammeStateReporter.reportWorkflow(.preparingMatch)
        do {
            let roster = try await store.roster(teamID: teamID)
            guard !roster.players.isEmpty else {
                errorMessage = "Add players to your roster before creating a match."
                return
            }
            let trimmed = opponent.trimmingCharacters(in: .whitespaces)
            let matchID = try await store.createMatch(
                teamID: teamID,
                seasonID: seasonID,
                opponentName: trimmed,
                opponentShortName: opponentShort.isEmpty ? nil : opponentShort,
                kickoff: kickoff,
                venue: venue,
                rules: rules,
                statProfile: profile,
                tracking: tracking,
                competition: competition.isEmpty ? nil : competition,
                location: location,
                roster: roster)

            // What the user explicitly chose becomes this team's default for
            // the next match. Untouched managed suggestions are not
            // persisted: they re-derive from the live MDM configuration.
            if let loadedDefaults {
                TeamMatchDefaults.save(
                    teamID: teamID,
                    profileID: profileID,
                    rulesName: rulesPresetName,
                    tracking: tracking,
                    loaded: loadedDefaults,
                    managed: appModel.managed.configuration)
            }

            await appModel.refreshWidgetSnapshot()
            dismiss()
            if openingScorer {
                // The scorer opens on the lineup editor when a match has no
                // starting lineup, so this lands exactly where the work is.
                // openLiveSession reports liveScoring itself.
                await appModel.openLiveSession(matchID: matchID)
            } else {
                ProgrammeStateReporter.reportWorkflow(.browsing)
                await appModel.open(.match(matchID))
            }
        } catch {
            errorMessage = "Programme couldn't create that match. Nothing was changed. Try again."
        }
    }
}

/// The full scoring configuration, one push away from New Match.
///
/// Nothing is removed here. The point of the summary row is that a scorer who
/// uses the same setup every week never has to come in.
struct MatchScoringSettings: View {
    @Binding var rulesPresetName: String
    @Binding var profileID: String
    @Binding var tracking: OpponentTrackingMode

    private var rules: MatchRules {
        MatchRules.presets.first { $0.name == rulesPresetName } ?? .highSchool
    }

    private var profile: StatProfile {
        StatProfile.preset(id: profileID) ?? .maxPreps
    }

    var body: some View {
        Form {
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
                Text(
                    "Programme stores the format with the match, so rate statistics like goals-against average stay correct even if you change formats later."
                )
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
                Text(
                    "Categories you don't track are reported as unknown rather than zero — in this match, in season totals, and in every export."
                )
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
        }
        .formStyle(.grouped)
        .navigationTitle("Scoring")
        .navigationBarTitleDisplayMode(.inline)
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
}

/// Creating the team. Kept to the few things Programme genuinely needs.
/// Calls `onCreated` with the new team so callers can select it; creating a
/// team never silently edits an existing one.
struct TeamSetupView: View {
    var onCreated: ((TeamID) -> Void)? = nil

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
            await appModel.reloadWorkspace(selecting: teamID)
            onCreated?(teamID)
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
                                value:
                                    "\(StatEngine.snapshot(context: context).score.us)–\(StatEngine.snapshot(context: context).score.opponent)"
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
