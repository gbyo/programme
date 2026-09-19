import Foundation
import Testing

@testable import ProgrammeCore

/// The pair-aware substitution draft.
///
/// A substitution is one relationship — this player off, that player on — and
/// a batch is several of them. These tests pin the part the interface depends
/// on: that a pair is never ambiguous, that the batch flattens into the ordered
/// arrays the event stores, and that the goalkeeper question cannot be answered
/// with someone who will not be on the field.
struct SubstitutionPlanTests {

    private let trotter = ProgrammeSample.trotter
    private let kinard = ProgrammeSample.playerID("Noah.Kinard")
    private let ferrer = ProgrammeSample.playerID("Luis.Ferrer")
    private let hollis = ProgrammeSample.playerID("Kade.Hollis")
    private let keeper = ProgrammeSample.keeper
    private let backupKeeper = ProgrammeSample.backupKeeper

    private var onField: [PlayerSnapshot] {
        ProgrammeSample.startingEleven.compactMap { ProgrammeSample.roster[$0] }
    }

    private var bench: [PlayerSnapshot] {
        let starting = Set(ProgrammeSample.startingEleven)
        return ProgrammeSample.roster.sortedByNumber.filter { !starting.contains($0.id) }
    }

    private var onFieldIDs: Set<PlayerID> { Set(ProgrammeSample.startingEleven) }

    private func plan(_ pairs: [(PlayerID, PlayerID)]) -> SubstitutionPlan {
        var plan = SubstitutionPlan()
        for (out, incoming) in pairs {
            plan.assign(out: out, in: incoming, currentlyOnField: onFieldIDs)
        }
        return plan
    }

    // MARK: - Pairs, and the arrays they become

    @Test func aBatchFlattensIntoOrderedArraysThatStayPaired() {
        let plan = plan([(trotter, ferrer), (kinard, hollis)])

        #expect(plan.playersOut == [trotter, kinard])
        #expect(plan.playersIn == [ferrer, hollis])
        // The whole point: index n on one side is index n on the other.
        for (index, pair) in plan.pairs.enumerated() {
            #expect(plan.playersOut[index] == pair.playerOut)
            #expect(plan.playersIn[index] == pair.playerIn)
        }
    }

    @Test func aPairedPlayerDisappearsFromBothSetsOfChoices() {
        let plan = plan([(trotter, ferrer)])

        #expect(plan.availableOutgoing(from: onField).contains { $0.id == trotter } == false)
        #expect(plan.availableIncoming(from: bench).contains { $0.id == ferrer } == false)
        // Everyone else is untouched.
        #expect(plan.availableOutgoing(from: onField).count == onField.count - 1)
        #expect(plan.availableIncoming(from: bench).count == bench.count - 1)
    }

    @Test func correctingAPairKeepsItsPlaceInTheBatch() {
        var plan = plan([(trotter, ferrer), (kinard, hollis)])

        plan.assign(out: trotter, in: ProgrammeSample.playerID("Theo.Nance"), currentlyOnField: onFieldIDs)

        #expect(plan.count == 2, "Correcting a pair added a second one")
        #expect(plan.playersOut == [trotter, kinard], "The batch order moved")
        #expect(plan.playersIn.first == ProgrammeSample.playerID("Theo.Nance"))
        // The player who was displaced is available again.
        #expect(plan.availableIncoming(from: bench).contains { $0.id == ferrer })
    }

    @Test func aPairBeingCorrectedStillOffersThePlayerItAlreadyHolds() {
        let plan = plan([(trotter, ferrer), (kinard, hollis)])

        let candidates = plan.availableIncoming(from: bench, replacing: trotter)
        #expect(candidates.contains { $0.id == ferrer })
        #expect(candidates.contains { $0.id == hollis } == false, "Another pair's player was offered")
    }

    @Test func anIncomingPlayerCannotBeStolenByASecondPair() {
        var plan = plan([(trotter, ferrer)])

        plan.assign(out: kinard, in: ferrer, currentlyOnField: onFieldIDs)

        #expect(plan.count == 1)
        #expect(plan.playersIn == [ferrer])
    }

    @Test func removingAPairReleasesBothPlayers() {
        var plan = plan([(trotter, ferrer), (kinard, hollis)])

        plan.remove(outgoing: trotter, currentlyOnField: onFieldIDs)

        #expect(plan.playersOut == [kinard])
        #expect(plan.availableOutgoing(from: onField).contains { $0.id == trotter })
        #expect(plan.availableIncoming(from: bench).contains { $0.id == ferrer })
    }

    // MARK: - Goalkeeper

    @Test func thePlanOnlyAsksAboutTheGoalkeeperWhenTheGoalkeeperIsComingOff() {
        let ordinary = plan([(trotter, ferrer)])
        #expect(ordinary.requiresGoalkeeperChoice(currentGoalkeeper: keeper) == false)
        #expect(ordinary.isReadyToRecord(currentGoalkeeper: keeper))

        let keeperComingOff = plan([(keeper, backupKeeper)])
        #expect(keeperComingOff.requiresGoalkeeperChoice(currentGoalkeeper: keeper))
        #expect(
            keeperComingOff.isReadyToRecord(currentGoalkeeper: keeper) == false,
            "The batch committed without saying who is in goal")
    }

    @Test func goalkeeperCandidatesAreWhoWillActuallyBeOnTheFieldAfterwards() {
        var plan = plan([(keeper, backupKeeper), (trotter, ferrer)])
        plan.setGoalkeeperAfter(backupKeeper)

        let candidates = plan.goalkeeperCandidates(onField: onField, bench: bench)
        let ids = Set(candidates.map(\.id))

        #expect(ids.contains(backupKeeper), "A player coming on was not offered")
        #expect(ids.contains(ferrer), "A player coming on was not offered")
        #expect(ids.contains(keeper) == false, "A player coming off was offered")
        #expect(ids.contains(trotter) == false, "A player coming off was offered")
        #expect(ids == plan.onFieldAfter(currentlyOnField: onFieldIDs))
    }

    @Test func recognisedGoalkeepersAreOfferedFirstAndTheRestByJerseyNumber() {
        var plan = SubstitutionPlan()
        plan.assign(out: keeper, in: backupKeeper, currentlyOnField: onFieldIDs)

        let candidates = plan.goalkeeperCandidates(onField: onField, bench: bench)

        #expect(candidates.first?.id == backupKeeper, "The recognised keeper was not first")
        let outfield = candidates.dropFirst().compactMap(\.jerseyNumber)
        #expect(outfield == outfield.sorted(), "Outfield candidates are not in jersey order")
    }

    @Test func aGoalkeeperChoiceIsClearedWhenALaterPairTakesThatPlayerOff() {
        var plan = SubstitutionPlan()
        plan.assign(out: keeper, in: backupKeeper, currentlyOnField: onFieldIDs)
        plan.setGoalkeeperAfter(trotter)
        #expect(plan.goalkeeperAfter == trotter)

        // Now Trotter comes off too, so the answer is no longer possible.
        plan.assign(out: trotter, in: ferrer, currentlyOnField: onFieldIDs)

        #expect(plan.goalkeeperAfter == nil, "A goalkeeper who is leaving stayed selected")
        #expect(plan.isReadyToRecord(currentGoalkeeper: keeper) == false)
    }

    @Test func aGoalkeeperIsOnlyRecordedWhenItActuallyChanges() {
        var ordinary = plan([(trotter, ferrer)])
        ordinary.setGoalkeeperAfter(ProgrammeSample.playerID("Marcus.Odom"))
        #expect(
            ordinary.resolvedGoalkeeperAfter(currentGoalkeeper: keeper) == nil,
            "A redundant goalkeeper interval would be opened")

        var replacing = plan([(keeper, backupKeeper)])
        replacing.setGoalkeeperAfter(backupKeeper)
        #expect(replacing.resolvedGoalkeeperAfter(currentGoalkeeper: keeper) == backupKeeper)
    }

    // MARK: - Re-entry

    @Test("Candidates come from the live lineup, so high-school re-entry keeps working")
    func reEntryIsOfferedWhenTheRulesAllowIt() throws {
        var fixture = MatchFixture(rules: .highSchool)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(
            .substitute(SubstitutionEvent(side: .us, playersOut: [trotter], playersIn: [ferrer])))

        // The bench is derived from where players are *now*, not from who started.
        let active = fixture.snapshot.activeLineup
        let benchNow = ProgrammeSample.roster.activeRoster.filter { !active.contains($0.id) }
        let plan = SubstitutionPlan()

        #expect(
            plan.availableIncoming(from: benchNow).contains { $0.id == trotter },
            "A player who came off is not offered to come back on")

        // And the engine still accepts it under high-school rules.
        fixture.seek(period: 1, minutes: 30)
        try fixture.perform(
            .substitute(SubstitutionEvent(side: .us, playersOut: [ferrer], playersIn: [trotter])))
        #expect(fixture.issues.contains { $0.kind == .reEntryViolation } == false)
    }

    // MARK: - Nothing moves until it is recorded

    @Test func aDraftIsInertUntilItIsHandedToTheEngine() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 18)
        let before = fixture.snapshot.activeLineup

        var plan = SubstitutionPlan()
        plan.assign(out: trotter, in: ferrer, currentlyOnField: before)
        plan.assign(out: kinard, in: hollis, currentlyOnField: before)

        #expect(fixture.snapshot.activeLineup == before, "Assembling a draft changed the lineup")

        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: plan.playersOut, playersIn: plan.playersIn,
                    goalkeeperAfter: plan.resolvedGoalkeeperAfter(
                        currentGoalkeeper: fixture.snapshot.activeGoalkeeper))))

        #expect(fixture.snapshot.activeLineup == plan.onFieldAfter(currentlyOnField: before))
        // One event, one timestamp, for the whole batch.
        let subs = fixture.events {
            if case .substitution = $0.payload { return true } else { return false }
        }
        #expect(subs.count == 1)
        #expect(subs.first?.payload.side == .us)
    }
}

/// How a batched substitution reads.
///
/// The event stores two arrays, but the arrays are ordered pairs, so the
/// narration must say who replaced whom rather than listing two groups and
/// leaving the reader to guess.
struct SubstitutionNarrationTests {

    private func describe(_ sub: SubstitutionEvent) throws -> EventDescription {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 22)
        try fixture.perform(.substitute(sub))
        let event = try #require(fixture.lastEvent)
        return MatchNarrator.describe(event, context: fixture.context)
    }

    @Test func aMultiSubstitutionReadsAsIndividualRelationships() throws {
        let description = try describe(
            SubstitutionEvent(
                side: .us,
                playersOut: [ProgrammeSample.trotter, ProgrammeSample.playerID("Noah.Kinard")],
                playersIn: [
                    ProgrammeSample.playerID("Luis.Ferrer"), ProgrammeSample.playerID("Kade.Hollis"),
                ]))

        #expect(description.detail == "#13 Ferrer for #11 Trotter; #14 Hollis for #6 Kinard")
    }

    @Test func oneSubstitutionStillReadsAsOnePhrase() throws {
        let description = try describe(
            SubstitutionEvent(
                side: .us,
                playersOut: [ProgrammeSample.trotter],
                playersIn: [ProgrammeSample.playerID("Luis.Ferrer")]))

        #expect(description.detail == "#13 Ferrer for #11 Trotter")
    }

    @Test("Unequal counts stay legal and narrate honestly")
    func playingShortIsNotForcedIntoAPair() throws {
        let description = try describe(
            SubstitutionEvent(
                side: .us,
                playersOut: [ProgrammeSample.trotter, ProgrammeSample.playerID("Noah.Kinard")],
                playersIn: [ProgrammeSample.playerID("Luis.Ferrer")]))

        #expect(description.detail == "#13 Ferrer for #11 Trotter; #6 Kinard off")
    }

    @Test func aGoalkeeperChangeIsStillCalledOutSeparately() throws {
        let description = try describe(
            SubstitutionEvent(
                side: .us,
                playersOut: [ProgrammeSample.keeper],
                playersIn: [ProgrammeSample.backupKeeper],
                goalkeeperAfter: ProgrammeSample.backupKeeper))

        #expect(description.detail == "#22 Brannon for #1 Whitfield")
        #expect(description.secondaryDetail == "#22 Brannon in goal")
    }
}
