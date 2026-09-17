import ProgrammeCore
import SwiftUI

/// A second window showing nothing but the score and clock, large enough to read
/// from the far touchline or on an external display.
struct ScoreboardWindow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if let session = appModel.liveSession {
                content(session: session)
            } else {
                ContentUnavailableView(
                    "No Match Being Scored",
                    systemImage: "sportscourt",
                    description: Text("Start scoring a match in Programme and it will appear here."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
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
