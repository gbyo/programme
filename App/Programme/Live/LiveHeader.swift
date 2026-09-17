import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// The one thing that must always be legible from several feet away.
struct LiveHeader: View {
    let session: LiveMatchSession
    var isCompact: Bool
    var onMenu: () -> Void
    var onToggleClock: () -> Void
    var onEndPeriod: () -> Void
    var onStartPeriod: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The scoreboard is Programme's, the layer it sits in is Apple's: a
        // floating glass bar above content that scrolls underneath. The score,
        // the clock and the period rule keep their own typography; the surface
        // they sit on is the system's Liquid Glass, not a hand-made imitation.
        GlassEffectContainer(spacing: isCompact ? 8 : 14) {
            HStack(alignment: .center, spacing: isCompact ? 8 : 14) {
                HStack(alignment: .center, spacing: isCompact ? 12 : 22) {
                    scoreBlock
                    Spacer(minLength: 8)
                    clockBlock
                }
                .padding(.horizontal, isCompact ? 14 : 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .glassEffect(.regular, in: .capsule)
                .overlay(alignment: .bottomLeading) {
                    // A quiet progress rule through the period. No numbers, no
                    // chrome — it rides the bottom of the scoreboard, inset so it
                    // stays inside the capsule rather than cutting across it.
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width * session.clock.periodProgress, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .padding(.horizontal, isCompact ? 14 : 20)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                }

                controls
            }
        }
        .padding(.horizontal, 16)
    }

    private var scoreBlock: some View {
        HStack(alignment: .center, spacing: isCompact ? 8 : 14) {
            teamSide(
                name: session.descriptor.teamShortName, score: session.snapshot.score.us,
                isUs: true)
            Text("–")
                .font(.programmeScore(isCompact ? 26 : 34))
                .foregroundStyle(.tertiary)
            teamSide(
                name: session.descriptor.opponentShortName, score: session.snapshot.score.opponent,
                isUs: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("live.score")
        .accessibilityLabel(
            "\(session.descriptor.teamShortName), \(session.snapshot.score.us), \(session.descriptor.opponentShortName), \(session.snapshot.score.opponent)"
        )
    }

    private func teamSide(name: String, score: Int, isUs: Bool) -> some View {
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

    private var clockBlock: some View {
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

    private var startTitle: String {
        session.phase == .scheduled ? "Start Match" : "Start \(session.nextPeriodLabel)"
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            switch session.phase {
            case .scheduled, .periodBreak:
                Button {
                    onStartPeriod()
                } label: {
                    if isCompact {
                        Image(systemName: "play.fill")
                    } else {
                        Label(startTitle, systemImage: "play.fill")
                    }
                }
                .programmePrimaryAction(in: .control)
                .disabled(!session.canStartNextPeriod || !session.hasStartingLineup)
                .accessibilityIdentifier("live.startPeriod")
                .accessibilityLabel(startTitle)

            case .inPeriod:
                Button {
                    onToggleClock()
                } label: {
                    Image(systemName: session.clock.isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("live.toggleClock")
                .accessibilityLabel(session.clock.isRunning ? "Stop the clock" : "Start the clock")

                Button("End \(session.clock.periodShortLabel)") {
                    onEndPeriod()
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("live.endPeriod")

            case .awaitingFinalization, .finalized:
                EmptyView()
            }

            Button {
                onMenu()
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("live.options")
            .accessibilityLabel("Match options")
        }
        // One place decides how big a live control is, instead of every button
        // carrying its own frame. `.extraLarge` keeps every target comfortably
        // past 44pt and scales with Dynamic Type.
        .controlSize(.extraLarge)
        .font(.headline)
    }
}
