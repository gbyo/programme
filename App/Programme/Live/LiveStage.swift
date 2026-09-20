import Foundation
import ProgrammeCore

/// The Event Composer.
///
/// Programme's middle area is not a dashboard. It exists for one job: to ask the
/// scorer for information that is genuinely missing from an event, and to stop
/// asking the moment nothing is missing. Everything passive — team totals, player
/// lines, goalkeeping — lives in the inspector.
///
/// The composer is deliberately built around a fact that is already recorded
/// wherever that is safe. A goal is a goal the instant the scorer says so: the
/// event is written, the score moves and the journal is flushed *before* the
/// composer asks who assisted. The enrichment answer then revises that same
/// event. A scorer who looks up at the pitch and never answers has still
/// recorded the goal; the unanswered part shows up in Review.
enum ComposerStep: Equatable {
    /// Who does this event belong to? Nothing is recorded yet — without a player
    /// there is no event to record.
    case choosePlayer(PlayerPrompt)

    /// A shot has a shooter but no outcome yet. The outcome is a primary fact,
    /// not enrichment: a shot whose outcome is unknown may or may not have been
    /// a goal, so nothing is recorded until the scorer answers.
    ///
    /// One step serves an open-play shot and a penalty kick. The question is the
    /// same — *what happened?* — and only the honest set of answers differs,
    /// which is what `ShotOutcomeContext` carries.
    case shotOutcome(shooter: PlayerRef, side: TeamSide, context: ShotOutcomeContext)

    /// The goal is **already recorded** with an unresolved assist. This step
    /// revises it.
    case assist(goal: EventID, scorerName: String, side: TeamSide)

    /// The shot is **already recorded** without a location. This step revises it,
    /// and skipping costs nothing.
    case shotLocation(shot: EventID, shooterName: String, outcome: ShotOutcome)

    /// Its own focused task rather than an event to complete, but it belongs to
    /// the same workspace and the same presentation rules.
    case substitution

    /// Whether abandoning this step would lose a fact. Steps that revise an
    /// already-recorded event are safe to walk away from.
    var isSafeToAbandon: Bool {
        switch self {
        case .assist, .shotLocation, .substitution: true
        case .choosePlayer, .shotOutcome: false
        }
    }

    /// Whether this step supplies its own `NavigationStack` and navigation
    /// chrome. A step that is a multi-screen flow does; a step that is a single
    /// question takes the composer sheet's.
    var providesOwnNavigation: Bool {
        switch self {
        case .substitution: true
        default: false
        }
    }

    /// Whether a compact-sheet step supplies the sheet's semantic actions
    /// itself instead of using the composer's generic Done affordance.
    var ownsSheetActions: Bool {
        switch self {
        case .shotLocation: true
        default: false
        }
    }

    /// What the compact sheet calls itself at this step.
    var title: String {
        switch self {
        case .choosePlayer(let prompt): prompt.title
        case .shotOutcome: "What happened?"
        case .assist: "Who assisted?"
        case .shotLocation: "Shot Location"
        case .substitution: "Substitution"
        }
    }

    /// Stable identity for the visible question.
    ///
    /// This is deliberately semantic rather than the `UUID` carried by
    /// `PlayerPrompt`. It lets the view replace one question with another while
    /// preserving state within the active question, without using an
    /// identity-resetting `UUID()` hack.
    var transitionID: String {
        switch self {
        case .choosePlayer(let prompt):
            "choose-player-\(prompt.side.rawValue)-\(prompt.action.transitionID)"
        case .shotOutcome(_, let side, let context):
            "shot-outcome-\(side.rawValue)-\(context.label)"
        case .assist(let goalID, _, _):
            "assist-\(goalID)"
        case .shotLocation(let shotID, _, _):
            "shot-location-\(shotID)"
        case .substitution:
            "substitution"
        }
    }
}

/// The composer's whole state: one optional step.
///
/// `nil` means the workspace has nothing to ask, which on a constrained layout
/// means it gives its space back to the lineup and on a compact one means the
/// sheet is not presented at all.
struct EventComposer: Equatable {
    var step: ComposerStep?

    var isComposing: Bool { step != nil }

    static let idle = EventComposer(step: nil)

    mutating func ask(_ step: ComposerStep) { self.step = step }
    mutating func finish() { step = nil }

    /// Offer optional location enrichment for a shot that is already recorded.
    ///
    /// This is shared by ordinary shots and by goals after their assist question,
    /// so the profile policy cannot drift between those two paths.
    mutating func offerShotLocation(
        shot: EventID,
        shooterName: String,
        outcome: ShotOutcome,
        side: TeamSide,
        profile: StatProfile
    ) {
        guard profile.prompts.shotLocation, side == .us else {
            finish()
            return
        }
        ask(.shotLocation(shot: shot, shooterName: shooterName, outcome: outcome))
    }
}

/// An action waiting for the player it belongs to.
enum PendingAction: Equatable {
    case goal(PlayPhase)

    /// A shot whose outcome the scorer has not stated yet.
    ///
    /// This is what tapping **Shot** means. Programme knows an attempt is being
    /// recorded and still needs the shooter, the outcome, or both; it does not
    /// know that the ball missed. Nothing reaches the event log until both
    /// facts exist.
    ///
    /// A penalty kick is the same intent with a different phase, which is why
    /// there is no separate penalty case: *who took it → what happened* is one
    /// flow, and the phase decides the wording and which outcomes are offered.
    case shotAttempt(PlayPhase)

    /// A shot whose outcome is already settled by the action that started it.
    ///
    /// The opponent's one-tap Shot in Our Team mode is the only thing that
    /// produces one — see `LiveMatchView.handleOpponent`, which explains why
    /// that tap stays a single tap.
    case shot(ShotOutcome)

    case corner
    case steal
    case foul
    case offside
    case card(CardType)
    case goalkeeper
    case ownGoal

    var title: String {
        switch self {
        case .goal: "Who scored?"
        case .shotAttempt(.penaltyKick): "Who took the penalty?"
        case .shotAttempt, .shot: "Who took the shot?"
        case .corner: "Who took the corner?"
        case .steal: "Who won the ball?"
        case .foul: "Who committed the foul?"
        case .offside: "Who was offside?"
        case .card(let type): "Who received the \(type.label.lowercased())?"
        case .goalkeeper: "Who is going in goal?"
        case .ownGoal: "Who put it in their own net?"
        }
    }

    /// Stable semantic identity used only by Composer presentation.
    var transitionID: String {
        switch self {
        case .goal(let phase): "goal-\(phase.rawValue)"
        case .shotAttempt(let phase): "shot-attempt-\(phase.rawValue)"
        case .shot(let outcome): "shot-\(outcome.rawValue)"
        case .corner: "corner"
        case .steal: "steal"
        case .foul: "foul"
        case .offside: "offside"
        case .card(let type): "card-\(type.rawValue)"
        case .goalkeeper: "goalkeeper"
        case .ownGoal: "own-goal"
        }
    }

    /// Whether "Player unknown" is offered. It always is for things that happen
    /// in open play, because the scorer must be able to keep watching.
    var allowsUnknown: Bool {
        switch self {
        case .goalkeeper: false
        default: true
        }
    }

    /// The domain question "who could this belong to?". ProgrammeCore answers it;
    /// the interface only asks.
    var attributionCategory: AttributionCategory {
        switch self {
        case .goal, .shot: .shot
        case .shotAttempt(let phase): phase == .penaltyKick ? .penaltyKick : .shot
        case .ownGoal: .ownGoal
        case .corner: .corner
        case .steal: .steal
        case .foul: .foul
        case .offside: .offside
        case .card: .card
        case .goalkeeper: .goalkeeperChange
        }
    }
}

/// Which kind of shot the outcome question is being asked about.
///
/// Programme asks one question of every unresolved shot — *what happened?* — and
/// the only thing that varies is the honest set of answers. Nobody blocks a
/// penalty kick before it reaches the keeper, and a penalty that misses the frame
/// is "missed" rather than "off target". Carrying that as a case here is what
/// lets open play and penalties share a single outcome stage instead of two views
/// drifting apart with duplicated strings.
enum ShotOutcomeContext: Equatable {
    case openPlay
    case penaltyKick

    init(phase: PlayPhase) {
        self = phase == .penaltyKick ? .penaltyKick : .openPlay
    }

    /// The phase the resulting `ShotEvent` is recorded with.
    var phase: PlayPhase {
        switch self {
        case .openPlay: .openPlay
        case .penaltyKick: .penaltyKick
        }
    }

    /// What the stage says it is asking about, beside the shooter's name.
    var label: String {
        switch self {
        case .openPlay: "Shot"
        case .penaltyKick: "Penalty kick"
        }
    }

    /// The outcomes worth offering, in the order they are offered. Goal is first
    /// because it is the one the scorer is most likely to be reaching for in a
    /// hurry, not because it is the default — there is no default.
    var choices: [ShotOutcomeChoice] {
        switch self {
        case .openPlay:
            [
                ShotOutcomeChoice(.goal, "Goal", "soccerball.inverse"),
                ShotOutcomeChoice(.saved, "Saved", "hand.raised.fill"),
                ShotOutcomeChoice(.offTarget, "Off Target", "arrow.up.forward"),
                ShotOutcomeChoice(.blocked, "Blocked", "shield"),
                ShotOutcomeChoice(.woodwork, "Post or Crossbar", "diamond"),
            ]
        case .penaltyKick:
            // Deliberately no Blocked: a penalty is struck with every outfield
            // player behind the ball, so there is nobody there to block it.
            [
                ShotOutcomeChoice(.goal, "Goal", "soccerball.inverse"),
                ShotOutcomeChoice(.saved, "Saved", "hand.raised.fill"),
                ShotOutcomeChoice(.offTarget, "Missed", "arrow.up.forward"),
                ShotOutcomeChoice(.woodwork, "Post or Crossbar", "diamond"),
            ]
        }
    }
}

/// One answer to *what happened?*: a domain `ShotOutcome` plus the words and
/// symbol Programme uses for it in this context.
struct ShotOutcomeChoice: Identifiable, Equatable {
    let outcome: ShotOutcome
    let title: String
    let symbolName: String

    init(_ outcome: ShotOutcome, _ title: String, _ symbolName: String) {
        self.outcome = outcome
        self.title = title
        self.symbolName = symbolName
    }

    var id: String { outcome.rawValue }
    var isGoal: Bool { outcome.isGoal }
}

struct PlayerPrompt: Equatable, Identifiable {
    var id = UUID()
    var action: PendingAction
    var side: TeamSide = .us

    var title: String { action.title }
}
