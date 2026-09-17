import Foundation
import ProgrammeCore

/// What the centre of the scoring workspace is showing.
///
/// Event entry happens here rather than in a sheet. A modal over a live match
/// hides the score and the clock at exactly the moment the scorer needs them,
/// and it puts a dismiss gesture between them and the next play.
enum LiveStage: Equatable {
    case pitch
    case choosePlayer(PlayerPrompt)
    case chooseAssist(ShotEvent)
    case penaltyOutcome(PlayerRef)
    case placeShotLocation(ShotEvent)
    case substitution

    var isPitch: Bool { self == .pitch }
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
