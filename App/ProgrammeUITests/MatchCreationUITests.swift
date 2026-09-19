import XCTest

/// Creating teams and matches, and the scoring configuration they carry.
///
/// These complement — they do not replace — the domain tests in ProgrammeCore,
/// which is where correctness of the statistics themselves is established.
/// Queries use accessibility identifiers so a wording change doesn't break a test.
final class MatchCreationUITests: ProgrammeUITestCase {

    func testManageTeamsCreatesAndEditsTeam() {
        let app = launch()
        waitForHome(app)

        // Settings → Manage Teams… → Add Team…
        tapToolbarButton(app, "home.settings", label: "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.staticTexts["Manage Teams…"].tap()
        XCTAssertTrue(app.navigationBars["Manage Teams"].waitForExistence(timeout: 5))
        app.buttons["Add Team…"].tap()
        // The sheet titles itself "New Team".
        XCTAssertTrue(app.navigationBars["New Team"].waitForExistence(timeout: 5))

        replaceText(app, app.textFields["Team name"], with: "JV Test Team")
        replaceText(app, app.textFields["Short name for the scoreboard"], with: "JV Test")
        app.buttons["Create"].tap()

        // Creating a team selects it: Home now shows the new, empty workspace.
        let header = element(app, "home.header")
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(
            header.label.contains("JV Test Team"),
            "Creating a team did not select it: \(header.label)")
        XCTAssertFalse(
            element(app, "match.Emerald").exists,
            "The previous team's matches leaked into the new workspace")

        // Editing the team updates it in place rather than creating another one.
        tapToolbarButton(app, "home.settings", label: "Settings")
        // The toolbar can still be rebuilding from the sheet dismissal when
        // the tap lands, opening nothing; retry once if no menu appeared.
        if !app.staticTexts["Manage Teams…"].waitForExistence(timeout: 5) {
            tapToolbarButton(app, "home.settings", label: "Settings")
        }
        XCTAssertTrue(app.staticTexts["Manage Teams…"].waitForExistence(timeout: 5))
        app.staticTexts["Manage Teams…"].tap()
        // The push lands inside the Settings sheet. Use the same global
        // navigation-bar query as the first half of this test: scoped
        // sheet queries do not resolve the pushed bar reliably.
        if !app.navigationBars["Manage Teams"].waitForExistence(timeout: 5) {
            // The tap dismissed the menu without activating the entry;
            // reopen Settings and tap it again.
            tapToolbarButton(app, "home.settings", label: "Settings")
            XCTAssertTrue(app.staticTexts["Manage Teams…"].waitForExistence(timeout: 5))
            app.staticTexts["Manage Teams…"].tap()
            XCTAssertTrue(app.navigationBars["Manage Teams"].waitForExistence(timeout: 10))
        }
        // Home's header and sidebar behind the sheet show the same team
        // name, so scope the row to its unique subtitle: the new team has
        // no players yet, which neither Home's chrome nor the other team's
        // row can match.
        let teamCell = app.cells.containing(.staticText, identifier: "0 players · 1 seasons").firstMatch
        XCTAssertTrue(teamCell.waitForExistence(timeout: 5))
        teamCell.staticTexts["JV Test Team"].tap()
        // The detail title shows the short name only after its async load,
        // so wait for the pushed content first, then for the titled nav bar.
        XCTAssertTrue(app.textFields["Team name"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["JV Test"].waitForExistence(timeout: 15))
        replaceText(app, app.textFields["Team name"], with: "JV Renamed")
        element(app, "teamDetail.save").tap()

        XCTAssertTrue(app.staticTexts["JV Renamed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["JV Test Team"].exists)
        XCTAssertTrue(
            app.staticTexts["Ninety Six Boys Soccer"].exists,
            "The original team disappeared after editing the new one")
    }

    func testCreatingAMatch() {
        let app = launch()
        waitForHome(app)

        app.buttons["New Match"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Match"].waitForExistence(timeout: 5))

        let opponent = app.textFields["Opponent"]
        XCTAssertTrue(opponent.waitForExistence(timeout: 5))
        opponent.tap()
        opponent.typeText("Newberry")
        attachScreenshot(named: "New match")

        // The primary action creates the match and goes straight to the lineup,
        // which is what the scorer does next every single time.
        element(app, "newMatch.create").tap()

        XCTAssertTrue(
            app.navigationBars["Starting Lineup"].waitForExistence(timeout: 15),
            "Create & Set Lineup did not open the lineup editor")

        let confirm = element(app, "lineup.confirm")
        XCTAssertFalse(confirm.isEnabled, "A new match should start with no lineup selected")
        XCTAssertTrue(element(app, "lineup.1").exists, "The roster list is missing")

        attachScreenshot(named: "Lineup editor landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(element(app, "lineup.1").waitForExistence(timeout: 5))
        attachScreenshot(named: "Lineup editor portrait")
        XCUIDevice.shared.orientation = .landscapeLeft

        let fallbackActions = element(app, "lineup.actions")
        let actions = fallbackActions.exists ? fallbackActions : app.buttons["More"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5), "The lineup actions menu is missing")
        actions.tap()
        app.buttons["Fill by Jersey Number"].tap()

        XCTAssertTrue(confirm.isEnabled, "The explicitly filled lineup was not valid")
        confirm.tap()

        waitForScorer(app)
        XCTAssertTrue(
            element(app, "live.score").label.contains("Newberry"),
            "The new match did not open in the scorer")
        // Creating a match never starts the clock.
        XCTAssertTrue(
            element(app, "live.startPeriod").exists,
            "The match clock was started automatically")
    }

    func testNewMatchRemembersTheScoringConfiguration() {
        let app = launch()
        waitForHome(app)

        app.buttons["New Match"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Match"].waitForExistence(timeout: 5))

        // One row, stating exactly what this match will record, instead of three
        // pickers to re-confirm before every kickoff.
        let scoring = element(app, "newMatch.scoring")
        XCTAssertTrue(scoring.waitForExistence(timeout: 5), "The scoring summary row is missing")
        XCTAssertTrue(
            scoring.label.contains("High School") && scoring.label.contains("MaxPreps")
                && scoring.label.contains("Our Team"),
            "The scoring summary does not state the configuration: \(scoring.label)")
    }

}
