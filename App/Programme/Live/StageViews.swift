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
                            "pick.\(player.jerseyNumber.map(String.init) ?? player.displaySurname)")
                        .accessibilityLabel(player.accessibilityLabel)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)

            if allowsUnknown {
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
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .programmeTile(tint: tint, shape: .roundedRectangle(radius: Programme.Metrics.cornerRadius))
        .accessibilityIdentifier("pick.wide.\(title)")
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

/// Assist attribution. "Unassisted" is first and full width, because it is the
/// single most common answer and needs to be the easiest thing to hit.
struct AssistPickerStage: View {
    let scorerName: String
    let players: [PlayerSnapshot]
    var onPick: (PlayerRef?) -> Void
    var onCancel: () -> Void

    @ScaledMetric(relativeTo: .title2) private var tileHeight: CGFloat = 82

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Who assisted?")
                        .font(.title3.weight(.semibold))
                    Text("Goal by \(scorerName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
            }

            HStack(spacing: 10) {
                Button {
                    onPick(nil)
                } label: {
                    Label("Unassisted", systemImage: "circle.slash")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .programmeTile()
                .accessibilityIdentifier("assist.unassisted")
                .keyboardShortcut(.return, modifiers: [])

                Button {
                    onPick(.unidentified)
                } label: {
                    Label("Assist Unknown", systemImage: "questionmark.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .programmeTile()
            }

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
                        .accessibilityLabel("Assist by \(player.accessibilityLabel)")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(16)
    }
}

/// Optional shot placement. Always skippable: a match is fully scoreable with no
/// shot map at all.
struct ShotLocationStage: View {
    let shot: ShotEvent
    let shooterName: String
    var markers: [ShotMarker]
    @State private var location: PitchPoint?
    var onCommit: (PitchPoint?) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Where was it struck?")
                        .font(.title3.weight(.semibold))
                    Text("\(shot.outcome.label) · \(shooterName) · optional")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Skip") { onCommit(nil) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
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
                    Haptics.selectionChanged()
                }
            )
        }
        .padding(16)
    }
}
