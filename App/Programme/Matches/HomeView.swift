import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI

/// Home answers one question: what does the scorer need to know or do now?
/// Scoped to one team workspace at fetch time via the store.
struct HomeView: View {
    let teamID: TeamID

    @Environment(AppModel.self) private var appModel
    @State private var matches: [MatchListItem] = []
    @State private var teamDetails: TeamDetails?
    @State private var seasonName: String?
    @State private var recordText: String?

    var body: some View {
        content
            .teamWorkspaceTitle("Home")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Match", systemImage: "plus") {
                        appModel.navigation.isPresentingNewMatch = true
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Settings", systemImage: "gearshape") {
                        appModel.navigation.isPresentingSettings = true
                    }
                    .accessibilityIdentifier("home.settings")
                }
            }
            .task(id: [teamID.rawValue.uuidString, "\(appModel.storeRevision)"]) { await load() }
    }

    /// An inset-grouped List rather than a stack of hand-drawn cards: the
    /// section headers, the row separators, the press highlight, pointer hover
    /// and keyboard focus are all things the system already provides here.
    private var content: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if let live = liveMatch {
                Section("In Progress") {
                    ResumeMatchListCard(match: live) {
                        Task { await appModel.openLiveSession(matchID: live.id) }
                    }
                }
            }

            if let next = nextMatch {
                Section {
                    NextMatchListCard(match: next) {
                        Task { await appModel.openLiveSession(matchID: next.id) }
                    }
                } header: {
                    sectionHeader("Next Match")
                }
            } else if liveMatch == nil {
                Section {
                    EmptyHint(
                        title: "No match scheduled",
                        message: "Create a match to prepare a lineup before kickoff.",
                        actionTitle: "Create a Match"
                    ) {
                        appModel.navigation.isPresentingNewMatch = true
                    }
                } header: {
                    sectionHeader("Next Match")
                }
            }

            if !needsReview.isEmpty {
                Section {
                    ForEach(needsReview) { match in
                        Button {
                            Task { await appModel.open(.match(match.id)) }
                        } label: {
                            MatchListRow(match: match)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    sectionHeader("Needs Review")
                }
            }

            if !recentMatches.isEmpty {
                Section {
                    ForEach(recentMatches) { match in
                        Button {
                            Task { await appModel.open(.match(match.id)) }
                        } label: {
                            MatchListRow(match: match)
                        }
                        .buttonStyle(.plain)
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
    }

    /// A plain section header that carries the identifier its coverage asks for.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).accessibilityIdentifier("section.\(title)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(teamDetails?.name ?? appModel.workspace.selectedTeam?.name ?? "")
                .font(.largeTitle.weight(.semibold))
            Text(seasonLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.header")
    }

    private var seasonLine: String {
        [seasonName, recordText].compactMap(\.self).joined(separator: " · ")
    }

    private func load() async {
        guard let store = appModel.store else { return }
        // Home works in the team's current season.
        let currentSeason =
            appModel.workspace.selectedTeamID == teamID
            ? appModel.workspace.currentSeasonID
            : try? await store.currentSeasonID(teamID: teamID)
        matches = (try? await store.matches(teamID: teamID, seasonID: currentSeason)) ?? []
        teamDetails = try? await store.teamDetails(teamID: teamID)
        if let currentSeason {
            let seasons = (try? await store.seasons(teamID: teamID)) ?? []
            seasonName = seasons.first { $0.id == currentSeason }?.name
        } else {
            seasonName = nil
        }
        let finalized = matches.filter { $0.phase == .finalized }
        if finalized.isEmpty {
            recordText = "No matches played yet"
        } else {
            let wins = finalized.filter { $0.result == .win }.count
            let losses = finalized.filter { $0.result == .loss }.count
            let draws = finalized.filter { $0.result == .draw }.count
            recordText = "\(wins)-\(losses)-\(draws)"
        }
    }

    private var liveMatch: MatchListItem? {
        matches.first { $0.isInterrupted }
    }

    private var nextMatch: MatchListItem? {
        let scheduled = matches.filter { $0.phase == .scheduled }.sorted { $0.kickoff < $1.kickoff }
        return scheduled.first { $0.kickoff > Date().addingTimeInterval(-6 * 3_600) }
            ?? scheduled.first
    }

    private var needsReview: [MatchListItem] {
        matches.filter { $0.needsReviewCount > 0 }.sorted { $0.kickoff > $1.kickoff }
    }

    private var recentMatches: [MatchListItem] {
        Array(matches.filter { $0.phase == .finalized }.sorted { $0.kickoff > $1.kickoff }.prefix(3))
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .programmeSectionHeader()
                .accessibilityIdentifier("section.\(title)")
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct ResumeMatchListCard: View {
    let match: MatchListItem
    var onResume: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(match.venue.shortLabel) \(match.opponentName)")
                    .font(.title3.weight(.semibold))
                Text("\(match.score.us)–\(match.score.opponent) · \(match.eventCount) events recorded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if match.needsReviewCount > 0 {
                    Label("\(match.needsReviewCount) need review", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Programme.Palette.caution)
                }
            }
            Spacer()
            Button(action: onResume) {
                Label("Resume Scoring", systemImage: "play.fill")
                    .font(.headline)
                    .frame(minHeight: 46)
                    .padding(.horizontal, 10)
            }
            .programmePrimaryAction()
        }
        .padding(.vertical, 6)
    }
}

struct NextMatchListCard: View {
    let match: MatchListItem
    var onPrepare: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(match.venue.shortLabel) \(match.opponentName)")
                    .font(.title3.weight(.semibold))
                Text("\(match.kickoff.matchDayText) · \(match.kickoff.matchTimeText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let competition = match.competition {
                    Text(competition).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(action: onPrepare) {
                Label("Prepare Match", systemImage: "list.clipboard")
                    .font(.headline)
                    .frame(minHeight: 46)
                    .padding(.horizontal, 10)
            }
            .programmePrimaryAction()
        }
        .padding(.vertical, 6)
    }
}

// Compatibility wrappers so existing MatchModel-based previews keep working.
struct ResumeMatchCard: View {
    let match: MatchModel
    var onResume: () -> Void
    var body: some View {
        ResumeMatchListCard(
            match: MatchListItem(
                id: match.matchID, opponentName: match.opponentName, kickoff: match.kickoff,
                venue: match.venue, phase: match.phase,
                score: SidePair(us: match.cachedScoreUs, opponent: match.cachedScoreOpponent),
                result: match.result, eventCount: match.cachedEventCount,
                needsReviewCount: match.cachedNeedsReviewCount, competition: match.competition,
                seasonName: match.season?.name),
            onResume: onResume)
    }
}

struct NextMatchCard: View {
    let match: MatchModel
    var onPrepare: () -> Void
    var body: some View {
        NextMatchListCard(
            match: MatchListItem(
                id: match.matchID, opponentName: match.opponentName, kickoff: match.kickoff,
                venue: match.venue, phase: match.phase,
                score: SidePair(us: match.cachedScoreUs, opponent: match.cachedScoreOpponent),
                result: match.result, eventCount: match.cachedEventCount,
                needsReviewCount: match.cachedNeedsReviewCount, competition: match.competition,
                seasonName: match.season?.name),
            onPrepare: onPrepare)
    }
}

struct MatchListRow: View {
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
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
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

struct MatchRow: View {
    let match: MatchModel
    var insets = EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

    var body: some View {
        MatchListRow(
            match: MatchListItem(
                id: match.matchID, opponentName: match.opponentName, kickoff: match.kickoff,
                venue: match.venue, phase: match.phase,
                score: SidePair(us: match.cachedScoreUs, opponent: match.cachedScoreOpponent),
                result: match.result, eventCount: match.cachedEventCount,
                needsReviewCount: match.cachedNeedsReviewCount, competition: match.competition,
                seasonName: match.season?.name),
            insets: insets)
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
        ZStack {
            Programme.Palette.brand
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 36)

                    VStack(spacing: 22) {
                        Image(systemName: "soccerball")
                            .font(.system(size: 72, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)

                        VStack(spacing: 12) {
                            Text("Welcome to Programme")
                                .font(.largeTitle.weight(.bold))

                            Text("Keep your team, score matches, and track the season — all in one place.")
                                .font(.title3)
                                .multilineTextAlignment(.center)
                                .text-wrap(.balance)
                                .foregroundStyle(Programme.Palette.onBrand.opacity(0.78))
                        }

                        Label(
                            "Your data stays on your device. No account or internet connection required.",
                            systemImage: "lock.fill"
                        )
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Programme.Palette.onBrand.opacity(0.72))
                    }
                    .foregroundStyle(Programme.Palette.onBrand)
                    .frame(maxWidth: 620)

                    Spacer(minLength: 28)

                    VStack(spacing: 12) {
                        Button("Create Your First Team") {
                            isCreatingTeam = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Programme.Palette.onBrand)
                        .foregroundStyle(Programme.Palette.brand)
                        .controlSize(.large)

                        Button {
                            isLoadingSample = true
                            Task {
                                await appModel.loadSampleData()
                                isLoadingSample = false
                            }
                        } label: {
                            if isLoadingSample {
                                HStack {
                                    ProgressView()
                                    Text("Loading Sample Team…")
                                }
                            } else {
                                Text("Explore a Sample Team")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Programme.Palette.onBrand)
                        .controlSize(.large)
                        .disabled(isLoadingSample)
                    }
                    .frame(maxWidth: 420)
                    .foregroundStyle(Programme.Palette.onBrand)

                    Spacer(minLength: 36)
                }
                .padding(.horizontal, 24)
                .containerRelativeFrame(.vertical)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
