import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// One primary scoring action.
struct PaletteAction: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var symbolName: String
    var pending: PendingAction?
    var kind: Kind
    /// A single, unmodified key. A scorer with a hardware keyboard should not
    /// have to reach for the screen for the common actions.
    var shortcut: KeyEquivalent?

    enum Kind: Equatable {
        case standard
        case emphasis
        case caution
        case critical
        case more
    }
}

/// The fixed action palette.
///
/// The order never changes during a match. Programme deliberately does not
/// reorder by frequency or promote recent actions: a scorer who is watching the
/// pitch is aiming from memory, and muscle memory is worth more than any
/// cleverness about what they tapped most last week.
struct EventPalette: View {
    let session: LiveMatchSession
    let isCompact: Bool
    var onAction: (PaletteAction) -> Void
    var onOpponentAction: (OpponentQuickAction) -> Void
    var onMore: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.descriptor.teamShortName)
                .programmeSectionHeader()
                .padding(.horizontal, 4)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(actions) { action in
                    PaletteButton(
                        action: action,
                        isArmed: session.armedPlayer != nil,
                        differentiateWithoutColor: differentiateWithoutColor
                    ) {
                        if action.kind == .more { onMore() } else { onAction(action) }
                    }
                }
            }

            OpponentStrip(
                opponentName: session.descriptor.opponentShortName,
                profile: session.profile,
                action: onOpponentAction)
        }
    }

    private var columns: [GridItem] {
        if isCompact {
            [GridItem(.adaptive(minimum: 220), spacing: 10)]
        } else {
            [
                GridItem(.flexible(minimum: 120), spacing: 10),
                GridItem(.flexible(minimum: 120), spacing: 10),
            ]
        }
    }

    /// Built from the match's stat profile, which is fixed before kickoff.
    var actions: [PaletteAction] {
        let profile = session.profile
        var result: [PaletteAction] = [
            PaletteAction(
                id: "goal", title: "Goal", subtitle: "Scorer, then assist",
                symbolName: "soccerball.inverse", pending: .goal(.openPlay), kind: .emphasis, shortcut: "g")
        ]
        if profile.tracks(.shots) {
            result.append(
                PaletteAction(
                    id: "sog", title: "Shot on Goal", subtitle: "Saved by their keeper",
                    symbolName: "scope", pending: .shot(.saved), kind: .standard, shortcut: "s"))
            result.append(
                PaletteAction(
                    id: "shot", title: "Shot", subtitle: "Off target",
                    symbolName: "arrow.up.forward", pending: .shot(.offTarget), kind: .standard, shortcut: "h"))
        }
        if profile.tracks(.goalkeeping) {
            result.append(
                PaletteAction(
                    id: "save", title: "Save", subtitle: "Their shot on goal",
                    symbolName: "hand.raised.fill", pending: nil, kind: .standard, shortcut: "v"))
        }
        if profile.tracks(.corners) {
            result.append(
                PaletteAction(
                    id: "corner", title: "Corner", subtitle: nil, symbolName: "flag.fill",
                    pending: .corner, kind: .standard, shortcut: "c"))
        }
        if profile.tracks(.steals) {
            result.append(
                PaletteAction(
                    id: "steal", title: "Steal", subtitle: nil, symbolName: "shoe.2.fill",
                    pending: .steal, kind: .standard, shortcut: "t"))
        }
        if profile.tracks(.penaltyKicks) {
            result.append(
                PaletteAction(
                    id: "pk", title: "Penalty Kick", subtitle: nil, symbolName: "circle.bottomhalf.filled",
                    pending: .goal(.penaltyKick), kind: .standard, shortcut: "p"))
        }
        if profile.tracks(.cards) {
            result.append(
                PaletteAction(
                    id: "yellow", title: "Yellow Card", subtitle: nil, symbolName: "rectangle.portrait",
                    pending: .card(.yellow), kind: .caution, shortcut: "y"))
            result.append(
                PaletteAction(
                    id: "red", title: "Red Card", subtitle: nil, symbolName: "rectangle.portrait.fill",
                    pending: .card(.red), kind: .critical, shortcut: "r"))
        }
        result.append(
            PaletteAction(
                id: "more", title: "More", subtitle: nil, symbolName: "ellipsis.circle",
                pending: nil, kind: .more, shortcut: "m"))
        return result
    }
}

/// One palette action.
///
/// The geometry is Programme's — a fixed two-column grid with a tall, left-aligned
/// target that never moves during a match — but the control is the system's
/// stable target that never moves during a match. Primary and semantic actions
/// carry colour; ordinary actions use the system background with a hairline
/// boundary instead of becoming a wall of grey fills.
struct PaletteButton: View {
    let action: PaletteAction
    let isArmed: Bool
    let differentiateWithoutColor: Bool
    let perform: () -> Void

    @ScaledMetric(relativeTo: .headline) private var minimumHeight: CGFloat = Programme.Metrics
        .paletteButtonHeight

    var body: some View {
        Button(action: perform) {
            buttonLabel
                .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
                .padding(.horizontal, 14)
        }
        .modifier(
            PaletteButtonAppearance(
                kind: action.kind,
                tint: tint
            ))
        .accessibilityIdentifier("palette.\(action.id)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .modifier(OptionalKeyboardShortcut(key: action.shortcut))
    }

    @ViewBuilder
    private var buttonLabel: some View {
        let label = VStack(alignment: .leading, spacing: 3) {
            title
            if let subtitle = action.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if action.kind == .emphasis {
            label
        } else {
            label.foregroundStyle(titleStyle)
        }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: action.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .imageScale(.medium)
            // One line, scaled to fit: a wrapped or hyphenated label is
            // harder to recognise at a glance than a slightly smaller one.
            Text(action.title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// Semantic colour, and only semantic colour. Everything ordinary is quiet:
    /// a scorer aiming from memory needs the exceptions to stand out, not ten
    /// tiles competing.
    private var tint: Color {
        guard !differentiateWithoutColor else { return .secondary }
        switch action.kind {
        case .emphasis: return .accentColor
        case .critical: return Programme.Palette.critical
        case .caution: return Programme.Palette.caution
        case .standard, .more: return .secondary
        }
    }

    /// A tinted action keeps the tint on its title; a quiet one does not inherit
    /// grey text along with its grey fill.
    private var titleStyle: AnyShapeStyle {
        tint == .secondary ? AnyShapeStyle(.primary) : AnyShapeStyle(tint)
    }

    private var accessibilityLabel: String {
        [action.title, action.subtitle].compactMap(\.self).joined(separator: ", ")
    }

    private var accessibilityHint: String {
        guard action.pending != nil else { return "" }
        return isArmed
            ? "Records this for the selected player."
            : "Asks which player this was."
    }
}

private struct PaletteButtonAppearance: ViewModifier {
    let kind: PaletteAction.Kind
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if kind == .emphasis {
            content
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: Programme.Metrics.cornerRadius))
                .tint(tint)
        } else {
            content
                .buttonStyle(.plain)
                .background(background, in: RoundedRectangle(cornerRadius: Programme.Metrics.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Programme.Metrics.cornerRadius)
                        .strokeBorder(stroke, lineWidth: 1)
                }
        }
    }

    private var background: Color {
        switch kind {
        case .caution, .critical: tint.opacity(0.09)
        case .standard, .more, .emphasis: Color(.systemBackground)
        }
    }

    private var stroke: Color {
        switch kind {
        case .caution, .critical: tint.opacity(0.22)
        case .standard, .more, .emphasis: Color.primary.opacity(0.11)
        }
    }
}

/// Applies a keyboard shortcut only when the action defines one.
struct OptionalKeyboardShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: [])
        } else {
            content
        }
    }
}

enum OpponentQuickAction: String, Identifiable, CaseIterable {
    case goal
    case shot
    case corner

    var id: String { rawValue }

    var title: String {
        switch self {
        case .goal: "Goal"
        case .shot: "Shot"
        case .corner: "Corner"
        }
    }

    var symbolName: String {
        switch self {
        case .goal: "soccerball"
        case .shot: "arrow.up.forward"
        case .corner: "flag"
        }
    }
}

/// Opponent events in `Our Team` mode need no player, so they are single taps.
struct OpponentStrip: View {
    let opponentName: String
    let profile: StatProfile
    let action: (OpponentQuickAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(opponentName)
                .programmeSectionHeader()
                .padding(.horizontal, 4)
                .lineLimit(1)
            HStack(spacing: 8) {
                ForEach(available) { quick in
                    Button {
                        action(quick)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: quick.symbolName)
                                .font(.system(size: 14, weight: .medium))
                            Text(quick.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Color(.systemBackground),
                        in: RoundedRectangle(cornerRadius: Programme.Metrics.cornerRadius)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Programme.Metrics.cornerRadius)
                            .strokeBorder(Color.primary.opacity(0.11), lineWidth: 1)
                    }
                    .accessibilityIdentifier("palette.opponent.\(quick.rawValue)")
                    .accessibilityLabel("\(opponentName) \(quick.title)")
                }
            }
        }
    }

    private var available: [OpponentQuickAction] {
        OpponentQuickAction.allCases.filter { quick in
            switch quick {
            case .goal: true
            case .shot: profile.tracks(.shots)
            case .corner: profile.tracks(.corners)
            }
        }
    }
}
