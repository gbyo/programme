import XCTest

/// iPad substitution: paired columns that batch several changes into one event.
///
/// These complement — they do not replace — the domain tests in ProgrammeCore,
/// which is where correctness of the statistics themselves is established.
/// Queries use accessibility identifiers so a wording change doesn't break a test.
final class SubstitutionUITests: ProgrammeUITestCase {

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

}
