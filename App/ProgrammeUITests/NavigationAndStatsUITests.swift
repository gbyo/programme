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

    /// With confirmation disabled, Finalize performs the same operation
    /// immediately: no native dialog is inserted, and the match still
    /// finalizes exactly once.
    func testFinalizeWithoutConfirmationSkipsDialog() {
        let app = launch(["-programme-open-live", "-programme-no-finalize-confirm"])
        waitForScorer(app)

        element(app, "live.endPeriod").tap()
        XCTAssertTrue(app.staticTexts["Halftime"].waitForExistence(timeout: 10))
        app.buttons["Start Second Half"].tap()

        XCTAssertTrue(element(app, "live.endPeriod").waitForExistence(timeout: 10))
        element(app, "live.endPeriod").tap()
        XCTAssertTrue(app.navigationBars["Full Time"].waitForExistence(timeout: 10))
        app.buttons["Finalize Match"].tap()

        XCTAssertTrue(app.navigationBars["Finalize Match"].waitForExistence(timeout: 10))
        element(app, "finalize.action").tap()

        // No confirmation dialog is presented on the immediate path.
        XCTAssertFalse(app.staticTexts["Finalize this match?"].exists)
        // Finalization still completes: the sheet closes and Home returns.
        waitForHome(app)
        XCTAssertFalse(app.navigationBars["Finalize Match"].exists)
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

    /// Universal search is a pull-down field on Matches — not a tab — and
    /// finds a match by opponent in both scopes before opening its detail.
    func testUniversalSearchFindsMatchAndOpensDetail() throws {
        let app = launch()
        waitForHome(app)
        openSection(app, "Matches")
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 10))

        searchFor(app, "Emerald")
        XCTAssertTrue(
            element(app, "match.Emerald").waitForExistence(timeout: 10),
            "Universal search did not find the seeded match by opponent")
        app.buttons["All Teams"].tap()
        XCTAssertTrue(
            element(app, "match.Emerald").waitForExistence(timeout: 10),
            "The match disappeared when widening search to all teams")
        element(app, "match.Emerald").tap()
        XCTAssertTrue(
            app.staticTexts["Box Score"].waitForExistence(timeout: 10),
            "Tapping a search result did not open match detail")
        attachScreenshot(named: "Universal search")
    }

    /// Every one of the four sections exposes the same universal search
    /// field with restrained pre-typing suggestions, and cancelling restores
    /// the section that was being browsed.
    func testUniversalSearchAvailableFromEverySection() throws {
        let app = launch()
        waitForHome(app)

        for section in ["Home", "Matches", "Roster", "Stats"] {
            openSection(app, section)
            let field = revealSearch(app)
            XCTAssertTrue(
                field.isHittable,
                "\(section) does not expose the universal search field")
            field.tap()
            XCTAssertTrue(
                app.staticTexts["Recent Matches"].waitForExistence(timeout: 10),
                "\(section) search shows no recent matches before typing")
            // Search acts on the section: the navigation title stays the
            // section's, never becoming a Search destination.
            let expectedTitle = section == "Stats" ? "Season Stats" : section
            XCTAssertTrue(
                app.navigationBars[expectedTitle].waitForExistence(timeout: 10),
                "\(section) search renamed the destination instead of keeping \(expectedTitle)")
            cancelSearch(app)
        }

        openSection(app, "Home")
        waitForHome(app)
    }

    /// One query surface finds matches, players, teams, and seasons alike,
    /// wherever it was opened — here from Roster. Tapping the team result
    /// selects the workspace and dismisses search.
    func testUniversalSearchFindsEveryEntityType() throws {
        let app = launch()
        waitForHome(app)
        openSection(app, "Roster")
        XCTAssertTrue(app.navigationBars["Roster"].waitForExistence(timeout: 10))

        searchFor(app, "Emerald")
        XCTAssertTrue(
            element(app, "match.Emerald").waitForExistence(timeout: 10),
            "Universal search found no match result from Roster")
        cancelSearch(app)

        searchFor(app, "Carter")
        XCTAssertTrue(
            element(app, "search.player.Carter").waitForExistence(timeout: 10),
            "Universal search found no player result from Roster")
        cancelSearch(app)

        searchFor(app, "Ninety")
        XCTAssertTrue(
            element(app, "search.team.Ninety Six Boys Soccer").waitForExistence(
                timeout: 10),
            "Universal search found no team result from Roster")
        cancelSearch(app)

        searchFor(app, "2027")
        XCTAssertTrue(
            element(app, "search.season.2027").waitForExistence(timeout: 10),
            "Universal search found no season result from Roster")
        cancelSearch(app)

        searchFor(app, "Ninety")
        element(app, "search.team.Ninety Six Boys Soccer").tap()
        XCTAssertTrue(
            app.navigationBars["Roster"].waitForExistence(timeout: 10),
            "Selecting a team result did not return to browsing")
        XCTAssertFalse(
            element(app, "search.content").exists,
            "Selecting a team result left a stale search surface")
    }

    /// Search is a launcher, not a navigation universe: a match found from
    /// Roster opens in the Matches stack, leaving the Roster stack at its
    /// root.
    func testUniversalSearchMatchRoutesToMatchesStack() throws {
        let app = launch()
        waitForHome(app)

        openSection(app, "Roster")
        searchFor(app, "Emerald")
        element(app, "match.Emerald").tap()
        XCTAssertTrue(
            app.staticTexts["Box Score"].waitForExistence(timeout: 10),
            "The match result did not open match detail")

        openSection(app, "Roster")
        XCTAssertTrue(app.navigationBars["Roster"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.staticTexts["Box Score"].exists,
            "The match detail landed in the Roster stack instead of Matches")
        openSection(app, "Matches")
        XCTAssertTrue(
            app.staticTexts["Box Score"].waitForExistence(timeout: 10),
            "The match detail is not in the Matches stack")
    }

    /// The mirror direction: a player found from Matches opens in the Roster
    /// stack, leaving the Matches stack at its root.
    func testUniversalSearchPlayerRoutesToRosterStack() throws {
        let app = launch()
        waitForHome(app)

        openSection(app, "Matches")
        searchFor(app, "Carter")
        element(app, "search.player.Carter").tap()
        XCTAssertTrue(
            app.navigationBars["Carter"].waitForExistence(timeout: 10),
            "The player result did not open player detail")

        openSection(app, "Matches")
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.navigationBars["Carter"].exists,
            "The player detail landed in the Matches stack instead of Roster")
        openSection(app, "Roster")
        XCTAssertTrue(
            app.navigationBars["Carter"].waitForExistence(timeout: 10),
            "The player detail is not in the Roster stack")
    }

    /// Current Team never leaks another team's matches or players, while All
    /// Teams finds them and routes across the workspace switch.
    func testUniversalSearchScopes() throws {
        let app = launch()
        waitForHome(app)
        createTeam(app, name: "JV Test Team", shortName: "JV Test")

        openSection(app, "Roster")
        app.buttons["Add a Player"].tap()
        XCTAssertTrue(app.navigationBars["Add Player"].waitForExistence(timeout: 10))
        replaceText(app, app.textFields["First name"], with: "Zelda")
        replaceText(app, app.textFields["Last name"], with: "Smith")
        replaceText(app, app.textFields["Jersey number"], with: "99")
        app.buttons["Save"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'Zelda'")
            ).firstMatch
                .waitForExistence(timeout: 10),
            "The new team's player was not saved")

        searchFor(app, "Carter")
        XCTAssertTrue(
            element(app, "search.content").waitForExistence(timeout: 10))
        XCTAssertTrue(
            element(app, "search.team.JV Test Team").waitForExistence(timeout: 10),
            "Search results never loaded")
        XCTAssertFalse(
            element(app, "search.player.Carter").exists,
            "Current Team leaked another team's player")
        cancelSearch(app)

        searchFor(app, "Emerald")
        XCTAssertTrue(
            element(app, "search.team.Ninety Six Boys Soccer").waitForExistence(
                timeout: 10),
            "Search results never loaded")
        XCTAssertFalse(
            element(app, "match.Emerald").exists,
            "Current Team leaked another team's match")
        app.buttons["All Teams"].tap()
        XCTAssertTrue(
            element(app, "match.Emerald").waitForExistence(timeout: 10),
            "All Teams lost the cross-team match")
        element(app, "match.Emerald").tap()
        XCTAssertTrue(
            app.staticTexts["Box Score"].waitForExistence(timeout: 10),
            "The cross-team result did not open match detail")
        // The cross-team routing switched the workspace: Home now shows the
        // seeded team's content instead of the new team's empty state.
        openSection(app, "Home")
        XCTAssertTrue(
            element(app, "match.Emerald").waitForExistence(timeout: 10),
            "The cross-team result did not switch teams")
    }

    /// Switching teams while searching reloads Current-Team content instead
    /// of keeping the previous team's snapshots on screen.
    func testUniversalSearchReloadsAfterTeamChange() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Switching teams mid-search needs the sidebar team switcher.")
        let app = launch()
        waitForHome(app)
        createTeam(app, name: "JV Test Team", shortName: "JV Test")

        element(app, "sidebar.teamSwitcher").tap()
        tapTeamMenuEntry(app, "Ninety Six Boys Soccer")
        XCTAssertTrue(
            element(app, "match.Emerald").waitForExistence(timeout: 10))

        openSection(app, "Matches")
        searchFor(app, "Emerald")
        XCTAssertTrue(
            element(app, "match.Emerald").waitForExistence(timeout: 10))

        element(app, "sidebar.teamSwitcher").tap()
        tapTeamMenuEntry(app, "JV Test Team")
        XCTAssertTrue(
            element(app, "search.team.JV Test Team").waitForExistence(timeout: 10),
            "Search results never reloaded for the new team")
        XCTAssertFalse(
            element(app, "match.Emerald").exists,
            "Search kept the previous team's matches after switching teams")
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

        // Search is an action on content, not a fifth destination: no tab,
        // no sidebar row.
        XCTAssertFalse(app.tabBars.buttons["Search"].exists)
        XCTAssertFalse(app.buttons["Search"].exists)

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
