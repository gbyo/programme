import ProgrammeCore
import XCTest

@testable import Programme

final class ComposerSheetPresentationTests: XCTestCase {
    func testShotLocationOwnsCompactSheetActions() {
        let step = ComposerStep.shotLocation(
            shot: EventID(), shooterName: "#9 Carter", outcome: .saved)

        XCTAssertTrue(step.ownsSheetActions)
        XCTAssertEqual(step.title, "Shot Location")
    }

    func testAssistOwnsCompactSheetActions() {
        let step = ComposerStep.assist(
            goal: EventID(), scorerName: "#9 Carter", side: .us)

        XCTAssertTrue(step.ownsSheetActions)
        XCTAssertEqual(step.title, "Who assisted?")
    }

    func testChoosePlayerOwnsCompactSheetActions() {
        let step = ComposerStep.choosePlayer(
            PlayerPrompt(action: .goal(phase: .openPlay), side: .us))

        XCTAssertTrue(step.ownsSheetActions)
    }

    func testShotOutcomeOwnsCompactSheetActions() {
        let step = ComposerStep.shotOutcome(
            shooter: .unidentified, side: .us, context: .openPlay)

        XCTAssertTrue(step.ownsSheetActions)
        XCTAssertEqual(step.title, "What happened?")
    }

    func testSubstitutionKeepsItsOwnNavigation() {
        XCTAssertFalse(ComposerStep.substitution.ownsSheetActions)
        XCTAssertTrue(ComposerStep.substitution.providesOwnNavigation)
    }
}
