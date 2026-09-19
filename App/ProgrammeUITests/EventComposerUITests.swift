import XCTest

/// Multi-step event composer flows: the composer borrows the workspace, then hands it back when nothing is outstanding.
///
/// These complement — they do not replace — the domain tests in ProgrammeCore,
/// which is where correctness of the statistics themselves is established.
/// Queries use accessibility identifiers so a wording change doesn't break a test.
final class EventComposerUITests: ProgrammeUITestCase {

    func testTheWorkspaceExistsToCompleteAnEventNotToShowStats() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // Whatever the layout, the middle is never a statistics panel: the
        // numbers have exactly one home, and it is the inspector.
        XCTAssertTrue(
            element(app, "live.matchStats").exists,
            "There is no way into the statistics inspector")

        // Starting an event fills the workspace with the question.
        element(app, "palette.corner").tap()
        XCTAssertTrue(app.staticTexts["Who took the corner?"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Event composer")
        element(app, "pick.7").tap()

        // And it hands the space straight back once nothing is outstanding.
        XCTAssertTrue(lastEventLabel(app).contains("Corner"))
        XCTAssertFalse(
            app.staticTexts["Who took the corner?"].waitForExistence(timeout: 2),
            "The composer stayed on screen with nothing left to ask")
    }

    func testAPenaltyAsksForTheOutcomeAndDoesNotImplyAGoal() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.pk").tap()

        // The taker, not "who scored".
        XCTAssertTrue(app.staticTexts["Who took the penalty?"].waitForExistence(timeout: 5))
        element(app, "pick.9").tap()

        XCTAssertTrue(app.staticTexts["What happened?"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Penalty outcome")

        let saved = element(app, "penalty.saved")
        XCTAssertTrue(saved.exists, "A saved penalty was not offered")
        saved.tap()

        let summary = lastEventLabel(app)
        XCTAssertFalse(
            summary.contains("GOAL"), "A saved penalty was recorded as a goal: \(summary)")
        XCTAssertTrue(element(app, "live.score").label.contains("Ninety Six, 1"), "The score changed")
    }

    func testMoreIsAMenuThatReturnsStraightToAttribution() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.more").tap()
        let blocked = app.buttons["Blocked"].firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 5), "More did not offer a blocked shot")
        blocked.tap()

        // Straight into the centre stage, with the match still on screen.
        XCTAssertTrue(app.staticTexts["Who took the shot?"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "live.score").exists, "The score was hidden by the More flow")
        element(app, "pick.9").tap()
        XCTAssertTrue(lastEventLabel(app).contains("Blocked"))
    }

}
