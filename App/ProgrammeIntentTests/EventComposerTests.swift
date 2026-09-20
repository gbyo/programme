import ProgrammeCore
import XCTest

@testable import Programme

final class EventComposerTests: XCTestCase {

    func testStandardContinuesFromAssistToShotLocation() {
        let goalID = EventID()
        var composer = EventComposer(
            step: .assist(goal: goalID, scorerName: "#9 Carter", side: .us))

        composer.offerShotEnrichment(
            shot: goalID,
            shooterName: "#9 Carter",
            outcome: .goal,
            currentPhase: .openPlay,
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

        composer.offerShotEnrichment(
            shot: goalID,
            shooterName: "#9 Carter",
            outcome: .goal,
            currentPhase: .openPlay,
            side: .us,
            tracking: .ourTeam,
            profile: .maxPreps)

        XCTAssertNil(composer.step)
    }

    func testOurTeamModeDoesNotAskForOpponentShotLocation() {
        let goalID = EventID()
        var composer = EventComposer(
            step: .assist(goal: goalID, scorerName: "Opponent", side: .opponent))

        composer.offerShotEnrichment(
            shot: goalID,
            shooterName: "Opponent",
            outcome: .goal,
            currentPhase: .openPlay,
            side: .opponent,
            tracking: .ourTeam,
            profile: .standard)

        XCTAssertNil(composer.step)
    }

    func testAdvancedContinuesFromLocationToBodyPartToPhase() {
        let shotID = EventID()
        var composer = EventComposer.idle

        composer.offerShotEnrichment(
            shot: shotID,
            shooterName: "#9 Carter",
            outcome: .saved,
            currentPhase: .openPlay,
            side: .us,
            tracking: .ourTeam,
            profile: .advanced)

        XCTAssertEqual(
            composer.step,
            .shotLocation(shot: shotID, shooterName: "#9 Carter", outcome: .saved))

        composer.offerShotEnrichment(
            shot: shotID,
            shooterName: "#9 Carter",
            outcome: .saved,
            currentPhase: .openPlay,
            side: .us,
            tracking: .ourTeam,
            profile: .advanced,
            startingAt: .bodyPart)

        XCTAssertEqual(
            composer.step,
            .shotBodyPart(shot: shotID, shooterName: "#9 Carter", outcome: .saved))

        composer.offerShotEnrichment(
            shot: shotID,
            shooterName: "#9 Carter",
            outcome: .saved,
            currentPhase: .freeKick,
            side: .us,
            tracking: .ourTeam,
            profile: .advanced,
            startingAt: .playPhase)

        XCTAssertEqual(
            composer.step,
            .shotPhase(
                shot: shotID,
                shooterName: "#9 Carter",
                outcome: .saved,
                currentPhase: .freeKick))
    }

    func testAdvancedOpponentSkipsLocationButStillCollectsShotDetail() {
        let shotID = EventID()
        var composer = EventComposer.idle

        composer.offerShotEnrichment(
            shot: shotID,
            shooterName: "#7 Opponent",
            outcome: .offTarget,
            currentPhase: .openPlay,
            side: .opponent,
            tracking: .ourTeam,
            profile: .advanced)

        XCTAssertEqual(
            composer.step,
            .shotBodyPart(shot: shotID, shooterName: "#7 Opponent", outcome: .offTarget))
    }

    func testAdvancedOffersCardReasonAfterCardIsRecorded() {
        let cardID = EventID()
        var composer = EventComposer.idle

        composer.offerCardReason(
            card: cardID,
            playerName: "#4 Mabry",
            type: .yellow,
            profile: .advanced)

        XCTAssertEqual(
            composer.step,
            .cardReason(card: cardID, playerName: "#4 Mabry", type: .yellow))
    }

    func testStandardDoesNotOfferAdvancedCardReason() {
        let cardID = EventID()
        var composer = EventComposer.idle

        composer.offerCardReason(
            card: cardID,
            playerName: "#4 Mabry",
            type: .yellow,
            profile: .standard)

        XCTAssertNil(composer.step)
    }

    func testBothTeamsModeAsksForOpponentShotLocation() {
        let goalID = EventID()
        var composer = EventComposer(
            step: .assist(goal: goalID, scorerName: "Opponent", side: .opponent))

        composer.offerShotEnrichment(
            shot: goalID,
            shooterName: "Opponent",
            outcome: .goal,
            currentPhase: .openPlay,
            side: .opponent,
            tracking: .bothTeams,
            profile: .standard)

        XCTAssertEqual(
            composer.step,
            .shotLocation(shot: goalID, shooterName: "Opponent", outcome: .goal))
    }
}
