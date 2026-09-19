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

    /// Scrolls the lineup column until a row is reachable. The swipe is anchored
    /// on a row rather than on the window, so it scrolls the lineup and not
    /// whichever panel happens to be in the middle of the workspace.
    private func revealInLineup(
        _ app: XCUIApplication, _ identifier: String, anchor: String = "player.9"
    ) -> XCUIElement {
        let target = element(app, identifier)
        var attempts = 0
        while !(target.exists && target.isHittable) && attempts < 6 {
            element(app, anchor).swipeUp()
            attempts += 1
        }
        return target
    }

    /// The Coming Off column can be taller than the workspace it sits in, so a
    /// row may need scrolling into reach — down for a player further into the
    /// squad, back up for the Ready section above them.
    @discardableResult
    private func revealInSubstitution(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier)
        if target.waitForExistence(timeout: 2), target.isHittable { return target }
        for attempt in 0..<8 {
            if target.exists && target.isHittable { return target }
            if attempt < 4 {
                element(app, "sub.comingOff").swipeUp()
            } else {
                element(app, "sub.comingOff").swipeDown()
            }
        }
        XCTAssertTrue(target.exists, "\(identifier) is not reachable")
        return target
    }

    private func lastEventLabel(_ app: XCUIApplication) -> String {
        let strip = element(app, "scoring.lastEvent")
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        return strip.label
    }

    /// Native lists create rows and section headers lazily. Scroll the list until
    /// the user-visible element is present rather than depending on the eager
    /// hierarchy exposed by the old hand-built card stack.
    @discardableResult
    private func revealInList(_ target: XCUIElement, app: XCUIApplication) -> XCUIElement {
        var attempts = 0
        while !target.exists && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        return target
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

    func testLiveToolbarKeepsPrimaryControlsSeparateAndTogglesTheClock() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        XCTAssertTrue(element(app, "live.closeScorer").exists)
        XCTAssertTrue(element(app, "live.toggleClock").exists)
        XCTAssertTrue(element(app, "live.endPeriod").exists)
        XCTAssertTrue(element(app, "live.options").exists)

        let clockControl = element(app, "live.toggleClock")
        let originalLabel = clockControl.label
        clockControl.tap()
        XCTAssertNotEqual(
            clockControl.label, originalLabel,
            "The toolbar control did not reflect the clock's new running state")
        clockControl.tap()
    }

    func testClosingALiveScorerRequiresNondestructiveConfirmation() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "live.closeScorer").tap()
        XCTAssertTrue(app.staticTexts["Leave this match running?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close Scorer"].exists)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(element(app, "live.score").waitForExistence(timeout: 5))
    }

    func testRecordingAGoalByArmingAPlayerThenTappingTheAction() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // Direction one: player, then action.
        element(app, "player.9").tap()

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

        element(app, "player.9").tap()
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

        element(app, "player.9").tap()
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

    func testTheWorkspaceExistsToCompleteAnEventNotToShowStats() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // Whatever the layout, the middle is never a statistics panel: the
        // numbers have exactly one home, and it is the inspector.
        XCTAssertTrue(
            element(app, "live.matchStats").exists,
            "There is no way into the statistics inspector")

        // Starting an event fills the workspace with the question.
        element(app, "palette.corner").tap()
        XCTAssertTrue(app.staticTexts["Who took the corner?"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Event composer")
        element(app, "pick.7").tap()

        // And it hands the space straight back once nothing is outstanding.
        XCTAssertTrue(lastEventLabel(app).contains("Corner"))
        XCTAssertFalse(
            app.staticTexts["Who took the corner?"].waitForExistence(timeout: 2),
            "The composer stayed on screen with nothing left to ask")
    }

    func testConstrainedLandscapeKeepsLineupAndRecordUntilAnEventNeedsCompleting() {
        // An iPad mini in landscape is too narrow for three permanent columns, so
        // the lineup and Record share the screen and the composer borrows the
        // lineup's side only while it has a question.
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        let lineupRow = element(app, "player.9")
        XCTAssertTrue(lineupRow.exists, "The lineup is not visible while idle")
        XCTAssertTrue(element(app, "palette.goal").exists, "Record is not visible while idle")
        attachScreenshot(named: "Constrained landscape, idle")

        element(app, "palette.corner").tap()
        XCTAssertTrue(app.staticTexts["Who took the corner?"].waitForExistence(timeout: 5))

        // Record never moves. Only the lineup's side is borrowed.
        XCTAssertTrue(
            element(app, "palette.goal").exists, "Record moved when the composer opened")
        attachScreenshot(named: "Constrained landscape, composing")

        element(app, "pick.7").tap()

        // And the lineup comes straight back.
        XCTAssertTrue(
            element(app, "player.9").waitForExistence(timeout: 5),
            "The lineup did not return after the event was completed")
    }

    func testClearingTheArmedPlayerIsOneTap() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "player.9").tap()
        XCTAssertTrue(element(app, "palette.armedPlayer").waitForExistence(timeout: 5))

        element(app, "palette.clearArmedPlayer").tap()
        XCTAssertFalse(
            element(app, "palette.armedPlayer").waitForExistence(timeout: 2),
            "Clearing the armed player did not take effect")
    }

    func testABenchPlayerCannotBeArmedForOrdinaryLivePlay() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "player.9").tap()
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

    func testOpponentQuickActionsStayVisibleWithoutScrollingThePalette() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // An opponent shot is how our goalkeeper's shots-faced is recorded, so it
        // must never sit below the fold of the our-team palette.
        let opponentShot = element(app, "palette.opponent.shot")
        XCTAssertTrue(opponentShot.exists, "The opponent quick actions are not pinned")
        XCTAssertTrue(opponentShot.isHittable, "The opponent quick actions require scrolling")
        XCTAssertTrue(element(app, "palette.opponent.goal").isHittable)

        opponentShot.tap()
        XCTAssertTrue(lastEventLabel(app).contains("Shot"))
    }

    func testRedoKeepsItsPlaceInTheToolbarAfterAnUndo() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // Redo exists before there is anything to redo, so pressing Undo never
        // moves the controls beside it.
        let redo = element(app, "scoring.redo")
        XCTAssertTrue(redo.exists, "Redo is missing when it is unavailable")
        XCTAssertFalse(redo.isEnabled)
        let restingFrame = redo.frame

        element(app, "palette.corner").tap()
        element(app, "pick.7").tap()
        XCTAssertTrue(lastEventLabel(app).contains("Corner"))

        element(app, "scoring.undo").tap()

        let enabled = expectation(
            for: NSPredicate(format: "isEnabled == true"), evaluatedWith: redo)
        wait(for: [enabled], timeout: 5)
        XCTAssertEqual(
            redo.frame, restingFrame, "Undo moved the toolbar controls out from under the scorer")
    }

    func testAPenaltyAsksForTheOutcomeAndDoesNotImplyAGoal() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.pk").tap()

        // The taker, not "who scored".
        XCTAssertTrue(app.staticTexts["Who took the penalty?"].waitForExistence(timeout: 5))
        element(app, "pick.9").tap()

        XCTAssertTrue(app.staticTexts["What happened?"].waitForExistence(timeout: 5))
        attachScreenshot(named: "Penalty outcome")

        let saved = element(app, "penalty.saved")
        XCTAssertTrue(saved.exists, "A saved penalty was not offered")
        saved.tap()

        let summary = lastEventLabel(app)
        XCTAssertFalse(
            summary.contains("GOAL"), "A saved penalty was recorded as a goal: \(summary)")
        XCTAssertTrue(element(app, "live.score").label.contains("Ninety Six, 1"), "The score changed")
    }

    func testMoreIsAMenuThatReturnsStraightToAttribution() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "palette.more").tap()
        let blocked = app.buttons["Blocked"].firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 5), "More did not offer a blocked shot")
        blocked.tap()

        // Straight into the centre stage, with the match still on screen.
        XCTAssertTrue(app.staticTexts["Who took the shot?"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "live.score").exists, "The score was hidden by the More flow")
        element(app, "pick.9").tap()
        XCTAssertTrue(lastEventLabel(app).contains("Blocked"))
    }

    func testNoTipInterruptsTheScorerWhileTheClockIsRunning() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        // The sample live match opens with the clock running.
        element(app, "palette.sog").tap()
        XCTAssertTrue(element(app, "pick.wide.Player Unknown").waitForExistence(timeout: 5))

        XCTAssertFalse(
            app.staticTexts["Don't know the number?"].exists,
            "A tip appeared in the scoring workspace while the clock was running")
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

    /// On an iPad the field and the bench are visible at once, but the right
    /// column is never an independent second list: it only ever answers *who
    /// comes on for the player just chosen*.
    func testSubstitutionOnIPadPairsEachPlayerWithTheirReplacement() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "scoring.substitution").tap()
        XCTAssertTrue(element(app, "sub.comingOff").waitForExistence(timeout: 5))

        // The columns, not the phone's pushed flow.
        revealInSubstitution(app, "sub.out.11")
        XCTAssertTrue(
            element(app, "sub.comingOn.idle").exists,
            "The bench is offered before anyone has been chosen to come off")
        XCTAssertFalse(
            app.navigationBars["Substitution"].exists,
            "The iPad fell back to the phone navigation layout")

        revealInSubstitution(app, "sub.out.11").tap()
        let comingOnHeader = element(app, "sub.comingOn.header")
        XCTAssertTrue(
            comingOnHeader.waitForExistence(timeout: 5),
            "The right column does not say who it is choosing for")
        XCTAssertTrue(
            comingOnHeader.label.contains("Trotter"),
            "The right column names the wrong player: \(comingOnHeader.label)")
        element(app, "sub.in.13").tap()

        // The pair is formed and both players leave the choices.
        XCTAssertTrue(revealInSubstitution(app, "sub.pair.11").exists)
        XCTAssertFalse(element(app, "sub.out.11").exists)
        XCTAssertTrue(
            element(app, "sub.comingOn.idle").exists,
            "The active outgoing selection was not cleared for the next pair")

        revealInSubstitution(app, "sub.out.6").tap()
        element(app, "sub.in.14").tap()
        XCTAssertTrue(revealInSubstitution(app, "sub.pair.6").exists)
        attachScreenshot(named: "Substitution, two pairs on iPad")

        let commit = element(app, "sub.commit")
        XCTAssertTrue(commit.isEnabled)
        XCTAssertTrue(commit.label.contains("2"), "Multiple substitutions were not batched")
        commit.tap()

        let summary = lastEventLabel(app)
        XCTAssertTrue(summary.contains("Substitution"))
        XCTAssertTrue(
            summary.contains("Ferrer") && summary.contains("Hollis"),
            "Both changes were not recorded together: \(summary)")
    }

    func testSubstitutionOnIPadRemovesAPendingPairWithASwipe() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "scoring.substitution").tap()
        XCTAssertTrue(element(app, "sub.comingOff").waitForExistence(timeout: 5))
        revealInSubstitution(app, "sub.out.11").tap()
        element(app, "sub.in.13").tap()
        let pending = revealInSubstitution(app, "sub.pair.11")
        XCTAssertTrue(pending.exists)

        pending.swipeLeft()
        let remove = element(app, "sub.remove.11")
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "No native swipe action to remove")
        remove.tap()

        XCTAssertFalse(element(app, "sub.pair.11").waitForExistence(timeout: 2))
        XCTAssertTrue(element(app, "sub.out.11").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "sub.commit").isEnabled, "Record survived an empty draft")
    }

    func testSubstitutingTheGoalkeeperOnIPadAsksWhoIsInGoal() {
        let app = launch(["-programme-open-live"])
        waitForScorer(app)

        element(app, "scoring.substitution").tap()
        XCTAssertTrue(element(app, "sub.comingOff").waitForExistence(timeout: 5))
        revealInSubstitution(app, "sub.out.1").tap()
        element(app, "sub.in.22").tap()

        XCTAssertTrue(
            element(app, "sub.goalkeeperChoice").waitForExistence(timeout: 5),
            "Taking the goalkeeper off did not ask who is in goal")
        XCTAssertFalse(
            element(app, "sub.commit").isEnabled,
            "The batch could be recorded without a goalkeeper")
        XCTAssertFalse(
            element(app, "sub.goalkeeper.1").exists, "The departing goalkeeper was offered")
        attachScreenshot(named: "Goalkeeper substitution on iPad")

        element(app, "sub.goalkeeper.22").tap()
        XCTAssertTrue(element(app, "sub.commit").isEnabled)
        element(app, "sub.commit").tap()

        XCTAssertTrue(lastEventLabel(app).contains("Brannon"))
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

    func testNewMatchRemembersTheScoringConfiguration() {
        let app = launch()
        XCTAssertTrue(element(app, "today.header").waitForExistence(timeout: 20))

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

    func testMatchDetailDistinguishesNotTrackedFromZero() {
        let app = launch()
        XCTAssertTrue(element(app, "today.header").waitForExistence(timeout: 20))

        element(app, "match.Dixie").tap()
        XCTAssertTrue(app.staticTexts["Team"].waitForExistence(timeout: 15))
        XCTAssertTrue(revealInList(app.staticTexts["Stat Completeness"], app: app).exists)

        // The MaxPreps profile does not track offsides, so it has to read as
        // unknown rather than as a zero.
        let offsides = element(app, "completeness.offsides")
        XCTAssertTrue(offsides.exists)
        XCTAssertTrue(
            offsides.label.contains("Not tracked"),
            "An untracked category was not reported as unknown: \(offsides.label)")

        // A category that was tracked and genuinely happened zero times is a zero.
        let steals = revealInList(element(app, "completeness.steals"), app: app)
        XCTAssertTrue(steals.label.contains("Complete"))
        attachScreenshot(named: "Match detail")
    }

    func testExportProducesShareableFiles() {
        let app = launch()
        XCTAssertTrue(element(app, "today.header").waitForExistence(timeout: 20))

        element(app, "match.Dixie").tap()
        XCTAssertTrue(app.staticTexts["Team"].waitForExistence(timeout: 15))

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

    // MARK: - Helpers

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
