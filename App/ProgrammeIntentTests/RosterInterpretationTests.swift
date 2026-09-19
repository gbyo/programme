import Foundation
import ProgrammeExport
import XCTest

@testable import Programme

/// Model output maps onto the shared review step: same preview, same
/// mapping UI, always human-confirmed. No model is invoked here.
final class RosterInterpretationTests: XCTestCase {
    func testInterpretedOutputMapsToReviewablePreview() {
        let interpreted = InterpretedRoster(players: [
            InterpretedPlayer(
                firstName: "Jalen", lastName: "Carter", jerseyNumber: 7,
                position: "Forward", classYear: "2027"),
            InterpretedPlayer(
                firstName: "Ava", lastName: "Nguyen", jerseyNumber: nil,
                position: nil, classYear: nil),
        ])
        let preview = RosterInterpreter.preview(from: interpreted)

        XCTAssertEqual(preview.headers, ["First name", "Last name", "Number", "Position", "Class"])
        XCTAssertEqual(preview.rows.count, 2)
        XCTAssertEqual(preview.rows[0].fields, ["Jalen", "Carter", "7", "Forward", "2027"])
        XCTAssertEqual(preview.rows[1].fields, ["Ava", "Nguyen", "", "", ""])
        // Model output is always a suggestion: the mapping step never skips.
        XCTAssertFalse(preview.mappingIsUnambiguous)
        XCTAssertTrue(preview.hasHeaderRow)

        let players = preview.players
        XCTAssertEqual(players.count, 2)
        XCTAssertEqual(players[0].firstName, "Jalen")
        XCTAssertEqual(players[0].lastName, "Carter")
        XCTAssertEqual(players[0].jerseyNumber, 7)
        XCTAssertEqual(players[1].firstName, "Ava")
        XCTAssertNil(players[1].jerseyNumber)
    }

    func testEmptyInterpretationYieldsNoRows() {
        let preview = RosterInterpreter.preview(from: InterpretedRoster(players: []))
        XCTAssertTrue(preview.rows.isEmpty)
        XCTAssertTrue(preview.players.isEmpty)
    }
}
