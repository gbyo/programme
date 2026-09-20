import DeviceDiscoveryUI
import Network
import ProgrammeCore
import SwiftUI

/// Renders a received snapshot with the scoreboard's visual semantics:
/// period, big score, anchor-rendered clock, last event. The clock ticks
/// locally from the anchor through the same model the scorer uses — no
/// per-second packets. A stale snapshot banners instead of going blank;
/// disconnects never affect scoring (there is no path back).
struct NearbyDisplayView: View {
    let snapshot: ScoreboardSnapshot
    /// Receiver-local receipt time of the last valid frame. The stale
    /// banner keys off this, never the wire `sentAt`.
    let lastFrameReceivedAt: Date?
    @State private var clock = MatchClockModel()
    @State private var isLinkStale = false

    var body: some View {
        VStack(spacing: 28) {
            Text(clock.periodLongLabel)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 40) {
                scoreColumn(name: snapshot.teamShortName, value: snapshot.scoreUs)
                Text("–")
                    .font(.system(size: 80, weight: .thin))
                    .foregroundStyle(.tertiary)
                scoreColumn(name: snapshot.opponentShortName, value: snapshot.scoreOpponent)
            }

            // System-animated from the snapshot's anchor, matching the
            // scorer header: advancing time costs no app-owned tick and
            // no extra nearby traffic.
            if clock.isRunning {
                Text(
                    timerInterval: WidgetClock.timerRange(
                        anchor: snapshot.clock, rules: snapshot.rules, at: Date()),
                    countsDown: WidgetClock.countsDown(rules: snapshot.rules),
                    showsHours: false
                )
                .font(.system(size: 92, weight: .light).monospacedDigit())
            } else {
                Text(clock.displayText)
                    .font(.system(size: 92, weight: .light).monospacedDigit())
            }

            if let last = snapshot.lastEventSummary {
                Text(last)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if snapshot.finalized {
                Text("Final")
                    .font(.headline.weight(.semibold))
            } else {
                // One-shot deadline: the banner flips exactly when the
                // stale threshold passes. The task below (keyed to the
                // deadline) wakes the view at that instant, so no polling
                // and no extra traffic are needed. A finalized snapshot
                // never shows this branch, so no stale work stays alive.
                if isLinkStale {
                    Label("Reconnecting…", systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("nearby.stale")
                }
            }
        }
        .padding(48)
        .task(id: snapshot.matchID) {
            clock.configure(anchor: snapshot.clock, rules: snapshot.rules)
        }
        // One-shot stale deadline keyed to the receipt time (via the
        // derived deadline, which also folds in finalization). A new
        // frame moves the deadline, cancelling this task and starting a
        // fresh wait; finalized snapshots yield no deadline, so no
        // stale-check work stays alive for them.
        .task(id: snapshot.staleDeadline(lastReceivedAt: lastFrameReceivedAt)) {
            isLinkStale = false
            guard let deadline = snapshot.staleDeadline(lastReceivedAt: lastFrameReceivedAt) else {
                return
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            isLinkStale = snapshot.isLinkStale(lastReceivedAt: lastFrameReceivedAt)
        }
        .onChange(of: snapshot) { _, next in
            clock.configure(anchor: next.clock, rules: next.rules)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(snapshot.teamShortName), \(snapshot.scoreUs), \(snapshot.opponentShortName), \(snapshot.scoreOpponent). \(clock.accessibilityText)"
        )
    }

    private func scoreColumn(name: String, value: Int) -> some View {
        VStack(spacing: 8) {
            Text(name)
                .font(.title.weight(.semibold))
            Text("\(value)")
                .font(.system(size: 92, weight: .light).monospacedDigit())
        }
    }
}

/// Scorer side: advertises this match and shows display count. Opening
/// this sheet starts advertising; dismissing it keeps serving while the
/// match is live (stop explicitly, or it ends with the session).
struct NearbyAdvertiseSheet: View {
    @Environment(NearbyScoreboardService.self) private var nearby
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch nearby.advertising {
                case .off:
                    ContentUnavailableView(
                        "Not Advertising",
                        systemImage: "wifi.slash",
                        description: Text("Start advertising to let nearby displays find this match."))
                case .waiting:
                    ContentUnavailableView(
                        "Waiting for Displays…",
                        systemImage: "wifi",
                        description: Text(
                            "Nearby devices can find this match from their scoreboard. Scoring is unaffected."))
                case .serving(let count):
                    ContentUnavailableView(
                        "Serving \(count) Display\(count == 1 ? "" : "s")",
                        systemImage: "checkmark.wifi",
                        description: Text("Displays mirror the score and clock read-only."))
                }
                // Apple's intended discoverability affordance: the system
                // pairing surface for this match, driven by the same
                // provider the listener advertises. Opening this sheet is
                // still the user-initiated act that starts advertising —
                // nothing is exposed on the LAN silently.
                DevicePairingView(
                    NearbyScoreboardService.pairingProvider,
                    label: {
                        Label("Discoverable as This Match", systemImage: "wifi")
                    },
                    fallback: {
                        Text("System pairing is unavailable on this device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                )
                .accessibilityIdentifier("nearby.pairing")
                if nearby.advertising != .off {
                    Button("Stop Advertising", systemImage: "wifi.slash", role: .destructive) {
                        nearby.stopAdvertising()
                        dismiss()
                    }
                    .accessibilityIdentifier("nearby.stopAdvertising")
                }
            }
            .padding()
            .navigationTitle("Nearby Display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { nearby.startAdvertising() }
    }
}

/// Display side: the system picker finds scorer devices; tapping one
/// connects and starts receiving. Privacy-preserving pairing is the
/// system's UI, not ours.
struct NearbyConnectSheet: View {
    @Environment(NearbyScoreboardService.self) private var nearby
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DevicePicker(
                .bonjour(NearbyScoreboardService.serviceType),
                onSelect: { endpoint in
                    nearby.connect(to: endpoint)
                    dismiss()
                },
                label: {
                    Label("Choose a Nearby Match", systemImage: "wifi")
                },
                fallback: {
                    ContentUnavailableView(
                        "No Nearby Matches",
                        systemImage: "wifi.slash",
                        description: Text(
                            "The scorer opens Connect Nearby Display… from the live match menu. Both devices need Wi-Fi or Bluetooth on."
                        ))
                }
            )
            .navigationTitle("Nearby Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
