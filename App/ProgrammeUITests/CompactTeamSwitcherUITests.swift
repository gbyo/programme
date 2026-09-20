import UIKit
import XCTest

/// The compact team switcher: with bottom tabs there is no sidebar and no
/// separate toolbar team control. The section title owns the navigation bar,
/// the team rides alongside it as the navigation subtitle, and tapping the
/// title opens the same team menu every other presentation uses.
///
/// These skip on iPad, where the sidebar bottom bar (or the collapsed top
/// bar) owns team switching instead. Run them against an iPhone
/// destination, for example with the `compact-team` test-ui.sh scope:
///
///     PROGRAMME_UI_TEST_SCOPE=compact-team bash scripts/test-ui.sh
final class CompactTeamSwitcherUITests: ProgrammeUITestCase {

    private func launchCompactHome() throws -> XCUIApplication {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "The title-menu switcher only applies without a sidebar.")
        let app = launch(landscape: false)
        XCUIDevice.shared.orientation = .portrait
        waitForHome(app)
        return app
    }

    /// Opens the title menu from whichever title SwiftUI is showing: the
    /// inline-bar title after scrolling, or the large title above content.
    /// The menu-entry lookup that follows proves the menu actually opened,
    /// so no production control is added just to expose the title for
    /// testing.
    private func openTitleMenu(_ app: XCUIApplication, title: String) {
        let inlineButton = app.navigationBars[title].buttons[title].firstMatch
        if inlineButton.waitForExistence(timeout: 3) {
            inlineButton.tap()
            return
        }
        let inlineText = app.navigationBars[title].staticTexts[title].firstMatch
        if inlineText.waitForExistence(timeout: 3) {
            inlineText.tap()
            return
        }
        let largeTitle = app.staticTexts[title].firstMatch
        XCTAssertTrue(
            largeTitle.waitForExistence(timeout: 5),
            "No tappable navigation title for \(title)")
        largeTitle.tap()
    }

    /// The page title stays visible with the team as its subtitle, no
    /// separate team control crowds the bar, the four destinations remain
    /// bottom tabs, and the title menu switches the workspace.
    func testCompactTitleMenuSwitchesWorkspace() throws {
        let app = try launchCompactHome()
        createTeam(app, name: "JV Test Team", shortName: "JV Test")

        XCTAssertTrue(
            app.navigationBars["Home"].waitForExistence(timeout: 10),
            "The Home navigation bar is missing")
        XCTAssertTrue(
            app.staticTexts["JV Test Team"].waitForExistence(timeout: 10),
            "The navigation subtitle does not name the current team")
        // No presentation-specific switcher control in a bottom-tab layout.
        XCTAssertFalse(
            element(app, "sidebar.teamSwitcher").exists,
            "The sidebar switcher appears where no sidebar is shown")
        XCTAssertFalse(
            element(app, "topbar.teamSwitcher").exists,
            "The top-bar switcher appears in a bottom-tab layout")
        for section in ["Home", "Matches", "Roster", "Stats"] {
            XCTAssertTrue(
                app.tabBars.buttons[section].exists,
                "\(section) is not a bottom tab")
        }

        openTitleMenu(app, title: "Home")
        tapTeamMenuEntry(app, "Ninety Six Boys Soccer")
        XCTAssertTrue(
            element(app, "match.Emerald").waitForExistence(timeout: 10),
            "Switching teams from the title menu did not change the workspace")
        XCTAssertTrue(
            app.staticTexts["Ninety Six Boys Soccer"].waitForExistence(timeout: 10),
            "The navigation subtitle did not follow the workspace switch")
        attachScreenshot(named: "Compact title menu")
    }

    /// A long team name keeps the compact layout intact: the page title
    /// remains, the subtitle carries the name, and no full-width team
    /// control appears.
    func testCompactLongTeamNameKeepsTitleVisible() throws {
        let app = try launchCompactHome()
        createTeam(
            app,
            name: "Springfield Heights Junior Varsity Exhibition Squad",
            shortName: "Springfield")

        XCTAssertTrue(
            app.navigationBars["Home"].waitForExistence(timeout: 10),
            "The Home navigation bar is missing")
        let subtitle = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Springfield Heights'")
        ).firstMatch
        XCTAssertTrue(
            subtitle.waitForExistence(timeout: 10),
            "The navigation subtitle lost the long team name")
        XCTAssertFalse(element(app, "sidebar.teamSwitcher").exists)
        XCTAssertFalse(element(app, "topbar.teamSwitcher").exists)
        for section in ["Home", "Matches", "Roster", "Stats"] {
            XCTAssertTrue(
                app.tabBars.buttons[section].exists,
                "\(section) is not a bottom tab")
        }
        attachScreenshot(named: "Compact long team name")
    }
}
