import ProgrammeCore
import SwiftUI

/// Read-only glanceable companion: selected team, live score, next
/// kickoff, recent results, review count. No scoring controls exist
/// anywhere in this target.
struct WatchContentView: View {
    var session: WatchSession

    var body: some View {
        ScrollView {
            if let snapshot = session.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    header(snapshot)
                    if let live = snapshot.live {
                        liveView(live)
                    } else if let upcoming = snapshot.upcoming {
                        upcomingView(upcoming)
                    } else {
                        Text("No match scheduled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    recentView(snapshot.recent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    Text("Programme")
                        .font(.headline)
                    Text("Open Programme on iPhone to send the latest score.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle(session.snapshot?.teamShortName ?? "Programme")
    }

    private func header(_ snapshot: WatchSnapshot) -> some View {
        HStack {
            Text(snapshot.recordText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if snapshot.reviewCount > 0 {
                Label("\(snapshot.reviewCount)", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func liveView(_ live: WatchSnapshot.Live) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("LIVE", systemImage: "record.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(live.scoreUs)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                Text("–").foregroundStyle(.tertiary)
                Text("\(live.scoreOpponent)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Text(live.opponentShortName)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            // The clock renders on-watch from the anchor carried in the
            // snapshot: no tick stream crosses the radio.
            if live.clock.isRunning {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    Text(clockText(live, at: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(clockText(live, at: Date()))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let last = live.lastEventText {
                Text(last)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func clockText(_ live: WatchSnapshot.Live, at date: Date) -> String {
        let time = live.clock.matchTime(at: date)
        let period = live.rules.period(at: live.clock.period)?.shortLabel ?? ""
        return "\(time.displayText(rules: live.rules)) \(period)".trimmingCharacters(
            in: .whitespaces)
    }

    private func upcomingView(_ upcoming: WatchSnapshot.Upcoming) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEXT MATCH")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(upcoming.opponentShortName)
                .font(.headline)
                .lineLimit(1)
            Text("\(upcoming.venueLabel) · \(upcoming.kickoff.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func recentView(_ recent: [WatchSnapshot.Recent]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(recent.prefix(3), id: \.matchID) { result in
                HStack {
                    Text(result.resultLetter)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(result.opponentShortName)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    Text("\(result.scoreUs)–\(result.scoreOpponent)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
