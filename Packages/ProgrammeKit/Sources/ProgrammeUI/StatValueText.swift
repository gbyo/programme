import ProgrammeCore
import SwiftUI

/// Renders a statistic while keeping "not tracked" visibly different from zero.
/// Every numeric surface in Programme goes through this, so the distinction can
/// never be lost by a view formatting an `Int` directly.
public struct StatValueText: View {
    public var value: StatValue
    public var style: Style
    public var fractionDigits: Int

    public enum Style {
        case count
        case percent
        case decimal
    }

    public init(_ value: StatValue, style: Style = .count, fractionDigits: Int = 2) {
        self.value = value
        self.style = style
        self.fractionDigits = fractionDigits
    }

    public var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(value.isTracked ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .accessibilityLabel(value.accessibilityText)
    }

    private var text: String {
        switch style {
        case .count: value.text()
        case .percent: value.percentText
        case .decimal: value.text(fractionDigits: fractionDigits)
        }
    }
}

/// A compact label/value pair used across match and season summaries.
public struct StatCell: View {
    public var label: String
    public var value: StatValue
    public var style: StatValueText.Style
    public var emphasis: Bool

    public init(
        _ label: String, _ value: StatValue, style: StatValueText.Style = .count, emphasis: Bool = false
    ) {
        self.label = label
        self.value = value
        self.style = style
        self.emphasis = emphasis
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            StatValueText(value, style: style)
                .font(emphasis ? .title2.weight(.semibold) : .body.weight(.medium))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value.accessibilityText)")
    }
}
