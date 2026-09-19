import XCTest

/// Shared UI-test support for the iPad and compact suites.
///
/// Each XCTestCase subclass launches a fresh app through the existing
/// `-programme-uitest` seams, so tests stay safe to run alone, in a random
/// order, or concurrently in another simulator clone. Helpers live here so the
/// split test classes do not duplicate launch/lookup/scroll logic.
class ProgrammeUITestCase: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func launch(_ extraArguments: [String] = [], landscape: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-programme-uitest"] + extraArguments
        app.launch()
        if landscape { XCUIDevice.shared.orientation = .landscapeLeft }
        return app
    }

    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func waitForScorer(_ app: XCUIApplication) {
        // Generous on purpose: the first launch on a fresh simulator-clone
        // install can take well over 20s, and with parallel workers several
        // clones pay that cost at once. The wait still returns the moment the
        // scorer appears, so healthy runs pay nothing extra.
        XCTAssertTrue(
            element(app, "live.score").waitForExistence(timeout: 60),
            "The scoring workspace did not appear")
    }

    /// Same cold-start headroom as waitForScorer for tests that land on Home.
    /// Returns the header so callers can assert on its label.
    @discardableResult
    func waitForHome(_ app: XCUIApplication) -> XCUIElement {
        let header = element(app, "home.header")
        XCTAssertTrue(
            header.waitForExistence(timeout: 60),
            "The home workspace did not appear")
        return header
    }

    /// Scrolls the lineup column until a row is reachable. The swipe is anchored
    /// on a row rather than on the window, so it scrolls the lineup and not
    /// whichever panel happens to be in the middle of the workspace.
    func revealInLineup(
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
    func revealInSubstitution(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
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

    /// Scrolls a long list until a section materializes. Lazily rendered rows
    /// below the fold may not exist in the hierarchy at all, so a bare
    /// `exists` check is not enough — swipe until the element appears.
    @discardableResult
    func revealByScrolling(_ app: XCUIApplication, _ identifier: String, maxSwipes: Int = 8) -> XCUIElement {
        let target = element(app, identifier)
        var attempts = 0
        while !target.exists && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(target.exists, "\(identifier) is not reachable by scrolling")
        return target
    }

    /// Taps a toolbar control, looking inside the overflow menu when it is not
    /// directly reachable. Secondary toolbar items can collapse into the
    /// system overflow, which rebuilds them as menu entries that keep their
    /// label but not the identifier the bar button carried — and on newer OS
    /// releases the control can surface as a PopUpButton rather than a
    /// Button, so the direct lookup stays type-agnostic too.
    func tapToolbarButton(_ app: XCUIApplication, _ identifier: String, label: String) {
        let direct = element(app, identifier)
        if (direct.exists && direct.isHittable)
            || (direct.waitForExistence(timeout: 5) && direct.isHittable)
        {
            direct.tap()
            return
        }
        let overflow = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS 'Overflow'")
        ).firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 5), "No overflow menu to look in")
        // The system rebuilds the entry without its identifier, so match the
        // menu contents by label. Depending on OS version and idiom it
        // surfaces as a Button or as a MenuItem; accept either one.
        func tapMenuEntry() -> Bool {
            let inMenuButton = app.buttons.matching(
                NSPredicate(format: "label == %@", label)
            ).firstMatch
            if inMenuButton.waitForExistence(timeout: 5) {
                inMenuButton.tap()
                return true
            }
            let inMenuItem = app.menuItems.matching(
                NSPredicate(format: "label == %@", label)
            ).firstMatch
            if inMenuItem.waitForExistence(timeout: 5) {
                inMenuItem.tap()
                return true
            }
            return false
        }
        overflow.tap()
        if tapMenuEntry() {
            return
        }
        // The tap can land while the toolbar is mid-rebuild, opening nothing;
        // verify the effect and tap once more rather than failing outright.
        overflow.tap()
        XCTAssertTrue(tapMenuEntry(), "\(label) is not reachable at all")
    }

    /// Taps a lineup row to arm its player, retrying while the tap is
    /// swallowed: under parallel workers the clones pay cold-start costs
    /// at once, and the row can resolve and accept the tap before the
    /// workspace finishes loading — arming nobody with no error. The retry
    /// repeats the same user action and stops the moment the palette shows
    /// the armed player, so healthy runs tap exactly once and no assertion
    /// is weakened.
    func tapToArm(_ app: XCUIApplication, _ identifier: String, attempts: Int = 3) {
        for _ in 0..<attempts {
            element(app, identifier).tap()
            if element(app, "palette.armedPlayer").waitForExistence(timeout: 3) {
                return
            }
        }
        XCTFail("Tapping \(identifier) never armed a player")
    }

    func lastEventLabel(_ app: XCUIApplication) -> String {
        let strip = element(app, "scoring.lastEvent")
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        return strip.label
    }

    /// Opens one of the four top-level sections, whether SwiftUI renders the
    /// destinations as a tab bar (iPhone) or an adaptable sidebar (iPad).
    func openSection(_ app: XCUIApplication, _ name: String) {
        if app.tabBars.buttons[name].exists {
            app.tabBars.buttons[name].tap()
            return
        }
        let button = app.buttons[name].firstMatch
        if button.waitForExistence(timeout: 5) {
            button.tap()
            return
        }
        let row = app.cells.containing(.staticText, identifier: name).firstMatch
        if row.exists {
            row.tap()
            return
        }
        XCTFail("Could not find the \(name) destination")
    }

    /// Replaces a text field's contents, since several editors open prefilled.
    /// Prefers the edit-menu Select All so typing replaces; when the
    /// callout does not appear (common on iPad, where the tap only places
    /// the cursor), clears the field by deleting its current contents.
    /// Without the fallback, typing would append and the test would assert
    /// on a concatenated value far from the real failure.
    func replaceText(_ app: XCUIApplication, _ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if app.menuItems["Select All"].waitForExistence(timeout: 3) {
            app.menuItems["Select All"].tap()
        } else if let current = field.value as? String, !current.isEmpty {
            let deleteKey = app.keys["delete"]
            XCTAssertTrue(deleteKey.waitForExistence(timeout: 5))
            for _ in current {
                deleteKey.tap()
            }
        }
        field.typeText(text)
        XCTAssertEqual(
            field.value as? String, text,
            "The text field did not end up holding the replacement text")
    }

    func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        // Kept on failure, dropped on success: failure evidence is preserved
        // without permanently retaining every diagnostic shot from green runs.
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
