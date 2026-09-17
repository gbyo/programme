import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// The between-periods check.
///
/// Not a statistics dashboard: a short, honest summary of whether the record
/// holds together, and the one button that matters next.
struct PeriodBreakView: View {
    let session: LiveMatchSession
    var onReview: () -> Void
    var onContinue: () -> Void
    var onShootout: () -> Void
    var onFinalize: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checks, id: \.title) { check in
                        CheckRow(check: check)
                    }
                }

                if session.profile.tracks(.shots) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("So far").programmeSectionHeader()
                        comparisonGrid
                    }
                }
            }
            .padding(22)
        }
        .navigationTitle(breakTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back to Match") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                if session.needsReviewCount > 0 || !session.issues.needingReview.isEmpty {
                    Button {
                        onReview()
                    } label: {
                        Label("Review Issues", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                }
                if shootoutIsNext {
                    Button {
                        onShootout()
                    } label: {
                        Label("Take the Shootout", systemImage: "circle.bottomhalf.filled")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                } else if session.canStartNextPeriod {
                    Button {
                        onContinue()
                    } label: {
                        Label("Start \(session.nextPeriodLabel)", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        onFinalize()
                    } label: {
                        Label("Finalize Match", systemImage: "flag.checkered")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .background(.bar)
        }
    }

    /// A shootout only becomes the next thing once every playable period is done
    /// and the score is still level.
    private var shootoutIsNext: Bool {
        guard session.rules.shootoutAvailable else { return false }
        guard session.snapshot.score.us == session.snapshot.score.opponent else { return false }
        let played = session.context.startedPeriods.max() ?? 0
        return played >= session.rules.regulationPeriods + session.rules.overtimePeriods
    }

    private var breakTitle: String {
        if session.phase == .awaitingFinalization { return "Full Time" }
        let ended = session.context.startedPeriods.max() ?? 1
        if ended == session.rules.regulationPeriods / 2 || (session.rules.regulationPeriods == 2 && ended == 1) {
            return "Halftime"
        }
        return "\(session.rules.period(at: ended)?.longLabel ?? "Period") Ended"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(breakTitle.uppercased())
                .font(.caption.weight(.semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(session.descriptor.teamShortName)
                    .font(.title2.weight(.semibold))
                Text("\(session.snapshot.score.us)–\(session.snapshot.score.opponent)")
                    .font(.programmeScore(38))
                Text(session.descriptor.opponentShortName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var comparisonGrid: some View {
        VStack(spacing: 0) {
            row("Shots", session.snapshot.team.us.shots, session.snapshot.team.opponent.shots)
            Divider()
            row(
                "Shots on Goal", session.snapshot.team.us.shotsOnGoal,
                session.snapshot.team.opponent.shotsOnGoal)
            if session.profile.tracks(.corners) {
                Divider()
                row("Corners", session.snapshot.team.us.corners, session.snapshot.team.opponent.corners)
            }
            if session.profile.tracks(.goalkeeping) {
                Divider()
                row("Saves", session.snapshot.team.us.saves, session.snapshot.team.opponent.saves)
            }
        }
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ us: Int, _ them: Int) -> some View {
        HStack {
            Text("\(us)").font(.body.weight(.semibold)).monospacedDigit().frame(width: 36, alignment: .leading)
            Spacer()
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text("\(them)").font(.body.weight(.semibold)).monospacedDigit().frame(width: 36, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(us) to \(them)")
    }

    private var checks: [PeriodCheck] {
        var result: [PeriodCheck] = []
        let keeperGA = session.snapshot.keepers.values.filter { $0.side == .us }
            .reduce(0) { $0 + $1.goalsAllowed }
        result.append(
            PeriodCheck(
                state: keeperGA == session.snapshot.score.opponent ? .ok : .warning,
                title: "Score reconciled",
                detail: keeperGA == session.snapshot.score.opponent
                    ? "Goals allowed match the opponent's score."
                    : "Goalkeepers are credited with \(keeperGA) goals allowed but the opponent has \(session.snapshot.score.opponent)."
            ))

        let active = session.snapshot.activeLineup.count
        result.append(
            PeriodCheck(
                state: active == session.rules.playersPerSide ? .ok : .warning,
                title: "\(active) players active at period end",
                detail: active == session.rules.playersPerSide
                    ? "Matches the \(session.rules.playersPerSide) this format expects."
                    : "This format expects \(session.rules.playersPerSide). A substitution may be missing."
            ))

        if session.needsReviewCount > 0 {
            result.append(
                PeriodCheck(
                    state: .warning,
                    title:
                        "\(session.needsReviewCount) event\(session.needsReviewCount == 1 ? "" : "s") need player attribution",
                    detail: "Assign them now while the half is fresh."
                ))
        }

        for issue in session.issues.needingReview where issue.kind != .unresolvedAttribution {
            result.append(
                PeriodCheck(
                    state: issue.severity == .blocking ? .blocking : .warning,
                    title: issue.title,
                    detail: issue.detail))
        }

        if result.allSatisfy({ $0.state == .ok }) {
            result.append(
                PeriodCheck(state: .ok, title: "Nothing needs review", detail: "The record is coherent."))
        }
        return result
    }
}

struct PeriodCheck {
    enum State {
        case ok
        case warning
        case blocking
    }

    var state: State
    var title: String
    var detail: String
}

struct CheckRow: View {
    let check: PeriodCheck

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(differentiateWithoutColor ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.body.weight(.medium))
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stateLabel). \(check.title). \(check.detail)")
    }

    private var symbolName: String {
        switch check.state {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocking: "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch check.state {
        case .ok: Programme.Palette.confirmed
        case .warning: Programme.Palette.caution
        case .blocking: Programme.Palette.critical
        }
    }

    private var stateLabel: String {
        switch check.state {
        case .ok: "Confirmed"
        case .warning: "Needs review"
        case .blocking: "Must resolve"
        }
    }
}
