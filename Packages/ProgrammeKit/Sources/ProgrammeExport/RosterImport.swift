import Foundation
import ProgrammeCore

/// A column Programme knows how to fill from an imported table.
public enum RosterColumn: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case ignore
    case jerseyNumber
    case fullName
    case firstName
    case lastName
    case position
    case classYear

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ignore: "Don't import"
        case .jerseyNumber: "Jersey Number"
        case .fullName: "Full Name"
        case .firstName: "First Name"
        case .lastName: "Last Name"
        case .position: "Position"
        case .classYear: "Class"
        }
    }

    /// Header text that maps to this column without asking.
    var aliases: [String] {
        switch self {
        case .ignore: []
        case .jerseyNumber: ["#", "no", "no.", "num", "number", "jersey", "jersey number", "uniform"]
        case .fullName: ["name", "player", "player name", "athlete", "full name"]
        case .firstName: ["first", "first name", "firstname", "given"]
        case .lastName: ["last", "last name", "lastname", "surname", "family"]
        case .position: ["pos", "position"]
        case .classYear: ["class", "year", "grade", "class year", "yr"]
        }
    }
}

public struct RosterImportRow: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var fields: [String]
    /// Set when the row cannot become a player as mapped.
    public var problem: String?
    public var isSelected: Bool = true
}

/// The result of reading a table, before anything is written to the database.
/// Programme always shows this step when the mapping is not unambiguous.
public struct RosterImportPreview: Hashable, Sendable {
    public var headers: [String]
    public var rows: [RosterImportRow]
    public var mapping: [Int: RosterColumn]
    public var hasHeaderRow: Bool
    /// True when every column was recognised, so the mapping step can be skipped.
    public var mappingIsUnambiguous: Bool

    public var mappedColumns: Set<RosterColumn> {
        Set(mapping.values.filter { $0 != .ignore })
    }

    public func player(from row: RosterImportRow) -> PlayerSnapshot? {
        var first = ""
        var last = ""
        var number: Int?
        var position: PlayerPosition?
        var classYear: String?

        for (index, column) in mapping {
            guard index < row.fields.count else { continue }
            let value = row.fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch column {
            case .ignore: continue
            case .jerseyNumber:
                number = Int(value.replacingOccurrences(of: "#", with: ""))
            case .fullName:
                let parts = Self.splitName(value)
                first = parts.first
                last = parts.last
            case .firstName: first = value
            case .lastName: last = value
            case .position: position = Self.parsePosition(value)
            case .classYear: classYear = value
            }
        }
        guard !first.isEmpty || !last.isEmpty else { return nil }
        return PlayerSnapshot(
            firstName: first, lastName: last, jerseyNumber: number, position: position,
            classYear: classYear)
    }

    public var players: [PlayerSnapshot] {
        rows.filter(\.isSelected).compactMap(player(from:))
    }

    /// "Carter, Jalen" and "Jalen Carter" both work.
    public static func splitName(_ value: String) -> (first: String, last: String) {
        if value.contains(",") {
            let parts = value.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return (parts.count > 1 ? parts[1] : "", parts[0])
        }
        let parts = value.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return (parts.first ?? value, "") }
        return (parts.dropLast().joined(separator: " "), parts[parts.count - 1])
    }

    public static func parsePosition(_ value: String) -> PlayerPosition? {
        switch value.lowercased().trimmingCharacters(in: .whitespaces) {
        case "gk", "g", "keeper", "goalie", "goalkeeper": .goalkeeper
        case "d", "def", "defender", "back", "fullback", "cb", "lb", "rb": .defender
        case "m", "mid", "midfield", "midfielder", "cm", "dm", "am": .midfielder
        case "f", "fw", "forward", "striker", "st", "winger", "w": .forward
        default: nil
        }
    }
}

/// Reads CSV and pasted tabular text into a reviewable roster import.
public enum RosterImporter {

    public static func preview(csv text: String) -> RosterImportPreview {
        let delimiter: Character = text.contains("\t") && !text.contains(",") ? "\t" : ","
        var rows = parse(text, delimiter: delimiter)
        guard !rows.isEmpty else {
            return RosterImportPreview(
                headers: [], rows: [], mapping: [:], hasHeaderRow: false, mappingIsUnambiguous: false)
        }

        let firstRow = rows[0]
        let looksLikeHeader = firstRow.contains { field in
            RosterColumn.allCases.contains { column in
                column.aliases.contains(field.lowercased().trimmingCharacters(in: .whitespaces))
            }
        }

        var headers: [String]
        if looksLikeHeader {
            headers = firstRow
            rows.removeFirst()
        } else {
            headers = (0..<firstRow.count).map { "Column \($0 + 1)" }
        }

        var mapping: [Int: RosterColumn] = [:]
        if looksLikeHeader {
            for (index, header) in headers.enumerated() {
                let normalized = header.lowercased().trimmingCharacters(in: .whitespaces)
                let match = RosterColumn.allCases.first { $0 != .ignore && $0.aliases.contains(normalized) }
                mapping[index] = match ?? .ignore
            }
        } else {
            // Guess from shape: a short numeric column is a jersey number, the
            // widest text column is the name.
            for index in 0..<headers.count {
                let values = rows.compactMap { index < $0.count ? $0[index] : nil }
                let numeric = values.allSatisfy { Int($0.trimmingCharacters(in: .whitespaces)) != nil }
                if numeric && !values.isEmpty {
                    mapping[index] = .jerseyNumber
                } else if values.contains(where: { $0.contains(" ") || $0.contains(",") }) {
                    mapping[index] = mapping.values.contains(.fullName) ? .ignore : .fullName
                } else {
                    mapping[index] = .ignore
                }
            }
        }

        let hasName = mapping.values.contains(.fullName)
            || (mapping.values.contains(.firstName) && mapping.values.contains(.lastName))
            || mapping.values.contains(.lastName)
        let unmapped = mapping.values.filter { $0 == .ignore }.count
        let unambiguous = looksLikeHeader && hasName && unmapped == 0

        var importRows = rows.map { RosterImportRow(fields: $0) }
        var preview = RosterImportPreview(
            headers: headers, rows: importRows, mapping: mapping, hasHeaderRow: looksLikeHeader,
            mappingIsUnambiguous: unambiguous)

        for index in importRows.indices {
            if preview.player(from: importRows[index]) == nil {
                importRows[index].problem = "No name in this row"
                importRows[index].isSelected = false
            }
        }
        preview.rows = importRows
        return preview
    }

    /// A CSV parser that handles quoted fields, embedded commas and newlines.
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func finishField() {
            row.append(field)
            field = ""
        }
        func finishRow() {
            finishField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                rows.append(row)
            }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": inQuotes = true
                case delimiter: finishField()
                case "\n": finishRow()
                case "\r": break
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { finishRow() }
        return rows
    }
}
