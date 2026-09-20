import ProgrammeCore
import SwiftUI

/// The review queue for one match, reached directly from Home's Needs Review
/// rows, deep links, widgets, and intents through `AppRoute.review`.
///
/// This is triage, not a second resolution system: it derives the same
/// `ValidationEngine` issues Match Detail shows, groups them the way the
/// live Review does, links event-linked rows into the Event Log for context,
/// and resolves through the scorer — the canonical place where events are
/// revised. Back navigation returns to wherever the review was opened from.
struct MatchReviewView: View {
    let matchID: MatchID

    @Environment(AppModel.self) private var appModel
    @State private var context: MatchContext?
    @State private var reviewIssues: [ValidationIssue] = []
    @State private var loadFailed = false

    private var unattributed: [ValidationIssue] {
        reviewIssues.filter { $0.kind == .unresolvedAttribution }
    }

    private var checks: [ValidationIssue] {
        reviewIssues.filter { $0.kind != .unresolvedAttribution }
    }

    var body: some View {
        Group {
            if let context {
                reviewList(context: context)
            } else if loadFailed {
                ContentUnavailableView(
                    "Match Not Available",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Programme couldn't load this match. Your other matches are unaffected."))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let context {
                ToolbarItem(placement: .primaryAction) {
                    Button(
                        context.phase == .finalized ? "Reopen for Corrections" : "Score This Match",
                        systemImage: context.phase == .finalized ? "lock.open" : "play.fill"
                    ) {
                        Task { await appModel.openLiveSession(matchID: matchID) }
                    }
                    .accessibilityIdentifier("review.openScorer")
                }
            }
        }
        .task(id: matchID) { await load() }
    }

    private func load() async {
        guard let store = appModel.store else { return }
        do {
            let loaded = try await store.context(for: matchID)
            let snapshot = StatEngine.snapshot(context: loaded)
            context = loaded
            reviewIssues = ValidationEngine.issues(context: loaded, snapshot: snapshot).needingReview
        } catch {
            loadFailed = true
        }
    }

    private func reviewList(context: MatchContext) -> some View {
        List {
            if !unattributed.isEmpty {
                Section {
                    ForEach(unattributed) { issue in
                        if let event = issue.eventID.flatMap({ id in context.events.first { $0.id == id } }) {
                            NavigationLink(value: AppRoute.eventLog(matchID)) {
                                eventRow(event, context: context)
                            }
                        } else {
                            IssueRow(issue: issue)
                        }
                    }
                } header: {
                    Text("Needs Attribution")
                } footer: {
                    Text(
                        "These were recorded without a jersey number. Assigning one in the scorer revises the original event — no duplicate statistics."
                    )
                }
            }

            if !checks.isEmpty {
                Section("Checks") {
                    ForEach(checks) { issue in
                        if issue.eventID != nil {
                            NavigationLink(value: AppRoute.eventLog(matchID)) {
                                IssueRow(issue: issue)
                            }
                        } else {
                            IssueRow(issue: issue)
                        }
                    }
                }
            }

            if reviewIssues.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Everything Reconciles",
                        systemImage: "checkmark.circle",
                        description: Text(
                            "The score, lineups and goalkeeper statistics all agree with the events recorded."
                        ))
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("review.content")
    }

    private func eventRow(_ event: MatchEvent, context: MatchContext) -> some View {
        let description = MatchNarrator.describe(event, context: context)
        return HStack(spacing: 12) {
            Text(description.timeText)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(description.title).font(.body.weight(.medium))
                if let secondary = description.secondaryDetail {
                    Text(secondary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
