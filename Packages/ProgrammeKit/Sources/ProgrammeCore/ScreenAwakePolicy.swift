import Foundation

/// Policy for "Keep the screen awake while scoring".
///
/// Pure decision logic with no platform dependencies: given the user's
/// preference, whether a live scorer is visibly active, and whether the
/// scene is active, it answers whether the idle timer should be disabled.
/// ProgrammeCore owns this so it is unit-testable; the App layer owns the
/// single `UIApplication.isIdleTimerDisabled` assignment behind an adapter.
///
/// The idle timer is disabled only when all three hold, so the display can
/// never stay awake outside active visible scoring just because the
/// preference is enabled.
public enum ScreenAwakePolicy {
    /// UserDefaults key for the Settings toggle. Absent means awake: the
    /// Settings toggle defaults to on, so the read path must treat a
    /// never-stored value as enabled rather than as `bool(forKey:)` false.
    public static let preferenceKey = "keepScreenAwakeWhileScoring"

    /// Whether the idle timer should be disabled right now.
    ///
    /// - preferenceEnabled: the Settings toggle.
    /// - scorerVisible: a live scorer is visibly active (appeared, not yet
    ///   disappeared), not merely that a session object exists.
    /// - sceneActive: the scene is active, not backgrounded or inactive.
    public static func wantsIdleTimerDisabled(
        preferenceEnabled: Bool,
        scorerVisible: Bool,
        sceneActive: Bool
    ) -> Bool {
        preferenceEnabled && scorerVisible && sceneActive
    }
}
