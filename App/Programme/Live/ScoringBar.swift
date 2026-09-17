import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// The bottom strip: what was just recorded, and how to fix it.
///
/// Undo is a single tap and never asks for confirmation — deleting an event you
/// recorded two seconds ago is a correction, not a destructive act.
struct ScoringBar: View {
    let session: LiveMatchSession
    let isCompact: Bool
    var onSubstitute: () -> Void
    var onEdit: () -> Void
    var onLog: () -> Void
    var onReview: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One shared control layer keeps match management, live feedback and
        // correction tools reading as a single dock. Only the controls use
        // glass; the recent event is a quiet status chip within that dock.
        GlassEffectContainer(spacing: 10) {
            if isCompact {
                compactDock
            } else {
                regularDock
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22), value: session.lastEventDescription?.id)
    }

    private var regularDock: some View {
        HStack(spacing: 12) {
            substitutionButton
            lastEventChip
                .frame(maxWidth: .infinity, alignment: .leading)
            actions(showLabels: true)
        }
    }

    private var compactDock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                substitutionButton
                    .fixedSize(horizontal: true, vertical: false)
                lastEventChip
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            actions(showLabels: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var substitutionButton: some View {
        Button(action: onSubstitute) {
            Label("Substitution", systemImage: "arrow.left.arrow.right")
                .font(.subheadline.weight(.semibold))
        }
        .programmePrimaryAction(in: .control)
        .controlSize(.extraLarge)
        .accessibilityIdentifier("scoring.substitution")
        .keyboardShortcut("b", modifiers: [])
    }

    private var lastEventChip: some View {
        lastEvent
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.secondary.opacity(0.08), in: .capsule)
    }

    @ViewBuilder
    private var lastEvent: some View {
        if let description = session.lastEventDescription {
            HStack(spacing: 10) {
                Image(systemName: description.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        description.category == .goal && !differentiateWithoutColor
                            ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
                    )
                    .frame(width: 22)
                    .accessibilityHidden(true)

                Text(description.timeText)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Text(description.title)
                    .font(.subheadline.weight(.semibold))

                if !isCompact, !description.detail.isEmpty {
                    Text(description.detail)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                if !isCompact, let secondary = description.secondaryDetail {
                    Text(secondary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let score = description.scoreText {
                    Text(score)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                if description.needsAttribution {
                    Label("Needs player", systemImage: "questionmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Programme.Palette.caution)
                        .labelStyle(.titleAndIcon)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("scoring.lastEvent")
            .accessibilityLabel("Last event: \(description.accessibilityLabel)")
        } else {
            Text("No events recorded yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func actions(showLabels: Bool) -> some View {
        HStack(spacing: showLabels ? 8 : 6) {
            Button {
                session.undo()
            } label: {
                Label {
                    if showLabels { Text("Undo") }
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(showLabels ? .capsule : .circle)
            .accessibilityIdentifier("scoring.undo")
            .accessibilityLabel("Undo")
            .disabled(!session.canUndo)
            .keyboardShortcut("z", modifiers: .command)

            if session.canRedo {
                Button("Redo", systemImage: "arrow.uturn.forward") {
                    session.redo()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }

            Button(action: onEdit) {
                Label {
                    if showLabels { Text("Edit") }
                } icon: {
                    Image(systemName: "pencil")
                }
            }
                .buttonStyle(.glass)
                .buttonBorderShape(showLabels ? .capsule : .circle)
                .accessibilityLabel("Edit last event")
                .disabled(session.lastEventDescription == nil)

            Button("Event Log", systemImage: "list.bullet") { onLog() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("scoring.eventLog")

            ReviewIndicator(count: session.needsReviewCount, issues: session.issues, action: onReview)
        }
        .controlSize(showLabels ? .extraLarge : .regular)
        .font(.subheadline.weight(.semibold))
    }
}

/// The Review affordance. Present but never shouting: noncritical inconsistencies
/// must not interrupt live scoring.
struct ReviewIndicator: View {
    let count: Int
    let issues: [ValidationIssue]
    let action: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var blockingCount: Int { issues.blocking.count }
    private var totalCount: Int { max(count, issues.needingReview.count) }

    var body: some View {
        Button(action: action) {
            Label {
                Text(totalCount > 0 ? "\(totalCount)" : "OK")
                    .monospacedDigit()
            } icon: {
                Image(systemName: totalCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle")
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .tint(tint)
        .accessibilityIdentifier("scoring.review")
        .accessibilityLabel(
            totalCount > 0 ? "Review, \(totalCount) items need attention" : "Review, nothing outstanding")
    }

    private var tint: Color {
        if differentiateWithoutColor { return .secondary }
        if blockingCount > 0 { return Programme.Palette.critical }
        return totalCount > 0 ? Programme.Palette.caution : .secondary
    }
}

/// A transient confirmation that floats over the workspace.
///
/// This is the one piece of Programme that genuinely belongs to the control
/// layer above the content, so it uses the real Liquid Glass effect rather than
/// a material and a hand-drawn ring pretending to be one. The tint carries the
/// meaning; the glass carries the "this is temporary, the match is underneath".
struct NoticeBanner: View {
    let notice: LiveNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.subheadline.weight(.semibold))
            Text(notice.text)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 4)
            Button("Dismiss", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(glassTint), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    /// Undo is deliberately untinted: taking something back should not read as
    /// an alarm.
    private var glassTint: Color? {
        switch notice.kind {
        case .confirmation: Programme.Palette.confirmed
        case .undo: nil
        case .warning: Programme.Palette.caution
        }
    }

    private var symbolName: String {
        switch notice.kind {
        case .confirmation: "checkmark.circle.fill"
        case .undo: "arrow.uturn.backward.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

}
