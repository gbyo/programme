import ActivityKit
import ProgrammeCore
import ProgrammeUI
import SwiftUI
import WidgetKit

/// The active-match Live Activity.
///
/// The clock is a system timer driven by a date range, so it stays accurate on
/// the Lock Screen without Programme updating it every second.
struct MatchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MatchActivityAttributes.self) { context in
            LockScreenMatchView(context: context)
                .activityBackgroundTint(MatchActivityStyle.background)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.liveURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandTeam(
                        name: context.attributes.teamName,
                        score: context.state.scoreUs,
                        alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandTeam(
                        name: context.attributes.opponentName,
                        score: context.state.scoreOpponent,
                        alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        ClockText(state: context.state)
                            .font(.headline.weight(.semibold).monospacedDigit())
                        Text(context.state.periodLabel)
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(MatchActivityStyle.accent)
                            .textCase(.uppercase)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        if let last = context.state.lastEventText {
                            Label(last, systemImage: "waveform.path.ecg")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        } else {
                            Text(context.attributes.venueLabel)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(MatchActivityStyle.accent)
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Circle()
                        .fill(MatchActivityStyle.accent)
                        .frame(width: 5, height: 5)
                    Text("\(context.state.scoreUs)–\(context.state.scoreOpponent)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                }
            } compactTrailing: {
                ClockText(state: context.state)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: 54)
            } minimal: {
                Text("\(context.state.scoreUs)–\(context.state.scoreOpponent)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
            }
            .keylineTint(MatchActivityStyle.accent)
            .widgetURL(context.attributes.liveURL)
        }
    }
}

private struct LockScreenMatchView: View {
    let context: ActivityViewContext<MatchActivityAttributes>

    var body: some View {
        VStack(spacing: 10) {
            statusRow
            scoreRow
            detailRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Label(context.attributes.venueLabel, systemImage: "sportscourt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(MatchActivityStyle.accent)
                    .frame(width: 6, height: 6)
                Text(context.state.periodLabel)
                    .textCase(.uppercase)
                ClockText(state: context.state)
                    .monospacedDigit()
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.12), in: Capsule())
        }
    }

    private var scoreRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            teamName(context.attributes.teamName, alignment: .leading)

            Text("\(context.state.scoreUs)")
                .accessibilityLabel("\(context.state.scoreUs)")
            Text("–")
                .foregroundStyle(.white.opacity(0.38))
            Text("\(context.state.scoreOpponent)")
                .accessibilityLabel("\(context.state.scoreOpponent)")

            teamName(context.attributes.opponentName, alignment: .trailing)
        }
        .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(context.attributes.teamName) \(context.state.scoreUs), "
                + "\(context.attributes.opponentName) \(context.state.scoreOpponent)")
    }

    private var detailRow: some View {
        HStack(spacing: 10) {
            Group {
                if context.state.needsReviewCount > 0 {
                    Label(
                        "\(context.state.needsReviewCount) to review",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(MatchActivityStyle.warning)
                } else if let last = context.state.lastEventText {
                    Label(last, systemImage: "waveform.path.ecg")
                        .foregroundStyle(.white.opacity(0.78))
                } else {
                    Text("Match in progress")
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)

            Spacer(minLength: 4)

            Link(destination: context.attributes.liveURL) {
                Label("Open scorer", systemImage: "arrow.up.forward.app.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MatchActivityStyle.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.white, in: Capsule())
            }
            .accessibilityHint("Opens this match in Programme")
        }
    }

    private func teamName(_ name: String, alignment: Alignment) -> some View {
        Text(name)
            .font(.subheadline.weight(.bold))
            .lineLimit(2)
            .minimumScaleFactor(0.72)
            .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

}

private struct IslandTeam: View {
    let name: String
    let score: Int
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
            Text("\(score)")
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

private enum MatchActivityStyle {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.08)
    static let accent = Color(red: 0.33, green: 0.92, blue: 0.62)
    static let warning = Color(red: 1, green: 0.72, blue: 0.26)
}

extension MatchActivityAttributes {
    fileprivate var liveURL: URL {
        URL(string: "programme://live/\(matchID)")!
    }
}

/// Uses a system timer while the clock runs, and a frozen string when it stops.
private struct ClockText: View {
    let state: MatchActivityAttributes.ContentState

    var body: some View {
        if state.isClockRunning {
            Text(timerInterval: state.timerRange, countsDown: state.countsDown)
                .multilineTextAlignment(.center)
        } else {
            Text(state.frozenClockText)
        }
    }
}
