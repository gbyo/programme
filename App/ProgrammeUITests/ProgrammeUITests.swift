import XCTest

/// UI coverage for the flows that would hurt most if they broke: getting into a
/// match, recording, correcting, and getting the statistics back out.
///
/// These complement — they do not replace — the domain tests in ProgrammeCore,
/// which is where correctness of the statistics themselves is established.
/// Queries use accessibility identifiers so a wording change doesn't break a test.
final class ProgrammeUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: [String] = [], landscape: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-programme-uitest"] + extraArguments
        app.launch()
        if landscape { XCUIDevice.shared.orientation = .landscapeLeft }
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForScorer(_ app: XCUIApplication) {
        XCTAssertTrue(
            element(app, "live.score").waitForExistence(timeout: 20),
            "The scoring workspace did not appear")
    }

    private func lastEventLabel(_ app: XCUIApplication) -> String {
        let strip = element(app, "scoring.lastEvent")
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        return strip.label
    }

    // MARK: - Live scoring

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

    func testRecordingAGoalByArmingAPlayerThenTappingTheAction() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // Direction one: player, then action.
        element(app, "player.9").tap()
        element(app, "palette.goal").tap()

        // The assist step takes over the centre panel rather than covering the score.
        let unassisted = element(app, "assist.unassisted")
        XCTAssertTrue(unassisted.waitForExistence(timeout: 5), "The assist step did not appear")
        XCTAssertTrue(element(app, "live.score").exists, "The score was hidden during event entry")
        attachScreenshot(named: "Assist attribution")
        unassisted.tap()

        XCTAssertTrue(lastEventLabel(app).contains("GOAL"))
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

    func testSubstitutionModeCommitsSeveralPlayersAtOneTimestamp() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "scoring.substitution").tap()
        XCTAssertTrue(element(app, "sub.out.11").waitForExistence(timeout: 5))

        element(app, "sub.out.11").tap()
        element(app, "sub.out.6").tap()
        element(app, "sub.in.13").tap()
        element(app, "sub.in.14").tap()
        attachScreenshot(named: "Substitution mode")

        let commit = element(app, "sub.commit")
        XCTAssertTrue(commit.isEnabled)
        XCTAssertTrue(commit.label.contains("2"), "Multiple substitutions were not batched")
        commit.tap()

        XCTAssertTrue(lastEventLabel(app).contains("Substitution"))
    }

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

    func testScoringWorkspaceAdaptsToPortrait() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        XCUIDevice.shared.orientation = .portrait

        XCTAssertTrue(element(app, "live.score").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "palette.goal").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "scoring.substitution").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "scoring.undo").exists)
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
            NSPredicate(format: "label CONTAINS 'GOAL'")).firstMatch
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

    // MARK: - Browsing, creating and exporting

    func testTodayShowsNextMatchAndRecentResults() {
        let app = launch()
        let header = element(app, "today.header")
        XCTAssertTrue(header.waitForExistence(timeout: 20))
        XCTAssertTrue(header.label.contains("Ninety Six Boys Soccer"))
        XCTAssertTrue(element(app, "section.Next Match").exists)
        XCTAssertTrue(element(app, "section.Recent").exists)
        attachScreenshot(named: "Today")
    }

    func testCreatingAMatch() {
        let app = launch()
        XCTAssertTrue(element(app, "today.header").waitForExistence(timeout: 20))

        app.buttons["New Match"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Match"].waitForExistence(timeout: 5))

        let opponent = app.textFields["Opponent"]
        XCTAssertTrue(opponent.waitForExistence(timeout: 5))
        opponent.tap()
        opponent.typeText("Newberry")
        attachScreenshot(named: "New match")

        app.buttons["Create"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Newberry'")).firstMatch
                .waitForExistence(timeout: 15),
            "The new match did not open after being created")
    }

    func testMatchDetailDistinguishesNotTrackedFromZero() {
        let app = launch()
        XCTAssertTrue(element(app, "today.header").waitForExistence(timeout: 20))

        element(app, "match.Dixie").tap()
        XCTAssertTrue(element(app, "section.Box Score").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "section.Stat Completeness").exists)

        // The MaxPreps profile does not track offsides, so it has to read as
        // unknown rather than as a zero.
        let offsides = element(app, "completeness.offsides")
        XCTAssertTrue(offsides.exists)
        XCTAssertTrue(
            offsides.label.contains("Not tracked"),
            "An untracked category was not reported as unknown: \(offsides.label)")

        // A category that was tracked and genuinely happened zero times is a zero.
        let steals = element(app, "completeness.steals")
        XCTAssertTrue(steals.label.contains("Complete"))
        attachScreenshot(named: "Match detail")
    }

    func testExportProducesShareableFiles() {
        let app = launch()
        XCTAssertTrue(element(app, "today.header").waitForExistence(timeout: 20))

        element(app, "match.Dixie").tap()
        XCTAssertTrue(element(app, "section.Box Score").waitForExistence(timeout: 15))

        app.buttons["Actions"].tap()
        app.buttons["Export…"].tap()
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 5))

        app.staticTexts["Programme Archive"].tap()
        app.buttons["Prepare"].tap()

        XCTAssertTrue(
            app.staticTexts["Ready to Share"].waitForExistence(timeout: 20),
            "The export did not produce a file")
        attachScreenshot(named: "Export")
    }

    // MARK: - Helpers

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
