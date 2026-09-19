import UIKit
import XCTest

/// The compact scorer: one pane at a time, and the Event Composer as a single
/// sheet over the top of it.
///
/// These skip on iPad, where the composer lives in a column instead and is
/// covered by the iPad suites in this target. Run them against an iPhone
/// destination:
///
///     xcodebuild test -scheme Programme \
///         -destination 'platform=iOS Simulator,name=Programme iPhone 17' \
///         -only-testing:ProgrammeUITests/CompactScorerUITests
final class CompactScorerUITests: ProgrammeUITestCase {

    private func launchCompactScorer(extraArguments: [String] = []) throws -> XCUIApplication {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "The compact composer only applies in a compact environment.")
        let app = XCUIApplication()
        app.launchArguments = ["-programme-uitest", "-programme-open-live"] + extraArguments
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        waitForScorer(app)
        return app
    }

    /// On a phone the bottom bar cannot show every secondary control, so the
    /// system moves low-priority items such as Match Stats and Event Log into an
    /// overflow menu. A test has to look inside the menu rather than assume those
    /// controls are visible.
    private func tapPossiblyOverflowed(
        _ app: XCUIApplication, identifier: String, label: String
    ) {
        tapToolbarButton(app, identifier, label: label)
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

    func testCompactLastEventFloatsAboveTheToolbarThenClears() throws {
        let app = try launchCompactScorer()

        XCTAssertFalse(
            element(app, "scoring.lastEvent").exists,
            "An old last-event summary is still occupying the compact toolbar")

        element(app, "palette.corner").tap()
        XCTAssertTrue(element(app, "composer.sheet").waitForExistence(timeout: 5))
        element(app, "pick.7").tap()

        let confirmation = element(app, "scoring.lastEvent")
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 5),
            "Recording an event did not show compact confirmation")
        XCTAssertTrue(
            confirmation.label.contains("Corner"),
            "Compact confirmation does not describe the recorded event")
        XCTAssertTrue(
            element(app, "scoring.undo").isHittable,
            "The confirmation displaced the correction controls")
        attachScreenshot(named: "Compact last-event confirmation")

        let disappears = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: confirmation)
        wait(for: [disappears], timeout: 5)
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

    // MARK: - Substitution
    //
    // A substitution is a pair: this player off, that player on for them. On a
    // phone that is a pushed flow — "Who is coming off?" then "Coming On" —
    // inside the composer's own sheet, and several pairs commit as one event.

    private func openSubstitution(_ app: XCUIApplication) {
        element(app, "scoring.substitution").tap()
        XCTAssertTrue(
            element(app, "composer.sheet").waitForExistence(timeout: 5),
            "Substitution did not use the composer sheet")
        XCTAssertTrue(
            element(app, "sub.comingOff").waitForExistence(timeout: 5),
            "The outgoing-player list is not the root of the flow")
    }

    /// One pair, from the root list to back at the root list.
    private func pair(_ app: XCUIApplication, out: String, in incoming: String) {
        reveal(app, "sub.out.\(out)", within: "sub.comingOff").tap()
        XCTAssertTrue(
            element(app, "sub.comingOn").waitForExistence(timeout: 5),
            "Choosing a player coming off did not push Coming On")
        reveal(app, "sub.in.\(incoming)", within: "sub.comingOn").tap()
    }

    /// A squad is longer than a phone at large text sizes, so a row may need
    /// scrolling into reach — downwards for a player further into the squad,
    /// upwards for the Ready section above them. Finding nothing at all is
    /// still a failure.
    @discardableResult
    private func reveal(
        _ app: XCUIApplication, _ identifier: String, within list: String
    ) -> XCUIElement {
        let target = element(app, identifier)
        if target.waitForExistence(timeout: 2), target.isHittable { return target }
        for attempt in 0..<8 {
            if target.exists && target.isHittable { return target }
            if attempt < 4 {
                element(app, list).swipeUp()
            } else {
                element(app, list).swipeDown()
            }
        }
        XCTAssertTrue(target.exists, "\(identifier) is not in \(list) at all")
        return target
    }

    /// A completed pair, from the Ready section at the top of the root list.
    @discardableResult
    private func pendingPair(_ app: XCUIApplication, _ jersey: String) -> XCUIElement {
        reveal(app, "sub.pair.\(jersey)", within: "sub.comingOff")
    }

    func testSubstitutionOpensAsAComposerSheetOntoWhoIsComingOff() throws {
        let app = try launchCompactScorer()
        openSubstitution(app)

        // A native list of on-field players, not a grid of tiles, and the
        // navigation bar carries the title and the period/clock.
        reveal(app, "sub.out.11", within: "sub.comingOff")
        XCTAssertTrue(app.navigationBars["Substitution"].exists, "No native navigation chrome")
        XCTAssertFalse(
            element(app, "sub.commit").isEnabled,
            "Record is offered before there is anything to record")
        attachScreenshot(named: "Substitution, who is coming off")
    }

    func testTheIncomingScreenSaysWhoItIsFor() throws {
        let app = try launchCompactScorer()
        openSubstitution(app)

        reveal(app, "sub.out.11", within: "sub.comingOff").tap()
        XCTAssertTrue(element(app, "sub.comingOn").waitForExistence(timeout: 5))

        // The relationship is the context of the screen, not an inference.
        XCTAssertTrue(
            app.staticTexts["For #11 Trotter"].waitForExistence(timeout: 5),
            "Coming On does not say who this player replaces")
        XCTAssertTrue(element(app, "sub.in.13").exists, "The bench is not offered")
        XCTAssertFalse(
            element(app, "sub.in.11").exists, "A player coming off was offered to come on")
        attachScreenshot(named: "Substitution, coming on for")
    }

    func testChoosingTheIncomingPlayerMakesOnePairAndReturnsToTheList() throws {
        let app = try launchCompactScorer()
        openSubstitution(app)

        pair(app, out: "11", in: "13")

        XCTAssertTrue(
            element(app, "sub.comingOff").waitForExistence(timeout: 5),
            "The flow did not return to the outgoing list")
        XCTAssertTrue(
            pendingPair(app, "11").exists, "The pair was not recorded in the draft")
        // Both players are now spoken for.
        XCTAssertFalse(element(app, "sub.out.11").exists, "A paired player stayed in the choices")
        XCTAssertEqual(
            element(app, "sub.commit").label, "Record",
            "One tap produced more than one pending substitution")
        attachScreenshot(named: "Substitution, one pair ready")
    }

    func testASecondPairNeedsNoAddAnotherStep() throws {
        let app = try launchCompactScorer()
        openSubstitution(app)

        pair(app, out: "11", in: "13")
        // No intervening tap: the root is already asking who else is coming off.
        pair(app, out: "6", in: "14")

        XCTAssertTrue(pendingPair(app, "11").exists)
        XCTAssertTrue(pendingPair(app, "6").exists)
        XCTAssertFalse(
            element(app, "sub.in.13").exists,
            "An incoming player used by another pair is still offered")
        XCTAssertTrue(
            element(app, "sub.commit").label.contains("2"),
            "The confirmation does not say how many changes are pending")
        attachScreenshot(named: "Substitution, two pairs ready")
    }

    func testAPendingPairIsRemovedWithTheNativeRowAction() throws {
        let app = try launchCompactScorer()
        openSubstitution(app)

        pair(app, out: "11", in: "13")
        let pending = pendingPair(app, "11")
        XCTAssertTrue(pending.exists)

        pending.swipeLeft()
        let remove = element(app, "sub.remove.11")
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "No swipe action to remove the pair")
        remove.tap()

        XCTAssertFalse(
            element(app, "sub.pair.11").waitForExistence(timeout: 2), "The pair was not removed")
        // Both players are available again.
        XCTAssertTrue(element(app, "sub.out.11").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "sub.commit").isEnabled, "Record survived an empty draft")
    }

    func testBackFromComingOnLeavesNoPartialPair() throws {
        let app = try launchCompactScorer()
        openSubstitution(app)

        reveal(app, "sub.out.11", within: "sub.comingOff").tap()
        XCTAssertTrue(element(app, "sub.comingOn").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(element(app, "sub.comingOff").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "sub.pair.11").exists, "Half a substitution was kept")
        XCTAssertFalse(
            element(app, "sub.commit").isEnabled, "Record was offered for half a pair")
        XCTAssertTrue(element(app, "sub.out.11").exists, "#11 was not returned to the choices")
    }

    func testCancellingAnUnfinishedSubstitutionChangesNothing() throws {
        let app = try launchCompactScorer()
        let eventsBefore = substitutionRowsInLog(app)

        openSubstitution(app)
        pair(app, out: "11", in: "13")
        XCTAssertTrue(pendingPair(app, "11").exists)
        element(app, "sub.cancel").tap()

        XCTAssertFalse(
            element(app, "composer.sheet").waitForExistence(timeout: 2), "The sheet stayed open")
        XCTAssertEqual(
            substitutionRowsInLog(app), eventsBefore, "Cancelling recorded something")
        XCTAssertTrue(onField(app, "11"), "Cancelling took a player off the field")
        XCTAssertFalse(onField(app, "13"), "Cancelling brought a player on")
    }

    func testCommittingTwoPairsRecordsOneEventAndMovesBothPlayers() throws {
        let app = try launchCompactScorer()
        openSubstitution(app)

        pair(app, out: "11", in: "13")
        pair(app, out: "6", in: "14")
        element(app, "sub.commit").tap()

        XCTAssertFalse(
            element(app, "composer.sheet").waitForExistence(timeout: 2),
            "Recording did not close the sheet")

        // One event at one match time, narrated as two relationships. The
        // sample match already contains one substitution, so this is the
        // second — and the pair of changes must not be two of them.
        openEventLog(app)
        let batched = app.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label CONTAINS 'Substitution' AND label CONTAINS 'Ferrer' AND label CONTAINS 'Hollis'"
            ))
        XCTAssertTrue(
            batched.firstMatch.waitForExistence(timeout: 5),
            "Both changes were not recorded as one event")
        attachScreenshot(named: "Substitution in the event log")
        closeEventLog(app)

        XCTAssertFalse(onField(app, "11"), "#11 did not come off")
        XCTAssertFalse(onField(app, "6"), "#6 did not come off")
        XCTAssertTrue(onField(app, "13"), "#13 did not come on")
        XCTAssertTrue(onField(app, "14"), "#14 did not come on")
    }

    func testReplacingTheGoalkeeperForcesAnExplicitChoice() throws {
        let app = try launchCompactScorer()
        openSubstitution(app)

        // #1 Whitfield is in goal. Taking the keeper off pushes the question
        // straight away, because every later save is attributed from it.
        pair(app, out: "1", in: "22")

        XCTAssertTrue(
            element(app, "sub.goalkeeperChoice").waitForExistence(timeout: 5),
            "Taking the goalkeeper off did not ask who is in goal")
        attachScreenshot(named: "Substitution, who is in goal")

        // Only players who will actually be on the field afterwards.
        XCTAssertTrue(element(app, "sub.goalkeeper.22").exists, "The arriving player is not offered")
        XCTAssertTrue(element(app, "sub.goalkeeper.9").exists, "A player staying on is not offered")
        XCTAssertFalse(
            element(app, "sub.goalkeeper.1").exists, "The departing goalkeeper was offered")
        XCTAssertFalse(
            element(app, "sub.goalkeeper.15").exists, "A player still on the bench was offered")

        // Walking away from the question does not let the batch through, and
        // the root keeps asking.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, "sub.comingOff").waitForExistence(timeout: 5))
        XCTAssertFalse(
            element(app, "sub.commit").isEnabled,
            "The batch could be recorded without a goalkeeper")
        let prompt = element(app, "sub.goalkeeperPrompt")
        XCTAssertTrue(prompt.exists, "The root stopped asking who is in goal")
        prompt.tap()

        // Nothing is assumed from a roster position: the scorer says so.
        XCTAssertTrue(element(app, "sub.goalkeeperChoice").waitForExistence(timeout: 5))
        element(app, "sub.goalkeeper.22").tap()

        XCTAssertTrue(
            element(app, "sub.comingOff").waitForExistence(timeout: 5),
            "Choosing the goalkeeper did not return to the substitution list")
        XCTAssertTrue(element(app, "sub.commit").isEnabled, "Record is still withheld")
        element(app, "sub.commit").tap()

        // Compact last-event confirmation is intentionally transient, so the
        // durable evidence comes from the log: one event, naming the new goalkeeper.
        openEventLog(app)
        let recorded = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Substitution' AND label CONTAINS 'Brannon'"))
        XCTAssertTrue(
            recorded.firstMatch.waitForExistence(timeout: 5),
            "The goalkeeper change was not recorded")
        closeEventLog(app)
    }

    func testHighSchoolReEntryStillOffersAPlayerWhoCameOff() throws {
        let app = try launchCompactScorer()

        // The sample match already has #8 Mabry substituted off, so he is on the
        // bench now and high-school rules allow him straight back on.
        openSubstitution(app)
        reveal(app, "sub.out.9", within: "sub.comingOff").tap()
        XCTAssertTrue(element(app, "sub.comingOn").waitForExistence(timeout: 5))
        XCTAssertTrue(
            element(app, "sub.in.8").exists,
            "A player who was substituted off is not offered to re-enter")

        reveal(app, "sub.in.8", within: "sub.comingOn").tap()
        element(app, "sub.commit").tap()

        XCTAssertTrue(onField(app, "8"), "#8 did not re-enter")
    }

    func testDynamicTypeKeepsEveryPlayerIdentifiable() throws {
        let app = try launchCompactScorer(
            extraArguments: [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
            ])
        openSubstitution(app)

        // The jersey number and the name are the identity. Neither may be
        // scaled or truncated into uselessness.
        let row = reveal(app, "sub.out.11", within: "sub.comingOff")
        XCTAssertTrue(row.label.contains("11"), "The jersey number is gone: \(row.label)")
        XCTAssertTrue(row.label.contains("Trotter"), "The name is gone: \(row.label)")
        attachScreenshot(named: "Substitution at accessibility text size")
    }

    func testVoiceOverDistinguishesOutgoingIncomingAndPendingPairs() throws {
        let app = try launchCompactScorer()
        openSubstitution(app)

        XCTAssertTrue(
            element(app, "sub.out.1").label.contains("goalkeeper"),
            "The goalkeeper is not announced")
        let outgoing = reveal(app, "sub.out.11", within: "sub.comingOff")
        XCTAssertTrue(outgoing.label.contains("on field"), "Outgoing row: \(outgoing.label)")

        outgoing.tap()
        XCTAssertTrue(element(app, "sub.comingOn").waitForExistence(timeout: 5))
        XCTAssertTrue(
            element(app, "sub.in.13").label.contains("bench"),
            "Incoming row: \(element(app, "sub.in.13").label)")

        reveal(app, "sub.in.13", within: "sub.comingOn").tap()
        let pending = pendingPair(app, "11")
        XCTAssertTrue(pending.exists)
        XCTAssertTrue(
            pending.label.contains("Ferrer replacing Trotter"),
            "A pending pair does not read as a relationship: \(pending.label)")
    }

    /// The event log is secondary, so a phone in portrait puts it in the bar's
    /// overflow menu rather than on screen.
    private func openEventLog(_ app: XCUIApplication) {
        tapPossiblyOverflowed(app, identifier: "scoring.eventLog", label: "Event Log")
    }

    private func closeEventLog(_ app: XCUIApplication) {
        app.buttons["Done"].firstMatch.tap()
    }

    private func substitutionRowsInLog(_ app: XCUIApplication) -> Int {
        openEventLog(app)
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Substitution'"))
        _ = rows.firstMatch.waitForExistence(timeout: 5)
        let count = rows.count
        closeEventLog(app)
        return count
    }

    /// Whether a jersey number is currently on the field, read from the Lineup
    /// pane rather than inferred from the substitution screen.
    private func onField(_ app: XCUIApplication, _ jersey: String) -> Bool {
        if !element(app, "player.\(jersey)").exists {
            app.buttons["Lineup"].firstMatch.tap()
        }
        let row = element(app, "player.\(jersey)")
        guard row.waitForExistence(timeout: 5) else { return false }
        return !(row.value as? String ?? "").contains("bench")
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
}
