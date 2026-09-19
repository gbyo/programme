import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// The scoreboard: the one thing that must always be legible from several feet
/// away.
///
/// This view owns the score, the clock, the period and the period progress, and
/// nothing else. Leaving the workspace and match management — pause, end the
/// period, start the next one, the options menu — live in the navigation bar as
/// real toolbar items, because those are ordinary iPad controls and should be
/// drawn by the system rather than approximated here. See
/// `MatchControlsToolbar`.
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
        ProgressView(value: session.clock.periodProgress)
            .progressViewStyle(.linear)
            .tint(.accentColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
                .contentTransition(.numericText(countsDown: session.clock.countsDown))
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.20),
                    value: session.clock.displayText
                )
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
/// Close, Pause, End <period>, Start <period> and the options menu are ordinary
/// iPad controls, so they are ordinary `ToolbarItem`s. Fixed `ToolbarSpacer`s
/// tell SwiftUI which controls do different jobs; the resulting separate Liquid
/// Glass groups, sizing, pointer behaviour and narrow-window adaptation all stay
/// system-owned. The one exception is Start, which uses Programme's
/// primary-action style because starting the match is the single prominent
/// action on this screen — and that is still a stock system style, not drawn
/// chrome.
struct MatchControlsToolbar: ToolbarContent {
    let session: LiveMatchSession
    var onClose: () -> Void
    var onShowStats: () -> Void
    var onEditLineup: () -> Void
    var onEditOpponentRoster: () -> Void
    var onAdjustClock: () -> Void
    var onOpenScoreboard: () -> Void
    var onConnectDisplay: () -> Void
    var onShootout: () -> Void
    var onFinalize: () -> Void
    var onToggleClock: () -> Void
    var onEndPeriod: () -> Void
    var onStartPeriod: () -> Void

    private var startTitle: String {
        session.phase == .scheduled ? "Start Match" : "Start \(session.nextPeriodLabel)"
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            CloseScorerButton(session: session, onClose: onClose)
        }
        .liveVisibilityPriority(.high)

        if session.phase == .scheduled || session.phase == .periodBreak {
            ToolbarItem(placement: .topBarTrailing) {
                Button(startTitle, systemImage: "play.fill") { onStartPeriod() }
                    .programmePrimaryAction(in: .control)
                    .disabled(!session.canStartNextPeriod || !session.hasStartingLineup)
                    .accessibilityIdentifier("live.startPeriod")
                    .accessibilityLabel(startTitle)
            }
            .liveVisibilityPriority(.high)

            ToolbarSpacer(.fixed, placement: .topBarTrailing)

        } else if session.phase == .inPeriod {
            ToolbarItem(placement: .topBarTrailing) {
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
            }
            .liveVisibilityPriority(.high)

            ToolbarSpacer(.fixed, placement: .topBarTrailing)

            ToolbarItem(placement: .topBarTrailing) {
                Button("End \(session.clock.periodShortLabel)") { onEndPeriod() }
                    .accessibilityIdentifier("live.endPeriod")
            }
            .liveVisibilityPriority(.high)

            ToolbarSpacer(.fixed, placement: .topBarTrailing)

        }

        ToolbarItem(placement: .topBarTrailing) {
            MatchManagementMenu(
                session: session,
                onShowStats: onShowStats,
                onEditLineup: onEditLineup,
                onEditOpponentRoster: onEditOpponentRoster,
                onAdjustClock: onAdjustClock,
                onOpenScoreboard: onOpenScoreboard,
                onConnectDisplay: onConnectDisplay,
                onShootout: onShootout,
                onFinalize: onFinalize,
                onClose: onClose)
        }
        .liveVisibilityPriority(.high)
    }
}

private struct CloseScorerButton: View {
    let session: LiveMatchSession
    var onClose: () -> Void

    @State private var isConfirmingClose = false

    var body: some View {
        Button("Close Scorer", systemImage: "xmark") {
            requestClose()
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("live.closeScorer")
        .confirmationDialog(
            "Leave this match running?", isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("Close Scorer", action: onClose)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The match stays live and every event is saved. Programme will offer to resume it.")
        }
    }

    private func requestClose() {
        if session.phase.isLive {
            isConfirmingClose = true
        } else {
            onClose()
        }
    }
}

private struct MatchManagementMenu: View {
    let session: LiveMatchSession
    var onShowStats: () -> Void
    var onEditLineup: () -> Void
    var onEditOpponentRoster: () -> Void
    var onAdjustClock: () -> Void
    var onOpenScoreboard: () -> Void
    var onConnectDisplay: () -> Void
    var onShootout: () -> Void
    var onFinalize: () -> Void
    var onClose: () -> Void

    @State private var isConfirmingClose = false

    var body: some View {
        Menu {
            Button("Match Stats", systemImage: "chart.bar", action: onShowStats)
            Button("Edit Lineup", systemImage: "person.3", action: onEditLineup)
            if session.descriptor.tracking == .bothTeams {
                Button(
                    "Opponent Roster", systemImage: "person.2", action: onEditOpponentRoster)
            }
            Button(
                "Adjust Clock", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                action: onAdjustClock)
            Button(
                "Open Scoreboard Window", systemImage: "rectangle.on.rectangle",
                action: onOpenScoreboard)
            Button(
                "Connect Nearby Display…", systemImage: "wifi",
                action: onConnectDisplay)

            Divider()

            if session.rules.shootoutAvailable {
                Button("Shootout", systemImage: "circle.bottomhalf.filled", action: onShootout)
            }
            Button("Finalize Match…", systemImage: "flag.checkered", action: onFinalize)

            Divider()

            Button("Close Scorer…", systemImage: "xmark.circle") {
                if session.phase.isLive {
                    isConfirmingClose = true
                } else {
                    onClose()
                }
            }
        } label: {
            Label("Match options", systemImage: "ellipsis")
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("live.options")
        .confirmationDialog(
            "Leave this match running?", isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("Close Scorer", action: onClose)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The match stays live and every event is saved. Programme will offer to resume it.")
        }
    }
}
