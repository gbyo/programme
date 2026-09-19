import Foundation
import ProgrammeCore
import ProgrammePersistence
import XCTest

@testable import Programme

/// Semantic announcements fire at the same `LiveMatchSession` boundary as
/// haptics. `Announcer` keeps a capped in-memory record of what was posted so
/// these tests can assert the scorer-facing copy without VoiceOver running.
@MainActor
final class ScorerAnnouncementTests: XCTestCase {
    struct Fixture {
        let harness: IntentTestHarness
        let session: LiveMatchSession
        let playerIDs: [PlayerID]
    }

    /// A fresh match with eight players: seven to start, one on the bench so
    /// substitutions are legal. Lineup and clock setup are `.silent` by
    /// design, so they must not announce anything themselves.
    private func makeFixture() async throws -> Fixture {
        let harness = try await IntentTestHarness.make()
        guard let store = harness.appModel.store, let journal = harness.appModel.journal else {
            throw IntentTestHarness.HarnessError.noStore
        }
        let positions: [PlayerPosition] = [.goalkeeper, .defender, .midfielder, .forward]
        let snapshots = (1...8).map { number in
            PlayerSnapshot(
                firstName: "Test", lastName: "Player\(number)", jerseyNumber: number,
                position: positions[number % positions.count])
        }
        let playerIDs = try await store.addPlayers(teamID: harness.seed.teamA, snapshots)
        let roster = try await store.roster(teamID: harness.seed.teamA)
        let matchID = try await store.createMatch(
            teamID: harness.seed.teamA, seasonID: harness.seed.seasonA,
            opponentName: "Dixie", opponentShortName: "DIX",
            kickoff: Date(timeIntervalSince1970: 1_790_000_000),
            venue: .home, rules: .highSchool, statProfile: .maxPreps,
            tracking: .ourTeam, competition: nil, roster: roster)
        let context = try await store.context(for: matchID)
        let session = LiveMatchSession(
            context: context, store: store, journal: journal, appModel: harness.appModel)
        _ = Announcer.drain()
        session.setStartingLineup(Array(playerIDs.prefix(7)), goalkeeper: playerIDs[0])
        session.startNextPeriod()
        let setupAnnouncements = Announcer.drain()
        XCTAssertTrue(
            setupAnnouncements.isEmpty,
            "Lineup and clock setup must stay silent, got: \(setupAnnouncements)")
        return Fixture(harness: harness, session: session, playerIDs: playerIDs)
    }

    func testGoalAnnouncementNamesScorerAndScore() async throws {
        let fixture = try await makeFixture()
        fixture.session.recordGoal(scorer: .player(fixture.playerIDs[1]), assist: nil)
        let posted = Announcer.drain()
        XCTAssertEqual(posted.count, 1)
        let message = try XCTUnwrap(posted.first)
        XCTAssertTrue(message.hasPrefix("Goal recorded."), "got: \(message)")
        XCTAssertTrue(message.contains("1–0"), "goal announcement must carry the score, got: \(message)")
    }

    func testSubstitutionAnnouncement() async throws {
        let fixture = try await makeFixture()
        fixture.session.substitute(
            out: [fixture.playerIDs[0]], in: [fixture.playerIDs[7]], goalkeeperAfter: nil)
        let posted = Announcer.drain()
        XCTAssertEqual(posted.count, 1)
        XCTAssertTrue(
            posted[0].hasPrefix("Substitution recorded."), "got: \(posted[0])")
    }

    func testUnattributedShotAnnouncesNeedsReview() async throws {
        let fixture = try await makeFixture()
        fixture.session.recordShot(.offTarget, by: .unidentified)
        let posted = Announcer.drain()
        XCTAssertEqual(posted.count, 1)
        XCTAssertTrue(posted[0].hasPrefix("Shot recorded."), "got: \(posted[0])")
        XCTAssertTrue(
            posted[0].contains("needs player attribution"),
            "unattributed shots must point at review, got: \(posted[0])")
    }

    func testSettledShotStaysHapticOnly() async throws {
        let fixture = try await makeFixture()
        fixture.session.recordShot(.offTarget, by: .player(fixture.playerIDs[1]))
        XCTAssertTrue(
            Announcer.drain().isEmpty,
            "A settled shot is haptic-only; routine events must not chatter.")
    }

    func testUndoAnnouncesWhatWasUndone() async throws {
        let fixture = try await makeFixture()
        fixture.session.recordGoal(scorer: .player(fixture.playerIDs[1]), assist: nil)
        _ = Announcer.drain()
        fixture.session.undo()
        let posted = Announcer.drain()
        XCTAssertEqual(posted.count, 1)
        XCTAssertTrue(posted[0].hasPrefix("Undid "), "got: \(posted[0])")
    }

    func testFailedCommandAnnouncesNoticeCopy() async throws {
        let fixture = try await makeFixture()
        // Nothing undone yet: redo has no target and the command fails with
        // its specific message. The announcement must match the transient
        // notice word for word — that is the only surface a VoiceOver scorer
        // gets for a rejection.
        fixture.session.redo()
        let posted = Announcer.drain()
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first, fixture.session.notice?.text)
        XCTAssertTrue(posted[0].contains("nothing to undo"), "got: \(posted[0])")
    }

    func testEditConfirmationAnnouncesMessage() async throws {
        let fixture = try await makeFixture()
        let eventID = try XCTUnwrap(
            fixture.session.recordReturningID(
                .recordShot(
                    ShotEvent(
                        side: .us, shooter: .player(fixture.playerIDs[1]), outcome: .goal,
                        assist: nil, location: nil, phase: .openPlay, isOwnGoal: false)),
                feedback: .goal))
        _ = Announcer.drain()
        XCTAssertTrue(fixture.session.edit(.void(eventID), message: "Deleted"))
        XCTAssertEqual(Announcer.drain(), ["Deleted"])
    }
}
