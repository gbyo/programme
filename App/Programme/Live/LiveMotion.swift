import SwiftUI

/// Short, semantic motion used by the live scorer.
///
/// The durations describe the meaning of a change rather than a particular
/// control. Composer questions are a workflow; notices are temporary status;
/// everything else here is an immediate local acknowledgement.
enum LiveMotion {
    static let acknowledgement = Animation.snappy(duration: 0.14)
    static let workflow = Animation.snappy(duration: 0.17)
    static let temporaryStatus = Animation.snappy(duration: 0.22)

    static func acknowledgementTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.animation(acknowledgement)
    }

    static func temporaryStatusTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .move(edge: .bottom)
            .combined(with: .opacity)
            .animation(temporaryStatus)
    }

    static func statusReplacementTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.animation(temporaryStatus)
    }

    static func composerPresenceTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.animation(acknowledgement)
    }

    static func composerStepTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        )
        .animation(workflow)
    }
}
