import Foundation
import ProgrammeCore

/// Everything an exporter needs. Derived statistics are computed once here and
/// shared, so producing four formats does not recompute a season four times.
public struct ExportPayload: Sendable {
    public var teamName: String
    public var teamShortName: String
    public var seasonName: String?
    public var contexts: [MatchContext]
    public var generatedAt: Date

    public init(
        teamName: String,
        teamShortName: String? = nil,
        seasonName: String? = nil,
        contexts: [MatchContext],
        generatedAt: Date = Date()
    ) {
        self.teamName = teamName
        self.teamShortName = teamShortName ?? teamName
        self.seasonName = seasonName
        self.contexts = contexts
        self.generatedAt = generatedAt
    }

    public var snapshots: [MatchSnapshot] {
        contexts.map { StatEngine.snapshot(context: $0) }
    }

    public var seasonStats: SeasonStats {
        SeasonEngine.aggregate(
            zip(contexts, snapshots)
                .filter { $0.0.phase == .finalized }
                .map { MatchStatSummary(snapshot: $0.1, tracked: $0.0.profile.tracked, isFinalized: true) }
        )
    }

    /// The roster to print, taken from the matches themselves so a player who
    /// left the programme still appears in their own matches.
    public var combinedRoster: RosterSnapshot {
        var seen: [PlayerID: PlayerSnapshot] = [:]
        for context in contexts {
            for player in context.roster.players where seen[player.id] == nil {
                seen[player.id] = player
            }
        }
        return RosterSnapshot(players: Array(seen.values))
    }

    public var isSingleMatch: Bool { contexts.count == 1 }

    public var suggestedBaseFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let context = contexts.first, isSingleMatch {
            let date = formatter.string(from: context.descriptor.kickoff)
            let opponent = context.descriptor.opponentShortName
                .replacingOccurrences(of: " ", with: "-")
            return "\(date)-\(teamShortName.replacingOccurrences(of: " ", with: "-"))-vs-\(opponent)"
        }
        let season = seasonName ?? formatter.string(from: generatedAt)
        return "\(teamShortName.replacingOccurrences(of: " ", with: "-"))-\(season)"
    }
}

/// The seam MaxPreps and any other destination plugs into.
///
/// Programme's scoring engine knows nothing about export formats. Adding an
/// official MaxPreps supplier exporter later means adding a type here, with no
/// change to the event model, the stat engine or the UI.
public protocol StatExporter: Sendable {
    var id: String { get }
    var name: String { get }
    var detail: String { get }
    var fileExtension: String { get }
    /// Uniform type identifier of the produced file.
    var contentTypeIdentifier: String { get }
    /// Symbol shown beside the export in the share sheet.
    var symbolName: String { get }
    func export(_ payload: ExportPayload) throws -> Data
}

extension StatExporter {
    public func filename(for payload: ExportPayload) -> String {
        "\(payload.suggestedBaseFilename)-\(id).\(fileExtension)"
    }
}

public enum ExportError: Error, Sendable {
    case nothingToExport
    case encodingFailed

    public var message: String {
        switch self {
        case .nothingToExport: "There's nothing to export yet."
        case .encodingFailed: "Programme couldn't create the export. Your match is safe. Try again."
        }
    }
}

/// Every exporter Programme ships.
public enum ProgrammeExporters {
    public static let archive = ProgrammeArchiveExporter()
    public static let boxScoreCSV = BoxScoreCSVExporter()
    public static let seasonCSV = SeasonCSVExporter()
    public static let maxPreps = MaxPrepsEntrySummaryExporter()
    public static let statSheet = StatSheetExporter()
    public static let pdf = PDFStatSheetExporter()

    public static var all: [any StatExporter] {
        [archive, maxPreps, statSheet, pdf, boxScoreCSV, seasonCSV]
    }

    public static func forMatch() -> [any StatExporter] {
        [maxPreps, statSheet, pdf, boxScoreCSV, archive]
    }

    public static func forSeason() -> [any StatExporter] {
        [seasonCSV, statSheet, pdf, archive]
    }
}

// MARK: - Shared formatting

enum ExportFormatting {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// A blank cell means "not tracked". A zero means zero. That difference is
    /// preserved in every format Programme writes.
    static func cell(_ value: StatValue) -> String {
        switch value {
        case .count(let v): "\(v)"
        case .rate(let v): String(format: "%.3f", v)
        case .notTracked: ""
        case .notApplicable: ""
        }
    }

    static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }

    static func csvRow(_ fields: [String]) -> String {
        fields.map(csvEscape).joined(separator: ",")
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.1f%%", value * 100)
    }

    static func decimal(_ value: Double?, places: Int = 2) -> String {
        guard let value else { return "" }
        return String(format: "%.\(places)f", value)
    }

    static func pad(_ text: String, _ width: Int, alignRight: Bool = false) -> String {
        if text.count >= width { return String(text.prefix(width)) }
        let padding = String(repeating: " ", count: width - text.count)
        return alignRight ? padding + text : text + padding
    }
}
