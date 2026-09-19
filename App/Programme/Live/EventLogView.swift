import ProgrammeCore
import ProgrammeUI
import SwiftUI
import TipKit

/// The chronological record, written to be read rather than to mirror a table.
struct EventLogView: View {
    let session: LiveMatchSession
    @Environment(\.dismiss) private var dismiss
    @State private var filter: LogFilter = .all
    @State private var showsVoided = false
    @State private var editingEvent: MatchEvent?
    private let timeTip = CorrectEventTimeTip()

    enum LogFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case goals = "Goals"
        case shots = "Shots"
        case substitutions = "Subs"
        case cards = "Cards"
        case review = "Needs Review"

        var id: String { rawValue }
    }

    var body: some View {
        List {
            // The editing tip lives in the scrolling content so it goes away
            // on its own; it never takes a persistent bar above or below.
            TipView(timeTip)

            ForEach(groupedByPeriod, id: \.period) { group in
                Section(periodTitle(group.period)) {
                    ForEach(group.events, id: \.event.id) { pair in
                        NavigationLink(value: pair.event) {
                            EventLogRow(description: pair.description, isEditable: true)
                        }
                        .swipeActions(edge: .trailing) {
                            if !pair.event.payload.isStructural {
                                Button(role: .destructive) {
                                    session.edit(.void(pair.event.id), message: "Event deleted")
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            Button("Edit Event", systemImage: "pencil") { editingEvent = pair.event }
                            if pair.event.isVoided {
                                Button("Restore", systemImage: "arrow.uturn.backward") {
                                    session.edit(.restore(pair.event.id), message: "Event restored")
                                }
                            } else if !pair.event.payload.isStructural {
                                Button("Delete Event", systemImage: "trash", role: .destructive) {
                                    session.edit(.void(pair.event.id), message: "Event deleted")
                                }
                            }
                        }
                    }
                }
            }
            if groupedByPeriod.isEmpty {
                ContentUnavailableView(
                    "Nothing Recorded Yet",
                    systemImage: "list.bullet",
                    description: Text(
                        filter == .all
                            ? "Events appear here as you record them."
                            : "No \(filter.rawValue.lowercased()) have been recorded."))
            }
        }
        .listStyle(.plain)
        .navigationTitle("Event Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("Show Deleted", systemImage: "eye.slash", isOn: $showsVoided)
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Show deleted events")
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    ForEach(LogFilter.allCases) { option in
                        Button {
                            filter = option
                        } label: {
                            if filter == option {
                                Label(filterTitle(option), systemImage: "checkmark")
                            } else {
                                Text(filterTitle(option))
                            }
                        }
                    }
                } label: {
                    Label(filterTitle(filter), systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter events")
            }
        }
        .navigationDestination(for: MatchEvent.self) { event in
            EventEditView(session: session, event: event)
        }
        .navigationDestination(item: $editingEvent) { event in
            EventEditView(session: session, event: event)
        }
    }

    private struct PeriodGroup {
        var period: Int
        var events: [(event: MatchEvent, description: EventDescription)]
    }

    private var groupedByPeriod: [PeriodGroup] {
        let descriptions = MatchNarrator.describeAll(
            context: session.context, includeVoided: showsVoided)
        let events = showsVoided ? session.context.events.chronological : session.context.activeEvents
        let paired = zip(events, descriptions).filter { matches(filter: $0.0) }

        var groups: [Int: [(MatchEvent, EventDescription)]] = [:]
        for pair in paired {
            groups[pair.0.time.period, default: []].append(pair)
        }
        return groups.keys.sorted(by: >).map { period in
            PeriodGroup(
                period: period,
                events: (groups[period] ?? []).reversed().map { (event: $0.0, description: $0.1) })
        }
    }

    private func matches(filter: MatchEvent) -> Bool {
        switch self.filter {
        case .all: return true
        case .goals: return filter.category == .goal
        case .shots: return [.shot, .goal, .save].contains(filter.category)
        case .substitutions: return filter.category == .substitution
        case .cards: return filter.category == .card
        case .review: return filter.awaitsAttribution
        }
    }

    private func periodTitle(_ period: Int) -> String {
        session.rules.period(at: period)?.longLabel ?? "Period \(period)"
    }

    private func filterTitle(_ option: LogFilter) -> String {
        guard option == .review, session.needsReviewCount > 0 else { return option.rawValue }
        return "\(option.rawValue) (\(session.needsReviewCount))"
    }
}

struct EventLogRow: View {
    let description: EventDescription
    var isEditable = false

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(description.timeText)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Image(systemName: description.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20)
                .foregroundStyle(
                    description.category == .goal && !differentiateWithoutColor
                        ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(description.title)
                        .font(.body.weight(description.category == .goal ? .semibold : .regular))
                    if !description.detail.isEmpty {
                        Text(description.detail)
                            .font(.body)
                    }
                    if let score = description.scoreText {
                        Text(score)
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                if let secondary = description.secondaryDetail {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if description.needsAttribution {
                        Label("Needs player", systemImage: "questionmark.circle.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Programme.Palette.caution)
                    }
                    if description.wasEdited && !description.isVoided {
                        Label("Edited", systemImage: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if description.isVoided {
                        Label("Deleted", systemImage: "trash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(description.isVoided ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description.accessibilityLabel)
        .accessibilityHint(isEditable ? "Double tap to edit this event." : "")
    }
}
