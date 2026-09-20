import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// One scoring action.
struct PaletteAction: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var symbolName: String
    var pending: PendingAction?
    var kind: Kind

    /// Semantic weight, and only semantic weight. Size and position carry
    /// frequency; colour is reserved for the goal and for the cards.
    enum Kind: Equatable {
        /// The one action that is the point of the app.
        case emphasis
        /// Everything ordinary.
        case standard
        case caution
        case critical
    }
}

/// Anything reachable from `More`, which is a native menu rather than a sheet.
enum PaletteOverflow: Equatable {
    case pending(PendingAction)
    case opponentPenalty
    case opponentCard
    case addNote
}

/// The fixed action palette: Programme's Record column.
///
/// The order never changes during a match. Programme deliberately does not
/// reorder by frequency or promote recent actions: a scorer who is watching the
/// pitch is aiming from memory, and muscle memory is worth more than any
/// cleverness about what they tapped most last week.
///
/// Frequency is expressed once, statically, in *size*: the three actions that
/// make up almost every match sit in a large block at the top, and everything
/// else is a shorter row underneath. The opponent's quick actions are pinned
/// below the scroll view so their common events never fall below the fold.
struct EventPalette: View {
    let session: LiveMatchSession
    var onAction: (PaletteAction) -> Void
    var onOverflow: (PaletteOverflow) -> Void
    var onOpponentAction: (OpponentQuickAction) -> Void
    var onClearArmedPlayer: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var goalActivation = 0

    var body: some View {
        VStack(spacing: 0) {
            RecordHeader(
                teamName: session.descriptor.teamShortName,
                armedPlayer: session.armedPlayerSnapshot,
                onClear: onClearArmedPlayer
            )
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 12) {
                    primaryBlock
                    secondaryBlock
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)

            OpponentQuickBar(
                opponentName: session.descriptor.opponentShortName,
                profile: session.profile,
                action: onOpponentAction)
        }
    }

    // MARK: - Blocks

    /// Goal, Shot, Save — the three that account for almost every event in a
    /// match, as the largest targets on the screen.
    ///
    /// A `Grid` rather than a `LazyVGrid`, because three actions do not fill a
    /// two-column grid. Goal spans the full width of the top row — it is the one
    /// action that is the point of the app, and the widest target on the screen
    /// is the right home for it — and Shot and Save share the row beneath. The
    /// alternatives were both worse: a lazy grid leaves Save as a half-width tile
    /// beside a hole, and filling that hole would mean promoting some rare
    /// command into the square a scorer's thumb has learned is a common one.
    ///
    /// The count only varies with the match's stat profile, which is fixed before
    /// kickoff, so nothing here moves during a match. When a profile leaves only
    /// one of Shot and Save, that one spans the row rather than sitting beside a
    /// gap.
    private var primaryBlock: some View {
        let supporting = supportingPrimaryActions
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                primaryButton(goalAction)
                    .gridCellColumns(2)
            }
            if !supporting.isEmpty {
                GridRow {
                    ForEach(supporting) { action in
                        primaryButton(action)
                            .gridCellColumns(supporting.count == 1 ? 2 : 1)
                    }
                }
            }
        }
    }

    private func primaryButton(_ action: PaletteAction) -> some View {
        PaletteButton(
            action: action,
            prominence: .primary,
            isArmed: session.armedPlayer != nil,
            differentiateWithoutColor: differentiateWithoutColor,
            goalActivation: action.id == "goal" ? goalActivation : nil
        ) {
            activate(action)
        }
    }

    private func activate(_ action: PaletteAction) {
        if action.id == "goal" {
            goalActivation += 1
        }
        onAction(action)
    }

    /// Everything real but less frequent, plus the overflow menu. Shorter tiles:
    /// still comfortably past a 44pt target, but visibly the second tier.
    private var secondaryBlock: some View {
        LazyVGrid(columns: twoColumns, spacing: 8) {
            ForEach(secondaryActions) { action in
                PaletteButton(
                    action: action,
                    prominence: .secondary,
                    isArmed: session.armedPlayer != nil,
                    differentiateWithoutColor: differentiateWithoutColor,
                    goalActivation: nil
                ) {
                    onAction(action)
                }
            }
            MoreMenu(session: session, onPick: onOverflow)
        }
    }

    private var twoColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 110), spacing: 10),
            GridItem(.flexible(minimum: 110), spacing: 10),
        ]
    }

    // MARK: - Actions

    /// The one action that is the point of the app. Always present, always first.
    ///
    /// A goal is semantically one of Shot's outcomes, and it still keeps its own
    /// button: it is the most time-critical thing that happens in a match, it
    /// moves the score, it is common, and it leads straight into the scorer and
    /// assist workflow. Reaching it through *Shot → Goal* would be a tap slower
    /// at the worst possible moment. Both routes record the same single event.
    var goalAction: PaletteAction {
        PaletteAction(
            id: "goal", title: "Goal", subtitle: "Scorer, then assist",
            symbolName: "soccerball.inverse", pending: .goal(.openPlay), kind: .emphasis)
    }

    /// The other large targets, built from the match's stat profile, which is
    /// fixed before kickoff.
    ///
    /// There is exactly one ordinary Shot button, and it does not claim to know
    /// what happened — the outcome is the next question. Save stays its own
    /// action because it is a different mental model: the scorer is watching our
    /// goalkeeper stop an opponent's shot, not entering one of our attempts, and
    /// making that *Opponent Shot → Saved* would cost two extra taps for one of
    /// the most common things they record.
    var supportingPrimaryActions: [PaletteAction] {
        let profile = session.profile
        var result: [PaletteAction] = []
        if profile.tracks(.shots) {
            result.append(
                PaletteAction(
                    id: "shot", title: "Shot", subtitle: "Then what happened?",
                    symbolName: "arrow.up.forward", pending: .shotAttempt(.openPlay),
                    kind: .standard))
        }
        if profile.tracks(.goalkeeping) {
            result.append(
                PaletteAction(
                    id: "save", title: "Save", subtitle: "Their shot on goal",
                    symbolName: "hand.raised.fill", pending: nil, kind: .standard))
        }
        return result
    }

    /// Every large target, in the order they appear.
    var primaryActions: [PaletteAction] { [goalAction] + supportingPrimaryActions }

    var secondaryActions: [PaletteAction] {
        let profile = session.profile
        var result: [PaletteAction] = []
        if profile.tracks(.corners) {
            result.append(
                PaletteAction(
                    id: "corner", title: "Corner", subtitle: nil, symbolName: "flag.fill",
                    pending: .corner, kind: .standard))
        }
        if profile.tracks(.steals) {
            result.append(
                PaletteAction(
                    id: "steal", title: "Steal", subtitle: nil, symbolName: "shoe.2.fill",
                    pending: .steal, kind: .standard))
        }
        if profile.tracks(.penaltyKicks) {
            result.append(
                PaletteAction(
                    id: "pk", title: "Penalty Kick", subtitle: nil,
                    symbolName: "circle.bottomhalf.filled",
                    pending: .shotAttempt(.penaltyKick), kind: .standard))
        }
        if profile.tracks(.cards) {
            result.append(
                PaletteAction(
                    id: "yellow", title: "Yellow Card", subtitle: nil,
                    symbolName: "rectangle.portrait",
                    pending: .card(.yellow), kind: .caution))
            result.append(
                PaletteAction(
                    id: "red", title: "Red Card", subtitle: nil,
                    symbolName: "rectangle.portrait.fill",
                    pending: .card(.red), kind: .critical))
        }
        return result
    }
}

/// The Record column's heading, and — when a player is armed — who the next
/// action will be credited to.
///
/// This is the other half of the armed state. The lineup already highlights the
/// row, but by the time the scorer's eyes are over here that highlight is out of
/// view, and tapping Goal must never be a guess about who it lands on.
struct RecordHeader: View {
    let teamName: String
    let armedPlayer: PlayerSnapshot?
    var onClear: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(armedPlayer == nil ? "Record" : "Record for")
                    .programmeSectionHeader()
                Text("·")
                    .programmeSectionHeader()
                Text(teamName)
                    .programmeSectionHeader()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if let armedPlayer {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(armedPlayer.shortLabel)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityIdentifier("palette.armedPlayer")
                        .accessibilityLabel("Recording for \(armedPlayer.accessibilityLabel)")
                    Spacer(minLength: 4)
                    Button("Clear", systemImage: "xmark.circle.fill") { onClear() }
                        .labelStyle(.titleOnly)
                        .buttonStyle(.borderless)
                        .font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("palette.clearArmedPlayer")
                        .accessibilityLabel("Clear selected player")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: 10))
                .id(armedPlayer.id)
                .transition(LiveMotion.acknowledgementTransition(reduceMotion: reduceMotion))
            }
        }
    }
}

/// One palette action.
///
/// The geometry is Programme's — a fixed grid with targets that never move
/// during a match — but the control is entirely the system's. Nothing here draws
/// a background, a border or a pressed state: the bordered and prominent button
/// styles already provide all of it, along with pointer and keyboard behaviour,
/// contrast adaptation and whatever Apple does to these styles next.
struct PaletteButton: View {
    enum Prominence {
        case primary
        case secondary
    }

    let action: PaletteAction
    let prominence: Prominence
    let isArmed: Bool
    let differentiateWithoutColor: Bool
    let goalActivation: Int?
    let perform: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var primaryHeight: CGFloat = Programme.Metrics
        .paletteButtonHeight
    @ScaledMetric(relativeTo: .headline) private var secondaryHeight: CGFloat = 54

    var body: some View {
        Button(action: perform) {
            label
                .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
        }
        .modifier(PaletteButtonStyle(kind: action.kind, tint: tint))
        .accessibilityIdentifier("palette.\(action.id)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var minimumHeight: CGFloat {
        prominence == .primary ? primaryHeight : secondaryHeight
    }

    @ViewBuilder
    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                symbol
                // One line, scaled to fit: a wrapped or hyphenated label is
                // harder to recognise at a glance than a slightly smaller one.
                Text(action.title)
                    .font(prominence == .primary ? .headline : .subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if prominence == .primary, let subtitle = action.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var symbol: some View {
        if action.id == "goal", let goalActivation, !reduceMotion {
            Image(systemName: action.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .imageScale(.medium)
                .symbolEffect(.bounce.wholeSymbol, value: goalActivation)
        } else {
            Image(systemName: action.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .imageScale(.medium)
        }
    }

    /// Semantic colour, and only semantic colour. Everything ordinary is quiet:
    /// a scorer aiming from memory needs the exceptions to stand out, not ten
    /// tiles competing.
    private var tint: Color {
        guard !differentiateWithoutColor else { return .secondary }
        switch action.kind {
        case .emphasis: return Programme.Palette.brand
        case .critical: return Programme.Palette.critical
        case .caution: return Programme.Palette.caution
        case .standard: return .secondary
        }
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

/// System button styles, chosen by meaning. There is no custom surface here on
/// purpose: a control that looks native has to behave native.
private struct PaletteButtonStyle: ViewModifier {
    let kind: PaletteAction.Kind
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        switch kind {
        case .emphasis:
            content
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: Programme.Metrics.cornerRadius))
                .tint(tint)
                .foregroundStyle(
                    tint == Programme.Palette.brand
                        ? AnyShapeStyle(Programme.Palette.onBrand) : AnyShapeStyle(.white))
        case .caution, .critical, .standard:
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: Programme.Metrics.cornerRadius))
                .tint(tint)
        }
    }
}

/// Secondary event selection.
///
/// A native menu rather than a sheet: choosing "Offside" is a one-step choice
/// among a handful of rare actions, and a sheet takes the match off the screen to
/// ask it. Picking something here drops straight back into the centre stage that
/// asks who it belonged to.
///
/// Everything here is a genuinely secondary *event type*. Shot outcomes are not:
/// blocked and woodwork are answers to Shot's own question now, not a second way
/// into the shot model hidden behind an ellipsis.
struct MoreMenu: View {
    let session: LiveMatchSession
    var onPick: (PaletteOverflow) -> Void

    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 54

    var body: some View {
        Menu {
            Section("Discipline") {
                if session.profile.tracks(.cards) {
                    Button("Second Yellow", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                        onPick(.pending(.card(.secondYellow)))
                    }
                }
                if session.profile.tracks(.fouls) {
                    Button("Foul", systemImage: "exclamationmark.triangle") { onPick(.pending(.foul)) }
                }
                if session.profile.tracks(.offsides) {
                    Button("Offside", systemImage: "flag.slash") { onPick(.pending(.offside)) }
                }
            }

            Section("Unusual") {
                Button("Own Goal", systemImage: "arrow.uturn.backward.circle") {
                    onPick(.pending(.ownGoal))
                }
                if session.profile.tracks(.goalkeeping) {
                    Button("Change Goalkeeper", systemImage: "hand.raised") {
                        onPick(.pending(.goalkeeper))
                    }
                }
            }

            Section(session.descriptor.opponentShortName) {
                if session.profile.tracks(.penaltyKicks) {
                    Button("Penalty Goal", systemImage: "circle.bottomhalf.filled") {
                        onPick(.opponentPenalty)
                    }
                }
                if session.profile.tracks(.cards) {
                    Button("Yellow Card", systemImage: "rectangle.portrait") { onPick(.opponentCard) }
                }
            }

            Button("Add Note…", systemImage: "text.quote") { onPick(.addNote) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                Text("More")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        }
        .menuOrder(.fixed)
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: Programme.Metrics.cornerRadius))
        .tint(.secondary)
        .accessibilityIdentifier("palette.more")
        .accessibilityLabel("More actions")
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

/// The opponent's quick actions, pinned below the palette's scroll view.
///
/// An opponent shot is how our goalkeeper's shots-faced and save percentage get
/// recorded, so it cannot be something the scorer has to scroll to find. In
/// `Our Team` mode each of these is a single tap; in `Both Teams` mode they route
/// through the same player picker as everything else.
struct OpponentQuickBar: View {
    let opponentName: String
    let profile: StatProfile
    let action: (OpponentQuickAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(opponentName)
                .programmeSectionHeader()
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
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: Programme.Metrics.cornerRadius))
                    .tint(.secondary)
                    .accessibilityIdentifier("palette.opponent.\(quick.rawValue)")
                    .accessibilityLabel("\(opponentName) \(quick.title)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Quiet separation rather than a floating card: the bar belongs to the
        // same surface as the palette, it simply does not scroll with it.
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Divider()
                Color.clear
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
