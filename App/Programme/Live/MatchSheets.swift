import ProgrammeCore
import ProgrammeUI
import SwiftUI

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
                .programmeConfirmationTint()
            }
        }
        .onAppear {
            minutes = session.clock.matchTime.minute
            seconds = session.clock.matchTime.second
        }
    }
}
