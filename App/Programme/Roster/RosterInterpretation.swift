import Foundation
import FoundationModels
import ProgrammeCore
import ProgrammeExport

/// Optional on-device interpretation of pasted roster text.
///
/// The model only ever produces a `RosterImportPreview`: the same review
/// step as every other import path, with human confirmation required
/// before anything is written. It never touches scoring, stats, conflicts
/// or recovery — those stay in the deterministic local core.
@Generable(description: "Roster players in the order listed, skipping non-player lines")
struct InterpretedRoster {
    var players: [InterpretedPlayer]
}

@Generable
struct InterpretedPlayer {
    var firstName: String
    var lastName: String
    var jerseyNumber: Int?
    var position: String?
    var classYear: String?
}

enum RosterInterpreter {
    /// Gated on `SystemLanguageModel.availability`: no model, no button.
    /// Foundation Models is unavailable on watchOS and on devices without
    /// Apple Intelligence; the rule-based CSV path always remains.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func interpret(_ text: String) async throws -> RosterImportPreview {
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: prompt(for: text), generating: InterpretedRoster.self)
        return preview(from: response.content)
    }

    static func prompt(for text: String) -> String {
        """
        Read the following roster text and list each player. Keep names \
        exactly as written. Leave a field empty when it is not shown. \
        Input is truncated to keep the request small.

        \(text.prefix(8_000))
        """
    }

    /// Maps structured model output onto the shared preview. The mapping
    /// step is always shown (`mappingIsUnambiguous: false`): model output
    /// is a suggestion the human confirms, never a write.
    static func preview(from roster: InterpretedRoster) -> RosterImportPreview {
        let rows = roster.players.map { player in
            RosterImportRow(fields: [
                player.firstName,
                player.lastName,
                player.jerseyNumber.map(String.init) ?? "",
                player.position ?? "",
                player.classYear ?? "",
            ])
        }
        return RosterImportPreview(
            headers: ["First name", "Last name", "Number", "Position", "Class"],
            rows: rows,
            mapping: [
                0: .firstName, 1: .lastName, 2: .jerseyNumber, 3: .position,
                4: .classYear,
            ],
            hasHeaderRow: true,
            mappingIsUnambiguous: false)
    }
}
