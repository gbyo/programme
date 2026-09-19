import XCTest

/// Mid-match lifecycle from the live scorer: inspectors, review, event log, period end, lineup edits, and clock adjustment.
///
/// These complement — they do not replace — the domain tests in ProgrammeCore,
/// which is where correctness of the statistics themselves is established.
/// Queries use accessibility identifiers so a wording change doesn't break a test.
final class MatchLifecycleUITests: ProgrammeUITestCase {

    func testMatchStatsCanBeClosed() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "live.matchStats").tap()
        let close = element(app, "stats.close")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        XCTAssertTrue(element(app, "palette.goal").waitForExistence(timeout: 5))
        XCTAssertFalse(close.exists)
    }

    func testReviewCollectsDeferredAttribution() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // The sample match already contains a shot recorded without a number.
        let review = element(app, "scoring.review")
        XCTAssertTrue(review.label.contains("need attention"))
        review.tap()

        XCTAssertTrue(app.navigationBars["Review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Needs Attribution"].exists)
        attachScreenshot(named: "Needs review")
    }

    func testEventLogOpensAnEventForEditing() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "scoring.eventLog").tap()
        XCTAssertTrue(app.navigationBars["Event Log"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Event log")

        let goalRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'GOAL'")
        ).firstMatch
        XCTAssertTrue(goalRow.waitForExistence(timeout: 5))
        goalRow.tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Edit event")
    }

    func testEndingAPeriodShowsTheHalftimeCheck() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "live.endPeriod").tap()

        XCTAssertTrue(app.staticTexts["Halftime"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'players active'"))
                .firstMatch.exists,
            "The halftime check did not report the active lineup")
        attachScreenshot(named: "Halftime check")
    }

    func testEditingAnExistingLineupLoadsItsStartersAndGoalkeeper() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "live.options").tap()
        XCTAssertFalse(app.navigationBars["Match"].exists, "The obsolete Match sheet was presented")
        app.buttons["Edit Lineup"].tap()

        XCTAssertTrue(app.navigationBars["Starting Lineup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["11 of 11 selected"].exists)
        XCTAssertTrue(element(app, "lineup.goalkeeper").exists)
        XCTAssertTrue(element(app, "lineup.confirm").isEnabled)
    }

    func testMatchMenuRoutesDirectlyToClockAdjustment() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "live.options").tap()
        XCTAssertTrue(app.buttons["Adjust Clock"].waitForExistence(timeout: 5))
        app.buttons["Adjust Clock"].tap()

        XCTAssertTrue(app.navigationBars["Adjust Clock"].waitForExistence(timeout: 5))
    }

}
