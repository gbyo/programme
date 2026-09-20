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

        // A penalty is taken with everyone behind the ball, so there is nobody
        // to block it and Programme does not offer it.
        XCTAssertFalse(
            element(app, "outcome.blocked").exists,
            "Blocked was offered as the outcome of a penalty kick")

        let saved = element(app, "outcome.saved")
        XCTAssertTrue(saved.exists, "A saved penalty was not offered")
        saved.tap()

        let summary = lastEventLabel(app)
        XCTAssertFalse(
            summary.contains("GOAL"), "A saved penalty was recorded as a goal: \(summary)")
        XCTAssertTrue(element(app, "live.score").label.contains("Ninety Six, 1"), "The score changed")
    }

    /// Shot is one action that asks what happened, in either interaction order.
    func testAShotAsksWhatHappenedAfterThePlayer() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.shot").tap()

        XCTAssertTrue(app.staticTexts["Who took the shot?"].waitForExistence(timeout: 5))
        element(app, "pick.9").tap()

        XCTAssertTrue(app.staticTexts["What happened?"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Shot outcome")
        element(app, "outcome.saved").tap()

        XCTAssertTrue(lastEventLabel(app).contains("Shot on Goal"))
        XCTAssertTrue(
            element(app, "live.score").label.contains("Ninety Six, 1"),
            "A saved shot changed the score")
    }

    func testAShotFromAnArmedPlayerGoesStraightToTheOutcome() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        tapToArm(app, "player.9")
        element(app, "palette.shot").tap()

        // The shooter is already known, so the only missing fact is asked for.
        XCTAssertTrue(app.staticTexts["What happened?"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts["Who took the shot?"].exists,
            "An armed player was asked for again")
        element(app, "outcome.blocked").tap()

        XCTAssertTrue(lastEventLabel(app).contains("Blocked"))
    }

    func testAShotCanBeRecordedOffTarget() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.shot").tap()
        element(app, "pick.9").tap()
        XCTAssertTrue(element(app, "outcome.offTarget").waitForExistence(timeout: 5))
        element(app, "outcome.offTarget").tap()

        let summary = lastEventLabel(app)
        XCTAssertTrue(summary.contains("Shot"))
        XCTAssertTrue(summary.contains("Off Target"))
        XCTAssertFalse(summary.contains("Shot on Goal"))
    }

    func testCancellingBeforeTheShotOutcomeRecordsNothing() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)
        let previousEvent = lastEventLabel(app)

        element(app, "palette.shot").tap()
        element(app, "pick.9").tap()
        XCTAssertTrue(element(app, "outcome.cancel").waitForExistence(timeout: 5))
        element(app, "outcome.cancel").tap()

        XCTAssertEqual(lastEventLabel(app), previousEvent)
        XCTAssertFalse(app.staticTexts["What happened?"].exists)
    }

    /// A shot that goes in must not mean cancelling and starting over. Choosing
    /// Goal here is the Goal button's own path: the score moves and the assist
    /// question follows, from one event.
    func testAShotThatGoesInBecomesAGoalWithoutStartingOver() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.shot").tap()
        element(app, "pick.9").tap()
        XCTAssertTrue(app.staticTexts["What happened?"].waitForExistence(timeout: 5))
        element(app, "outcome.goal").tap()

        XCTAssertTrue(
            app.staticTexts["Who assisted?"].waitForExistence(timeout: 5),
            "Shot → Goal skipped the assist workflow the Goal button uses")
        XCTAssertTrue(element(app, "assist.recordedConfirmation").exists)
        XCTAssertTrue(element(app, "live.score").label.contains("Ninety Six, 2"))

        element(app, "assist.unassisted").tap()
        XCTAssertTrue(lastEventLabel(app).contains("GOAL"))
    }

    /// More is for genuinely secondary event types. Shot outcomes are answers to
    /// Shot's own question now, not a second entrance to the shot model.
    func testMoreIsAMenuThatReturnsStraightToAttribution() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.more").tap()
        let offside = app.buttons["Offside"].firstMatch
        XCTAssertTrue(offside.waitForExistence(timeout: 5), "More did not offer an offside")
        XCTAssertFalse(
            app.buttons["Blocked"].exists,
            "More still offers a shot outcome as a way into the shot model")
        offside.tap()

        // Straight into the centre stage, with the match still on screen.
        XCTAssertTrue(app.staticTexts["Who was offside?"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "live.score").exists, "The score was hidden by the More flow")
        element(app, "pick.9").tap()
        XCTAssertTrue(lastEventLabel(app).contains("Offside"))
    }

}
