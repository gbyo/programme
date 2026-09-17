import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// The bottom strip: match management, what was just recorded, and how to fix it.
///
/// This is a real system toolbar rather than a bar Programme draws. `.bottomBar`
/// items already get Liquid Glass, their grouping (items either side of a
/// `ToolbarSpacer` sit on separate glass), their sizing, their narrow-width
/// adaptation and their scroll-edge behaviour from the system — so there is no
/// `GlassEffectContainer` here, no `glassEffect`, no `buttonBorderShape`, and no
/// hand-written compact layout to keep in sync.
///
/// Undo is a single tap and never asks for confirmation — deleting an event you
/// recorded two seconds ago is a correction, not a destructive act.
struct ScoringToolbar: ToolbarContent {
    let session: LiveMatchSession
    var onSubstitute: () -> Void
    var onEdit: () -> Void
    var onLog: () -> Void
    var onReview: () -> Void

    var body: some ToolbarContent {
        // The one primary action down here, so it gets its own glass.
        ToolbarItem(placement: .bottomBar) {
            Button(action: onSubstitute) {
                Label("Substitution", systemImage: "arrow.left.arrow.right")
            }
            .programmePrimaryAction(in: .control)
            .accessibilityIdentifier("scoring.substitution")
            .keyboardShortcut("b", modifiers: [])
        }

        ToolbarSpacer(.fixed, placement: .bottomBar)

        // Status, not a control, so it opts out of the shared control background
        // rather than drawing its own capsule to look different.
        ToolbarItem(placement: .bottomBar) {
            LastEventSummary(session: session)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible, placement: .bottomBar)

        // Correcting what was just recorded: one group, because undo, redo and
        // edit are the same job.
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Undo", systemImage: "arrow.uturn.backward") {
                session.undo()
            }
            .disabled(!session.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityIdentifier("scoring.undo")

            if session.canRedo {
                Button("Redo", systemImage: "arrow.uturn.forward") {
                    session.redo()
                }
                .labelStyle(.iconOnly)
            }

            Button("Edit", systemImage: "pencil") { onEdit() }
                .accessibilityLabel("Edit last event")
                .disabled(session.lastEventDescription == nil)
        }

        ToolbarSpacer(.fixed, placement: .bottomBar)

        // Looking at the record as a whole: a different job, so its own glass.
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Event Log", systemImage: "list.bullet") { onLog() }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("scoring.eventLog")

            ReviewIndicator(
                count: session.needsReviewCount, issues: session.issues, action: onReview)
        }
    }
}

/// What was recorded a moment ago, so the scorer can confirm it landed without
/// opening the log.
struct LastEventSummary: View {
    let session: LiveMatchSession

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.22),
                value: session.lastEventDescription?.id)
    }

    @ViewBuilder
    private var content: some View {
        if let description = session.lastEventDescription {
            HStack(spacing: 10) {
                Image(systemName: description.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        description.category == .goal && !differentiateWithoutColor
                            ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
                    )
                    .accessibilityHidden(true)

                Text(description.timeText)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Text(description.title)
                    .font(.subheadline.weight(.semibold))

                if !description.detail.isEmpty {
                    Text(description.detail)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                if let secondary = description.secondaryDetail {
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
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("scoring.lastEvent")
            .accessibilityLabel("Last event: \(description.accessibilityLabel)")
        } else {
            Text("No events recorded yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
        .labelStyle(.titleAndIcon)
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
