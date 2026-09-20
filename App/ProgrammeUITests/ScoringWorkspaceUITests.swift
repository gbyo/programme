import XCTest

/// Workspace layout, toolbar, and orientation behavior for the live scorer.
///
/// These complement — they do not replace — the domain tests in ProgrammeCore,
/// which is where correctness of the statistics themselves is established.
/// Queries use accessibility identifiers so a wording change doesn't break a test.
final class ScoringWorkspaceUITests: ProgrammeUITestCase {

    func testScoringWorkspaceShowsScoreClockLineupAndPalette() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // Everything a scorer needs is on one screen.
        XCTAssertTrue(element(app, "live.clock").exists)
        XCTAssertTrue(element(app, "player.9").exists, "The active lineup is not visible")
        XCTAssertTrue(element(app, "palette.goal").exists, "The action palette is not visible")
        XCTAssertTrue(element(app, "scoring.undo").exists)

        XCTAssertTrue(element(app, "live.score").label.contains("Ninety Six"))
        attachScreenshot(named: "Live scoring workspace")
    }

    func testLiveToolbarKeepsPrimaryControlsSeparateAndTogglesTheClock() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        XCTAssertTrue(element(app, "live.closeScorer").exists)
        XCTAssertTrue(element(app, "live.toggleClock").exists)
        XCTAssertTrue(element(app, "live.endPeriod").exists)
        XCTAssertTrue(element(app, "live.options").exists)

        let clockControl = element(app, "live.toggleClock")
        let originalLabel = clockControl.label
        clockControl.tap()
        XCTAssertNotEqual(
            clockControl.label, originalLabel,
            "The toolbar control did not reflect the clock's new running state")
        clockControl.tap()
    }

    func testClosingALiveScorerRequiresNondestructiveConfirmation() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "live.closeScorer").tap()
        XCTAssertTrue(app.staticTexts["Leave this match running?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close Scorer"].exists)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(element(app, "live.score").waitForExistence(timeout: 5))
    }

    func testConstrainedLandscapeKeepsLineupAndRecordUntilAnEventNeedsCompleting() {
        // An iPad mini in landscape is too narrow for three permanent columns, so
        // the lineup and Record share the screen and the composer borrows the
        // lineup's side only while it has a question.
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        let lineupRow = element(app, "player.9")
        XCTAssertTrue(lineupRow.exists, "The lineup is not visible while idle")
        XCTAssertTrue(element(app, "palette.goal").exists, "Record is not visible while idle")
        attachScreenshot(named: "Constrained landscape, idle")

        element(app, "palette.corner").tap()
        XCTAssertTrue(app.staticTexts["Who took the corner?"].waitForExistence(timeout: 5))

        // Record never moves. Only the lineup's side is borrowed.
        XCTAssertTrue(
            element(app, "palette.goal").exists, "Record moved when the composer opened")
        attachScreenshot(named: "Constrained landscape, composing")

        element(app, "pick.7").tap()

        // And the lineup comes straight back.
        XCTAssertTrue(
            element(app, "player.9").waitForExistence(timeout: 5),
            "The lineup did not return after the event was completed")
    }

    func testOpponentQuickActionsStayVisibleWithoutScrollingThePalette() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // An opponent shot is how our goalkeeper's shots-faced is recorded, so it
        // must never sit below the fold of the our-team palette.
        let opponentShot = element(app, "palette.opponent.shot")
        XCTAssertTrue(opponentShot.exists, "The opponent quick actions are not pinned")
        XCTAssertTrue(opponentShot.isHittable, "The opponent quick actions require scrolling")
        XCTAssertTrue(element(app, "palette.opponent.goal").isHittable)

        opponentShot.tap()
        XCTAssertTrue(lastEventLabel(app).contains("Shot"))
    }

    func testRedoKeepsItsPlaceInTheToolbarAfterAnUndo() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // Redo exists before there is anything to redo, so pressing Undo never
        // moves the controls beside it.
        let redo = element(app, "scoring.redo")
        XCTAssertTrue(redo.exists, "Redo is missing when it is unavailable")
        XCTAssertFalse(redo.isEnabled)
        let restingFrame = redo.frame

        element(app, "palette.corner").tap()
        element(app, "pick.7").tap()
        XCTAssertTrue(lastEventLabel(app).contains("Corner"))

        element(app, "scoring.undo").tap()

        let enabled = expectation(
            for: NSPredicate(format: "isEnabled == true"), evaluatedWith: redo)
        wait(for: [enabled], timeout: 5)
        XCTAssertEqual(
            redo.frame, restingFrame, "Undo moved the toolbar controls out from under the scorer")
    }

    func testNoTipInterruptsTheScorerWhileTheClockIsRunning() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // The sample live match opens with the clock running.
        element(app, "palette.shot").tap()
        XCTAssertTrue(element(app, "pick.wide.Player Unknown").waitForExistence(timeout: 5))

        XCTAssertFalse(
            app.staticTexts["Don't know the number?"].exists,
            "A tip appeared in the scoring workspace while the clock was running")
    }

    func testScoringWorkspaceAdaptsToPortrait() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        XCUIDevice.shared.orientation = .portrait

        XCTAssertTrue(element(app, "live.score").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "palette.goal").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "scoring.substitution").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "scoring.undo").exists)
    }

}
