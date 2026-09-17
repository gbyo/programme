import Foundation
import Testing

@testable import ProgrammeCore

@Suite("Validation catches incoherent matches without interrupting scoring")
struct ValidationTests {

    @Test("Starting with twelve players is refused")
    func tooManyInStartingLineup() throws {
        var fixture = MatchFixture()
        let twelve = ProgrammeSample.startingEleven + [ProgrammeSample.ridgeway]
        #expect(throws: MatchCommandError.tooManyPlayers(attempted: 12, maximum: 11)) {
            try fixture.perform(
                .setLineup(LineupEvent(side: .us, onField: twelve, goalkeeper: ProgrammeSample.keeper)))
        }
    }

    @Test("Starting with too few players is refused")
    func tooFewInStartingLineup() throws {
        var fixture = MatchFixture()
        let six = Array(ProgrammeSample.startingEleven.prefix(6))
        #expect(throws: MatchCommandError.lineupTooSmall(attempted: 6, minimum: 7)) {
            try fixture.perform(
                .setLineup(LineupEvent(side: .us, onField: six, goalkeeper: ProgrammeSample.keeper)))
        }
    }

    @Test("A goalkeeper has to be one of the players on the field")
    func goalkeeperMustBeInLineup() throws {
        var fixture = MatchFixture()
        #expect(throws: MatchCommandError.goalkeeperNotInLineup(ProgrammeSample.backupKeeper)) {
            try fixture.perform(
                .setLineup(
                    LineupEvent(
                        side: .us, onField: ProgrammeSample.startingEleven,
                        goalkeeper: ProgrammeSample.backupKeeper)))
        }
    }

    @Test("Substituting in a player who is already on the field is refused")
    func duplicateSubstitutionRefused() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        #expect(throws: MatchCommandError.playerAlreadyOnField(ProgrammeSample.carter)) {
            try fixture.perform(
                .substitute(
                    SubstitutionEvent(
                        side: .us, playersOut: [ProgrammeSample.mabry], playersIn: [ProgrammeSample.carter])))
        }
    }

    @Test("Substituting out a player who is on the bench is refused")
    func substitutingOutBenchPlayerRefused() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        #expect(throws: MatchCommandError.playerNotOnField(ProgrammeSample.ridgeway)) {
            try fixture.perform(
                .substitute(
                    SubstitutionEvent(
                        side: .us, playersOut: [ProgrammeSample.ridgeway],
                        playersIn: [ProgrammeSample.playerID("Theo.Nance")])))
        }
    }

    @Test("A substitution that would overfill the field is refused")
    func oversizedSubstitutionRefused() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        #expect(throws: MatchCommandError.tooManyPlayers(attempted: 12, maximum: 11)) {
            try fixture.perform(
                .substitute(
                    SubstitutionEvent(
                        side: .us, playersOut: [ProgrammeSample.mabry],
                        playersIn: [ProgrammeSample.ridgeway, ProgrammeSample.playerID("Theo.Nance")])))
        }
    }

    @Test("An event credited to a benched player is flagged, not blocked")
    func eventByBenchedPlayerIsFlagged() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        try fixture.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.mabry], playersIn: [ProgrammeSample.ridgeway])))
        fixture.seek(period: 1, minutes: 25)
        // Recording this succeeds — the scorer is never blocked mid-play.
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.mabry), outcome: .offTarget)))

        let issues = fixture.issues
        #expect(issues.contains { $0.kind == .eventByInactivePlayer })
        #expect(issues.blocking.isEmpty)
        // The shot still counts; the scorer decides what to do about it.
        #expect(fixture.snapshot.player(ProgrammeSample.mabry).shots == 1)
    }

    @Test("A goal assisted by its own scorer must be resolved before finalizing")
    func selfAssistIsBlocking() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 10)
        try fixture.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal,
                    assist: .player(ProgrammeSample.carter))))

        let issues = fixture.issues
        #expect(issues.contains { $0.kind == .selfAssist })
        #expect(issues.canFinalizeCleanly == false)
    }

    @Test("Playing a player short without a red card is surfaced for review")
    func tooFewActiveIsFlagged() throws {
        var fixture = MatchFixture()
        let ten = Array(ProgrammeSample.startingEleven.prefix(10))
        try fixture.startMatch(lineup: ten)
        fixture.seek(period: 1, minutes: 5)

        let issues = fixture.issues
        #expect(issues.contains { $0.kind == .tooFewActive })
        #expect(issues.first { $0.kind == .tooFewActive }?.severity == .review)
    }

    @Test("An unattributed event becomes a review item and blocks nothing")
    func unknownPlayerIsReviewNotBlocking() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 31, seconds: 48)
        try fixture.perform(.recordShot(ShotEvent(side: .us, shooter: .unidentified, outcome: .saved)))

        let snapshot = fixture.snapshot
        #expect(snapshot.needsReviewCount == 1)
        #expect(fixture.issues.contains { $0.kind == .unresolvedAttribution })
        #expect(fixture.issues.blocking.isEmpty)
        #expect(snapshot.completeness(.shots) == .needsReview)
    }

    @Test("Resolving an unknown player revises the event rather than adding another")
    func resolvingUnknownPlayerRevisesEvent() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 31, seconds: 48)
        try fixture.perform(.recordShot(ShotEvent(side: .us, shooter: .unidentified, outcome: .saved)))
        let event = try #require(fixture.lastEvent)
        let countBefore = fixture.context.activeEvents.count

        try fixture.edit(.attribute(event.id, .primary, .player(ProgrammeSample.sanders)))

        let snapshot = fixture.snapshot
        #expect(fixture.context.activeEvents.count == countBefore)
        #expect(snapshot.needsReviewCount == 0)
        #expect(snapshot.player(ProgrammeSample.sanders).shots == 1)
        #expect(snapshot.player(ProgrammeSample.sanders).shotsOnGoal == 1)
        #expect(snapshot.completeness(.shots) == .complete)
        // The correction is auditable.
        let revised = try #require(fixture.context.events.first { $0.id == event.id })
        #expect(revised.revision == 2)
        #expect(revised.revisions.last?.kind == .attributed)
    }

    @Test("A team-total shot on goal is never a review item")
    func opponentShotIsNotAReviewItem() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        fixture.seek(period: 1, minutes: 12)
        try fixture.perform(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved)))

        #expect(fixture.snapshot.needsReviewCount == 0)
        #expect(fixture.issues.contains { $0.kind == .unresolvedAttribution } == false)
    }

    @Test("Events recorded before kickoff are refused")
    func cannotRecordBeforeKickoff() throws {
        var fixture = MatchFixture()
        try fixture.perform(
            .setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven, goalkeeper: ProgrammeSample.keeper)))
        #expect(throws: MatchCommandError.matchNotStarted) {
            try fixture.perform(
                .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        }
    }

    @Test("A finalized match refuses new events until it is reopened")
    func finalizedMatchIsReadMostly() throws {
        var fixture = MatchFixture()
        try fixture.startMatch()
        try fixture.playFullMatchAndFinalize()

        #expect(throws: MatchCommandError.matchFinalized) {
            try fixture.perform(
                .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        }

        try fixture.perform(.reopen)
        #expect(fixture.context.phase == .awaitingFinalization)
        fixture.seek(period: 2, minutes: 39)
        try fixture.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)))
        #expect(fixture.snapshot.score.us == 1)
    }

    @Test("Re-entry is flagged only under rulesets that forbid it")
    func reEntryRules() throws {
        var professional = MatchFixture(rules: .professional)
        try professional.startMatch()
        professional.seek(period: 1, minutes: 20)
        try professional.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.trotter], playersIn: [ProgrammeSample.ridgeway])))
        professional.seek(period: 1, minutes: 30)
        try professional.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.ridgeway], playersIn: [ProgrammeSample.trotter])))
        #expect(professional.issues.contains { $0.kind == .reEntryViolation })

        var highSchool = MatchFixture(rules: .highSchool)
        try highSchool.startMatch()
        highSchool.seek(period: 1, minutes: 20)
        try highSchool.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.trotter], playersIn: [ProgrammeSample.ridgeway])))
        highSchool.seek(period: 1, minutes: 30)
        try highSchool.perform(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: [ProgrammeSample.ridgeway], playersIn: [ProgrammeSample.trotter])))
        #expect(highSchool.issues.contains { $0.kind == .reEntryViolation } == false)
    }
}
