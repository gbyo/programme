import XCTest

/// Recording events in both directions (player-then-action and action-then-player), arming, deferred attribution, and undo.
///
/// These complement — they do not replace — the domain tests in ProgrammeCore,
/// which is where correctness of the statistics themselves is established.
/// Queries use accessibility identifiers so a wording change doesn't break a test.
final class EventRecordingUITests: ProgrammeUITestCase {

    func testRecordingAGoalByArmingAPlayerThenTappingTheAction() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // Direction one: player, then action.
        tapToArm(app, "player.9")

        // The palette itself has to say who the next action lands on: by the
        // time the scorer's eyes are on Record, the lineup highlight is out of
        // view.
        let armed = element(app, "palette.armedPlayer")
        XCTAssertTrue(armed.waitForExistence(timeout: 5), "The armed player is not shown in Record")
        XCTAssertTrue(
            armed.label.contains("Carter"),
            "The armed player state does not name the player: \(armed.label)")
        attachScreenshot(named: "Player armed")

        element(app, "palette.goal").tap()

        // The goal is already recorded by the time the composer asks about the
        // assist: the score has moved and the event is in the log.
        let unassisted = element(app, "assist.unassisted")
        XCTAssertTrue(unassisted.waitForExistence(timeout: 5), "The assist step did not appear")
        XCTAssertTrue(
            element(app, "assist.recordedConfirmation").exists,
            "The composer did not say the goal was already recorded")
        XCTAssertTrue(element(app, "live.score").exists, "The score was hidden during event entry")
        XCTAssertTrue(
            lastEventLabel(app).contains("GOAL"),
            "The goal was not recorded before the assist was asked for")
        attachScreenshot(named: "Assist attribution")
        unassisted.tap()

        let summary = lastEventLabel(app)
        XCTAssertTrue(summary.contains("GOAL"))
        XCTAssertTrue(summary.contains("Carter"), "The goal was not credited to the armed player")
    }

    func testAGoalIsRecordedBeforeTheAssistIsAnswered() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        let scoreBefore = element(app, "live.score").label

        tapToArm(app, "player.9")
        element(app, "palette.goal").tap()
        XCTAssertTrue(element(app, "assist.unassisted").waitForExistence(timeout: 5))

        // The primary fact landed first: the scoreboard already reads one more.
        XCTAssertNotEqual(
            element(app, "live.score").label, scoreBefore,
            "The score did not move until the assist was answered")
        XCTAssertTrue(lastEventLabel(app).contains("GOAL"))
    }

    func testLeavingTheAssistUnansweredKeepsTheGoalAndFlagsItForReview() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        tapToArm(app, "player.9")
        element(app, "palette.goal").tap()
        XCTAssertTrue(element(app, "assist.unassisted").waitForExistence(timeout: 5))
        let scoreWithGoal = element(app, "live.score").label

        // Walk away from the question the way a scorer watching play would.
        element(app, "assist.notNow").tap()

        XCTAssertFalse(
            element(app, "assist.unassisted").waitForExistence(timeout: 2),
            "The composer stayed open after being dismissed")
        XCTAssertEqual(
            element(app, "live.score").label, scoreWithGoal, "The goal was lost on dismissal")
        XCTAssertTrue(lastEventLabel(app).contains("GOAL"), "The goal was not kept")
        XCTAssertTrue(
            element(app, "scoring.review").label.contains("need attention"),
            "The unanswered assist was not collected for Review")
    }

    func testClearingTheArmedPlayerIsOneTap() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        tapToArm(app, "player.9")
        XCTAssertTrue(element(app, "palette.armedPlayer").waitForExistence(timeout: 5))

        element(app, "palette.clearArmedPlayer").tap()
        XCTAssertFalse(
            element(app, "palette.armedPlayer").waitForExistence(timeout: 2),
            "Clearing the armed player did not take effect")
    }

    func testABenchPlayerCannotBeArmedForOrdinaryLivePlay() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        tapToArm(app, "player.9")
        XCTAssertTrue(element(app, "palette.armedPlayer").waitForExistence(timeout: 5))

        // #8 came off in the sample match, so he is on the bench and cannot be
        // credited with a shot. Tapping him must not arm him — and must not
        // silently leave the previous player armed either.
        let benchRow = revealInLineup(app, "player.8")
        XCTAssertTrue(benchRow.exists, "The bench row was not reachable")
        benchRow.tap()

        XCTAssertFalse(
            element(app, "palette.armedPlayer").waitForExistence(timeout: 2),
            "A player on the bench was armed for an ordinary live-play action")
    }

    func testRecordingAnEventByTappingTheActionThenThePlayer() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // Direction two: action, then player. Both orders have to work.
        element(app, "palette.corner").tap()
        let pick = element(app, "pick.7")
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "The player picker did not appear")
        pick.tap()

        XCTAssertTrue(lastEventLabel(app).contains("Corner"))
    }

    func testOpponentSaveIsASingleTap() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.save").tap()

        // No player picker: the goalkeeper is already known.
        XCTAssertTrue(lastEventLabel(app).contains("Shot on Goal"))
    }

    func testUnknownPlayerIsOfferedAndDefersAttribution() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.sog").tap()
        let unknown = element(app, "pick.wide.Player Unknown")
        XCTAssertTrue(unknown.waitForExistence(timeout: 5), "Player Unknown was not offered")
        unknown.tap()

        XCTAssertTrue(lastEventLabel(app).contains("needs player attribution"))
        XCTAssertTrue(element(app, "scoring.review").label.contains("need attention"))
    }

    func testUndoIsImmediateAndNeedsNoConfirmation() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.corner").tap()
        element(app, "pick.7").tap()
        XCTAssertTrue(lastEventLabel(app).contains("Corner"))

        element(app, "scoring.undo").tap()

        XCTAssertFalse(app.alerts.firstMatch.exists, "Undo asked for confirmation")
        let expectation = expectation(
            for: NSPredicate(format: "NOT (label CONTAINS 'Corner')"),
            evaluatedWith: element(app, "scoring.lastEvent"))
        wait(for: [expectation], timeout: 5)
    }

}
