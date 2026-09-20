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
            tracking: .ourTeam,
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
            tracking: .ourTeam,
            profile: .maxPreps)

        XCTAssertNil(composer.step)
    }

    func testOurTeamModeDoesNotAskForOpponentShotLocation() {
        let goalID = EventID()
        var composer = EventComposer(
            step: .assist(goal: goalID, scorerName: "Opponent", side: .opponent))

        composer.offerShotLocation(
            shot: goalID,
            shooterName: "Opponent",
            outcome: .goal,
            side: .opponent,
            tracking: .ourTeam,
            profile: .standard)

        XCTAssertNil(composer.step)
    }

    func testBothTeamsModeAsksForOpponentShotLocation() {
        let goalID = EventID()
        var composer = EventComposer(
            step: .assist(goal: goalID, scorerName: "Opponent", side: .opponent))

        composer.offerShotLocation(
            shot: goalID,
            shooterName: "Opponent",
            outcome: .goal,
            side: .opponent,
            tracking: .bothTeams,
            profile: .standard)

        XCTAssertEqual(
            composer.step,
            .shotLocation(shot: goalID, shooterName: "Opponent", outcome: .goal))
    }
}
