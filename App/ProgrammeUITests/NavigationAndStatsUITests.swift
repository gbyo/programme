import UIKit
import XCTest

/// Top-level navigation, match detail, and exports.
///
/// These complement — they do not replace — the domain tests in ProgrammeCore,
/// which is where correctness of the statistics themselves is established.
/// Queries use accessibility identifiers so a wording change doesn't break a test.
final class NavigationAndStatsUITests: ProgrammeUITestCase {

    func testHomeShowsNextMatchAndRecentResults() {
        let app = launch()
        waitForHome(app)
        // Team identity lives in the workspace switcher, not in body content.
        XCTAssertTrue(app.navigationBars["Home"].exists)
        XCTAssertTrue(element(app, "section.Next Match").exists)
        XCTAssertTrue(element(app, "section.Recent").exists)
        attachScreenshot(named: "Home")
    }

    /// The interrupted seed match surfaces as one Current Match action row,
    /// and tapping anywhere on that row resumes scoring.
    func testCurrentMatchResumesFromTheWholeRow() {
        let app = launch(["-programme-open-live"])
        closeLiveScorerAndWaitForHome(app)

        XCTAssertTrue(element(app, "section.Current Match").exists)
        let row = element(app, "home.currentMatch")
        XCTAssertTrue(row.exists)
        XCTAssertTrue(
            row.label.contains("in progress"),
            "The Current Match row does not carry its state: \(row.label)")
        row.tap()

        waitForScorer(app)
    }

    /// The interrupted match reports its review items inside Current Match,
    /// so it must not appear a second time under Needs Review.
    func testCurrentMatchIsNotDuplicatedInNeedsReview() {
        let app = launch(["-programme-open-live"])
        closeLiveScorerAndWaitForHome(app)

        XCTAssertTrue(element(app, "section.Current Match").exists)
        XCTAssertTrue(
            element(app, "home.currentMatch").label.contains("need review"),
            "The seeded live match was expected to carry review items")
        XCTAssertFalse(
            element(app, "section.Needs Review").exists,
            "The current match is duplicated under Needs Review")
    }

    /// Playing out both halves leaves the match awaiting finalization, and
    /// Home must offer Finish — not Resume Scoring — for that state.
    func testAwaitingFinalizationOffersFinish() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "live.endPeriod").tap()
        XCTAssertTrue(app.staticTexts["Halftime"].waitForExistence(timeout: 10))
        app.buttons["Start Second Half"].tap()

        XCTAssertTrue(element(app, "live.endPeriod").waitForExistence(timeout: 10))
        element(app, "live.endPeriod").tap()
        XCTAssertTrue(app.navigationBars["Full Time"].waitForExistence(timeout: 10))
        app.buttons["Finalize Match"].tap()

        XCTAssertTrue(app.navigationBars["Finalize Match"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            element(app, "finalize.action").exists,
            "Finalize should be a native toolbar confirmation action")
        app.buttons["Not Yet"].tap()

        // Awaiting finalization is not a live phase, so closing needs no
        // confirmation and Home takes over again.
        element(app, "live.closeScorer").tap()
        waitForHome(app)

        XCTAssertTrue(element(app, "section.Current Match").exists)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ready to finalize'"))
                .firstMatch.waitForExistence(timeout: 10),
            "The awaiting-finalization match does not read as ready to finalize")
        XCTAssertTrue(app.staticTexts["Finish"].exists)
        XCTAssertFalse(app.buttons["Resume Scoring"].exists)
        XCTAssertFalse(element(app, "section.Needs Review").exists)
        attachScreenshot(named: "Home awaiting finalization")
    }

    /// Halftime keeps one obvious primary next action and offers review as
    /// a secondary toolbar action — never two competing giant CTAs, and the
    /// primary is never duplicated between a bar and the toolbar.
    func testHalftimeOffersSinglePrimaryActionWithReviewAvailable() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "live.endPeriod").tap()
        XCTAssertTrue(app.navigationBars["Halftime"].waitForExistence(timeout: 10))

        // The seeded live match carries review items, so Review Issues must
        // be reachable without a second prominent bottom button.
        XCTAssertTrue(
            app.buttons["Review Issues"].waitForExistence(timeout: 10),
            "Review Issues is missing from the halftime review path")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label == 'Start Second Half'")).count == 1,
            "The primary next-period action is duplicated or missing")
        attachScreenshot(named: "Halftime single primary action")
    }

    /// Manage Teams pushed from Settings is a normal pushed destination:
    /// the system back button is the way out, with no Settings-again
    /// action leading back where the user just came from.
    func testManageTeamsPushedFromSettingsHasNoSettingsAgain() {
        let app = launch()
        waitForHome(app)

        openSettings(app)
        app.staticTexts["Manage Teams…"].tap()
        XCTAssertTrue(app.navigationBars["Manage Teams"].waitForExistence(timeout: 5))

        XCTAssertFalse(
            element(app, "manageTeams.settings").exists,
            "Manage Teams pushed from Settings offers a redundant Settings action")
        attachScreenshot(named: "Manage Teams pushed")
    }

    /// Both action rows are single native rows: no nested prominent
    /// Resume Scoring / Prepare Match buttons anywhere, portrait included.
    func testHomeHasNoNestedProminentActionButtons() {
        let app = launch(["-programme-open-live"], landscape: false)
        XCUIDevice.shared.orientation = .portrait
        closeLiveScorerAndWaitForHome(app)

        XCTAssertTrue(element(app, "home.currentMatch").exists)
        XCTAssertTrue(element(app, "home.nextMatch").exists)
        XCTAssertFalse(app.buttons["Resume Scoring"].exists)
        XCTAssertFalse(app.buttons["Prepare Match"].exists)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'events recorded'"))
                .firstMatch.exists,
            "Recovery reassurance leaked into everyday Home content")
    }

    /// The sidebar bottom bar is workspace context, not a fifth destination:
    /// opening it offers the team menu, and picking another team switches
    /// the workspace Home shows.
    func testSidebarTeamMenuSwitchesWorkspace() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The sidebar bottom bar only exists in a regular-width sidebar.")
        let app = launch()
        waitForHome(app)
        createTeam(app, name: "JV Test Team", shortName: "JV Test")

        let switcher = element(app, "sidebar.teamSwitcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        XCTAssertTrue(
            switcher.label.contains("JV Test Team"),
            "The sidebar switcher does not name the current team: \(switcher.label)")
        // One switcher per presentation: with the sidebar visible, the
        // collapsed-top-bar icon stays out of the hierarchy.
        XCTAssertFalse(
            element(app, "topbar.teamSwitcher").exists,
            "The top-bar switcher is shown alongside the sidebar switcher")
        switcher.tap()
        tapTeamMenuEntry(app, "Ninety Six Boys Soccer")
        XCTAssertTrue(
            element(app, "match.Emerald").waitForExistence(timeout: 10),
            "Switching teams from the sidebar menu did not change the workspace")

        // Reopening the switcher offers the team list again instead of
        // navigating anywhere: it is a menu, not a destination.
        element(app, "sidebar.teamSwitcher").tap()
        XCTAssertTrue(
            app.menuItems["Manage Teams…"].waitForExistence(timeout: 5)
                || app.buttons["Manage Teams…"].firstMatch.waitForExistence(timeout: 5),
            "The sidebar switcher did not open the team menu")
        attachScreenshot(named: "Sidebar team menu")
    }

    /// A long team name stays on one truncated line: the four destinations
    /// remain reachable instead of being pushed out by a giant switcher.
    func testLongTeamNameKeepsFourDestinations() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The sidebar bottom bar only exists in a regular-width sidebar.")
        let app = launch()
        waitForHome(app)
        createTeam(
            app,
            name: "Springfield Heights Junior Varsity Exhibition Squad",
            shortName: "Springfield")

        let switcher = element(app, "sidebar.teamSwitcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        XCTAssertTrue(
            switcher.label.contains("Springfield Heights"),
            "The sidebar switcher lost the long team name: \(switcher.label)")
        for section in ["Home", "Matches", "Roster", "Stats"] {
            openSection(app, section)
        }
        XCTAssertTrue(element(app, "home.content").waitForExistence(timeout: 10))
        attachScreenshot(named: "Sidebar long team name")
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
        XCTAssertTrue(element(app, "home.content").waitForExistence(timeout: 10))

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

    func testMatchDetailWithoutLocationOffersNoMapsAction() {
        let app = launch()
        waitForHome(app)

        // The fixture match has no location, so Match Detail must not offer
        // an Open in Maps action for it. Home shows only the three most
        // recent results, so reach the older Dixie fixture via Matches.
        openSection(app, "Matches")
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 10))
        element(app, "match.Dixie").tap()
        XCTAssertTrue(element(app, "section.Box Score").waitForExistence(timeout: 15))
        XCTAssertFalse(
            element(app, "matchDetail.openInMaps").exists,
            "Open in Maps must not appear for a match with no location")
    }

    func testScheduledMatchOffersCalendarAndReminderActions() {
        let app = launch()
        waitForHome(app)

        // The Clinton fixture kicks off in the future, so its detail offers
        // the scheduled-match system actions. Neither is tapped: that would
        // present system permission UI.
        openSection(app, "Matches")
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 10))
        element(app, "match.Clinton").tap()
        XCTAssertTrue(
            element(app, "matchDetail.addToCalendar").waitForExistence(timeout: 15),
            "Add to Calendar is missing from scheduled Match Detail")
        XCTAssertTrue(
            element(app, "matchDetail.remindMe").exists,
            "Remind Me is missing from scheduled Match Detail")
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
