import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI

/// The opening screen answers one question: what match am I working on?
struct TodayView: View {
    @Environment(AppModel.self) private var appModel
    @Query(sort: \TeamModel.name) private var teams: [TeamModel]
    @Query(sort: \MatchModel.kickoff, order: .reverse) private var matches: [MatchModel]
    @State private var isCreatingTeam = false

    var body: some View {
        Group {
            if teams.isEmpty {
                FirstRunView(isCreatingTeam: $isCreatingTeam)
            } else {
                content
            }
        }
        .navigationTitle("Today")
        .toolbar {
            if !teams.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Match", systemImage: "plus") {
                        appModel.navigation.isPresentingNewMatch = true
                    }
                }
            }
        }
        .sheet(isPresented: $isCreatingTeam) {
            NavigationStack { TeamSetupView() }
        }
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
                    ResumeMatchCard(match: live) {
                        Task { await appModel.openLiveSession(matchID: live.matchID) }
                    }
                }
            }

            if let next = nextMatch {
                Section("Next Match") {
                    NextMatchCard(match: next) {
                        Task { await appModel.openLiveSession(matchID: next.matchID) }
                    }
                }
            } else if liveMatch == nil {
                Section("Next Match") {
                    EmptyHint(
                        title: "No match scheduled",
                        message: "Create a match to prepare a lineup before kickoff.",
                        actionTitle: "Create a Match"
                    ) {
                        appModel.navigation.isPresentingNewMatch = true
                    }
                }
            }

            if !recentMatches.isEmpty {
                Section("Recent") {
                    ForEach(recentMatches) { match in
                        Button {
                            appModel.navigation.open(.match(match.matchID))
                        } label: {
                            MatchRow(match: match)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(appModel.teamName)
                .font(.largeTitle.weight(.semibold))
            Text(seasonLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.header")
    }

    private var seasonLine: String {
        let finalized = matches.filter { $0.phase == .finalized }
        let wins = finalized.filter { $0.result == .win }.count
        let losses = finalized.filter { $0.result == .loss }.count
        let draws = finalized.filter { $0.result == .draw }.count
        let season = matches.first?.season?.name
        let record = finalized.isEmpty ? "No matches played yet" : "\(wins)-\(losses)-\(draws)"
        return [season, record].compactMap(\.self).joined(separator: " · ")
    }

    private var liveMatch: MatchModel? {
        matches.first { $0.isInterrupted }
    }

    private var nextMatch: MatchModel? {
        matches
            .filter { $0.phase == .scheduled }
            .sorted { $0.kickoff < $1.kickoff }
            .first { $0.kickoff > Date().addingTimeInterval(-6 * 3_600) }
            ?? matches.filter { $0.phase == .scheduled }.min { $0.kickoff < $1.kickoff }
    }

    private var recentMatches: [MatchModel] {
        Array(matches.filter { $0.phase == .finalized }.prefix(5))
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

struct ResumeMatchCard: View {
    let match: MatchModel
    var onResume: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(match.venue.shortLabel) \(match.opponentName)")
                    .font(.title3.weight(.semibold))
                Text("\(match.cachedScoreUs)–\(match.cachedScoreOpponent) · \(match.cachedEventCount) events recorded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if match.cachedNeedsReviewCount > 0 {
                    Label("\(match.cachedNeedsReviewCount) need review", systemImage: "exclamationmark.triangle")
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

struct NextMatchCard: View {
    let match: MatchModel
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

struct MatchRow: View {
    let match: MatchModel
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
                Text("\(match.cachedScoreUs)–\(match.cachedScoreOpponent)")
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
            parts.append("\(result.label), \(match.cachedScoreUs) to \(match.cachedScoreOpponent)")
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

/// First run. One job: get a team created so everything else has somewhere to go.
struct FirstRunView: View {
    @Binding var isCreatingTeam: Bool
    @Environment(AppModel.self) private var appModel
    @State private var isLoadingSample = false

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Programme", systemImage: "book.closed")
        } description: {
            Text("Create your team to start keeping statistics. Everything stays on this iPad — no account, and nothing needed during a match except the iPad itself.")
        } actions: {
            Button("Create Your First Team") { isCreatingTeam = true }
                .programmePrimaryAction()
                .controlSize(.large)
            Button("Explore with a Sample Team") {
                isLoadingSample = true
                Task {
                    await appModel.loadSampleData()
                    isLoadingSample = false
                }
            }
            .disabled(isLoadingSample)
        }
    }
}
