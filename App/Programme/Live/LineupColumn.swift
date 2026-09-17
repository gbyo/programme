import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// A player as a tappable target. Sized for someone who is not looking at it.
struct PlayerTile: View {
    let player: PlayerSnapshot
    var minutes: Int?
    var isGoalkeeper: Bool = false
    var isArmed: Bool = false
    var isDimmed: Bool = false
    var badge: String?
    var perform: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = Programme.Metrics.playerRowHeight

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Text(player.jerseyNumber.map(String.init) ?? "–")
                    .font(.programmeJersey(19))
                    .frame(minWidth: 34, alignment: .trailing)
                    .foregroundStyle(isArmed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))

                VStack(alignment: .leading, spacing: 1) {
                    Text(player.displaySurname)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let minutes {
                        Text("\(minutes)'")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 4)

                if isGoalkeeper {
                    Text("GK")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .accessibilityHidden(true)
                }
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isArmed ? Color.accentColor : .clear,
                    lineWidth: isArmed ? (differentiateWithoutColor ? 3 : 2) : 0)
        )
        .opacity(isDimmed ? 0.45 : 1)
        .accessibilityIdentifier("player.\(player.jerseyNumber.map(String.init) ?? player.displaySurname)")
        .accessibilityLabel(player.accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isArmed ? [.isSelected, .isButton] : .isButton)
    }

    private var background: some ShapeStyle {
        isArmed ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(Color(.secondarySystemFill))
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if isGoalkeeper { parts.append("goalkeeper") }
        if let minutes { parts.append("\(minutes) minutes played") }
        if isArmed { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}

/// The leading column of the scoring workspace: who is on, who is available.
struct LineupColumn: View {
    let session: LiveMatchSession
    var onSelect: (PlayerSnapshot) -> Void
    var onSubstitute: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(session.onFieldPlayers) { player in
                        PlayerTile(
                            player: player,
                            minutes: session.snapshot.player(player.id).minutesPlayed,
                            isGoalkeeper: session.snapshot.activeGoalkeeper == player.id,
                            isArmed: session.armedPlayer == player.id,
                            badge: contributionBadge(for: player)
                        ) {
                            onSelect(player)
                        }
                    }
                } header: {
                    sectionHeader(
                        "On Field", count: session.onFieldPlayers.count,
                        expected: session.rules.playersPerSide)
                }

                Section {
                    ForEach(session.benchPlayers) { player in
                        PlayerTile(
                            player: player,
                            minutes: minutesIfPlayed(player),
                            isArmed: session.armedPlayer == player.id,
                            isDimmed: true,
                            badge: contributionBadge(for: player)
                        ) {
                            onSelect(player)
                        }
                    }
                    if session.benchPlayers.isEmpty {
                        Text("Every player is on the field.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                } header: {
                    sectionHeader("Bench", count: session.benchPlayers.count, expected: nil)
                }

                if !session.dismissedPlayers.isEmpty {
                    Section {
                        ForEach(session.dismissedPlayers) { player in
                            PlayerTile(
                                player: player,
                                minutes: session.snapshot.player(player.id).minutesPlayed,
                                isDimmed: true,
                                badge: "SENT OFF"
                            ) {}
                                .disabled(true)
                        }
                    } header: {
                        sectionHeader("Sent Off", count: session.dismissedPlayers.count, expected: nil)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    onSubstitute()
                } label: {
                    Label("Substitution", systemImage: "arrow.left.arrow.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("lineup.substitution")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func minutesIfPlayed(_ player: PlayerSnapshot) -> Int? {
        let line = session.snapshot.player(player.id)
        return line.appeared ? line.minutesPlayed : nil
    }

    /// A very small nudge that this player has done something, so the scorer can
    /// confirm an attribution landed without opening the log.
    private func contributionBadge(for player: PlayerSnapshot) -> String? {
        let line = session.snapshot.player(player.id)
        var parts: [String] = []
        if line.goals > 0 { parts.append("\(line.goals)G") }
        if line.assists > 0 { parts.append("\(line.assists)A") }
        if line.yellowCards > 0 { parts.append("YC") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func sectionHeader(_ title: String, count: Int, expected: Int?) -> some View {
        HStack {
            Text(title)
                .programmeSectionHeader()
            Spacer()
            Text(expected.map { "\(count)/\($0)" } ?? "\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(
                    expected != nil && count != expected ? Programme.Palette.caution : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            expected != nil ? "\(title), \(count) of \(expected!) players" : "\(title), \(count) players")
    }
}
