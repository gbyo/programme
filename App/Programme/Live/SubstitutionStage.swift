import ProgrammeCore
import ProgrammeUI
import SwiftUI
import TipKit

/// Dedicated high-speed substitution mode.
///
/// Substitutions get the same priority as goals here: several players can go out
/// and come on in one pass, all committed at the same match time, without opening
/// and closing anything in between. The two columns make an impossible
/// substitution unreachable rather than merely rejected.
struct SubstitutionStage: View {
    let session: LiveMatchSession
    var onCommit: (_ out: [PlayerID], _ in: [PlayerID], _ goalkeeper: PlayerID?) -> Void
    var onCancel: () -> Void

    @State private var goingOut: [PlayerID] = []
    @State private var comingIn: [PlayerID] = []
    @State private var newGoalkeeper: PlayerID?

    @ScaledMetric(relativeTo: .body) private var tileHeight: CGFloat = 76
    private let multiSubTip = MultiSubstitutionTip()

    var body: some View {
        VStack(spacing: 12) {
            header

            // The tip is donated on every visit but only shown when play is
            // stopped. A scorer making a substitution during play needs the two
            // columns, not a lesson about them.
            if session.showsContextualTips {
                TipView(multiSubTip)
            }

            HStack(alignment: .top, spacing: 14) {
                column(
                    title: "Out",
                    subtitle: "On the field",
                    players: session.onFieldPlayers,
                    selection: goingOut,
                    tint: Programme.Palette.caution
                ) { player in
                    toggle(player.id, in: &goingOut)
                    if goingOut.contains(player.id), session.snapshot.activeGoalkeeper == player.id {
                        newGoalkeeper = nil
                    }
                }

                Image(systemName: "arrow.left.arrow.right")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 60)
                    .accessibilityHidden(true)

                column(
                    title: "In",
                    subtitle: "Bench",
                    players: session.benchPlayers,
                    selection: comingIn,
                    tint: Programme.Palette.confirmed
                ) { player in
                    toggle(player.id, in: &comingIn)
                }
            }

            if needsGoalkeeper {
                goalkeeperPicker
            }

            footer
        }
        .padding(16)
        // View-state selection is a declarative fact about this screen, so the
        // feedback for it is declarative too. Recording an event stays imperative
        // in the session, where the domain meaning lives.
        .sensoryFeedback(.selection, trigger: goingOut)
        .sensoryFeedback(.selection, trigger: comingIn)
        .sensoryFeedback(.selection, trigger: newGoalkeeper)
        .onAppear {
            newGoalkeeper = session.snapshot.activeGoalkeeper
            Task { await MultiSubstitutionTip.didOpenSubstitution.donate() }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Substitution")
                    .font(.title3.weight(.semibold))
                Text("At \(session.clock.displayText) · \(session.clock.periodShortLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Cancel") { onCancel() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            Button(commitTitle) { commit() }
                .accessibilityIdentifier("sub.commit")
                .programmePrimaryAction()
                .disabled(!canCommit)
                .keyboardShortcut(.return, modifiers: [])
        }
    }

    private func column(
        title: String,
        subtitle: String,
        players: [PlayerSnapshot],
        selection: [PlayerID],
        tint: Color,
        toggle: @escaping (PlayerSnapshot) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).programmeSectionHeader()
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !selection.isEmpty {
                    Text("\(selection.count)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
            }
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 90, maximum: 130), spacing: 8)], spacing: 8
                ) {
                    ForEach(players) { player in
                        let isSelected = selection.contains(player.id)
                        Button {
                            toggle(player)
                        } label: {
                            VStack(spacing: 1) {
                                Text(player.jerseyNumber.map(String.init) ?? "–")
                                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                                Text(player.displaySurname)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            }
                            .frame(maxWidth: .infinity, minHeight: tileHeight)
                        }
                        .programmeSelectable(isSelected: isSelected, tint: tint)
                        .overlay(alignment: .topTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .padding(6)
                            } else if session.snapshot.activeGoalkeeper == player.id {
                                Text("GK")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .padding(6)
                            }
                        }
                        .accessibilityIdentifier(
                            "sub.\(title.lowercased()).\(player.jerseyNumber.map(String.init) ?? player.displaySurname)"
                        )
                        .accessibilityLabel(player.accessibilityLabel)
                        .accessibilityValue(isSelected ? "selected to go \(title.lowercased())" : "")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity)
        }
    }

    private var goalkeeperPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The goalkeeper is coming off. Who takes the gloves?", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Programme.Palette.caution)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(goalkeeperCandidates) { player in
                        Button {
                            newGoalkeeper = player.id
                        } label: {
                            VStack(spacing: 1) {
                                Text(player.jerseyNumber.map(String.init) ?? "–")
                                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                                Text(player.displaySurname)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(width: 84, height: 56)
                        }
                        .programmeSelectable(
                            isSelected: newGoalkeeper == player.id,
                            shape: .roundedRectangle(radius: 10)
                        )
                        .accessibilityLabel("\(player.accessibilityLabel) in goal")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if goingOut.isEmpty && comingIn.isEmpty {
                Text("Tap players on the left to come off, and on the right to come on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(summaryText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
            Spacer()
            if goingOut.count != comingIn.count && !(goingOut.isEmpty && comingIn.isEmpty) {
                Label(
                    "This changes the number of players on the field",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(Programme.Palette.caution)
            }
        }
        .frame(minHeight: 34)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Logic

    private var needsGoalkeeper: Bool {
        guard let keeper = session.snapshot.activeGoalkeeper else {
            return !comingIn.isEmpty && session.profile.tracks(.goalkeeping) && session.snapshot.activeGoalkeeper == nil
        }
        return goingOut.contains(keeper)
    }

    /// Who can take the gloves *after* this substitution: whoever is staying on,
    /// plus whoever is coming on. Recognised goalkeepers first.
    private var goalkeeperCandidates: [PlayerSnapshot] {
        let staying = session.onFieldPlayers.filter { !goingOut.contains($0.id) }
        let incoming = session.benchPlayers.filter { comingIn.contains($0.id) }
        return (staying + incoming).sorted {
            if ($0.position == .goalkeeper) != ($1.position == .goalkeeper) {
                return $0.position == .goalkeeper
            }
            return ($0.jerseyNumber ?? .max) < ($1.jerseyNumber ?? .max)
        }
    }

    private var canCommit: Bool {
        guard !goingOut.isEmpty || !comingIn.isEmpty else { return false }
        if needsGoalkeeper && newGoalkeeper == nil { return false }
        return true
    }

    private var commitTitle: String {
        let count = max(goingOut.count, comingIn.count)
        return count > 1 ? "Make \(count) Substitutions" : "Make Substitution"
    }

    private var summaryText: String {
        func names(_ ids: [PlayerID]) -> String {
            ids.compactMap { session.roster[$0]?.shortLabel }.joined(separator: ", ")
        }
        if goingOut.isEmpty { return "\(names(comingIn)) on" }
        if comingIn.isEmpty { return "\(names(goingOut)) off" }
        return "\(names(comingIn)) for \(names(goingOut))"
    }

    private func toggle(_ id: PlayerID, in list: inout [PlayerID]) {
        if let index = list.firstIndex(of: id) {
            list.remove(at: index)
        } else {
            list.append(id)
        }
    }

    private func commit() {
        let keeperAfter: PlayerID?
        if needsGoalkeeper {
            keeperAfter = newGoalkeeper
        } else if let current = session.snapshot.activeGoalkeeper, newGoalkeeper != current {
            keeperAfter = newGoalkeeper
        } else {
            keeperAfter = nil
        }
        onCommit(goingOut, comingIn, keeperAfter)
    }
}
