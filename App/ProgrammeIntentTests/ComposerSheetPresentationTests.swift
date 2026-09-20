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

    func testOtherSingleQuestionStepsKeepGenericDismissAction() {
        let step = ComposerStep.assist(
            goal: EventID(), scorerName: "#9 Carter", side: .us)

        XCTAssertFalse(step.ownsSheetActions)
        XCTAssertEqual(step.title, "Who assisted?")
    }
}
