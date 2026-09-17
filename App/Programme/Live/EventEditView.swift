import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// Focused editing for one event.
///
/// Every correction here revises the existing event rather than creating a new
/// one, so derived statistics move with it and nothing is left orphaned.
struct EventEditView: View {
    let session: LiveMatchSession
    let event: MatchEvent

    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var period: Int
    @State private var isConfirmingDelete = false

    init(session: LiveMatchSession, event: MatchEvent) {
        self.session = session
        self.event = event
        _minutes = State(initialValue: event.time.minute)
        _seconds = State(initialValue: event.time.second)
        _period = State(initialValue: event.time.period)
    }

    private var current: MatchEvent {
        session.context.events.first { $0.id == event.id } ?? event
    }

    var body: some View {
        Form {
            Section {
                let description = MatchNarrator.describe(current, context: session.context)
                VStack(alignment: .leading, spacing: 4) {
                    Text(description.title)
                        .font(.headline)
                    if !description.detail.isEmpty {
                        Text(description.detail).font(.subheadline)
                    }
                    if let secondary = description.secondaryDetail {
                        Text(secondary).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Time") {
                Picker("Period", selection: $period) {
                    ForEach(session.rules.periods) { descriptor in
                        Text(descriptor.longLabel).tag(descriptor.index)
                    }
                }
                HStack {
                    Text("Elapsed")
                    Spacer()
                    Picker("Minutes", selection: $minutes) {
                        ForEach(0...60, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 80, height: 100)
                    .clipped()
                    Text(":")
                    Picker("Seconds", selection: $seconds) {
                        ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 80, height: 100)
                    .clipped()
                }
                if timeChanged {
                    Button("Apply New Time") { applyTime() }
                        .font(.body.weight(.semibold))
                    Text("Playing time for every affected player is recalculated automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            attributionSection

            if case .shot(let shot) = current.payload {
                Section("Outcome") {
                    Picker("Outcome", selection: outcomeBinding(shot)) {
                        ForEach(ShotOutcome.allCases, id: \.self) { outcome in
                            Text(outcome.label).tag(outcome)
                        }
                    }
                    Picker("Phase", selection: phaseBinding(shot)) {
                        ForEach(PlayPhase.allCases, id: \.self) { phase in
                            Text(phase.label).tag(phase)
                        }
                    }
                    Toggle("Own Goal", isOn: ownGoalBinding(shot))
                        .disabled(!shot.outcome.isGoal)
                }
            }

            if case .card(let card) = current.payload {
                Section("Card") {
                    Picker("Card", selection: cardBinding(card)) {
                        ForEach(CardType.allCases, id: \.self) { type in
                            Text(type.label).tag(type)
                        }
                    }
                }
            }

            if !current.revisions.isEmpty {
                Section("History") {
                    ForEach(current.revisions.reversed()) { revision in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(revision.summary).font(.subheadline)
                            Text(revision.at.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !current.payload.isStructural {
                Section {
                    if current.isVoided {
                        Button("Restore Event", systemImage: "arrow.uturn.backward") {
                            session.edit(.restore(current.id), message: "Event restored")
                            dismiss()
                        }
                    } else {
                        Button("Delete Event", systemImage: "trash", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                } footer: {
                    Text("Deleting an event corrects every statistic derived from it. You can restore it from the event log.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Edit Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Delete this event?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Event", role: .destructive) {
                session.edit(.void(current.id), message: "Event deleted")
                dismiss()
            }
        } message: {
            Text("Statistics will be recalculated. You can restore it from the event log.")
        }
    }

    // MARK: - Attribution

    @ViewBuilder
    private var attributionSection: some View {
        switch current.payload {
        case .shot(let shot):
            Section("Players") {
                playerPicker(
                    "Shooter", current: shot.shooter, slot: .primary, includeUnknown: true)
                if shot.outcome.isGoal {
                    assistPicker(current: shot.assist)
                }
            }
        case .corner(let action), .steal(let action), .foul(let action), .offside(let action):
            Section("Player") {
                playerPicker("Player", current: action.player, slot: .primary, includeUnknown: true)
            }
        case .card(let card):
            Section("Player") {
                playerPicker(
                    "Player", current: card.player, slot: .primary, includeUnknown: true,
                    fromFullRoster: true)
            }
        default:
            EmptyView()
        }
    }

    private func playerPicker(
        _ label: String, current currentRef: PlayerRef, slot: AttributionSlot,
        includeUnknown: Bool, fromFullRoster: Bool = false
    ) -> some View {
        Picker(
            label,
            selection: Binding(
                get: { currentRef },
                set: { session.attribute(eventID: current.id, slot: slot, to: $0) })
        ) {
            if includeUnknown {
                Text("Player unknown").tag(PlayerRef.unidentified)
            }
            if current.payload.side == .opponent {
                Text(session.descriptor.opponentShortName).tag(PlayerRef.untracked)
            }
            ForEach(candidates(fromFullRoster: fromFullRoster)) { player in
                Text(player.shortLabel).tag(PlayerRef.player(player.id))
            }
        }
    }

    private func assistPicker(current assist: PlayerRef?) -> some View {
        Picker(
            "Assist",
            selection: Binding<String>(
                get: {
                    switch assist {
                    case .none: "none"
                    case .some(.unidentified): "unknown"
                    case .some(.untracked): "untracked"
                    case .some(.player(let id)): id.rawValue.uuidString
                    }
                },
                set: { value in
                    switch value {
                    case "none":
                        applyAssist(nil)
                    case "unknown":
                        session.attribute(eventID: current.id, slot: .assist, to: .unidentified)
                    case "untracked":
                        session.attribute(eventID: current.id, slot: .assist, to: .untracked)
                    default:
                        guard let uuid = UUID(uuidString: value) else { return }
                        session.attribute(eventID: current.id, slot: .assist, to: .player(PlayerID(uuid)))
                    }
                })
        ) {
            Text("Unassisted").tag("none")
            Text("Assist unknown").tag("unknown")
            ForEach(candidates(fromFullRoster: false)) { player in
                Text(player.shortLabel).tag(player.id.rawValue.uuidString)
            }
        }
    }

    private func applyAssist(_ ref: PlayerRef?) {
        guard case .shot(var shot) = current.payload else { return }
        shot.assist = ref
        session.edit(
            .replacePayload(current.id, .shot(shot), summary: "Assist removed"),
            message: "Recorded as unassisted")
    }

    private func candidates(fromFullRoster: Bool) -> [PlayerSnapshot] {
        fromFullRoster
            ? session.roster.activeRoster
            : session.roster.sortedByNumber.filter {
                session.snapshot.player($0.id).appeared || session.snapshot.activeLineup.contains($0.id)
            }
    }

    // MARK: - Bindings

    private var timeChanged: Bool {
        MatchTime(period: period, secondsElapsed: minutes * 60 + seconds) != current.time
    }

    private func applyTime() {
        let time = MatchTime(period: period, secondsElapsed: minutes * 60 + seconds)
        session.edit(
            .changeTime(current.id, time),
            message: "Moved to \(time.displayText(rules: session.rules))")
    }

    private func outcomeBinding(_ shot: ShotEvent) -> Binding<ShotOutcome> {
        Binding(
            get: { shot.outcome },
            set: { newValue in
                var updated = shot
                updated.outcome = newValue
                if !newValue.isGoal { updated.assist = nil }
                session.edit(
                    .replacePayload(
                        current.id, .shot(updated), summary: "Outcome changed to \(newValue.label)"),
                    message: "Outcome updated")
            })
    }

    private func phaseBinding(_ shot: ShotEvent) -> Binding<PlayPhase> {
        Binding(
            get: { shot.phase },
            set: { newValue in
                var updated = shot
                updated.phase = newValue
                session.edit(
                    .replacePayload(current.id, .shot(updated), summary: "Phase changed to \(newValue.label)"),
                    message: "Updated")
            })
    }

    private func ownGoalBinding(_ shot: ShotEvent) -> Binding<Bool> {
        Binding(
            get: { shot.isOwnGoal },
            set: { newValue in
                var updated = shot
                updated.isOwnGoal = newValue
                if newValue { updated.assist = nil }
                session.edit(
                    .replacePayload(
                        current.id, .shot(updated),
                        summary: newValue ? "Marked as an own goal" : "No longer an own goal"),
                    message: newValue ? "Recorded as an own goal" : "Updated")
            })
    }

    private func cardBinding(_ card: CardEvent) -> Binding<CardType> {
        Binding(
            get: { card.card },
            set: { newValue in
                var updated = card
                updated.card = newValue
                session.edit(
                    .replacePayload(current.id, .card(updated), summary: "Changed to \(newValue.label)"),
                    message: "Card updated")
            })
    }
}
