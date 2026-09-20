import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// Recording a shootout.
///
/// Kept separate from the scoring palette because a shootout is not live play:
/// there is time between kicks, the order matters, and the scorer is reading
/// names off a sheet. Shootout goals are recorded as their own events and never
/// count toward the match score or a player's goal total.
struct ShootoutView: View {
    let session: LiveMatchSession

    @Environment(\.dismiss) private var dismiss
    @State private var pendingSide: TeamSide = .us
    @State private var pendingTaker: PlayerID?

    private var attempts: [(event: MatchEvent, payload: ShootoutAttemptEvent)] {
        session.context.activeEvents.compactMap { event in
            guard case .shootoutAttempt(let payload) = event.payload else { return nil }
            return (event, payload)
        }
        .sorted { $0.payload.order < $1.payload.order }
    }

    private var nextOrder: Int { (attempts.map(\.payload.order).max() ?? 0) + 1 }

    private var score: SidePair<Int> { session.snapshot.shootoutScore }

    var body: some View {
        List {
            Section {
                Picker("Side", selection: $pendingSide) {
                    Text(session.descriptor.teamShortName).tag(TeamSide.us)
                    Text(session.descriptor.opponentShortName).tag(TeamSide.opponent)
                }
                .pickerStyle(.segmented)

                if pendingSide == .us {
                    Picker("Taker", selection: $pendingTaker) {
                        Text("Choose Taker").tag(PlayerID?.none)
                        ForEach(sortedPlayers) { player in
                            Text(player.shortLabel).tag(PlayerID?.some(player.id))
                        }
                    } currentValueLabel: {
                        Text(selectedTakerLabel)
                    }
                    .pickerStyle(.navigationLink)
                }

                HStack(spacing: 12) {
                    Button {
                        record(scored: true)
                    } label: {
                        Label("Scored", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(minHeight: 52)
                    }
                    .programmePrimaryAction()
                    .buttonSizing(.flexible)
                    .disabled(pendingSide == .us && pendingTaker == nil)

                    Button {
                        record(scored: false)
                    } label: {
                        Label("Missed", systemImage: "xmark.circle")
                            .font(.headline)
                            .frame(minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .buttonSizing(.flexible)
                    .disabled(pendingSide == .us && pendingTaker == nil)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Kick \(nextOrder)")
            } footer: {
                Text(
                    "Shootout kicks are recorded separately. They decide the result but never count toward the score or a player's goal total."
                )
            }

            if !attempts.isEmpty {
                Section("Kicks") {
                    ForEach(attempts, id: \.event.id) { attempt in
                        HStack(spacing: 12) {
                            Image(
                                systemName: attempt.payload.scored
                                    ? "checkmark.circle.fill" : "xmark.circle"
                            )
                            .foregroundStyle(
                                attempt.payload.scored
                                    ? AnyShapeStyle(Programme.Palette.confirmed)
                                    : AnyShapeStyle(.tertiary))
                            Text("\(attempt.payload.order)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            Text(session.descriptor.shortName(for: attempt.payload.side))
                                .font(.subheadline.weight(.medium))
                            Text(
                                session.context.roster(for: attempt.payload.side)
                                    .label(for: attempt.payload.taker)
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                session.edit(.void(attempt.event.id), message: "Kick removed")
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .safeAreaBar(edge: .top) { scoreboard }
        .navigationTitle("Shootout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear {
            // Alternate sides by default, which is how a shootout is taken.
            pendingSide = attempts.count.isMultiple(of: 2) ? .us : .opponent
        }
        .programmeSensoryFeedback(.selection, trigger: pendingTaker) { oldValue, newValue in
            newValue != nil && newValue != oldValue
        }
    }

    private var scoreboard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(session.descriptor.teamShortName).font(.headline)
            Text("\(score.us)–\(score.opponent)")
                .font(.programmeScore(34))
            Text(session.descriptor.opponentShortName)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Shootout, \(session.descriptor.teamShortName) \(score.us), \(session.descriptor.opponentShortName) \(score.opponent)"
        )
    }

    private var sortedPlayers: [PlayerSnapshot] {
        session.roster.activeRoster.sorted {
            ($0.jerseyNumber ?? Int.max, $0.displaySurname) < ($1.jerseyNumber ?? Int.max, $1.displaySurname)
        }
    }

    private var selectedTakerLabel: String {
        guard let pendingTaker, let player = session.roster[pendingTaker] else { return "Choose Taker" }
        return player.shortLabel
    }

    private func record(scored: Bool) {
        let taker: PlayerRef =
            pendingSide == .us
            ? (pendingTaker.map(PlayerRef.player) ?? .unidentified)
            : .untracked
        session.run(
            .recordShootoutAttempt(
                ShootoutAttemptEvent(
                    side: pendingSide,
                    taker: taker,
                    goalkeeper: pendingSide == .opponent
                        ? session.snapshot.activeGoalkeeper.map(PlayerRef.player) : nil,
                    scored: scored,
                    order: nextOrder)),
            feedback: scored ? .goal : .standard)
        pendingTaker = nil
        pendingSide = pendingSide.opposite
    }
}
