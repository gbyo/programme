import ProgrammeCore
import XCTest

@testable import Programme

final class OpponentPaletteTests: XCTestCase {

    func testAdvancedExposesEveryBothTeamsSecondaryAction() {
        let available = OpponentMenuAction.allCases.filter { $0.isAvailable(in: .advanced) }
        XCTAssertEqual(Set(available), Set(OpponentMenuAction.allCases))
    }

    func testMaxPrepsFiltersStandardOnlyOpponentActions() {
        let available = Set(
            OpponentMenuAction.allCases.filter { $0.isAvailable(in: .maxPreps) })

        XCTAssertTrue(available.contains(.penaltyKick))
        XCTAssertTrue(available.contains(.steal))
        XCTAssertTrue(available.contains(.yellowCard))
        XCTAssertTrue(available.contains(.secondYellow))
        XCTAssertTrue(available.contains(.redCard))
        XCTAssertTrue(available.contains(.ownGoal))
        XCTAssertFalse(available.contains(.foul))
        XCTAssertFalse(available.contains(.offside))
    }

    func testOpponentMenuUsesSharedPendingActions() {
        XCTAssertEqual(OpponentMenuAction.penaltyKick.pending, .shotAttempt(.penaltyKick))
        XCTAssertEqual(OpponentMenuAction.steal.pending, .steal)
        XCTAssertEqual(OpponentMenuAction.foul.pending, .foul)
        XCTAssertEqual(OpponentMenuAction.offside.pending, .offside)
        XCTAssertEqual(OpponentMenuAction.yellowCard.pending, .card(.yellow))
        XCTAssertEqual(OpponentMenuAction.secondYellow.pending, .card(.secondYellow))
        XCTAssertEqual(OpponentMenuAction.redCard.pending, .card(.red))
        XCTAssertEqual(OpponentMenuAction.ownGoal.pending, .ownGoal)
    }
}
