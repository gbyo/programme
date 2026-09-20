import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftUI

/// Home answers one question: what does the scorer need to know or do now?
/// Scoped to one team workspace at fetch time via the store.
///
/// Team identity lives in the workspace switcher (sidebar, top bar, or
/// navigation title); the list below holds only actionable sections. Immediate actions
/// (Resume/Prepare) are whole-row Buttons into the live-session flow, while
/// drill-down rows are NavigationLinks that the List discloses natively.
struct HomeView: View {
    let teamID: TeamID

    @Environment(AppModel.self) private var appModel
    @State private var matches: [MatchListItem] = []

    var body: some View {
        content
            .teamWorkspaceTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Match", systemImage: "plus") {
                        appModel.navigation.isPresentingNewMatch = true
                    }
                }
            }
            .task(id: [teamID.rawValue.uuidString, "\(appModel.storeRevision)"]) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if matches.isEmpty {
            ContentUnavailableView {
                Label("No Matches Yet", systemImage: "calendar.badge.plus")
            } description: {
                Text("Schedule your first match to prepare the lineup and start scoring.")
            } actions: {
                Button("New Match") {
                    appModel.navigation.isPresentingNewMatch = true
                }
            }
            .accessibilityIdentifier("home.content")
        } else {
            List {
                if let live = liveMatch {
                    Section {
                        CurrentMatchRow(match: live)
                    } header: {
                        sectionHeader("Current Match")
                    }
                }

                Section {
                    if let next = nextMatch {
                        NextMatchRow(match: next)
                    } else {
                        Button {
                            appModel.navigation.isPresentingNewMatch = true
                        } label: {
                            Label("Schedule Next Match", systemImage: "plus")
                        }
                    }
                } header: {
                    sectionHeader("Next Match")
                }

                if !needsReview.isEmpty {
                    Section {
                        ForEach(needsReview) { match in
                            NavigationLink(value: AppRoute.match(match.id)) {
                                MatchRowContent(match: match)
                            }
                        }
                    } header: {
                        sectionHeader("Needs Review")
                    }
                }

                if !recentMatches.isEmpty {
                    Section {
                        ForEach(recentMatches) { match in
                            NavigationLink(value: AppRoute.match(match.id)) {
                                MatchRowContent(match: match)
                            }
                        }
                        Button {
                            appModel.navigation.section = .matches
                        } label: {
                            Text("All Matches")
                        }
                    } header: {
                        sectionHeader("Recent")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("home.content")
        }
    }

    /// A plain section header that carries the identifier its coverage asks for.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).accessibilityIdentifier("section.\(title)")
    }

    private func load() async {
        guard let store = appModel.store else { return }
        // Home works in the team's current season.
        let currentSeason =
            appModel.workspace.selectedTeamID == teamID
            ? appModel.workspace.currentSeasonID
            : try? await store.currentSeasonID(teamID: teamID)
        matches = (try? await store.matches(teamID: teamID, seasonID: currentSeason)) ?? []
    }

    private var liveMatch: MatchListItem? {
        matches.first { $0.isInterrupted }
    }

    private var nextMatch: MatchListItem? {
        let scheduled = matches.filter { $0.phase == .scheduled }.sorted { $0.kickoff < $1.kickoff }
        return scheduled.first { $0.kickoff > Date().addingTimeInterval(-6 * 3_600) }
            ?? scheduled.first
    }

    /// The interrupted match surfaces its review count inside Current Match,
    /// so it never appears here a second time.
    private var needsReview: [MatchListItem] {
        matches
            .filter { $0.needsReviewCount > 0 && $0.id != liveMatch?.id }
            .sorted { $0.kickoff > $1.kickoff }
    }

    private var recentMatches: [MatchListItem] {
        Array(matches.filter { $0.phase == .finalized }.sorted { $0.kickoff > $1.kickoff }.prefix(3))
    }
}

/// The one match that needs the scorer right now. The whole row is a single
/// Button into the existing live-session flow; the List owns the container,
/// so there is no nested control and no card chrome.
struct CurrentMatchRow: View {
    let match: MatchListItem

    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button {
            Task { await appModel.openLiveSession(matchID: match.id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(match.venue.shortLabel) \(match.opponentName)")
                        .font(.headline)
                    Text("\(match.score.us)–\(match.score.opponent) · \(statusText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if match.needsReviewCount > 0 {
                        Label(
                            "\(match.needsReviewCount) need review",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Programme.Palette.caution)
                    }
                }
                Spacer()
                Label(actionText, systemImage: actionSymbol)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityIdentifier("home.currentMatch")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var statusText: String {
        switch match.phase {
        case .inPeriod: "In progress"
        case .periodBreak: "Between periods"
        case .awaitingFinalization: "Ready to finalize"
        case .scheduled, .finalized: match.phase.rawValue
        }
    }

    private var actionText: String {
        match.phase == .awaitingFinalization ? "Finish" : "Resume"
    }

    private var actionSymbol: String {
        match.phase == .awaitingFinalization ? "checkmark.circle" : "play.fill"
    }

    private var accessibilityLabel: String {
        var parts = [
            "\(match.venue.label) versus \(match.opponentName)",
            "\(match.score.us) to \(match.score.opponent)",
            statusText.lowercased(),
        ]
        if match.needsReviewCount > 0 {
            parts.append("\(match.needsReviewCount) need review")
        }
        return parts.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        match.phase == .awaitingFinalization ? "Opens the final match review" : "Resumes scoring"
    }
}

/// The next match to prepare, in the same row language as Current Match:
/// one whole-row Button into the existing open-live-session behavior.
struct NextMatchRow: View {
    let match: MatchListItem

    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button {
            Task { await appModel.openLiveSession(matchID: match.id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(match.venue.shortLabel) \(match.opponentName)")
                        .font(.headline)
                    Text("\(match.kickoff.matchDayText) · \(match.kickoff.matchTimeText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let competition = match.competition {
                        Text(competition)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Label("Prepare", systemImage: "list.clipboard")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityIdentifier("home.nextMatch")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Prepares the match for scoring")
    }

    private var accessibilityLabel: String {
        var parts = [
            "\(match.venue.label) versus \(match.opponentName)",
            match.kickoff.matchDayText,
            match.kickoff.matchTimeText,
        ]
        if let competition = match.competition { parts.append(competition) }
        return parts.joined(separator: ", ")
    }
}

/// Match row content without any container behavior: NavigationLink (or any
/// other semantic container) owns disclosure, so no chevron is drawn here.
struct MatchRowContent: View {
    let match: MatchListItem
    var insets = EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

    var body: some View {
        HStack(spacing: 14) {
            if let result = match.result {
                Text(result.letter)
                    .font(.subheadline.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(result.tint.opacity(0.18), in: Circle())
                    .accessibilityHidden(true)
            } else {
                Image(systemName: match.isInterrupted ? "record.circle" : "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(match.venue.shortLabel) \(match.opponentName)")
                    .font(.body.weight(.medium))
                Text(match.kickoff.matchDayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if match.phase == .finalized {
                Text("\(match.score.us)–\(match.score.opponent)")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            } else if match.isInterrupted {
                Text("In progress")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Programme.Palette.caution)
            } else {
                Text(match.kickoff.matchTimeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(insets)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("match.\(match.opponentName)")
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["\(match.venue.label) versus \(match.opponentName)", match.kickoff.matchDayText]
        if match.phase == .finalized, let result = match.result {
            parts.append("\(result.label), \(match.score.us) to \(match.score.opponent)")
        } else if match.isInterrupted {
            parts.append("in progress")
        }
        return parts.joined(separator: ", ")
    }
}

struct EmptyHint: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .programmePrimaryAction()
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// First run lives above the team-scoped tab shell: with no team there are no
/// meaningful Home/Matches/Roster/Stats destinations to show.
struct FirstRunView: View {
    @Binding var isCreatingTeam: Bool
    @Environment(AppModel.self) private var appModel
    @State private var isLoadingSample = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 40)

                VStack(spacing: 20) {
                    Image(systemName: "soccerball")
                        .font(.system(size: 56, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Welcome to Programme")
                            .font(.largeTitle.weight(.semibold))
                            .multilineTextAlignment(.center)

                        Text("Score matches. Track players. Keep the season together.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Text("No account required. Works offline.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 520)

                Spacer(minLength: 36)

                VStack(spacing: 14) {
                    Button {
                        isCreatingTeam = true
                    } label: {
                        Text("Create Your First Team")
                            .font(.headline)
                            .frame(minWidth: 220)
                    }
                    .programmePrimaryAction(in: .control)
                    .controlSize(.large)

                    Button {
                        isLoadingSample = true
                        Task {
                            await appModel.loadSampleData()
                            isLoadingSample = false
                        }
                    } label: {
                        if isLoadingSample {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Loading Sample Team…")
                            }
                        } else {
                            Text("Explore a Sample Team")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .disabled(isLoadingSample)
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
            .containerRelativeFrame(.vertical)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
