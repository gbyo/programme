import Foundation

/// What kind of thing is being attributed to a player.
///
/// This is deliberately coarser than the event payloads: it is the question
/// "which players could legitimately be responsible for this?", and several
/// payloads share one answer.
public enum AttributionCategory: String, Hashable, Sendable, CaseIterable {
    /// A goal, a shot, a shot on goal — anything struck during live play.
    case shot
    /// Assist credit on a goal.
    case assist
    /// The penalty taker.
    case penaltyKick
    /// An own goal: still struck by someone who was on the field.
    case ownGoal
    case corner
    case steal
    case foul
    case offside
    /// A caution or a dismissal.
    case card
    /// Taking over in goal.
    case goalkeeperChange
}

/// The set of players a category may legitimately be attributed to.
public enum AttributionScope: Hashable, Sendable {
    /// Only players currently on the field. The normal case for live play: a
    /// player on the bench did not take that shot.
    case onField
    /// Everyone available to the match, on the field or not. A caution can be
    /// shown to a substitute, and an import or a correction may legitimately
    /// name someone who has already come off.
    case availableRoster

    /// Whether a scope admits a player who is not currently on the field.
    public var admitsBenchPlayers: Bool { self == .availableRoster }
}

/// Programme's rules about who an event can belong to.
///
/// These live here, beside the rest of the soccer knowledge, rather than in the
/// interface. The scoring workspace uses them to make an impossible attribution
/// unreachable; `ValidationEngine` remains the safety net for events that arrive
/// from an import, an edit, or a repaired file.
public enum AttributionEngine {

    public static func scope(for category: AttributionCategory) -> AttributionScope {
        switch category {
        case .shot, .assist, .penaltyKick, .ownGoal, .corner, .steal, .foul, .offside,
            .goalkeeperChange:
            .onField
        case .card:
            // A substitute or a member of the bench can be cautioned, and a
            // dismissal has to be recordable against them.
            .availableRoster
        }
    }

    /// The players a scorer may pick from, in the order they should be offered.
    ///
    /// Dismissed players are never offered: they have left the match. The one
    /// exception is a card, where a second caution is exactly how a dismissal is
    /// recorded, so a player who has only been booked stays available.
    public static func candidates(
        for category: AttributionCategory,
        side: TeamSide = .us,
        context: MatchContext,
        snapshot: MatchSnapshot
    ) -> [PlayerSnapshot] {
        guard side == .us else {
            // Programme does not track an opponent lineup, so the whole opponent
            // roster is offered when the match attributes opponent events at all.
            return context.opponentRoster.sortedByNumber
        }

        let roster = context.roster.activeRoster
        let dismissed = dismissedPlayers(in: snapshot)
        let available = roster.filter { !dismissed.contains($0.id) }

        switch scope(for: category) {
        case .onField:
            let active = snapshot.activeLineup
            return available.filter { active.contains($0.id) }
        case .availableRoster:
            return available
        }
    }

    /// Whether one specific player may be credited with this category right now.
    ///
    /// The armed-player path in the scoring workspace asks this before it lets a
    /// tap become an event.
    public static func allows(
        _ playerID: PlayerID,
        category: AttributionCategory,
        side: TeamSide = .us,
        context: MatchContext,
        snapshot: MatchSnapshot
    ) -> Bool {
        candidates(for: category, side: side, context: context, snapshot: snapshot)
            .contains { $0.id == playerID }
    }

    /// The players who may take over in goal: whoever is on the field, with
    /// recognised goalkeepers offered first.
    public static func goalkeeperCandidates(
        context: MatchContext,
        snapshot: MatchSnapshot
    ) -> [PlayerSnapshot] {
        candidates(for: .goalkeeperChange, context: context, snapshot: snapshot)
            .sorted {
                if ($0.position == .goalkeeper) != ($1.position == .goalkeeper) {
                    return $0.position == .goalkeeper
                }
                return ($0.jerseyNumber ?? .max) < ($1.jerseyNumber ?? .max)
            }
    }

    private static func dismissedPlayers(in snapshot: MatchSnapshot) -> Set<PlayerID> {
        Set(snapshot.players.filter { $0.value.redCards > 0 }.keys)
    }
}
