import XCTest

/// Top-level navigation, match detail, and exports.
///
/// These complement — they do not replace — the domain tests in ProgrammeCore,
/// which is where correctness of the statistics themselves is established.
/// Queries use accessibility identifiers so a wording change doesn't break a test.
final class NavigationAndStatsUITests: ProgrammeUITestCase {

    func testHomeShowsNextMatchAndRecentResults() {
        let app = launch()
        let header = waitForHome(app)
        XCTAssertTrue(header.label.contains("Ninety Six Boys Soccer"))
        XCTAssertTrue(element(app, "section.Next Match").exists)
        XCTAssertTrue(element(app, "section.Recent").exists)
        attachScreenshot(named: "Home")
    }

    func testTopLevelDestinationsAreHomeMatchesRosterStats() {
        let app = launch()
        waitForHome(app)

        openSection(app, "Matches")
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 10))
        openSection(app, "Roster")
        XCTAssertTrue(app.navigationBars["Roster"].waitForExistence(timeout: 10))
        openSection(app, "Stats")
        XCTAssertTrue(app.navigationBars["Season Stats"].waitForExistence(timeout: 10))
        openSection(app, "Home")
        XCTAssertTrue(element(app, "home.header").waitForExistence(timeout: 10))

        // Exports is a utility under Settings, not a top-level destination.
        XCTAssertFalse(app.tabBars.buttons["Exports"].exists)
        XCTAssertFalse(app.buttons["Exports"].exists)
        XCTAssertFalse(app.navigationBars["Exports"].exists)
        attachScreenshot(named: "Top-level destinations")
    }

    func testStatsExportProducesFiles() {
        let app = launch()
        waitForHome(app)

        openSection(app, "Stats")
        XCTAssertTrue(app.navigationBars["Season Stats"].waitForExistence(timeout: 10))

        app.buttons["Export"].tap()
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 5))

        // The sheet pre-selects the first format ("Season Totals (CSV)"), and
        // tapping a selected row would toggle it off and disable Prepare, so
        // assert the default selection is active instead of tapping the row.
        XCTAssertTrue(
            app.buttons["Prepare"].isEnabled, "No export format is selected by default")
        app.buttons["Prepare"].tap()

        XCTAssertTrue(
            app.staticTexts["Ready to Share"].waitForExistence(timeout: 20),
            "The season export did not produce a file")
        attachScreenshot(named: "Stats export")
    }

    func testMatchDetailDistinguishesNotTrackedFromZero() {
        let app = launch()
        waitForHome(app)

        // Emerald is the most recent finalized seed, so it is always inside
        // Home's Recent window (Dixie is older than the three matches shown).
        element(app, "match.Emerald").tap()
        XCTAssertTrue(element(app, "section.Box Score").waitForExistence(timeout: 15))
        // The detail list is long; lower rows only materialize once scrolled
        // into view, so reveal everything this test reads in document order.
        revealByScrolling(app, "section.Stat Completeness")
        revealByScrolling(app, "completeness.offsides")

        // The MaxPreps profile does not track offsides, so it has to read as
        // unknown rather than as a zero.
        let offsides = element(app, "completeness.offsides")
        XCTAssertTrue(offsides.exists)
        XCTAssertTrue(
            offsides.label.contains("Not tracked"),
            "An untracked category was not reported as unknown: \(offsides.label)")

        // A category that was tracked and genuinely happened zero times is a zero.
        revealByScrolling(app, "completeness.steals")
        let steals = element(app, "completeness.steals")
        XCTAssertTrue(steals.label.contains("Complete"))
        attachScreenshot(named: "Match detail")
    }

    func testExportProducesShareableFiles() {
        let app = launch()
        waitForHome(app)

        // Emerald is the most recent finalized seed, so it is always inside
        // Home's Recent window (Dixie is older than the three matches shown).
        element(app, "match.Emerald").tap()
        XCTAssertTrue(element(app, "section.Box Score").waitForExistence(timeout: 15))

        // Match actions live in the toolbar overflow (native overflow on
        // iOS 27+, a "More" menu below that).
        app.buttons["More"].tap()
        app.buttons["Export…"].tap()
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 5))

        app.staticTexts["Programme Archive"].tap()
        app.buttons["Prepare"].tap()

        XCTAssertTrue(
            app.staticTexts["Ready to Share"].waitForExistence(timeout: 20),
            "The export did not produce a file")
        attachScreenshot(named: "Export")
    }

}
