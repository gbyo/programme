import ProgrammeCore
import ProgrammeUI
import SwiftUI

/// The bottom strip: what was just recorded, and how to fix it.
///
/// Undo is a single tap and never asks for confirmation — deleting an event you
/// recorded two seconds ago is a correction, not a destructive act.
struct ScoringBar: View {
    let session: LiveMatchSession
    var onEdit: () -> Void
    var onLog: () -> Void
    var onReview: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            lastEvent
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 62)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .top) {
            if let notice = session.notice {
                NoticeBanner(notice: notice) { session.dismissNotice() }
                    .padding(.horizontal, 16)
                    .offset(y: -50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: session.notice)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22), value: session.lastEventDescription?.id)
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
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("scoring.lastEvent")
            .accessibilityLabel("Last event: \(description.accessibilityLabel)")
        } else {
            Text("No events recorded yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                session.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 42)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("scoring.undo")
            .disabled(!session.canUndo)
            .keyboardShortcut("z", modifiers: .command)

            if session.canRedo {
                Button {
                    session.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(width: 40, height: 42)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Redo")
            }

            Button {
                onEdit()
            } label: {
                Text("Edit")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 42)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .disabled(session.lastEventDescription == nil)

            Button {
                onLog()
            } label: {
                Label("Event Log", systemImage: "list.bullet")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 42)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("scoring.eventLog")
            .accessibilityLabel("Event log")

            ReviewIndicator(count: session.needsReviewCount, issues: session.issues, action: onReview)
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
            HStack(spacing: 6) {
                Image(systemName: totalCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                Text(totalCount > 0 ? "\(totalCount)" : "OK")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(minHeight: 42)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.4))
        )
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch notice.kind {
        case .confirmation: "checkmark.circle.fill"
        case .undo: "arrow.uturn.backward.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .confirmation: Programme.Palette.confirmed
        case .undo: .secondary
        case .warning: Programme.Palette.caution
        }
    }
}
