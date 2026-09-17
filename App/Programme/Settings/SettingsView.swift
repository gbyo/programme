import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI
import TipKit

/// Settings stay small on purpose. Match behaviour belongs to a match's rules
/// preset, not to a pile of global switches.
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TeamModel.name) private var teams: [TeamModel]

    @AppStorage("defaultStatProfile") private var defaultProfileID = StatProfile.maxPreps.id
    @AppStorage("defaultRulesPreset") private var defaultRulesName = MatchRules.highSchool.name
    @AppStorage("defaultOpponentTracking") private var defaultTrackingID = OpponentTrackingMode
        .ourTeam.rawValue
    @AppStorage("confirmBeforeFinalizing") private var confirmBeforeFinalizing = true
    @AppStorage("keepScreenAwakeWhileScoring") private var keepScreenAwake = true
    @AppStorage("hapticFeedbackEnabled") private var hapticsEnabled = true

    @State private var isEditingTeam = false
    @State private var isResettingTips = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Team") {
                    if let team = teams.first {
                        LabeledContent("Name", value: team.name)
                        LabeledContent("Short name", value: team.shortName)
                        if let mascot = team.mascot { LabeledContent("Mascot", value: mascot) }
                        Button("Edit Team…") { isEditingTeam = true }
                    } else {
                        Button("Create a Team…") { isEditingTeam = true }
                    }
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
                    Text("Defaults for New Matches")
                } footer: {
                    Text(
                        "New Match starts from these, and remembers whatever you used last. Any match can override them when you create it."
                    )
                }

                Section("Scoring") {
                    Toggle("Haptic feedback", isOn: $hapticsEnabled)
                    Toggle("Keep the screen awake while scoring", isOn: $keepScreenAwake)
                    Toggle("Confirm before finalizing", isOn: $confirmBeforeFinalizing)
                }

                Section {
                    NavigationLink("Stat Profiles") { StatProfileListView() }
                    NavigationLink("Match Formats") { MatchFormatListView() }
                }

                Section {
                    LabeledContent("Storage", value: "On this iPad")
                    LabeledContent("Account", value: "Not required")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(
                        "Programme works completely offline. Rosters and match data stay on this iPad, there is no analytics, and nothing is uploaded unless you export it yourself."
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
            .sheet(isPresented: $isEditingTeam) {
                NavigationStack { TeamSetupView() }
            }
        }
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
