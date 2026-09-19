import ProgrammeCore
import ProgrammeUI
import SwiftUI
import TipKit

/// A large, fast player chooser that takes over the centre of the workspace.
/// Big targets, no scrolling for a normal squad, and an obvious way out.
struct PlayerPickerStage: View {
    let title: String
    let players: [PlayerSnapshot]
    var goalkeeperID: PlayerID?
    var allowsUnknown: Bool
    var unknownTitle: String = "Player Unknown"
    var unknownSubtitle: String = "Record now, attribute later"
    var extraOption: (title: String, subtitle: String)?
    /// Educational UI only appears when the scorer is not executing. See
    /// `LiveMatchSession.showsContextualTips`.
    var showsTips: Bool = false
    var onPick: (PlayerRef) -> Void
    var onExtra: (() -> Void)?
    var onCancel: () -> Void

    @ScaledMetric(relativeTo: .title2) private var tileHeight: CGFloat = 86
    private let unknownTip = UnknownPlayerTip()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel", systemImage: "xmark") { onCancel() }
                    .labelStyle(.titleOnly)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(players) { player in
                        Button {
                            onPick(.player(player.id))
                        } label: {
                            VStack(spacing: 2) {
                                Text(player.jerseyNumber.map(String.init) ?? "–")
                                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                                Text(player.displaySurname)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: tileHeight)
                        }
                        .programmeTile(shape: .roundedRectangle(radius: Programme.Metrics.cornerRadius))
                        .overlay(alignment: .topTrailing) {
                            if player.id == goalkeeperID {
                                Text("GK")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                            }
                        }
                        .accessibilityIdentifier(
                            "pick.\(player.jerseyNumber.map(String.init) ?? player.displaySurname)"
                        )
                        .accessibilityLabel(player.accessibilityLabel)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)

            // No tip while the clock is running: the button below says what it
            // does, and a live scorer is executing rather than learning.
            if allowsUnknown && showsTips {
                TipView(unknownTip)
            }

            HStack(spacing: 10) {
                if let extraOption {
                    wideButton(
                        title: extraOption.title, subtitle: extraOption.subtitle,
                        symbol: "arrow.uturn.backward", tint: .secondary
                    ) {
                        onExtra?()
                    }
                }
                if allowsUnknown {
                    wideButton(
                        title: unknownTitle, subtitle: unknownSubtitle,
                        symbol: "questionmark.circle", tint: Programme.Palette.caution
                    ) {
                        onPick(.unidentified)
                    }
                }
            }
        }
        .padding(16)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 10)]
    }

    private func wideButton(
        title: String, subtitle: String, symbol: String, tint: Color, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 60)
        }
        .programmeTile(tint: tint, shape: .roundedRectangle(radius: Programme.Metrics.cornerRadius))
        .buttonSizing(.flexible)
        .accessibilityIdentifier("pick.wide.\(title)")
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

/// Assist attribution, for a goal that is **already recorded**.
///
/// The score has already moved and the event is already journalled by the time
/// this appears, so nothing here is load-bearing: every exit leaves a correct
/// goal behind. That is why the escape is "Not now" rather than "Cancel" — there
/// is nothing to cancel.
///
/// Most goals are unassisted, so "Unassisted" is not one option among several: it
/// is a single full-width target across the top, and the Return key triggers it.
/// The players who could actually have assisted come next, visible without
/// scrolling for a normal squad. "Assist Unknown" is real and stays available,
/// but it is the quiet row at the bottom rather than an equal partner.
struct AssistPickerStage: View {
    let scorerName: String
    let players: [PlayerSnapshot]
    var onPick: (PlayerRef?) -> Void
    var onSkip: () -> Void

    @ScaledMetric(relativeTo: .title2) private var tileHeight: CGFloat = 82
    @ScaledMetric(relativeTo: .title3) private var unassistedHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Who assisted?")
                        .font(.title3.weight(.semibold))
                    Label("Goal recorded · \(scorerName)", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Programme.Palette.confirmed)
                        .accessibilityIdentifier("assist.recordedConfirmation")
                }
                Spacer()
                Button("Not now") { onSkip() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("assist.notNow")
                    .accessibilityHint("Leaves the assist for Review. The goal stays recorded.")
            }

            Button {
                onPick(nil)
            } label: {
                Label("Unassisted", systemImage: "circle.slash")
                    .font(.title3.weight(.semibold))
                    .frame(minHeight: unassistedHeight)
            }
            .programmePrimaryAction()
            .buttonSizing(.flexible)
            .buttonBorderShape(.roundedRectangle(radius: Programme.Metrics.cornerRadius))
            .accessibilityIdentifier("assist.unassisted")
            .keyboardShortcut(.return, modifiers: [])

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 10)], spacing: 10) {
                    ForEach(players) { player in
                        Button {
                            onPick(.player(player.id))
                        } label: {
                            VStack(spacing: 2) {
                                Text(player.jerseyNumber.map(String.init) ?? "–")
                                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                                Text(player.displaySurname)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: tileHeight)
                        }
                        .programmeTile()
                        .accessibilityIdentifier(
                            "assist.\(player.jerseyNumber.map(String.init) ?? player.displaySurname)"
                        )
                        .accessibilityLabel("Assist by \(player.accessibilityLabel)")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Button {
                onPick(.unidentified)
            } label: {
                Label("Assist Unknown", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 46)
            }
            .buttonStyle(.bordered)
            .buttonSizing(.flexible)
            .buttonBorderShape(.roundedRectangle(radius: Programme.Metrics.cornerRadius))
            .tint(.secondary)
            .accessibilityIdentifier("assist.unknown")
            .accessibilityHint("Records the assist now and collects it under Review.")
        }
        .padding(16)
    }
}

/// Optional shot placement, for a shot that is **already recorded**.
///
/// Always skippable, and skipping now costs nothing at all: the shot exists with
/// its outcome and its shooter before this appears. A match is fully scoreable
/// with no shot map.
struct ShotLocationStage: View {
    let shooterName: String
    let outcome: ShotOutcome
    var markers: [ShotMarker]
    @State private var location: PitchPoint?
    var onCommit: (PitchPoint?) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Where was it struck?")
                        .font(.title3.weight(.semibold))
                    Label("\(outcome.label) recorded · \(shooterName)", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Programme.Palette.confirmed)
                }
                Spacer()
                Button("Skip") { onCommit(nil) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("shotLocation.skip")
                Button("Record") { onCommit(location) }
                    .programmePrimaryAction()
                    .disabled(location == nil)
                    .keyboardShortcut(.return, modifiers: [])
            }
            PitchView(
                markers: markers,
                pendingLocation: location,
                isPlacementActive: true,
                onPlace: { point in
                    location = point
                }
            )
        }
        .padding(16)
        .sensoryFeedback(.selection, trigger: location)
    }
}
