import Foundation
import ProgrammeCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Read path for the keep-awake preference.
///
/// Mirrors `HapticPreferences`: the Settings toggle defaults to on, so a
/// never-stored value reads as enabled rather than as `bool(forKey:)` false.
enum ScreenAwakePreferences {
    static var isEnabled: Bool {
        guard
            UserDefaults.standard.object(forKey: ScreenAwakePolicy.preferenceKey) != nil
        else { return true }
        return UserDefaults.standard.bool(forKey: ScreenAwakePolicy.preferenceKey)
    }
}

/// Seam for the single app-wide idle-timer assignment. Production writes
/// through to `UIApplication`; previews and tests substitute a recorder.
@MainActor
protocol IdleTimerControl {
    func setIdleTimerDisabled(_ disabled: Bool)
}

struct SystemIdleTimerControl: IdleTimerControl {
    func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

/// Central owner of the app-wide idle-timer setting.
///
/// `UIApplication.isIdleTimerDisabled` is global state: any view writing it
/// directly can leave the display awake after its own dismissal. Every
/// scorer-lifecycle event funnels through this one controller — owned by
/// `AppModel` — which recomputes `ScreenAwakePolicy` and applies the result,
/// so no view can leave the timer disabled behind it.
@MainActor
final class ScreenAwakeController {
    var preferenceEnabled: Bool
    var isScorerVisible = false
    var isSceneActive = true

    private let control: any IdleTimerControl

    init(
        control: any IdleTimerControl = SystemIdleTimerControl(),
        preferenceEnabled: Bool = ScreenAwakePreferences.isEnabled
    ) {
        self.control = control
        self.preferenceEnabled = preferenceEnabled
    }

    var idleTimerShouldBeDisabled: Bool {
        ScreenAwakePolicy.wantsIdleTimerDisabled(
            preferenceEnabled: preferenceEnabled,
            scorerVisible: isScorerVisible,
            sceneActive: isSceneActive)
    }

    /// Recompute the policy and apply it. Call after every lifecycle event:
    /// scorer appear/disappear, preference change, scene activation change,
    /// and session close.
    func refresh() {
        control.setIdleTimerDisabled(idleTimerShouldBeDisabled)
    }
}
