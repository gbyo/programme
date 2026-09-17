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
    case corner
    case steal
    case foul
    case offside
    case card(CardType)
    case goalkeeper
    case ownGoal

    var title: String {
        switch self {
        case .goal(.penaltyKick): "Who scored the penalty?"
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

    /// Cards and substitutions can involve a player who is no longer on the
    /// field, so those pick from the full roster.
    var picksFromFullRoster: Bool {
        switch self {
        case .card: true
        default: false
        }
    }
}

struct PlayerPrompt: Equatable, Identifiable {
    var id = UUID()
    var action: PendingAction
    var side: TeamSide = .us

    var title: String { action.title }
}
