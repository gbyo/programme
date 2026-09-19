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

    /// A penalty has a taker but no outcome yet. The outcome is a primary fact,
    /// not enrichment: a penalty attempt with an unknown outcome would be a
    /// score that might or might not have happened, so nothing is recorded until
    /// the scorer answers.
    case penaltyOutcome(taker: PlayerRef)

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
        case .choosePlayer, .penaltyOutcome: false
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

    /// What the compact sheet calls itself at this step.
    var title: String {
        switch self {
        case .choosePlayer(let prompt): prompt.title
        case .penaltyOutcome: "What happened?"
        case .assist: "Who assisted?"
        case .shotLocation: "Where was it struck?"
        case .substitution: "Substitution"
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
}

/// An action waiting for the player it belongs to.
enum PendingAction: Equatable {
    case goal(PlayPhase)
    case shot(ShotOutcome)
    /// A penalty *attempt*. The outcome is not known until the scorer says so,
    /// so this never implies a goal.
    case penaltyAttempt
    case corner
    case steal
    case foul
    case offside
    case card(CardType)
    case goalkeeper
    case ownGoal

    var title: String {
        switch self {
        case .penaltyAttempt: "Who took the penalty?"
        case .goal: "Who scored?"
        case .shot(.saved): "Who took the shot?"
        case .shot: "Who took the shot?"
        case .corner: "Who took the corner?"
        case .steal: "Who won the ball?"
        case .foul: "Who committed the foul?"
        case .offside: "Who was offside?"
        case .card(let type): "Who received the \(type.label.lowercased())?"
        case .goalkeeper: "Who is going in goal?"
        case .ownGoal: "Who put it in their own net?"
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
        case .penaltyAttempt: .penaltyKick
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

struct PlayerPrompt: Equatable, Identifiable {
    var id = UUID()
    var action: PendingAction
    var side: TeamSide = .us

    var title: String { action.title }
}
