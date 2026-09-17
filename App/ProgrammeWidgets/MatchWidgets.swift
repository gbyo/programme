import ProgrammeCore
import ProgrammeUI
import SwiftUI
import WidgetKit

struct ProgrammeEntry: TimelineEntry {
    var date: Date
    var snapshot: ProgrammeWidgetSnapshot?
}

struct ProgrammeTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProgrammeEntry {
        ProgrammeEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (ProgrammeEntry) -> Void) {
        completion(
            ProgrammeEntry(
                date: Date(),
                snapshot: context.isPreview ? .preview : ProgrammeSharedContainer.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProgrammeEntry>) -> Void) {
        let snapshot = ProgrammeSharedContainer.read()
        let entry = ProgrammeEntry(date: Date(), snapshot: snapshot)
        // A live match refreshes often; otherwise the next kickoff is the only
        // thing that changes, so there is no reason to burn a budget on it.
        let refresh = snapshot?.live != nil ? 60.0 : 60 * 30
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(refresh))))
    }
}

/// What is happening right now: a live match, or the next one.
struct MatchStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "org.programme.matchStatus", provider: ProgrammeTimelineProvider()) { entry in
            MatchStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Match")
        .description("The match you're scoring, or the next one on the schedule.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct MatchStatusWidgetView: View {
    var entry: ProgrammeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            if let live = snapshot.live {
                liveView(live)
            } else if let upcoming = snapshot.upcoming {
                upcomingView(upcoming, teamShortName: snapshot.teamShortName)
            } else {
                emptyView("No match scheduled")
            }
        } else {
            emptyView("Open Programme")
        }
    }

    private func liveView(_ live: ProgrammeWidgetSnapshot.LiveMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Scoring", systemImage: "record.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(live.scoreUs)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                Text("–").foregroundStyle(.tertiary)
                Text("\(live.scoreOpponent)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Text(live.opponentShortName)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 5) {
                Text(live.clockText).monospacedDigit()
                Text(live.periodLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if family != .systemSmall, let last = live.lastEventText {
                Text(last)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "programme://live/\(live.matchID)"))
        .accessibilityLabel(
            "Scoring, \(live.teamShortName) \(live.scoreUs), \(live.opponentShortName) \(live.scoreOpponent), \(live.clockText) \(live.periodLabel)"
        )
    }

    private func upcomingView(_ upcoming: ProgrammeWidgetSnapshot.UpcomingMatch, teamShortName: String)
        -> some View
    {
        VStack(alignment: .leading, spacing: 5) {
            Text("NEXT MATCH")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(upcoming.venueLabel) \(upcoming.opponentShortName)")
                .font(.headline)
                .lineLimit(2)
            Text(upcoming.kickoff.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "programme://match/\(upcoming.matchID)"))
    }

    private func emptyView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
            Text("Programme").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "programme://today"))
    }
}

/// The season at a glance.
struct SeasonRecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "org.programme.seasonRecord", provider: ProgrammeTimelineProvider()) { entry in
            SeasonRecordWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Season")
        .description("Your record and recent results.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct SeasonRecordWidgetView: View {
    var entry: ProgrammeEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(snapshot.teamShortName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(snapshot.recordText)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
                Divider()
                if snapshot.recent.isEmpty {
                    Text("No finalized matches yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.recent, id: \.matchID) { result in
                        HStack(spacing: 8) {
                            Text(result.resultLetter)
                                .font(.caption.weight(.bold))
                                .frame(width: 18)
                            Text(result.opponentShortName)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(result.scoreUs)–\(result.scoreOpponent)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .widgetURL(URL(string: "programme://season"))
        } else {
            Text("Open Programme").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension ProgrammeWidgetSnapshot {
    static let preview = ProgrammeWidgetSnapshot(
        teamName: "Ninety Six Boys Soccer",
        teamShortName: "Ninety Six",
        seasonName: "2027",
        recordText: "9-3-1",
        live: LiveMatch(
            matchID: UUID().uuidString, teamShortName: "Ninety Six", opponentShortName: "Dixie",
            scoreUs: 2, scoreOpponent: 1, periodLabel: "2nd", clockText: "23:41", isClockRunning: true,
            needsReviewCount: 1, lastEventText: "27:33 · #9 Carter · Shot on Goal · Saved"),
        upcoming: UpcomingMatch(
            matchID: UUID().uuidString, opponentShortName: "Clinton", venueLabel: "vs",
            kickoff: Date().addingTimeInterval(86_400 * 3)),
        recent: [
            RecentResult(
                matchID: UUID().uuidString, opponentShortName: "Dixie", resultLetter: "W", scoreUs: 3,
                scoreOpponent: 1, kickoff: Date().addingTimeInterval(-86_400 * 7)),
            RecentResult(
                matchID: UUID().uuidString, opponentShortName: "Ware Shoals", resultLetter: "W",
                scoreUs: 2, scoreOpponent: 0, kickoff: Date().addingTimeInterval(-86_400 * 10)),
        ])
}
