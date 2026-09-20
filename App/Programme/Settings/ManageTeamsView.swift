import ProgrammeCollaboration
import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftUI

/// Team management. Team is workspace context: this list selects and edits
/// teams but is never itself a tab.
///
/// Content is identical in both presentations; only dismissal differs, and
/// the presentation is stated explicitly rather than inferred. Pushed inside
/// Settings the system back button is the way out, so no extra control is
/// shown. Presented as its own sheet the owner supplies a native Done path.
struct ManageTeamsView: View {
    enum Presentation {
        case pushed
        case sheet
    }

    var presentation: Presentation = .pushed

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingTeam = false

    var body: some View {
        List {
            Section {
                ForEach(appModel.teamSummaries) { team in
                    NavigationLink {
                        TeamDetailView(teamID: team.id)
                    } label: {
                        HStack {
                            Circle()
                                .fill(Programme.teamColor(hex: nil))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(team.name).font(.body)
                                Text("\(team.playerCount) players · \(team.seasonCount) seasons")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if team.id == appModel.workspace.selectedTeamID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("Selected team")
                            }
                        }
                    }
                }
            } header: {
                Text("Teams")
            }

            Section {
                Button("Add Team…", systemImage: "plus") { isAddingTeam = true }
            }
        }
        .navigationTitle("Manage Teams")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentation == .sheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isAddingTeam) {
            NavigationStack { TeamSetupView() }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        await appModel.reloadWorkspace(selecting: appModel.workspace.selectedTeamID)
        await appModel.refreshTeamSummaries()
    }
}

/// Team details and editing. Editing an existing team calls `updateTeam` —
/// it never creates a second team. Season management lives here too.
struct TeamDetailView: View {
    let teamID: TeamID

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var details: TeamDetails?
    @State private var seasons: [SeasonListItem] = []
    @State private var name = ""
    @State private var shortName = ""
    @State private var mascot = ""
    @State private var color = Color.accentColor
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var shareItem: TeamShareItem?
    @State private var participants: [ShareParticipant] = []
    @State private var conflicts: [(conflict: TeamConflict, matchName: String)] = []
    @State private var syncState: TeamSyncState = .synced
    @State private var isConfirmingStopSharing = false
    @State private var isAddingSeason = false
    @State private var newSeasonName = ""
    @State private var newSeasonMakeCurrent = true

    var body: some View {
        Form {
            Section {
                TextField("Team name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Short name", text: $shortName)
                    .textInputAutocapitalization(.words)
                TextField("Mascot (optional)", text: $mascot)
                    .textInputAutocapitalization(.words)
                ColorPicker("Team colour", selection: $color, supportsOpacity: false)
            } header: {
                Text("Identity")
            } footer: {
                Text("Used as a small accent. Programme keeps the scoring screen high-contrast rather than tinting it.")
            }

            if appModel.workspace.selectedTeamID != teamID {
                Section {
                    Button("Select This Team") {
                        Task { await appModel.selectTeam(teamID) }
                    }
                } footer: {
                    Text("Makes this team the workspace for Home, Matches, Roster and Stats.")
                }
            }

            Section {
                ForEach(seasons) { season in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(season.name).font(.body)
                            Text("\(season.matchCount) matches")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if season.isCurrent {
                            Text("Current")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Button("Make Current") {
                                Task { await makeCurrent(season.id) }
                            }
                            .font(.subheadline)
                        }
                    }
                }
                Button("Add Season…", systemImage: "plus") { isAddingSeason = true }
            } header: {
                Text("Seasons")
            } footer: {
                Text(
                    "The current season is used for Home, New Match and default filtering. Viewing an older season in Stats never changes it."
                )
            }

            Section {
                Label(syncState.label, systemImage: syncState.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("teamDetail.syncState")
                let collaborationAllowed = appModel.managed.configuration.isCollaborationAllowed
                if !collaborationAllowed {
                    Label(
                        "Team sharing is disabled by this device's management.",
                        systemImage: "lock.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("teamDetail.share.disabled")
                }
                // An existing share is always manageable through the system
                // UI — revoking (owner) or leaving (participant) stays
                // available under any policy. Only creating a share is
                // gated, so ShareLink and its loading state live strictly
                // inside the collaboration-allowed branch.
                if let prepared = shareItem?.prepared, let shareItem {
                    if case .shared = shareItem.scope {
                        // Shared with me: the sharer's share through the
                        // system UI. Leaving happens there; Programme
                        // never offers a second private share.
                        Text("Shared with you")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    CollaborationView(
                        share: prepared, container: shareItem.container(),
                        teamName: shareItem.teamName
                    )
                    .frame(height: 48)
                    .accessibilityIdentifier("teamDetail.collaboration")
                } else if collaborationAllowed {
                    if let shareItem {
                        switch shareItem.scope {
                        case .shared:
                            // Shared scope whose share hasn't re-fetched:
                            // wait, don't offer to share someone else's team.
                            HStack {
                                Text("Loading shared team…")
                                Spacer()
                                ProgressView()
                            }
                            .accessibilityIdentifier("teamDetail.share.loading")
                        case .owned:
                            ShareLink(
                                item: shareItem,
                                preview: SharePreview(
                                    Text("Share \(shareItem.teamName)"),
                                    image: Image(systemName: "person.2"))
                            ) {
                                Label(
                                    "Share \(shareItem.teamName)…",
                                    systemImage: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier("teamDetail.share")
                        }
                    } else {
                        HStack {
                            Text("Preparing Share…")
                            Spacer()
                            ProgressView()
                        }
                        .accessibilityIdentifier("teamDetail.share.loading")
                    }
                }
                if !participants.isEmpty {
                    ForEach(participants) { participant in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    participant.displayName
                                        + (participant.isCurrentUser ? " (You)" : "")
                                )
                                .font(.body)
                                Text(
                                    participant.roleLabel
                                        + (participant.accepted ? "" : " · Invited")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                // Owner-only destructive action: revokes the share for
                // everyone without touching local truth. Revocation stays
                // available when collaboration is disabled — only creating
                // new shares is gated. Participants manage (and leave)
                // through the system collaboration UI above — Programme
                // never offers them "Stop Sharing".
                if shareItem?.scope == .owned,
                    shareItem?.prepared != nil
                {
                    Button("Stop Sharing…", systemImage: "person.2.slash", role: .destructive) {
                        isConfirmingStopSharing = true
                    }
                    .accessibilityIdentifier("teamDetail.stopSharing")
                }
            } header: {
                Text("Sharing")
            } footer: {
                Text(
                    "Shares the whole team workspace by invitation only — there is no public link. Adding people and changing permissions happens in the system share sheet. Shared changes still need review when they contradict local scoring, and statistics always re-derive on this device."
                )
            }

            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts, id: \.conflict.eventID) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Contradiction in \(entry.matchName)").font(.body)
                            Text(
                                "Both sides recorded revision \(entry.conflict.localRevision) differently. Your version stands."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Button("Keep Mine") {
                                Task { await resolveConflict(entry.conflict) }
                            }
                            .font(.subheadline)
                            .accessibilityIdentifier(
                                "teamDetail.conflict.keep.\(entry.conflict.eventID.rawValue.uuidString)")
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Needs Review")
                } footer: {
                    Text(
                        "A collaborator's change contradicted yours at the same revision, so nothing was overwritten. Keeping yours clears the entry; editing the event instead supersedes them everywhere."
                    )
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Programme.Palette.critical)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(details?.shortName ?? "Team")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("teamDetail.save")
            }
        }
        .sheet(isPresented: $isAddingSeason) {
            NavigationStack {
                Form {
                    Section("Season") {
                        TextField("Season name", text: $newSeasonName)
                        Toggle("Make current", isOn: $newSeasonMakeCurrent)
                    }
                }
                .formStyle(.grouped)
                .navigationTitle("Add Season")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isAddingSeason = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { Task { await addSeason() } }
                            .disabled(newSeasonName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        // Reloads when the collaboration policy flips, so disabling or
        // re-enabling sharing applies immediately without reopening the view.
        // Team fields load only when the team changes: reloading them on
        // every policy or account flip would discard unsaved edits.
        .task(id: teamID) {
            await load()
        }
        // Sharing state refreshes independently when the collaboration
        // policy or the iCloud account state changes.
        .task(id: teamShareReloadKey) {
            await loadShareItem()
        }
        .confirmationDialog(
            "Stop sharing this team?",
            isPresented: $isConfirmingStopSharing,
            titleVisibility: .visible
        ) {
            Button("Stop Sharing", role: .destructive) { Task { await stopSharing() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Everyone loses access. Matches already on their devices stay there, but nothing new syncs."
            )
        }
    }

    /// Resolves the share item without creating anything: an already-shared
    /// team presents its live share, otherwise the item prepares the share
    /// on first use. Failures (e.g. iCloud signed out) surface here, never
    /// as a dead Share button.
    private var teamShareReloadKey: String {
        "\(teamID.rawValue.uuidString)#\(appModel.managed.configuration.hashValue)#\(appModel.cloudAccount.state)"
    }

    private func loadShareItem() async {
        conflicts = await appModel.syncConflicts(teamID: teamID)
        syncState = await appModel.syncState(teamID: teamID)
        do {
            shareItem = try await appModel.teamShareItem(teamID: teamID)
            participants = await appModel.teamParticipants(teamID: teamID)
            errorMessage = nil
        } catch {
            errorMessage =
                (error as? any LocalizedError)?.errorDescription
                ?? "Programme couldn't prepare that share. Nothing was changed. Try again."
        }
    }

    private func resolveConflict(_ conflict: TeamConflict) async {
        await appModel.resolveConflict(conflict)
        conflicts = await appModel.syncConflicts(teamID: teamID)
    }

    private func stopSharing() async {
        do {
            try await appModel.stopSharing(teamID: teamID)
            participants = []
            await loadShareItem()
            Haptics.success()
        } catch {
            errorMessage = "Programme couldn't stop sharing. Nothing was changed. Try again."
            Haptics.error()
        }
    }

    private func load() async {
        guard let store = appModel.store else { return }
        details = try? await store.teamDetails(teamID: teamID)
        seasons = (try? await store.seasons(teamID: teamID)) ?? []
        if let details {
            name = details.name
            shortName = details.shortName
            mascot = details.mascot ?? ""
            color = Programme.teamColor(hex: details.primaryColorHex)
        }
    }

    private func save() async {
        guard let store = appModel.store else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.updateTeam(
                teamID,
                name: name.trimmingCharacters(in: .whitespaces),
                shortName: shortName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? name.trimmingCharacters(in: .whitespaces) : shortName.trimmingCharacters(in: .whitespaces),
                mascot: mascot.isEmpty ? nil : mascot,
                primaryColorHex: Programme.hex(from: color),
                secondaryColorHex: details?.secondaryColorHex)
            await appModel.reloadWorkspace(selecting: appModel.workspace.selectedTeamID)
            await appModel.refreshTeamSummaries()
            await load()
            errorMessage = nil
            Haptics.success()
            dismiss()
        } catch {
            errorMessage = "Programme couldn't save that team. Nothing was changed. Try again."
            Haptics.error()
        }
    }

    private func makeCurrent(_ seasonID: SeasonID) async {
        guard let store = appModel.store else { return }
        do {
            try await store.setCurrentSeason(teamID: teamID, seasonID: seasonID)
            if appModel.workspace.selectedTeamID == teamID {
                appModel.workspace.currentSeasonID = seasonID
                appModel.workspace.viewedStatsSeasonID = seasonID
                await appModel.refreshWidgetSnapshot(reloadingSeasonRecord: true)
            }
            await load()
            Haptics.selectionChanged()
        } catch {
            errorMessage = "Programme couldn't change the current season. Nothing was changed."
            Haptics.error()
        }
    }

    private func addSeason() async {
        guard let store = appModel.store else { return }
        do {
            let id = try await store.createSeason(
                teamID: teamID,
                name: newSeasonName.trimmingCharacters(in: .whitespaces),
                startDate: Date(), endDate: nil,
                makeCurrent: newSeasonMakeCurrent)
            if newSeasonMakeCurrent, appModel.workspace.selectedTeamID == teamID {
                appModel.workspace.currentSeasonID = id
                appModel.workspace.viewedStatsSeasonID = id
                await appModel.refreshWidgetSnapshot(reloadingSeasonRecord: true)
            }
            newSeasonName = ""
            isAddingSeason = false
            await appModel.refreshTeamSummaries()
            await load()
            Haptics.success()
        } catch {
            errorMessage = "Programme couldn't add that season. Nothing was changed."
            Haptics.error()
        }
    }
}
