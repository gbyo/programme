import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI
import TipKit

/// Settings stay small on purpose. Match behaviour belongs to a match's rules
/// preset, not to a pile of global switches. Settings is a sheet, never a tab.
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("confirmBeforeFinalizing") private var confirmBeforeFinalizing = true
    @AppStorage("keepScreenAwakeWhileScoring") private var keepScreenAwake = true
    @AppStorage("hapticFeedbackEnabled") private var hapticsEnabled = true

    @State private var defaultProfileID = StatProfile.maxPreps.id
    @State private var defaultRulesName = MatchRules.highSchool.name
    @State private var defaultTrackingID = OpponentTrackingMode.ourTeam.rawValue
    @State private var isResettingTips = false
    /// Snapshot of what the pickers were loaded from. Saves persist only
    /// deltas against this, so merely opening Settings never writes a
    /// managed suggestion into the team's stored defaults.
    @State private var loadedDefaults: TeamMatchDefaults.LoadedDefaults?

    private var selectedTeamID: TeamID? { appModel.workspace.selectedTeamID }
    private var selectedTeamName: String {
        appModel.workspace.selectedTeam?.name ?? "No team"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Manage Teams…") { ManageTeamsView() }
                } header: {
                    Text("Teams")
                } footer: {
                    Text("Teams are workspaces. Home, Matches, Roster and Stats always show the selected team.")
                }

                Section {
                    Picker("Stat profile", selection: $defaultProfileID) {
                        ForEach(StatProfile.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    Picker("Match format", selection: $defaultRulesName) {
                        ForEach(MatchRules.presets, id: \.name) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                    Picker("Opponent tracking", selection: $defaultTrackingID) {
                        ForEach(OpponentTrackingMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                } header: {
                    Text("Defaults for \(selectedTeamName)")
                } footer: {
                    Text(
                        "New Match starts from these, and remembers whatever you used last for this team. Any match can override them when you create it."
                    )
                }
                .onChange(of: defaultProfileID) { saveTeamDefaults() }
                .onChange(of: defaultRulesName) { saveTeamDefaults() }
                .onChange(of: defaultTrackingID) { saveTeamDefaults() }

                Section("Scoring") {
                    Toggle("Haptic feedback", isOn: $hapticsEnabled)
                    Toggle("Keep the screen awake while scoring", isOn: $keepScreenAwake)
                    Toggle("Confirm before finalizing", isOn: $confirmBeforeFinalizing)
                }

                Section("Configuration") {
                    NavigationLink("Stat Profiles") { StatProfileListView() }
                    NavigationLink("Match Formats") { MatchFormatListView() }
                }

                Section {
                    NavigationLink("Data & Transfer…") { DataTransferView() }
                } header: {
                    Text("Data")
                } footer: {
                    Text(
                        "Programme archives, backup and import live here. Season exports live in Stats; match exports live in each match."
                    )
                }

                Section {
                    LabeledContent("Storage", value: "On this iPad")
                    LabeledContent("Account", value: "Not required")
                    LabeledContent("Diagnostics", value: "On this iPad")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(
                        "Programme works completely offline. Rosters and match data stay on this iPad, and nothing is uploaded unless you export it yourself. Diagnostics (timing intervals, on-device performance reports, and coarse app states like scoring or exporting) also stay on this device to help debug issues — they never leave it and never contain names, scores, or notes."
                    )
                }

                Section {
                    Button("Show Tips Again") {
                        try? Tips.resetDatastore()
                        try? Tips.configure()
                        isResettingTips = true
                    }
                } footer: {
                    if isResettingTips {
                        Text("Tips will appear again where they are useful.")
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text(
                        "Programme keeps a write-ahead recovery log alongside its library so an interrupted match is never lost."
                    )
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // Reloads when the team changes and when the MDM configuration
            // changes: a new managed suggestion appears here unless the user
            // overrode that value (stored user values win in
            // TeamMatchDefaults.load). Picker interaction is atomic on the
            // main actor, so a reload cannot clobber an in-flight user edit.
            .task(id: defaultsReloadKey) { loadTeamDefaults() }
        }
    }

    private var defaultsReloadKey: String {
        "\(selectedTeamID?.rawValue.uuidString ?? "none")#\(appModel.managed.configuration.hashValue)"
    }

    private func loadTeamDefaults() {
        guard let selectedTeamID else { return }
        let saved = TeamMatchDefaults.load(
            teamID: selectedTeamID, managed: appModel.managed.configuration)
        defaultProfileID = saved.profileID
        defaultRulesName = saved.rulesName
        defaultTrackingID = saved.tracking.rawValue
        loadedDefaults = saved
    }

    private func saveTeamDefaults() {
        guard let selectedTeamID, let loadedDefaults else { return }
        TeamMatchDefaults.save(
            teamID: selectedTeamID,
            profileID: defaultProfileID,
            rulesName: defaultRulesName,
            tracking: OpponentTrackingMode(rawValue: defaultTrackingID) ?? .ourTeam,
            loaded: loadedDefaults,
            managed: appModel.managed.configuration)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// Read-only reference for what each profile records. Changing a profile never
/// changes what a played match meant.
struct StatProfileListView: View {
    var body: some View {
        List(StatProfile.presets) { profile in
            VStack(alignment: .leading, spacing: 8) {
                Text(profile.name).font(.headline)
                Text(profile.detail).font(.subheadline).foregroundStyle(.secondary)
                FlowLabels(
                    tracked: TrackedStat.allCases.filter { profile.tracks($0) },
                    untracked: TrackedStat.allCases.filter { !profile.tracks($0) })
            }
            .padding(.vertical, 6)
        }
        .navigationTitle("Stat Profiles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FlowLabels: View {
    let tracked: [TrackedStat]
    let untracked: [TrackedStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tracked.isEmpty {
                Label(tracked.map(\.label).joined(separator: ", "), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Programme.Palette.confirmed)
            }
            if !untracked.isEmpty {
                Label(
                    "Not tracked: " + untracked.map(\.label).joined(separator: ", "),
                    systemImage: "minus.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct MatchFormatListView: View {
    var body: some View {
        List(MatchRules.presets, id: \.name) { rules in
            VStack(alignment: .leading, spacing: 6) {
                Text(rules.name).font(.headline)
                Text(
                    "\(rules.regulationPeriods) × \(rules.regulationPeriodDuration / 60) minutes"
                        + (rules.overtimePeriods > 0
                            ? " · \(rules.overtimePeriods) × \(rules.overtimePeriodDuration / 60) min overtime" : "")
                        + (rules.shootoutAvailable ? " · shootout" : "")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text("\(rules.clockDisplay.label) · \(rules.reEntry.label) · \(rules.playersPerSide) a side")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
        }
        .navigationTitle("Match Formats")
        .navigationBarTitleDisplayMode(.inline)
    }
}
