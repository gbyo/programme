import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// A player as a tappable target. Sized for someone who is not looking at it.
///
/// This is a list row, not a card. It fills the row, takes its pressed and
/// hovered appearance from the list, and shows selection with a row background
/// and a check rather than a hand-drawn ring — so the whole column reads as one
/// surface instead of a stack of floating tiles. The row is still tall enough to
/// hit without looking, which is the part that is genuinely Programme's.
struct PlayerTile: View {
    let player: PlayerSnapshot
    var minutes: Int?
    var isGoalkeeper: Bool = false
    var isArmed: Bool = false
    var isDimmed: Bool = false
    /// Whether tapping this row arms the player for the next action. Bench rows
    /// stay readable and stay in the list, but ordinary live play cannot be
    /// credited to someone who is not on the field.
    var isArmable: Bool = true
    var badge: String?
    var perform: () -> Void

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
                        .font(.body.weight(isArmed ? .semibold : .medium))
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
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                // Selection is never carried by colour alone.
                if isArmed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .opacity(isDimmed ? 0.6 : 1)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .contentShape(.rect)
            // The system's pointer highlight, rather than a bespoke hover state.
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
        .listRowBackground(isArmed ? Color.accentColor.opacity(0.16) : nil)
        .accessibilityIdentifier("player.\(player.jerseyNumber.map(String.init) ?? player.displaySurname)")
        .accessibilityLabel(player.accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(
            isArmable
                ? "" : "On the bench. Use Substitution to bring them on, or More for a card."
        )
        .accessibilityAddTraits(isArmed ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if isGoalkeeper { parts.append("goalkeeper") }
        if !isArmable { parts.append("on the bench") }
        if let minutes { parts.append("\(minutes) minutes played") }
        if isArmed { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}

/// The leading column of the scoring workspace: who is on, who is available.
struct LineupColumn: View {
    let session: LiveMatchSession
    var onSelect: (PlayerSnapshot) -> Void

    var body: some View {
        // A plain List rather than a hand-built scrolling stack: pinned section
        // headers, separators, row highlighting, pointer hover and keyboard
        // focus are all things the system already does well here.
        List {
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
                        isDimmed: true,
                        isArmable: false,
                        badge: contributionBadge(for: player)
                    ) {
                        onSelect(player)
                    }
                }
                if session.benchPlayers.isEmpty {
                    Text("Every player is on the field.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                            isArmable: false,
                            badge: "SENT OFF"
                        ) {}
                        .disabled(true)
                    }
                } header: {
                    sectionHeader("Sent Off", count: session.dismissedPlayers.count, expected: nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollBounceBehavior(.basedOnSize)
        // Deliberately explicit rather than `.automatic`.
        //
        // Against the bottom bar, `.automatic` resolves to a hard edge effect
        // whose view sits over the last ~114pt of the list and swallows touches:
        // the bottom rows look tappable, report as hittable, and do nothing.
        // That is fatal here — the lineup is half of the scorer's two-tap path,
        // and the player they want is as likely to be #9 as #1. `.soft` renders
        // the same fade without the interactive overlay.
        .scrollEdgeEffectStyle(.soft, for: .all)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            expected != nil ? "\(title), \(count) of \(expected!) players" : "\(title), \(count) players")
    }
}
