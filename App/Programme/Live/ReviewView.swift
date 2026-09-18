import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// The Needs Review queue.
///
/// Nothing here interrupts play. It collects the things the scorer deferred — an
/// unreadable jersey number, a substitution that looks off — so they can be
/// settled at a break rather than in the middle of an attack.
struct ReviewView: View {
    let session: LiveMatchSession

    @Environment(\.dismiss) private var dismiss
    @State private var resolving: MatchEvent?

    var body: some View {
        List {
            if !unattributed.isEmpty {
                Section {
                    ForEach(unattributed, id: \.id) { event in
                        Button {
                            resolving = event
                        } label: {
                            let description = MatchNarrator.describe(event, context: session.context)
                            HStack(spacing: 12) {
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
                                Text("Select player")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Needs Attribution")
                } footer: {
                    Text(
                        "These were recorded during play without a jersey number. Assigning one revises the original event — no duplicate statistics."
                    )
                }
            }

            let otherIssues = session.issues.filter { $0.kind != .unresolvedAttribution }
            if !otherIssues.isEmpty {
                Section("Checks") {
                    ForEach(otherIssues) { issue in
                        IssueRow(issue: issue) {
                            guard let eventID = issue.eventID,
                                let event = session.context.events.first(where: { $0.id == eventID })
                            else { return }
                            resolving = event
                        }
                    }
                }
            }

            if unattributed.isEmpty && session.issues.isEmpty {
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
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $resolving) { event in
            NavigationStack {
                AttributionResolverView(session: session, event: event)
            }
        }
    }

    private var unattributed: [MatchEvent] {
        session.snapshot.eventsNeedingReview
    }
}

struct IssueRow: View {
    let issue: ValidationIssue
    var onOpen: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.severity.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    differentiateWithoutColor ? AnyShapeStyle(.secondary) : AnyShapeStyle(issue.severity.tint)
                )
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.body.weight(.medium))
                Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                if issue.severity == .blocking {
                    Text("Must be resolved before finalizing")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Programme.Palette.critical)
                }
            }
            Spacer(minLength: 0)
            if issue.eventID != nil {
                Button("Open", action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(issue.severity.label). \(issue.title). \(issue.detail)")
    }
}

/// Resolve one deferred attribution with a big, fast player grid.
struct AttributionResolverView: View {
    let session: LiveMatchSession
    let event: MatchEvent

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            PlayerPickerStage(
                title: promptTitle,
                players: candidates,
                goalkeeperID: session.snapshot.activeGoalkeeper,
                allowsUnknown: false,
                onPick: { ref in
                    session.attribute(eventID: event.id, slot: slot, to: ref)
                    dismiss()
                },
                onCancel: { dismiss() }
            )
        }
        .navigationTitle("Assign Player")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Delete Event", role: .destructive) {
                    session.edit(.void(event.id), message: "Event deleted")
                    dismiss()
                }
            }
        }
    }

    /// If the assist is the unknown part, resolve that rather than the shooter.
    private var slot: AttributionSlot {
        if case .shot(let shot) = event.payload, shot.shooter.isResolved, shot.assist == .unidentified {
            return .assist
        }
        return .primary
    }

    private var promptTitle: String {
        let description = MatchNarrator.describe(event, context: session.context)
        let base = slot == .assist ? "Who assisted?" : "Who was it?"
        return "\(description.timeText) · \(description.title) — \(base)"
    }

    /// Players who were on the field at that moment, which is almost always the
    /// right list, followed by the rest of the roster.
    private var candidates: [PlayerSnapshot] {
        let onFieldThen = session.snapshot.timeline.onField(side: .us, at: event.time)
        let primary = session.roster.sortedByNumber.filter { onFieldThen.contains($0.id) }
        let others = session.roster.activeRoster.filter { !onFieldThen.contains($0.id) }
        return primary + others
    }
}
