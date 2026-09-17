import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// Secondary match controls. Everything here is deliberately out of the way of
/// live scoring, and none of it is needed to record an event.
struct MatchOptionsSheet: View {
    let session: LiveMatchSession
    var onEditLineup: () -> Void
    var onShootout: () -> Void
    var onFinalize: () -> Void
    var onClose: () -> Void
    var onShowStats: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var isAdjustingClock = false
    @State private var isConfirmingClose = false
    @State private var isEditingOpponentRoster = false

    var body: some View {
        List {
            Section {
                Button("Match Stats", systemImage: "chart.bar") { onShowStats() }
                Button("Edit Lineup", systemImage: "person.3") { onEditLineup() }
                if session.descriptor.tracking == .bothTeams {
                    Button("\(session.descriptor.opponentShortName) Roster", systemImage: "person.2") {
                        isEditingOpponentRoster = true
                    }
                }
                Button("Adjust Clock", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                    isAdjustingClock = true
                }
                Button("Open Scoreboard Window", systemImage: "rectangle.on.rectangle") {
                    openWindow(id: ProgrammeScene.scoreboard.rawValue)
                    dismiss()
                }
            }

            Section {
                if session.phase == .inPeriod {
                    Button("End \(session.clock.periodLongLabel)", systemImage: "pause.fill") {
                        session.endCurrentPeriod()
                        dismiss()
                    }
                }
                if session.canStartNextPeriod {
                    Button("Start \(session.nextPeriodLabel)", systemImage: "play.fill") {
                        session.startNextPeriod()
                        dismiss()
                    }
                }
                if session.rules.shootoutAvailable {
                    Button("Shootout", systemImage: "circle.bottomhalf.filled") { onShootout() }
                }
                Button("Finalize Match", systemImage: "flag.checkered") { onFinalize() }
            }

            Section {
                Button("Close Scorer", systemImage: "xmark.circle") {
                    if session.phase.isLive {
                        isConfirmingClose = true
                    } else {
                        onClose()
                    }
                }
            } footer: {
                Text(
                    "Everything recorded is already saved. Closing the scorer leaves the match where it is — you can resume it at any time."
                )
            }
        }
        .navigationTitle("Match")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .sheet(isPresented: $isAdjustingClock) {
            NavigationStack { ClockAdjustmentView(session: session) }
        }
        .sheet(isPresented: $isEditingOpponentRoster) {
            NavigationStack { OpponentRosterView(session: session) }
        }
        .confirmationDialog(
            "Leave this match running?", isPresented: $isConfirmingClose, titleVisibility: .visible
        ) {
            Button("Close Scorer") { onClose() }
        } message: {
            Text("The match stays live and every event is saved. Programme will offer to resume it.")
        }
    }
}

/// Correcting the clock never rewrites the times already recorded on events.
struct ClockAdjustmentView: View {
    let session: LiveMatchSession

    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 0
    @State private var seconds: Int = 0
    @State private var reason: String = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    Picker("Minutes", selection: $minutes) {
                        ForEach(0...60, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 90, height: 120)
                    .clipped()
                    Text(":").font(.title2)
                    Picker("Seconds", selection: $seconds) {
                        ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 90, height: 120)
                    .clipped()
                    Spacer()
                }
            } header: {
                Text("Elapsed in \(session.clock.periodLongLabel)")
            } footer: {
                Text(
                    "Programme stores elapsed time, so this is the time played in this period — the scoreboard reading is derived from it."
                )
            }

            Section("Reason") {
                TextField("Scoreboard correction", text: $reason, axis: .vertical)
            }

            Section {
                Text(
                    "Events already recorded keep the times they were recorded at. The adjustment itself is stored in the event log so the change is auditable."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Adjust Clock")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    session.adjustClock(
                        toSeconds: minutes * 60 + seconds,
                        reason: reason.isEmpty ? nil : reason)
                    dismiss()
                }
            }
        }
        .onAppear {
            minutes = session.clock.matchTime.minute
            seconds = session.clock.matchTime.second
        }
    }
}

/// Everything that is real but uncommon. Labelled plainly rather than buried in
/// a context menu.
struct MoreActionsSheet: View {
    let session: LiveMatchSession
    var onPick: (PendingAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isAddingNote = false
    @State private var note = ""

    var body: some View {
        List {
            Section("Discipline") {
                Button("Second Yellow", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                    onPick(.card(.secondYellow))
                }
                if session.profile.tracks(.fouls) {
                    Button("Foul", systemImage: "exclamationmark.triangle") { onPick(.foul) }
                }
                if session.profile.tracks(.offsides) {
                    Button("Offside", systemImage: "flag.slash") { onPick(.offside) }
                }
            }

            Section("Unusual") {
                Button("Own Goal", systemImage: "arrow.uturn.backward.circle") { onPick(.ownGoal) }
                Button("Change Goalkeeper", systemImage: "hand.raised") { onPick(.goalkeeper) }
                Button("Shot Hit the Woodwork", systemImage: "diamond") { onPick(.shot(.woodwork)) }
                Button("Shot Blocked", systemImage: "shield") { onPick(.shot(.blocked)) }
            }

            Section("Opponent") {
                Button("Opponent Penalty Kick", systemImage: "circle.bottomhalf.filled") {
                    session.run(
                        .recordShot(
                            ShotEvent(
                                side: .opponent, shooter: .untracked, outcome: .goal, phase: .penaltyKick)))
                    dismiss()
                }
                Button("Opponent Card", systemImage: "rectangle.portrait") {
                    session.run(
                        .recordCard(CardEvent(side: .opponent, player: .untracked, card: .yellow)))
                    dismiss()
                }
            }

            Section("Notes") {
                Button("Add a Note", systemImage: "text.quote") { isAddingNote = true }
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .alert("Add a note", isPresented: $isAddingNote) {
            TextField("What happened?", text: $note)
            Button("Cancel", role: .cancel) { note = "" }
            Button("Add") {
                if !note.isEmpty { session.run(.addNote(note), feedback: .silent) }
                note = ""
                dismiss()
            }
        } message: {
            Text("Notes appear in the event log and in exported stat sheets.")
        }
    }
}
