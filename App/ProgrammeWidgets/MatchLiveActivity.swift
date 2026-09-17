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
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.teamName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(context.state.scoreUs)")
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.opponentName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(context.state.scoreOpponent)")
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    ClockText(state: context.state)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let last = context.state.lastEventText {
                        Text(last)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Text("\(context.state.scoreUs)–\(context.state.scoreOpponent)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            } compactTrailing: {
                ClockText(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Text("\(context.state.scoreUs)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .widgetURL(URL(string: "programme://live/\(context.attributes.matchID)"))
        }
    }
}

struct LockScreenMatchView: View {
    let context: ActivityViewContext<MatchActivityAttributes>

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                team(context.attributes.teamName, context.state.scoreUs)
                VStack(spacing: 1) {
                    ClockText(state: context.state)
                        .font(.title3.weight(.medium).monospacedDigit())
                    Text(context.state.periodLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 86)
                team(context.attributes.opponentName, context.state.scoreOpponent)
            }
            if let last = context.state.lastEventText {
                Text(last)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if context.state.needsReviewCount > 0 {
                Label(
                    "\(context.state.needsReviewCount) to review",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(context.attributes.teamName) \(context.state.scoreUs), \(context.attributes.opponentName) \(context.state.scoreOpponent), \(context.state.periodLabel)"
        )
    }

    private func team(_ name: String, _ score: Int) -> some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(score)")
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }
}

/// Uses a system timer while the clock runs, and a frozen string when it stops.
struct ClockText: View {
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
