import ProgrammeCore
import SwiftUI

/// One shot placed on the pitch.
public struct ShotMarker: Identifiable, Hashable, Sendable {
    public var id: EventID
    public var point: PitchPoint
    public var outcome: ShotOutcome
    public var side: TeamSide
    public var label: String
    public var isHighlighted: Bool

    public init(
        id: EventID, point: PitchPoint, outcome: ShotOutcome, side: TeamSide, label: String,
        isHighlighted: Bool = false
    ) {
        self.id = id
        self.point = point
        self.outcome = outcome
        self.side = side
        self.label = label
        self.isHighlighted = isHighlighted
    }
}

extension ShotOutcome {
    /// Markers are told apart by shape first. Colour is a reinforcement, never
    /// the only signal, so the map still reads with Differentiate Without Colour
    /// on or in bright sun.
    public var markerSymbolName: String {
        switch self {
        case .goal: "circle.circle.fill"
        case .saved: "circle.fill"
        case .offTarget: "circle"
        case .blocked: "square"
        case .woodwork: "diamond"
        }
    }
}

/// Programme's pitch: a vector drawing, not an image, so it is crisp at any
/// window size and readable in both appearances.
///
/// It is the scoring workspace's centre panel and has to earn that space: it
/// carries the shot map, accepts a tap or an Apple Pencil touch to place a
/// location, and previews the prospective point under a hovering Pencil.
public struct PitchView: View {
    public var markers: [ShotMarker]
    public var pendingLocation: PitchPoint?
    public var isPlacementActive: Bool
    public var onPlace: ((PitchPoint) -> Void)?
    public var onClearPendingLocation: (() -> Void)?
    public var onConfirmPendingLocation: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.preferredPencilDoubleTapAction) private var preferredPencilDoubleTapAction
    @Environment(\.preferredPencilSqueezeAction) private var preferredPencilSqueezeAction
    @State private var hoverPoint: CGPoint?

    public init(
        markers: [ShotMarker] = [],
        pendingLocation: PitchPoint? = nil,
        isPlacementActive: Bool = false,
        onPlace: ((PitchPoint) -> Void)? = nil,
        onClearPendingLocation: (() -> Void)? = nil,
        onConfirmPendingLocation: (() -> Void)? = nil
    ) {
        self.markers = markers
        self.pendingLocation = pendingLocation
        self.isPlacementActive = isPlacementActive
        self.onPlace = onPlace
        self.onClearPendingLocation = onClearPendingLocation
        self.onConfirmPendingLocation = onConfirmPendingLocation
    }

    /// A real pitch is about 105 by 68 metres.
    private static let aspectRatio: CGFloat = 105.0 / 68.0

    public var body: some View {
        GeometryReader { proxy in
            let rect = pitchRect(in: proxy.size)
            ZStack {
                Canvas(rendersAsynchronously: false) { context, _ in
                    draw(pitch: rect, in: &context)
                    drawMarkers(in: rect, context: &context)
                }
                .accessibilityHidden(true)

                if let hoverPoint, isPlacementActive {
                    crosshair(at: hoverPoint)
                        .allowsHitTesting(false)
                }
                if let pendingLocation {
                    let point = pointFor(pendingLocation, in: rect)
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .background(Circle().fill(Color.accentColor.opacity(0.28)))
                        .frame(width: 26, height: 26)
                        .position(point)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard isPlacementActive, let onPlace else { return }
                onPlace(normalized(location, in: rect))
            }
            // Apple Pencil double-tap clears the proposed point. Programme has
            // no drawing tools, so the system double-tap preference (which
            // governs tool switching) has nothing to switch between; the fixed
            // mapping is clear, matching the on-screen Clear affordance.
            .onPencilDoubleTap { _ in
                guard isPlacementActive, preferredPencilDoubleTapAction != .ignore else { return }
                onClearPendingLocation?()
            }
            // Apple Pencil Pro squeeze confirms, mirroring the Record button.
            // Only the release phase commits, so previewing the squeeze does
            // nothing; with no pending point it is a no-op.
            .onPencilSqueeze { phase in
                guard
                    isPlacementActive,
                    preferredPencilSqueezeAction != .ignore,
                    case .ended = phase
                else { return }
                onConfirmPendingLocation?()
            }
            .onContinuousHover { phase in
                guard isPlacementActive else {
                    hoverPoint = nil
                    return
                }
                switch phase {
                case .active(let location): hoverPoint = location
                case .ended: hoverPoint = nil
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: pendingLocation)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(accessibilityDetail)
        .accessibilityAddTraits(isPlacementActive ? .isButton : [])
        .accessibilityHint(isPlacementActive ? "Double tap to place the shot in the centre of the box." : "")
        .accessibilityAction(named: "Place in the centre of the box") {
            guard isPlacementActive else { return }
            onPlace?(PitchPoint(x: 0.88, y: 0.5))
        }
    }

    // MARK: - Geometry

    private func pitchRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 10
        let available = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        var width = available.width
        var height = width / Self.aspectRatio
        if height > available.height {
            height = available.height
            width = height * Self.aspectRatio
        }
        return CGRect(
            x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// Attacking direction is left to right, which is how a shot chart is read.
    private func pointFor(_ point: PitchPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * point.x, y: rect.minY + rect.height * point.y)
    }

    private func normalized(_ location: CGPoint, in rect: CGRect) -> PitchPoint {
        PitchPoint(
            x: (location.x - rect.minX) / max(1, rect.width),
            y: (location.y - rect.minY) / max(1, rect.height))
    }

    // MARK: - Drawing

    private var lineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.26) : Color.black.opacity(0.18)
    }

    private var surfaceColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025)
    }

    private func draw(pitch rect: CGRect, in context: inout GraphicsContext) {
        let line = GraphicsContext.Shading.color(lineColor)
        let lineWidth: CGFloat = max(1, rect.height * 0.0035)

        context.fill(
            Path(roundedRect: rect, cornerRadius: 3),
            with: .color(surfaceColor))

        var path = Path()
        path.addRect(rect)

        // Halfway line and centre circle.
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        let centreRadius = rect.height * (9.15 / 68)
        path.addEllipse(
            in: CGRect(
                x: rect.midX - centreRadius, y: rect.midY - centreRadius,
                width: centreRadius * 2, height: centreRadius * 2))

        // Penalty and goal areas at both ends.
        let penaltyDepth = rect.width * (16.5 / 105)
        let penaltyHeight = rect.height * (40.32 / 68)
        let goalAreaDepth = rect.width * (5.5 / 105)
        let goalAreaHeight = rect.height * (18.32 / 68)
        let goalDepth = rect.width * (1.5 / 105)
        let goalHeight = rect.height * (7.32 / 68)

        for leading in [true, false] {
            let penaltyX = leading ? rect.minX : rect.maxX - penaltyDepth
            path.addRect(
                CGRect(
                    x: penaltyX, y: rect.midY - penaltyHeight / 2, width: penaltyDepth,
                    height: penaltyHeight))
            let goalAreaX = leading ? rect.minX : rect.maxX - goalAreaDepth
            path.addRect(
                CGRect(
                    x: goalAreaX, y: rect.midY - goalAreaHeight / 2, width: goalAreaDepth,
                    height: goalAreaHeight))
            let goalX = leading ? rect.minX - goalDepth : rect.maxX
            path.addRect(
                CGRect(x: goalX, y: rect.midY - goalHeight / 2, width: goalDepth, height: goalHeight))
        }
        context.stroke(path, with: line, lineWidth: lineWidth)

        // Penalty spots.
        let spotRadius = max(1.2, rect.height * 0.006)
        for leading in [true, false] {
            let x = leading ? rect.minX + rect.width * (11 / 105) : rect.maxX - rect.width * (11 / 105)
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: x - spotRadius, y: rect.midY - spotRadius, width: spotRadius * 2,
                        height: spotRadius * 2)),
                with: line)
        }
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: rect.midX - spotRadius, y: rect.midY - spotRadius, width: spotRadius * 2,
                    height: spotRadius * 2)),
            with: line)

        // Penalty arcs, clipped to the area outside the box.
        let arcRadius = rect.height * (9.15 / 68)
        for leading in [true, false] {
            let spotX = leading ? rect.minX + rect.width * (11 / 105) : rect.maxX - rect.width * (11 / 105)
            var arc = Path()
            arc.addArc(
                center: CGPoint(x: spotX, y: rect.midY), radius: arcRadius,
                startAngle: .degrees(leading ? -55 : 125), endAngle: .degrees(leading ? 55 : 235),
                clockwise: false)
            context.stroke(arc, with: line, lineWidth: lineWidth)
        }

        // Attacking direction, so the map is never ambiguous.
        var arrow = Path()
        let arrowY = rect.maxY + 14
        let arrowWidth = min(60, rect.width * 0.12)
        arrow.move(to: CGPoint(x: rect.midX - arrowWidth / 2, y: arrowY))
        arrow.addLine(to: CGPoint(x: rect.midX + arrowWidth / 2, y: arrowY))
        arrow.move(to: CGPoint(x: rect.midX + arrowWidth / 2 - 5, y: arrowY - 4))
        arrow.addLine(to: CGPoint(x: rect.midX + arrowWidth / 2, y: arrowY))
        arrow.addLine(to: CGPoint(x: rect.midX + arrowWidth / 2 - 5, y: arrowY + 4))
        if arrowY < rect.maxY + 24 {
            context.stroke(arrow, with: .color(lineColor.opacity(0.8)), lineWidth: 1)
        }
    }

    private func drawMarkers(in rect: CGRect, context: inout GraphicsContext) {
        for marker in markers {
            // Opponent shots attack the other way, so they mirror.
            let point =
                marker.side == .us
                ? marker.point
                : PitchPoint(x: 1 - marker.point.x, y: 1 - marker.point.y)
            let position = pointFor(point, in: rect)
            let size: CGFloat = marker.outcome.isGoal ? 15 : 11
            let frame = CGRect(
                x: position.x - size / 2, y: position.y - size / 2, width: size, height: size)
            let tint = markerColor(for: marker)

            switch marker.outcome {
            case .goal:
                context.fill(Path(ellipseIn: frame), with: .color(tint))
                context.stroke(
                    Path(ellipseIn: frame.insetBy(dx: -4, dy: -4)), with: .color(tint.opacity(0.55)),
                    lineWidth: 1.5)
            case .saved:
                context.fill(Path(ellipseIn: frame), with: .color(tint))
            case .offTarget:
                context.stroke(Path(ellipseIn: frame), with: .color(tint), lineWidth: 1.8)
            case .blocked:
                context.stroke(Path(roundedRect: frame, cornerRadius: 1.5), with: .color(tint), lineWidth: 1.8)
            case .woodwork:
                var diamond = Path()
                diamond.move(to: CGPoint(x: frame.midX, y: frame.minY))
                diamond.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
                diamond.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
                diamond.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
                diamond.closeSubpath()
                context.stroke(diamond, with: .color(tint), lineWidth: 1.8)
            }

            if marker.isHighlighted {
                context.stroke(
                    Path(ellipseIn: frame.insetBy(dx: -7, dy: -7)), with: .color(Color.accentColor),
                    lineWidth: 2)
            }
        }
    }

    private func markerColor(for marker: ShotMarker) -> Color {
        if differentiateWithoutColor {
            return marker.side == .us ? .primary : .secondary
        }
        return marker.side == .us ? Color.accentColor : Color.secondary
    }

    private func crosshair(at point: CGPoint) -> some View {
        ZStack {
            Circle()
                .strokeBorder(Color.accentColor.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: 30, height: 30)
            Circle()
                .fill(Color.accentColor.opacity(0.3))
                .frame(width: 6, height: 6)
        }
        .position(point)
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        isPlacementActive ? "Pitch, placing a shot location" : "Shot map"
    }

    private var accessibilityDetail: String {
        guard !markers.isEmpty else { return "No shot locations recorded." }
        let ours = markers.filter { $0.side == .us }
        let theirs = markers.count - ours.count
        var text = "\(ours.count) shots by our team"
        if theirs > 0 { text += ", \(theirs) by the opponent" }
        let goals = markers.filter { $0.outcome.isGoal }
        if !goals.isEmpty {
            text += ". Goals: " + goals.map(\.label).joined(separator: ", ")
        }
        return text
    }
}

#Preview("Pitch with shots") {
    PitchView(
        markers: [
            ShotMarker(
                id: EventID(), point: PitchPoint(x: 0.86, y: 0.52), outcome: .goal, side: .us,
                label: "#9 Carter"),
            ShotMarker(
                id: EventID(), point: PitchPoint(x: 0.74, y: 0.34), outcome: .saved, side: .us,
                label: "#10 Sanders"),
            ShotMarker(
                id: EventID(), point: PitchPoint(x: 0.68, y: 0.72), outcome: .offTarget, side: .us,
                label: "#11 Trotter"),
            ShotMarker(
                id: EventID(), point: PitchPoint(x: 0.8, y: 0.45), outcome: .blocked, side: .us,
                label: "#7 Williams"),
            ShotMarker(
                id: EventID(), point: PitchPoint(x: 0.83, y: 0.6), outcome: .saved, side: .opponent,
                label: "Dixie"),
        ]
    )
    .padding()
    .frame(height: 340)
}
