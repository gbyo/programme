import Foundation
import Testing

@testable import ProgrammeCore

/// The event model behind the live Event Composer.
///
/// The composer records the primary fact the moment the scorer states it, then
/// revises that same event with the enrichment answers. These tests pin the part
/// that matters for correctness: a goal recorded before the assist question is a
/// real, complete, correctly-scored goal, and answering later revises it rather
/// than adding a second one.
struct ComposerFlowTests {

    /// Record `#9 → Goal` before anyone has been asked about an assist.
    private func goalAwaitingAssist() throws -> (MatchFixture, EventID) {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12)
        let effects = try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal,
                    assist: .unidentified)))
        let id = try #require(
            effects.compactMap { effect -> EventID? in
                if case .appendEvent(let event) = effect { return event.id }
                return nil
            }.first)
        return (fixture, id)
    }

    @Test func theGoalCountsImmediatelyEvenThoughTheAssistIsUnanswered() throws {
        let (fixture, _) = try goalAwaitingAssist()

        // The score moved and the scorer was credited before anything was asked.
        #expect(fixture.snapshot.score.us == 1)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).goals == 1)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).shotsOnGoal == 1)
    }

    @Test func anUnansweredAssistIsCollectedForReviewRatherThanLost() throws {
        let (fixture, id) = try goalAwaitingAssist()

        let event = try #require(fixture.context.events.first { $0.id == id })
        #expect(event.awaitsAttribution)
        #expect(fixture.snapshot.needsReviewCount == 1)
        // Nobody has been wrongly credited with an assist.
        #expect(fixture.snapshot.players.values.allSatisfy { $0.assists == 0 })
    }

    @Test func answeringTheAssistRevisesTheSameGoalRatherThanAddingAnother() throws {
        var (fixture, id) = try goalAwaitingAssist()
        let goalsBefore = fixture.context.activeEvents.count

        try fixture.edit(.attribute(id, .assist, .player(ProgrammeSample.williams)))

        #expect(fixture.context.activeEvents.count == goalsBefore, "A second event was created")
        #expect(fixture.snapshot.score.us == 1, "The score double-counted")
        #expect(fixture.snapshot.player(ProgrammeSample.williams).assists == 1)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).goals == 1)
        #expect(fixture.snapshot.needsReviewCount == 0)
    }

    @Test func unassistedSettlesTheGoalWithoutCreditingAnyone() throws {
        var (fixture, id) = try goalAwaitingAssist()
        var shot = try #require(shotPayload(of: id, in: fixture))
        shot.assist = nil

        try fixture.edit(.replacePayload(id, .shot(shot), summary: "Recorded as unassisted"))

        #expect(fixture.snapshot.score.us == 1)
        #expect(fixture.snapshot.needsReviewCount == 0, "Unassisted still reads as unresolved")
        #expect(fixture.snapshot.players.values.allSatisfy { $0.assists == 0 })
    }

    @Test func theGoalSurvivesAnAssistQuestionThatIsNeverAnswered() throws {
        var (fixture, id) = try goalAwaitingAssist()

        // The scorer looked back at the pitch and carried on scoring the match.
        fixture.seek(period: 1, minutes: 20)
        try fixture.perform(.recordCorner(side: .us, player: .player(ProgrammeSample.williams)))
        try fixture.completePeriod(1)

        let event = try #require(fixture.context.events.first { $0.id == id })
        #expect(event.isActive)
        #expect(fixture.snapshot.score.us == 1)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).goals == 1)
        // Still exactly one thing to settle, and it is this goal.
        #expect(fixture.snapshot.eventsNeedingReview.map(\.id) == [id])
    }

    @Test func aShotIsRecordedBeforeItsOptionalLocationAndKeepsItsOutcome() throws {
        var fixture = MatchFixture(profile: .advanced)
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 8)

        let effects = try fixture.perform(
            .recordShot(
                ShotEvent(side: .us, shooter: .player(ProgrammeSample.sanders), outcome: .saved)))
        let id = try #require(
            effects.compactMap { effect -> EventID? in
                if case .appendEvent(let event) = effect { return event.id }
                return nil
            }.first)

        // The shot counts with no location at all.
        #expect(fixture.snapshot.player(ProgrammeSample.sanders).shots == 1)
        #expect(fixture.snapshot.player(ProgrammeSample.sanders).shotsOnGoal == 1)
        #expect(shotPayload(of: id, in: fixture)?.location == nil)

        var shot = try #require(shotPayload(of: id, in: fixture))
        shot.location = PitchPoint(x: 0.8, y: 0.5)
        try fixture.edit(.replacePayload(id, .shot(shot), summary: "Shot location added"))

        #expect(fixture.snapshot.player(ProgrammeSample.sanders).shots == 1, "The shot was counted twice")
        #expect(shotPayload(of: id, in: fixture)?.location != nil)
        #expect(shotPayload(of: id, in: fixture)?.outcome == .saved)
    }

    @Test func aPenaltyIsOnlyRecordedOnceItsOutcomeIsKnown() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 30)

        // A saved penalty is an attempt, not a goal, and never an assist.
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .saved,
                    phase: .penaltyKick)))

        #expect(fixture.snapshot.score.us == 0)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).penaltyAttempts == 1)
        #expect(fixture.snapshot.player(ProgrammeSample.carter).penaltyGoals == 0)
        #expect(fixture.snapshot.needsReviewCount == 0)
    }

    private func shotPayload(of id: EventID, in fixture: MatchFixture) -> ShotEvent? {
        guard let event = fixture.context.events.first(where: { $0.id == id }),
            case .shot(let shot) = event.payload
        else { return nil }
        return shot
    }
}
