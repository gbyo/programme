import ProgrammeCore
import XCTest

@testable import Programme

final class EventComposerTests: XCTestCase {

    func testStandardContinuesFromAssistToShotLocation() {
        let goalID = EventID()
        var composer = EventComposer(
            step: .assist(goal: goalID, scorerName: "#9 Carter", side: .us))

        composer.offerShotLocation(
            shot: goalID,
            shooterName: "#9 Carter",
            outcome: .goal,
            side: .us,
            profile: .standard)

        XCTAssertEqual(
            composer.step,
            .shotLocation(shot: goalID, shooterName: "#9 Carter", outcome: .goal))
    }

    func testMaxPrepsFinishesAfterAssistWithoutOfferingLocation() {
        let goalID = EventID()
        var composer = EventComposer(
            step: .assist(goal: goalID, scorerName: "#9 Carter", side: .us))

        composer.offerShotLocation(
            shot: goalID,
            shooterName: "#9 Carter",
            outcome: .goal,
            side: .us,
            profile: .maxPreps)

        XCTAssertNil(composer.step)
    }

    func testStandardDoesNotAskForOpponentShotLocation() {
        let goalID = EventID()
        var composer = EventComposer(
            step: .assist(goal: goalID, scorerName: "Opponent", side: .opponent))

        composer.offerShotLocation(
            shot: goalID,
            shooterName: "Opponent",
            outcome: .goal,
            side: .opponent,
            profile: .standard)

        XCTAssertNil(composer.step)
    }
}
