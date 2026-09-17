import ProgrammeCore
import SwiftUI
import TipKit

/// Tips are used sparingly and only for things that are genuinely not obvious
/// from the interface. Programme is understandable without any of them, and none
/// of them appears during play.

/// Several players can go off and come on in one pass.
struct MultiSubstitutionTip: Tip {
    static let didOpenSubstitution = Event(id: "programme.substitution.opened")

    var title: Text { Text("Make several substitutions at once") }
    var message: Text? {
        Text("Tap every player coming off, then every player coming on, and commit them together. They are all recorded at the same match time.")
    }
    var image: Image? { Image(systemName: "arrow.left.arrow.right") }

    var rules: [Rule] {
        #Rule(Self.didOpenSubstitution) { $0.donations.count >= 2 }
    }
}

/// Correcting the time of an event is the fix for the most common scoring
/// mistake, and it is not discoverable from the log row alone.
struct CorrectEventTimeTip: Tip {
    static let didUndo = Event(id: "programme.undo.used")

    var title: Text { Text("Got the time wrong?") }
    var message: Text? {
        Text("Tap any event in the log to change its time. Programme recalculates every player's minutes from the corrected time — you never repair totals by hand.")
    }
    var image: Image? { Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90") }

    var rules: [Rule] {
        #Rule(Self.didUndo) { $0.donations.count >= 1 }
    }
}

/// The distinction the whole application is built around.
struct CompletenessTip: Tip {
    var title: Text { Text("Not tracked is not zero") }
    var message: Text? {
        Text("Categories this match wasn't recording stay unknown in season totals and exports, instead of being published as zeros.")
    }
    var image: Image? { Image(systemName: "minus.circle") }
}

/// The scorer does not have to stop watching the match to identify a player.
struct UnknownPlayerTip: Tip {
    var title: Text { Text("Don't know the number?") }
    var message: Text? {
        Text("Choose “Player Unknown”. The event is recorded straight away and collected under Review, so you can keep watching play and settle it at halftime.")
    }
    var image: Image? { Image(systemName: "questionmark.circle") }
}
