import ProgrammeCore
import SwiftUI

/// A second window showing nothing but the score and clock, large enough to read
/// from the far touchline or on an external display.
struct ScoreboardWindow: View {
    @Environment(AppModel.self) private var appModel

    @State private var isConnectingNearby = false

    var body: some View {
        Group {
            if let session = appModel.liveSession {
                content(session: session)
            } else if let received = appModel.nearby.received {
                NearbyDisplayView(
                    snapshot: received,
                    lastFrameReceivedAt: appModel.nearby.lastFrameReceivedAt
                )
                .overlay(alignment: .topTrailing) {
                    if appModel.nearby.displayLink == .live {
                        Button("Disconnect", systemImage: "wifi.slash") {
                            appModel.nearby.disconnectDisplay()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("scoreboard.disconnectNearby")
                        .padding()
                    } else {
                        Button("Reconnect…", systemImage: "wifi") {
                            isConnectingNearby = true
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("scoreboard.reconnectNearby")
                        .padding()
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Match Being Scored",
                    systemImage: "sportscourt",
                    description: Text("Start scoring a match in Programme and it will appear here.")
                )
                .overlay(alignment: .bottom) {
                    Button("Connect to Nearby Match…", systemImage: "wifi") {
                        isConnectingNearby = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("scoreboard.connectNearby")
                    .padding(.bottom, 48)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // Apple's DevicePicker documentation presents the picker as a
        // full-screen modal, not a sheet.
        .fullScreenCover(isPresented: $isConnectingNearby) {
            NearbyConnectSheet()
                .environment(appModel.nearby)
        }
    }

    private func content(session: LiveMatchSession) -> some View {
        VStack(spacing: 28) {
            Text(session.clock.periodLongLabel)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 40) {
                scoreColumn(
                    name: session.descriptor.teamShortName, value: session.snapshot.score.us)
                Text("–")
                    .font(.system(size: 80, weight: .thin))
                    .foregroundStyle(.tertiary)
                scoreColumn(
                    name: session.descriptor.opponentShortName, value: session.snapshot.score.opponent)
            }

            Text(session.clock.displayText)
                .font(.system(size: 92, weight: .light).monospacedDigit())
                .contentTransition(.numericText())
        }
        .padding(48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.descriptor.teamShortName), \(session.snapshot.score.us), \(session.descriptor.opponentShortName), \(session.snapshot.score.opponent). \(session.clock.accessibilityText)"
        )
    }

    private func scoreColumn(name: String, value: Int) -> some View {
        VStack(spacing: 10) {
            Text(name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(value)")
                .font(.system(size: 140, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(minWidth: 220)
    }
}
