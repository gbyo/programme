import UIKit
import XCTest

/// The compact scorer: one pane at a time, and the Event Composer as a single
/// sheet over the top of it.
///
/// These skip on iPad, where the composer lives in a column instead and is
/// covered by `ProgrammeUITests`. Run them against an iPhone destination:
///
///     xcodebuild test -scheme Programme \
///         -destination 'platform=iOS Simulator,name=Programme iPhone 17' \
///         -only-testing:ProgrammeUITests/CompactScorerUITests
final class CompactScorerUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchCompactScorer() throws -> XCUIApplication {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "The compact composer only applies in a compact environment.")
        let app = XCUIApplication()
        app.launchArguments = ["-programme-uitest", "-programme-open-live"]
        app.launch()
        XCTAssertTrue(
            element(app, "live.score").waitForExistence(timeout: 20),
            "The scoring workspace did not appear")
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// On a phone the bottom bar cannot show everything, so the system moves its
    /// lowest-priority items into an overflow menu. That is the right outcome —
    /// the last-event strip is status and Match Stats is secondary — but it means
    /// a test has to look inside the menu rather than assume a visible button.
    private func tapPossiblyOverflowed(
        _ app: XCUIApplication, identifier: String, label: String
    ) {
        let direct = element(app, identifier)
        if direct.exists && direct.isHittable {
            direct.tap()
            return
        }
        let overflow = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS 'Overflow'")).firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 5), "No overflow menu to look in")
        overflow.tap()
        // The system rebuilds overflowed items as menu entries, which keep their
        // label but not the identifier the bar button carried.
        let inMenu = app.buttons[label].firstMatch
        XCTAssertTrue(inMenu.waitForExistence(timeout: 5), "\(label) is not reachable at all")
        inMenu.tap()
    }

    /// The scoreboard is always visible, so it is the reliable evidence in a
    /// compact window that a goal actually landed.
    private func scoreLabel(_ app: XCUIApplication) -> String {
        element(app, "live.score").label
    }

    // MARK: - One pane at a time

    func testCompactShowsRecordAndLineupAsTwoPanes() throws {
        let app = try launchCompactScorer()

        XCTAssertTrue(element(app, "live.compactPane").exists, "The pane control is missing")
        XCTAssertTrue(element(app, "palette.goal").exists, "Record is not the opening pane")
        attachScreenshot(named: "Compact scorer")
    }

    func testChoosingAPlayerReturnsToRecordSoTheNextTapIsTheAction() throws {
        let app = try launchCompactScorer()

        app.buttons["Lineup"].firstMatch.tap()
        let row = element(app, "player.9")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The lineup pane did not appear")
        row.tap()

        // Having said who, the scorer's next tap is always an action — so Record
        // comes forward without being asked for.
        XCTAssertTrue(
            element(app, "palette.goal").waitForExistence(timeout: 5),
            "Record did not come forward after a player was chosen")
        XCTAssertTrue(
            element(app, "palette.armedPlayer").exists, "The armed player was not carried over")
        attachScreenshot(named: "Compact player armed")
    }

    // MARK: - One sheet, several questions

    func testTheComposerIsOneSheetThatMovesBetweenQuestions() throws {
        let app = try launchCompactScorer()

        // Action first: Record asks who.
        element(app, "palette.goal").tap()

        let sheet = element(app, "composer.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The composer sheet did not appear")
        XCTAssertTrue(app.staticTexts["Who scored?"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Composer sheet, who scored")

        element(app, "pick.9").tap()

        // The same sheet moves on to the next question rather than stacking a
        // second one on top.
        XCTAssertTrue(
            element(app, "assist.unassisted").waitForExistence(timeout: 5),
            "The composer did not move on to the assist")
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "composer.sheet").count, 1,
            "A second sheet was presented for the next question")
        attachScreenshot(named: "Composer sheet, who assisted")

        let scoreWithGoal = scoreLabel(app)
        element(app, "assist.unassisted").tap()

        XCTAssertFalse(
            sheet.waitForExistence(timeout: 2), "The composer sheet did not dismiss when finished")
        XCTAssertEqual(scoreLabel(app), scoreWithGoal, "Answering the assist changed the score")
    }

    func testDismissingTheComposerLeavesTheGoalRecorded() throws {
        let app = try launchCompactScorer()

        let scoreBefore = scoreLabel(app)

        element(app, "palette.goal").tap()
        XCTAssertTrue(element(app, "composer.sheet").waitForExistence(timeout: 5))
        element(app, "pick.9").tap()
        XCTAssertTrue(element(app, "assist.unassisted").waitForExistence(timeout: 5))

        // The score has already moved: the goal is recorded, the assist is not.
        let scoreWithGoal = scoreLabel(app)
        XCTAssertNotEqual(
            scoreWithGoal, scoreBefore,
            "The goal was not recorded before the assist was asked for")

        // Dismiss the sheet without answering, the way a scorer looking back at
        // the pitch would.
        element(app, "composer.done").tap()

        XCTAssertFalse(
            element(app, "composer.sheet").waitForExistence(timeout: 2),
            "The composer sheet stayed open")
        XCTAssertEqual(scoreLabel(app), scoreWithGoal, "The goal was lost on dismissal")
        XCTAssertTrue(
            element(app, "scoring.review").label.contains("need attention"),
            "The unanswered assist was not collected for Review")
    }

    func testSubstitutionUsesTheSameSheetInCompact() throws {
        let app = try launchCompactScorer()

        element(app, "scoring.substitution").tap()

        XCTAssertTrue(
            element(app, "composer.sheet").waitForExistence(timeout: 5),
            "Substitution did not use the composer sheet")
        XCTAssertTrue(element(app, "sub.out.11").waitForExistence(timeout: 5))
        attachScreenshot(named: "Compact substitution")
    }

    func testStatisticsStayInTheInspectorRatherThanTheWorkspace() throws {
        let app = try launchCompactScorer()

        // No mini dashboard in the scorer: the numbers are one tap away, in the
        // inspector, which the system presents as a sheet here.
        tapPossiblyOverflowed(app, identifier: "live.matchStats", label: "Match Stats")
        let close = element(app, "stats.close")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Match stats did not open")
        attachScreenshot(named: "Compact stats inspector")
        close.tap()
        XCTAssertTrue(element(app, "palette.goal").waitForExistence(timeout: 5))
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
