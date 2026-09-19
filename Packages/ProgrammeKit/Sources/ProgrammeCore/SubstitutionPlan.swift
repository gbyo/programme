import Foundation

/// One substitution the way a scorer thinks about it: *this* player comes off,
/// and *this specific* player comes on for them.
///
/// The recorded event still stores two ordered arrays, because that is what an
/// export and a lineup timeline need. The pair is what the scorer is actually
/// holding in their head between the two taps, and losing it is what made a
/// multi-substitution ambiguous: three players on the left and three on the
/// right do not say who replaced whom.
public struct SubstitutionPair: Identifiable, Hashable, Sendable {
    public var playerOut: PlayerID
    public var playerIn: PlayerID

    /// The outgoing player identifies the pair: a player can only come off once
    /// in one batch, so this is stable and unique within a plan.
    public var id: PlayerID { playerOut }

    public init(playerOut: PlayerID, playerIn: PlayerID) {
        self.playerOut = playerOut
        self.playerIn = playerIn
    }
}

/// A substitution being assembled, before anything is recorded.
///
/// Deliberately a value in ProgrammeCore rather than view state: "who is still
/// available to come off", "who will be on the field afterwards" and "does this
/// still need a goalkeeper" are questions about the match, not about a screen,
/// and they are the same questions on a phone and on an iPad.
///
/// Nothing here touches the live context. A plan is inert until it is flattened
/// into a `SubstitutionEvent` and handed to `MatchEngine`, so abandoning one
/// cannot change a lineup.
public struct SubstitutionPlan: Hashable, Sendable {
    public private(set) var pairs: [SubstitutionPair]
    /// Who holds the gloves once this batch is applied. Only meaningful when the
    /// plan actually takes the current goalkeeper off; the scorer states it
    /// explicitly rather than Programme inferring it from a roster position.
    public private(set) var goalkeeperAfter: PlayerID?

    public init(pairs: [SubstitutionPair] = [], goalkeeperAfter: PlayerID? = nil) {
        self.pairs = pairs
        self.goalkeeperAfter = goalkeeperAfter
    }

    public var isEmpty: Bool { pairs.isEmpty }
    public var count: Int { pairs.count }

    /// The two ordered arrays the event stores. `playersOut[n]` is replaced by
    /// `playersIn[n]`; preserving that order is what lets narration and any
    /// later export recover the relationship.
    public var playersOut: [PlayerID] { pairs.map(\.playerOut) }
    public var playersIn: [PlayerID] { pairs.map(\.playerIn) }

    public var outgoing: Set<PlayerID> { Set(playersOut) }
    public var incoming: Set<PlayerID> { Set(playersIn) }

    public func pair(replacing playerOut: PlayerID) -> SubstitutionPair? {
        pairs.first { $0.playerOut == playerOut }
    }

    // MARK: - Building

    /// States that `playerIn` replaces `playerOut`.
    ///
    /// Assigning to an outgoing player who is already paired revises that pair
    /// **in place**, which is what makes tapping a Ready row to correct it
    /// harmless: the batch keeps its order, so `playersOut[n]` still matches
    /// `playersIn[n]`. An incoming player already used by a different pair is
    /// ignored rather than silently stolen — the candidate lists make that
    /// unreachable, and this is the backstop.
    public mutating func assign(
        out playerOut: PlayerID, in playerIn: PlayerID, currentlyOnField: Set<PlayerID>
    ) {
        guard playerOut != playerIn else { return }
        let existing = pairs.firstIndex { $0.playerOut == playerOut }
        let claimedElsewhere = pairs.contains {
            $0.playerIn == playerIn && $0.playerOut != playerOut
        }
        guard !claimedElsewhere else { return }

        if let existing {
            pairs[existing].playerIn = playerIn
        } else {
            pairs.append(SubstitutionPair(playerOut: playerOut, playerIn: playerIn))
        }
        reconcileGoalkeeper(currentlyOnField: currentlyOnField)
    }

    public mutating func remove(outgoing playerOut: PlayerID, currentlyOnField: Set<PlayerID>) {
        pairs.removeAll { $0.playerOut == playerOut }
        reconcileGoalkeeper(currentlyOnField: currentlyOnField)
    }

    public mutating func setGoalkeeperAfter(_ player: PlayerID?) {
        goalkeeperAfter = player
    }

    /// A goalkeeper choice only survives while the person chosen will still be
    /// on the field. Changing the rest of the batch can invalidate it, and a
    /// stale keeper would be attributed every save for the rest of the match.
    public mutating func reconcileGoalkeeper(currentlyOnField: Set<PlayerID>) {
        guard let keeper = goalkeeperAfter else { return }
        if !onFieldAfter(currentlyOnField: currentlyOnField).contains(keeper) {
            goalkeeperAfter = nil
        }
    }

    // MARK: - Consequences

    /// Who is on the field once every pending pair is applied.
    public func onFieldAfter(currentlyOnField: Set<PlayerID>) -> Set<PlayerID> {
        currentlyOnField.subtracting(outgoing).union(incoming)
    }

    /// Whether Programme still has to be told who is in goal. It does exactly
    /// when the batch takes the current goalkeeper off the field.
    public func requiresGoalkeeperChoice(currentGoalkeeper: PlayerID?) -> Bool {
        guard let currentGoalkeeper else { return false }
        return outgoing.contains(currentGoalkeeper)
    }

    public func isReadyToRecord(currentGoalkeeper: PlayerID?) -> Bool {
        guard !pairs.isEmpty else { return false }
        if requiresGoalkeeperChoice(currentGoalkeeper: currentGoalkeeper) {
            return goalkeeperAfter != nil
        }
        return true
    }

    /// The value to record, which is `nil` unless the goalkeeper actually
    /// changes. Passing a keeper that did not change would open a redundant
    /// goalkeeping interval.
    public func resolvedGoalkeeperAfter(currentGoalkeeper: PlayerID?) -> PlayerID? {
        guard requiresGoalkeeperChoice(currentGoalkeeper: currentGoalkeeper) else { return nil }
        return goalkeeperAfter
    }

    // MARK: - Candidates
    //
    // Always derived from the caller's live lineup state rather than from a
    // roster, so a player who was substituted off earlier and is currently on
    // the bench is offered again wherever the ruleset allows re-entry.

    /// On-field players who have not already been spoken for.
    public func availableOutgoing(from onField: [PlayerSnapshot]) -> [PlayerSnapshot] {
        onField.filter { !outgoing.contains($0.id) }
    }

    /// Bench players who have not already been used by another pending pair.
    ///
    /// `replacing` names the outgoing player currently being chosen for, so a
    /// pair being corrected still offers the player it already holds.
    public func availableIncoming(
        from bench: [PlayerSnapshot], replacing playerOut: PlayerID? = nil
    ) -> [PlayerSnapshot] {
        let claimed = Set(pairs.filter { $0.playerOut != playerOut }.map(\.playerIn))
        return bench.filter { !claimed.contains($0.id) }
    }

    /// Who can take the gloves *afterwards*: whoever is staying on, plus
    /// whoever is coming on. Recognised goalkeepers first, then by jersey
    /// number — and deterministically, since this ordering is shown to a person
    /// who is picking by position on screen.
    public func goalkeeperCandidates(
        onField: [PlayerSnapshot], bench: [PlayerSnapshot]
    ) -> [PlayerSnapshot] {
        let staying = onField.filter { !outgoing.contains($0.id) }
        let arriving = bench.filter { incoming.contains($0.id) }
        return (staying + arriving).sorted { first, second in
            if (first.position == .goalkeeper) != (second.position == .goalkeeper) {
                return first.position == .goalkeeper
            }
            if first.jerseyNumber != second.jerseyNumber {
                return (first.jerseyNumber ?? .max) < (second.jerseyNumber ?? .max)
            }
            return first.displaySurname < second.displaySurname
        }
    }
}
