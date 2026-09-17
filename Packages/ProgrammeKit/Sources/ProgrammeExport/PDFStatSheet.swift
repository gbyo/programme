import CoreGraphics
import CoreText
import Foundation
import ProgrammeCore

/// A small typesetting layer over Core Graphics so the printed stat sheet looks
/// like a scorebook page rather than a screenshot of a table view.
final class PDFPageRenderer {
    let context: CGContext
    let pageSize: CGSize
    let margin: CGFloat
    private(set) var cursorY: CGFloat
    private var pageStarted = false

    init(context: CGContext, pageSize: CGSize, margin: CGFloat) {
        self.context = context
        self.pageSize = pageSize
        self.margin = margin
        self.cursorY = pageSize.height - margin
    }

    var contentWidth: CGFloat { pageSize.width - margin * 2 }

    static func body(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func bold(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// The system font with monospaced figures, rather than a monospaced
    /// typeface: columns stay aligned without the numbers looking like code.
    static func mono(_ size: CGFloat) -> CTFont {
        let base = body(size)
        let features: [[CFString: Any]] = [
            [
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ]
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute: features] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    func beginPage() {
        context.beginPDFPage(nil)
        pageStarted = true
        cursorY = pageSize.height - margin
    }

    func endPage() {
        guard pageStarted else { return }
        context.endPDFPage()
        pageStarted = false
    }

    /// Start a new page when the next block would not fit.
    func ensureSpace(_ height: CGFloat) {
        if !pageStarted { beginPage(); return }
        if cursorY - height < margin {
            endPage()
            beginPage()
        }
    }

    func advance(_ amount: CGFloat) { cursorY -= amount }

    func draw(
        _ text: String, font: CTFont, x: CGFloat, width: CGFloat? = nil,
        alignRight: Bool = false, gray: CGFloat = 0
    ) {
        guard !text.isEmpty else { return }
        // Core Text attribute keys directly: this module has no UIKit or AppKit
        // dependency, so the same renderer works everywhere Programme runs.
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1),
        ]
        guard
            let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var originX = margin + x
        if alignRight, let width {
            let bounds = CTLineGetTypographicBounds(line, nil, nil, nil)
            originX = margin + x + width - CGFloat(bounds)
        }
        context.textPosition = CGPoint(x: originX, y: cursorY)
        CTLineDraw(line, context)
    }

    func rule(gray: CGFloat = 0.8, inset: CGFloat = 0) {
        context.saveGState()
        context.setStrokeColor(CGColor(gray: gray, alpha: 1))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin + inset, y: cursorY))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: cursorY))
        context.strokePath()
        context.restoreGState()
    }
}

struct PDFColumn {
    var title: String
    var x: CGFloat
    var width: CGFloat
    var alignRight: Bool
}

/// A printable match or season report.
public struct PDFStatSheetExporter: StatExporter {
    public init() {}
    public let id = "stat-sheet"
    public let name = "Stat Sheet (PDF)"
    public let detail = "A printable scorebook page with the box score and timeline."
    public let fileExtension = "pdf"
    public let contentTypeIdentifier = "com.adobe.pdf"
    public let symbolName = "doc.richtext"

    public func export(_ payload: ExportPayload) throws -> Data {
        guard !payload.contexts.isEmpty else { throw ExportError.nothingToExport }

        let pageSize = CGSize(width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ExportError.encodingFailed
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        var info: [CFString: Any] = [
            kCGPDFContextTitle: "\(payload.teamName) — Programme Stat Sheet",
            kCGPDFContextCreator: "Programme",
        ]
        if let first = payload.contexts.first {
            info[kCGPDFContextSubject] = "\(first.descriptor.teamShortName) vs \(first.descriptor.opponentShortName)"
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ExportError.encodingFailed
        }

        let renderer = PDFPageRenderer(context: context, pageSize: pageSize, margin: 48)
        renderer.beginPage()

        for (index, pair) in zip(payload.contexts, payload.snapshots).enumerated() {
            if index > 0 {
                renderer.endPage()
                renderer.beginPage()
            }
            drawMatch(pair.0, snapshot: pair.1, payload: payload, renderer: renderer)
        }

        if payload.contexts.count > 1 {
            renderer.endPage()
            renderer.beginPage()
            drawSeason(payload: payload, renderer: renderer)
        }

        renderer.endPage()
        context.closePDF()
        return data as Data
    }

    private func drawMatch(
        _ match: MatchContext, snapshot: MatchSnapshot, payload: ExportPayload,
        renderer: PDFPageRenderer
    ) {
        let profile = match.profile

        renderer.draw("PROGRAMME", font: PDFPageRenderer.bold(9), x: 0, gray: 0.45)
        renderer.advance(22)
        renderer.draw(
            "\(match.descriptor.teamShortName)  \(snapshot.score.us) – \(snapshot.score.opponent)  \(match.descriptor.opponentShortName)",
            font: PDFPageRenderer.bold(22), x: 0)
        renderer.advance(16)
        var subtitle = ExportFormatting.dateFormatter.string(from: match.descriptor.kickoff)
        subtitle += " · \(match.descriptor.venue.label) · \(match.rules.name)"
        if let competition = match.descriptor.competition { subtitle += " · \(competition)" }
        renderer.draw(subtitle, font: PDFPageRenderer.body(9.5), x: 0, gray: 0.35)
        renderer.advance(14)
        renderer.rule()
        renderer.advance(20)

        // Team comparison
        renderer.draw("TEAM", font: PDFPageRenderer.bold(8.5), x: 0, gray: 0.45)
        renderer.advance(14)
        let teamRows: [(String, TrackedStat, Int, Int)] = [
            ("Goals", .goals, snapshot.team.us.goals, snapshot.team.opponent.goals),
            ("Shots", .shots, snapshot.team.us.shots, snapshot.team.opponent.shots),
            ("Shots on Goal", .shots, snapshot.team.us.shotsOnGoal, snapshot.team.opponent.shotsOnGoal),
            ("Saves", .goalkeeping, snapshot.team.us.saves, snapshot.team.opponent.saves),
            ("Corner Kicks", .corners, snapshot.team.us.corners, snapshot.team.opponent.corners),
            ("Steals", .steals, snapshot.team.us.steals, snapshot.team.opponent.steals),
            ("Yellow Cards", .cards, snapshot.team.us.yellowCards, snapshot.team.opponent.yellowCards),
            ("Red Cards", .cards, snapshot.team.us.redCards, snapshot.team.opponent.redCards),
        ]
        renderer.draw(match.descriptor.teamShortName, font: PDFPageRenderer.body(8), x: 150, width: 60, alignRight: true, gray: 0.45)
        renderer.draw(match.descriptor.opponentShortName, font: PDFPageRenderer.body(8), x: 220, width: 60, alignRight: true, gray: 0.45)
        renderer.advance(13)
        for (label, stat, us, them) in teamRows {
            renderer.ensureSpace(14)
            renderer.draw(label, font: PDFPageRenderer.body(9.5), x: 0)
            let ours = ExportFormatting.cell(profile.value(stat, us))
            let theirs = ExportFormatting.cell(profile.value(stat, them))
            renderer.draw(ours.isEmpty ? "—" : ours, font: PDFPageRenderer.mono(9.5), x: 150, width: 60, alignRight: true, gray: ours.isEmpty ? 0.6 : 0)
            renderer.draw(theirs.isEmpty ? "—" : theirs, font: PDFPageRenderer.mono(9.5), x: 220, width: 60, alignRight: true, gray: theirs.isEmpty ? 0.6 : 0)
            renderer.advance(13)
        }
        renderer.advance(14)

        // Box score
        let columns: [PDFColumn] = [
            PDFColumn(title: "#", x: 0, width: 22, alignRight: false),
            PDFColumn(title: "PLAYER", x: 24, width: 130, alignRight: false),
            PDFColumn(title: "MIN", x: 158, width: 30, alignRight: true),
            PDFColumn(title: "G", x: 192, width: 24, alignRight: true),
            PDFColumn(title: "A", x: 220, width: 24, alignRight: true),
            PDFColumn(title: "PTS", x: 248, width: 30, alignRight: true),
            PDFColumn(title: "SH", x: 282, width: 28, alignRight: true),
            PDFColumn(title: "SOG", x: 314, width: 32, alignRight: true),
            PDFColumn(title: "CK", x: 350, width: 26, alignRight: true),
            PDFColumn(title: "ST", x: 380, width: 26, alignRight: true),
            PDFColumn(title: "YC", x: 410, width: 26, alignRight: true),
            PDFColumn(title: "RC", x: 440, width: 26, alignRight: true),
        ]
        renderer.ensureSpace(40)
        renderer.draw("BOX SCORE", font: PDFPageRenderer.bold(8.5), x: 0, gray: 0.45)
        renderer.advance(14)
        for column in columns {
            renderer.draw(
                column.title, font: PDFPageRenderer.body(7.5), x: column.x, width: column.width,
                alignRight: column.alignRight, gray: 0.45)
        }
        renderer.advance(4)
        renderer.rule(gray: 0.85)
        renderer.advance(12)

        for player in match.roster.sortedByNumber {
            guard let line = snapshot.players[player.id], line.appeared else { continue }
            renderer.ensureSpace(13)
            func numeric(_ stat: TrackedStat, _ value: Int) -> String {
                let text = ExportFormatting.cell(profile.value(stat, value))
                return text.isEmpty ? "—" : text
            }
            let values: [String] = [
                player.jerseyNumber.map(String.init) ?? "",
                player.fullName + (line.started ? "" : "  (sub)"),
                "\(line.minutesPlayed)",
                numeric(.goals, line.goals),
                numeric(.assists, line.assists),
                numeric(.goals, line.points),
                numeric(.shots, line.shots),
                numeric(.shots, line.shotsOnGoal),
                numeric(.corners, line.corners),
                numeric(.steals, line.steals),
                numeric(.cards, line.yellowCards),
                numeric(.cards, line.redCards),
            ]
            for (column, value) in zip(columns, values) {
                let font = column.alignRight ? PDFPageRenderer.mono(9) : PDFPageRenderer.body(9.5)
                renderer.draw(
                    value, font: font, x: column.x, width: column.width, alignRight: column.alignRight,
                    gray: value == "—" ? 0.62 : 0)
            }
            renderer.advance(13)
        }
        renderer.advance(12)

        // Goalkeeping
        if profile.tracks(.goalkeeping) {
            let keepers = snapshot.keepers.values
                .filter { $0.side == .us && $0.secondsPlayed > 0 }
                .sorted { $0.secondsPlayed > $1.secondsPlayed }
            if !keepers.isEmpty {
                renderer.ensureSpace(50)
                renderer.draw("GOALKEEPING", font: PDFPageRenderer.bold(8.5), x: 0, gray: 0.45)
                renderer.advance(14)
                let keeperColumns: [PDFColumn] = [
                    PDFColumn(title: "#", x: 0, width: 22, alignRight: false),
                    PDFColumn(title: "PLAYER", x: 24, width: 130, alignRight: false),
                    PDFColumn(title: "MIN", x: 158, width: 30, alignRight: true),
                    PDFColumn(title: "SOGA", x: 192, width: 36, alignRight: true),
                    PDFColumn(title: "SV", x: 232, width: 28, alignRight: true),
                    PDFColumn(title: "GA", x: 264, width: 28, alignRight: true),
                    PDFColumn(title: "SV%", x: 296, width: 46, alignRight: true),
                    PDFColumn(title: "GAA", x: 346, width: 40, alignRight: true),
                    PDFColumn(title: "SHO", x: 390, width: 32, alignRight: true),
                ]
                for column in keeperColumns {
                    renderer.draw(
                        column.title, font: PDFPageRenderer.body(7.5), x: column.x, width: column.width,
                        alignRight: column.alignRight, gray: 0.45)
                }
                renderer.advance(4)
                renderer.rule(gray: 0.85)
                renderer.advance(12)
                for keeper in keepers {
                    guard let player = match.roster[keeper.playerID] else { continue }
                    renderer.ensureSpace(13)
                    let gaa = keeper.goalsAgainstAverage(regulationSeconds: match.rules.regulationLength)
                    let values = [
                        player.jerseyNumber.map(String.init) ?? "",
                        player.fullName,
                        "\(keeper.minutesPlayed)",
                        "\(keeper.shotsOnGoalFaced)",
                        "\(keeper.saves)",
                        "\(keeper.goalsAllowed)",
                        keeper.savePercentage.map { ExportFormatting.percent($0) } ?? "—",
                        gaa.map { ExportFormatting.decimal($0) } ?? "—",
                        "\(keeper.shutouts + keeper.sharedShutouts)",
                    ]
                    for (column, value) in zip(keeperColumns, values) {
                        let font = column.alignRight ? PDFPageRenderer.mono(9) : PDFPageRenderer.body(9.5)
                        renderer.draw(
                            value, font: font, x: column.x, width: column.width,
                            alignRight: column.alignRight, gray: value == "—" ? 0.62 : 0)
                    }
                    renderer.advance(13)
                }
                renderer.advance(12)
            }
        }

        // Timeline
        let descriptions = MatchNarrator.describeAll(context: match)
            .filter { $0.category != .structural || $0.title.contains("begins") || $0.title.contains("ends") }
        if !descriptions.isEmpty {
            renderer.ensureSpace(40)
            renderer.draw("TIMELINE", font: PDFPageRenderer.bold(8.5), x: 0, gray: 0.45)
            if match.rules.clockDisplay == .countDownInPeriod {
                // Times descend within a period under a counting-down clock.
                // Say so, rather than leaving a reader to wonder.
                renderer.draw(
                    "times as shown on a counting-down scoreboard", font: PDFPageRenderer.body(7.5),
                    x: 70, gray: 0.55)
            }
            renderer.advance(14)
            for description in descriptions {
                renderer.ensureSpace(12)
                renderer.draw(description.timeText, font: PDFPageRenderer.mono(8.5), x: 0, width: 40, alignRight: true, gray: 0.4)
                var text = description.title
                if !description.detail.isEmpty { text += " · \(description.detail)" }
                if let secondary = description.secondaryDetail { text += " · \(secondary)" }
                renderer.draw(text, font: PDFPageRenderer.body(9), x: 50)
                if let score = description.scoreText {
                    renderer.draw(score, font: PDFPageRenderer.mono(9), x: 460, width: 56, alignRight: true, gray: 0.2)
                }
                renderer.advance(12)
            }
            renderer.advance(10)
        }

        // Completeness
        renderer.ensureSpace(60)
        renderer.rule(gray: 0.85)
        renderer.advance(14)
        renderer.draw("STAT COMPLETENESS", font: PDFPageRenderer.bold(8.5), x: 0, gray: 0.45)
        renderer.advance(13)
        let stats = TrackedStat.allCases.sorted { $0.label < $1.label }
        for (index, stat) in stats.enumerated() {
            let column = CGFloat(index % 3) * 170
            if index % 3 == 0 { renderer.ensureSpace(12) }
            let state = snapshot.completeness(stat)
            renderer.draw(stat.label, font: PDFPageRenderer.body(8.5), x: column, gray: 0.15)
            renderer.draw(
                state.label, font: PDFPageRenderer.body(8.5), x: column + 88, width: 70,
                alignRight: false, gray: state == .complete ? 0.35 : 0.55)
            if index % 3 == 2 { renderer.advance(12) }
        }
        if stats.count % 3 != 0 { renderer.advance(12) }
        renderer.advance(6)
        renderer.draw(
            "“Not tracked” means the category was never recorded for this match. It is unknown, not zero.",
            font: PDFPageRenderer.body(8), x: 0, gray: 0.45)
        renderer.advance(12)
        renderer.draw(
            "Generated by Programme on \(ExportFormatting.dateFormatter.string(from: payload.generatedAt)).",
            font: PDFPageRenderer.body(8), x: 0, gray: 0.55)
    }

    private func drawSeason(payload: ExportPayload, renderer: PDFPageRenderer) {
        let season = payload.seasonStats
        let roster = payload.combinedRoster

        renderer.draw("PROGRAMME", font: PDFPageRenderer.bold(9), x: 0, gray: 0.45)
        renderer.advance(22)
        renderer.draw(payload.teamName, font: PDFPageRenderer.bold(20), x: 0)
        renderer.advance(16)
        var subtitle = "Season totals"
        if let name = payload.seasonName { subtitle = "\(name) season totals" }
        subtitle += " · \(season.recordText) · \(season.goalsFor) GF / \(season.goalsAgainst) GA"
        renderer.draw(subtitle, font: PDFPageRenderer.body(9.5), x: 0, gray: 0.35)
        renderer.advance(14)
        renderer.rule()
        renderer.advance(20)

        let columns: [PDFColumn] = [
            PDFColumn(title: "#", x: 0, width: 22, alignRight: false),
            PDFColumn(title: "PLAYER", x: 24, width: 140, alignRight: false),
            PDFColumn(title: "GP", x: 168, width: 26, alignRight: true),
            PDFColumn(title: "GS", x: 198, width: 26, alignRight: true),
            PDFColumn(title: "MIN", x: 228, width: 38, alignRight: true),
            PDFColumn(title: "G", x: 270, width: 26, alignRight: true),
            PDFColumn(title: "A", x: 300, width: 26, alignRight: true),
            PDFColumn(title: "PTS", x: 330, width: 32, alignRight: true),
            PDFColumn(title: "SH", x: 366, width: 30, alignRight: true),
            PDFColumn(title: "SOG", x: 400, width: 34, alignRight: true),
            PDFColumn(title: "GWG", x: 438, width: 34, alignRight: true),
        ]
        for column in columns {
            renderer.draw(
                column.title, font: PDFPageRenderer.body(7.5), x: column.x, width: column.width,
                alignRight: column.alignRight, gray: 0.45)
        }
        renderer.advance(4)
        renderer.rule(gray: 0.85)
        renderer.advance(12)

        for stats in season.sortedPlayers {
            guard let player = roster[stats.playerID] else { continue }
            renderer.ensureSpace(13)
            func cell(_ value: StatValue) -> String {
                let text = ExportFormatting.cell(value)
                return text.isEmpty ? "—" : text
            }
            let values = [
                player.jerseyNumber.map(String.init) ?? "",
                player.fullName,
                "\(stats.matchesPlayed)",
                "\(stats.starts)",
                "\(stats.minutesPlayed)",
                cell(stats.value(.goals, \.goals)),
                cell(stats.value(.assists, \.assists)),
                cell(stats.value(.goals, \.points)),
                cell(stats.value(.shots, \.shots)),
                cell(stats.value(.shots, \.shotsOnGoal)),
                cell(stats.value(.goals, \.gameWinningGoals)),
            ]
            for (column, value) in zip(columns, values) {
                let font = column.alignRight ? PDFPageRenderer.mono(9) : PDFPageRenderer.body(9.5)
                renderer.draw(
                    value, font: font, x: column.x, width: column.width, alignRight: column.alignRight,
                    gray: value == "—" ? 0.62 : 0)
            }
            renderer.advance(13)
        }

        renderer.advance(16)
        renderer.draw(
            "Generated by Programme on \(ExportFormatting.dateFormatter.string(from: payload.generatedAt)).",
            font: PDFPageRenderer.body(8), x: 0, gray: 0.55)
    }
}
