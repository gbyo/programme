import Testing

@testable import ProgrammeCore

@Suite("Screen-awake policy only keeps the display awake while scoring")
struct ScreenAwakePolicyTests {
    @Test("Idle timer disabled only while scoring visibly with preference on")
    func disabledOnlyDuringActiveVisibleScoring() {
        #expect(
            ScreenAwakePolicy.wantsIdleTimerDisabled(
                preferenceEnabled: true, scorerVisible: true, sceneActive: true))
    }

    @Test("Preference off never keeps the screen awake")
    func preferenceOffAlwaysAllowsSleep() {
        #expect(
            !ScreenAwakePolicy.wantsIdleTimerDisabled(
                preferenceEnabled: false, scorerVisible: true, sceneActive: true))
        #expect(
            !ScreenAwakePolicy.wantsIdleTimerDisabled(
                preferenceEnabled: false, scorerVisible: false, sceneActive: false))
    }

    @Test("Leaving the scorer restores normal sleep immediately")
    func hiddenScorerRestoresSleep() {
        #expect(
            !ScreenAwakePolicy.wantsIdleTimerDisabled(
                preferenceEnabled: true, scorerVisible: false, sceneActive: true))
    }

    @Test("Backgrounded or inactive scene restores normal sleep")
    func inactiveSceneRestoresSleep() {
        #expect(
            !ScreenAwakePolicy.wantsIdleTimerDisabled(
                preferenceEnabled: true, scorerVisible: true, sceneActive: false))
        #expect(
            !ScreenAwakePolicy.wantsIdleTimerDisabled(
                preferenceEnabled: false, scorerVisible: false, sceneActive: false))
    }

    @Test("Preference key is the Settings toggle's key")
    func preferenceKeyMatchesSettings() {
        #expect(ScreenAwakePolicy.preferenceKey == "keepScreenAwakeWhileScoring")
    }
}
