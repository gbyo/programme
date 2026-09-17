import ProgrammeCore
import ProgrammeUI
import SwiftUI
import TipKit

/// The full-time check.
///
/// The most important thing on this screen is the completeness list. A category
/// nobody tracked is reported as unknown, never as a row of zeros, because a
/// published zero is a claim and an untracked category is not.
struct FinalizeView: View {
    let session: LiveMatchSession
    var onFinalized: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                section("Match Check") {
                    ForEach(checks, id: \.title) { check in
                        CheckRow(check: check)
                    }
                }

                section("Stat Completeness") {
                    TipView(CompletenessTip())
                    ForEach(TrackedStat.allCases.sorted { $0.label < $1.label }) { stat in
                        CompletenessRow(
                            stat: stat, state: session.snapshot.completeness(stat))
                    }
                    Text("“Not tracked” means the category was never recorded for this match. It stays unknown in exports and season totals — it is never counted as zero.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                section("Playing Time") {
                    ForEach(playedPlayers) { player in
                        HStack {
                            Text(player.shortLabel).font(.subheadline)
                            Spacer()
                            Text("\(session.snapshot.player(player.id).minutesPlayed) min")
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    HStack {
                        Text("Total").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(totalMinutes) min")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    Text(minutesExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
        .navigationTitle("Finalize Match")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Not Yet") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if !blockingIssues.isEmpty {
                    Label(
                        "\(blockingIssues.count) issue\(blockingIssues.count == 1 ? "" : "s") must be resolved first",
                        systemImage: "exclamationmark.octagon.fill"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Programme.Palette.critical)
                }
                Button {
                    isConfirming = true
                } label: {
                    Label("Finalize Match", systemImage: "flag.checkered")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!blockingIssues.isEmpty)
            }
            .padding(16)
            .background(.bar)
        }
        .confirmationDialog(
            "Finalize this match?", isPresented: $isConfirming, titleVisibility: .visible
        ) {
            Button("Finalize") {
                session.finalize()
                onFinalized()
            }
        } message: {
            Text(
                "The match becomes read-only for everyday use. You can still reopen it later to make a correction, and Programme records that as a revision."
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FULL TIME")
                .font(.caption.weight(.semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(session.descriptor.teamShortName).font(.title2.weight(.semibold))
                Text("\(session.snapshot.score.us)–\(session.snapshot.score.opponent)")
                    .font(.programmeScore(38))
                Text(session.descriptor.opponentShortName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let result = session.snapshot.result {
                    Text(result.letter)
                        .font(.headline)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(result.tint.opacity(0.18), in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).programmeSectionHeader()
            content()
        }
    }

    private var blockingIssues: [ValidationIssue] { session.issues.blocking }

    private var playedPlayers: [PlayerSnapshot] {
        session.roster.sortedByNumber.filter { session.snapshot.player($0.id).appeared }
    }

    private var totalMinutes: Int {
        session.snapshot.players.values.filter { $0.side == .us }.reduce(0) { $0 + $1.minutesPlayed }
    }

    private var minutesExplanation: String {
        let expected = session.rules.playersPerSide * publishedMinutes(
            fromSeconds: session.snapshot.timeline.periods.totalSecondsPlayed)
        if abs(totalMinutes - expected) <= session.rules.playersPerSide {
            return "Derived from lineup intervals. Consistent with \(session.rules.playersPerSide) players for the full match."
        }
        return "Derived from lineup intervals. Expected roughly \(expected) minutes across \(session.rules.playersPerSide) positions — a substitution may be missing or mistimed."
    }

    private var checks: [PeriodCheck] {
        var result: [PeriodCheck] = []
        let keeperGA = session.snapshot.keepers.values.filter { $0.side == .us }
            .reduce(0) { $0 + $1.goalsAllowed }

        result.append(
            PeriodCheck(
                state: keeperGA == session.snapshot.score.opponent ? .ok : .warning,
                title: "Score matches goal events",
                detail:
                    "\(session.snapshot.score.us) for, \(session.snapshot.score.opponent) against, from \(session.context.activeEvents.filter { $0.category == .goal }.count) goal events."
            ))

        let periodsPlayed = session.snapshot.timeline.periods.spans.count
        result.append(
            PeriodCheck(
                state: periodsPlayed >= session.rules.regulationPeriods ? .ok : .warning,
                title: "\(periodsPlayed) period\(periodsPlayed == 1 ? "" : "s") played",
                detail: periodsPlayed >= session.rules.regulationPeriods
                    ? "\(session.rules.name) regulation is complete."
                    : "\(session.rules.name) expects \(session.rules.regulationPeriods) periods."
            ))

        if session.profile.tracks(.goalkeeping) {
            let keeperSeconds = session.snapshot.keepers.values.filter { $0.side == .us }
                .reduce(0) { $0 + $1.secondsPlayed }
            let matchSeconds = session.snapshot.timeline.periods.totalSecondsPlayed
            result.append(
                PeriodCheck(
                    state: abs(keeperSeconds - matchSeconds) <= 60 ? .ok : .warning,
                    title: "Goalkeeper minutes covered",
                    detail: abs(keeperSeconds - matchSeconds) <= 60
                        ? "A goalkeeper is accounted for throughout the match."
                        : "\(publishedMinutes(fromSeconds: abs(matchSeconds - keeperSeconds))) minutes have no goalkeeper recorded."
                ))
        }

        if session.needsReviewCount > 0 {
            result.append(
                PeriodCheck(
                    state: .warning,
                    title: "\(session.needsReviewCount) unresolved attribution\(session.needsReviewCount == 1 ? "" : "s")",
                    detail: "These count toward team totals but not toward any player."
                ))
        }

        for issue in session.issues where issue.severity >= .review && issue.kind != .unresolvedAttribution {
            result.append(
                PeriodCheck(
                    state: issue.severity == .blocking ? .blocking : .warning,
                    title: issue.title, detail: issue.detail))
        }

        if result.allSatisfy({ $0.state == .ok }) {
            result.append(
                PeriodCheck(
                    state: .ok, title: "Ready to export",
                    detail: "Everything reconciles. Nothing needs attention."))
        }
        return result
    }
}

struct CompletenessRow: View {
    let stat: TrackedStat
    let state: CompletenessState

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    differentiateWithoutColor ? AnyShapeStyle(.secondary) : AnyShapeStyle(state.tint)
                )
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(stat.label).font(.subheadline)
            Spacer()
            Text(state.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(state == .complete ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("completeness.\(stat.rawValue)")
        .accessibilityLabel("\(stat.label), \(state.label)")
    }
}
