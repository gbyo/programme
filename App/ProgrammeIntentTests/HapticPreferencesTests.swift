import Foundation
import XCTest

@testable import Programme

final class HapticPreferencesTests: XCTestCase {
    func testHapticsDefaultOnAndRespectStoredPreference() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: HapticPreferences.key)

        defer {
            if let original {
                defaults.set(original, forKey: HapticPreferences.key)
            } else {
                defaults.removeObject(forKey: HapticPreferences.key)
            }
        }

        defaults.removeObject(forKey: HapticPreferences.key)
        XCTAssertTrue(HapticPreferences.isEnabled)

        defaults.set(false, forKey: HapticPreferences.key)
        XCTAssertFalse(HapticPreferences.isEnabled)

        defaults.set(true, forKey: HapticPreferences.key)
        XCTAssertTrue(HapticPreferences.isEnabled)
    }
}
