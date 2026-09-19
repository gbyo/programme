import ProgrammeCore
import SwiftUI

/// Programme's visual language.
///
/// The rules here are deliberately restrictive. Semantic colour stays semantic:
/// red means destructive or a sending-off, amber means caution, green means
/// confirmed. Team identity is an accent — a bar, a dot, a label tint — and never
/// a background wash in the working interface, because a scorer reading a score
/// at arm's length needs contrast, not decoration. The one-time first-run welcome
/// may use the brand colour as a full-screen arrival surface.
public enum Programme {

    public enum Metrics {
        /// The smallest a control may be during live scoring. Comfortably above
        /// the 44pt minimum, because the person tapping is watching the pitch.
        public static let liveTouchTarget: CGFloat = 64
        public static let paletteButtonHeight: CGFloat = 78
        public static let playerRowHeight: CGFloat = 56
        public static let cornerRadius: CGFloat = 12
        public static let largeCornerRadius: CGFloat = 18
        public static let gutter: CGFloat = 16
    }

    public enum Palette {
        /// Programme's brand lime, taken from the app icon.
        ///
        /// It is Programme's branded fill: primarily for prominent actions, plus
        /// the one-time first-run welcome surface. It is never a text colour — at
        /// roughly 1.2:1 against white it cannot carry a label, a link, a focus
        /// ring or a tinted selection, which is why the app's accent stays a
        /// legible colour and content shown on the lime uses `onBrand`.
        public static let brand = Color(
            .displayP3, red: 0.759_19, green: 0.967_83, blue: 0.181_74, opacity: 1)

        /// The label colour on top of `brand`. Near-black in both appearances,
        /// because the lime fill does not change between them. 17:1 against the
        /// lime; white would be 1.2:1.
        public static let onBrand = Color(.sRGB, white: 0.06, opacity: 1)

        /// Confirmed, reconciled, complete.
        public static let confirmed = Color.green
        /// Needs a look, but play continues.
        public static let caution = Color.orange
        /// Destructive, or a dismissal.
        public static let critical = Color.red
        /// The colour of a recorded goal. Deliberately the accent rather than a
        /// team colour, so it reads the same for either side.
        public static let goal = Color.accentColor
    }

    /// Team identity, resolved from stored hex with a sensible fallback.
    public static func teamColor(hex: String?) -> Color {
        guard let hex, let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16)
        else { return .accentColor }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    public static func hex(from color: Color) -> String? {
        #if canImport(UIKit)
            let resolved = UIColor(color)
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
            return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #else
            return nil
        #endif
    }
}

extension Font {
    /// The score. Large, tabular, never shifting width as it changes.
    public static func programmeScore(_ size: CGFloat = 44) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// The clock. Must not jitter, so monospaced digits are mandatory.
    public static func programmeClock(_ size: CGFloat = 30) -> Font {
        .system(size: size, weight: .medium).monospacedDigit()
    }

    public static func programmeJersey(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .semibold).monospacedDigit()
    }

    public static var programmeSectionLabel: Font {
        .system(.caption, design: .default, weight: .semibold)
    }
}

extension View {
    /// Section headers in Programme are small, wide-tracked and quiet.
    public func programmeSectionHeader() -> some View {
        self
            .font(.programmeSectionLabel)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }

    /// Applies a tint only when the system is not asking us to avoid relying on
    /// colour to convey meaning.
    @ViewBuilder
    public func semanticTint(_ color: Color, differentiateWithoutColor: Bool) -> some View {
        if differentiateWithoutColor {
            self.foregroundStyle(.primary)
        } else {
            self.foregroundStyle(color)
        }
    }
}

extension CompletenessState {
    public var symbolName: String {
        switch self {
        case .complete: "checkmark.circle.fill"
        case .needsReview: "exclamationmark.triangle.fill"
        case .notTracked: "minus.circle"
        }
    }

    public var tint: Color {
        switch self {
        case .complete: Programme.Palette.confirmed
        case .needsReview: Programme.Palette.caution
        case .notTracked: .secondary
        }
    }
}

extension IssueSeverity {
    public var tint: Color {
        switch self {
        case .info: .secondary
        case .review: Programme.Palette.caution
        case .blocking: Programme.Palette.critical
        }
    }
}

extension MatchResult {
    public var tint: Color {
        switch self {
        case .win: Programme.Palette.confirmed
        case .loss: Programme.Palette.critical
        case .draw: .secondary
        }
    }
}
