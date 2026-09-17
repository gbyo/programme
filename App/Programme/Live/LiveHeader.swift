import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// The scoreboard: the one thing that must always be legible from several feet
/// away.
///
/// This view owns the score, the clock, the period and the period progress, and
/// nothing else. Match management — pause, end the period, start the next one,
/// the options menu — lives in the navigation bar as real toolbar items, because
/// those are ordinary iPad controls and should be drawn by the system rather
/// than approximated here. See `MatchControlsToolbar`.
struct LiveHeader: View {
    let session: LiveMatchSession

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The header is structural chrome, so it stays flat: no glass, no
        // shadow, nothing drawn to imitate a control.
        //
        // Which arrangement it uses is decided by what fits, not by a device
        // width: the full-width row states the narrowest width at which the
        // score and the clock both still read at arm's length, and below that
        // the tighter arrangement takes over. Now that the controls have moved
        // to the toolbar, the narrow case no longer needs a second line — the
        // scoreboard is a single row at every size.
        ViewThatFits(in: .horizontal) {
            scoreboard(isCompact: false)
                .frame(minWidth: 520, idealWidth: 520, maxWidth: .infinity)
            scoreboard(isCompact: true)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func scoreboard(isCompact: Bool) -> some View {
        scoreAndClock(isCompact: isCompact)
            .padding(.horizontal, isCompact ? 14 : 20)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .overlay(alignment: .bottomLeading) {
                progressRule(horizontalPadding: isCompact ? 14 : 20)
            }
    }

    private func scoreAndClock(isCompact: Bool) -> some View {
        HStack(alignment: .center, spacing: isCompact ? 8 : 22) {
            scoreBlock(isCompact: isCompact)
                .layoutPriority(1)
            Spacer(minLength: 6)
            clockBlock(isCompact: isCompact)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func progressRule(horizontalPadding: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.accentColor)
                .frame(
                    width: proxy.size.width * session.clock.periodProgress,
                    height: 3
                )
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, 6)
        .allowsHitTesting(false)
    }

    private func scoreBlock(isCompact: Bool) -> some View {
        HStack(alignment: .center, spacing: isCompact ? 8 : 14) {
            teamSide(
                name: session.descriptor.teamShortName, score: session.snapshot.score.us,
                isUs: true, isCompact: isCompact)
            Text("–")
                .font(.programmeScore(isCompact ? 26 : 34))
                .foregroundStyle(.tertiary)
            teamSide(
                name: session.descriptor.opponentShortName, score: session.snapshot.score.opponent,
                isUs: false, isCompact: isCompact)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("live.score")
        .accessibilityLabel(
            "\(session.descriptor.teamShortName), \(session.snapshot.score.us), \(session.descriptor.opponentShortName), \(session.snapshot.score.opponent)"
        )
    }

    private func teamSide(name: String, score: Int, isUs: Bool, isCompact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isUs {
                Text(name)
                    .font(isCompact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: isCompact ? 90 : 190, alignment: .trailing)
                Text("\(score)")
                    .font(.programmeScore(isCompact ? 30 : 40))
                    .contentTransition(.numericText())
            } else {
                Text("\(score)")
                    .font(.programmeScore(isCompact ? 30 : 40))
                    .contentTransition(.numericText())
                Text(name)
                    .font(isCompact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: isCompact ? 90 : 190, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: score)
    }

    private func clockBlock(isCompact: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(session.clock.displayText)
                .font(.programmeClock(isCompact ? 24 : 32))
                .contentTransition(.numericText(countsDown: true))
            Text(periodText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("live.clock")
        .accessibilityLabel("Match clock")
        .accessibilityValue("\(session.clock.accessibilityText), \(periodText)")
    }

    private var periodText: String {
        switch session.phase {
        case .scheduled: "Not started"
        case .inPeriod:
            session.clock.isRunning
                ? session.clock.periodShortLabel : "\(session.clock.periodShortLabel) · stopped"
        case .periodBreak: session.clock.periodShortLabel + " ended"
        case .awaitingFinalization: "Full time"
        case .finalized: "Final"
        }
    }

}

/// Match management, as real navigation-bar items.
///
/// Pause, End <period>, Start <period> and the options menu are ordinary iPad
/// controls, so they are ordinary `ToolbarItem`s. Nothing here sets a button
/// style, a border shape or a control size: the system already knows how big a
/// navigation-bar control is, what it looks like when pressed, how it responds
/// to the pointer, and how it behaves when the window gets too narrow to show
/// everything. The one exception is Start, which uses Programme's primary-action
/// style because starting the match is the single prominent action on this
/// screen — and that is still a stock system style, not drawn chrome.
///
/// They sit in one trailing group so the bar stays a single row beside the
/// scoreboard rather than becoming a second strip of its own.
struct MatchControlsToolbar: ToolbarContent {
    let session: LiveMatchSession
    var onMenu: () -> Void
    var onToggleClock: () -> Void
    var onEndPeriod: () -> Void
    var onStartPeriod: () -> Void

    private var startTitle: String {
        session.phase == .scheduled ? "Start Match" : "Start \(session.nextPeriodLabel)"
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            switch session.phase {
            case .scheduled, .periodBreak:
                Button(startTitle, systemImage: "play.fill") { onStartPeriod() }
                    .programmePrimaryAction(in: .control)
                    .disabled(!session.canStartNextPeriod || !session.hasStartingLineup)
                    .accessibilityIdentifier("live.startPeriod")
                    .accessibilityLabel(startTitle)

            case .inPeriod:
                // Icon-only, because the clock beside it already says whether it
                // is running and a word here would only repeat it.
                Button(
                    session.clock.isRunning ? "Stop the clock" : "Start the clock",
                    systemImage: session.clock.isRunning ? "pause.fill" : "play.fill"
                ) {
                    onToggleClock()
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("live.toggleClock")

                Button("End \(session.clock.periodShortLabel)") { onEndPeriod() }
                    .accessibilityIdentifier("live.endPeriod")

            case .awaitingFinalization, .finalized:
                EmptyView()
            }

            Button("Match options", systemImage: "ellipsis") { onMenu() }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("live.options")
        }
    }
}
