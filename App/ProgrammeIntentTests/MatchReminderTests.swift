import Foundation
import ProgrammeCore
import UserNotifications
import XCTest

@testable import Programme

/// Local match reminders: stable identifiers, correct fire dates, graceful
/// past-date handling, and reschedule-replaces semantics — all without
/// touching the real notification center.
final class MatchReminderTests: XCTestCase {
    final class FakeScheduler: MatchNotificationScheduling, @unchecked Sendable {
        private let lock = NSLock()
        private var _added: [UNNotificationRequest] = []
        private var _removed: [[String]] = []

        var added: [UNNotificationRequest] { lock.withLock { _added } }
        var removed: [[String]] { lock.withLock { _removed } }

        func add(_ request: UNNotificationRequest) async throws {
            lock.withLock { _added.append(request) }
        }

        func removePending(withIdentifiers identifiers: [String]) async {
            lock.withLock { _removed.append(identifiers) }
        }

        func pendingIdentifiers() async -> [String] { [] }
    }

    private func matchID(_ seed: String = "match.dixie") -> MatchID {
        MatchID(ProgrammeSample.id(seed))
    }

    func testOptionsCoverNoneFifteenThirtySixty() {
        XCTAssertNil(MatchReminderOption.none.minutesBefore)
        XCTAssertEqual(MatchReminderOption.fifteenMinutes.minutesBefore, 15)
        XCTAssertEqual(MatchReminderOption.thirtyMinutes.minutesBefore, 30)
        XCTAssertEqual(MatchReminderOption.oneHour.minutesBefore, 60)
        XCTAssertEqual(MatchReminderOption.option(minutesBefore: nil), .none)
        XCTAssertEqual(MatchReminderOption.option(minutesBefore: 30), .thirtyMinutes)
        XCTAssertEqual(MatchReminderOption.option(minutesBefore: 999), .none)
    }

    func testNotificationIDIsStableAndUniquePerMatch() {
        let first = MatchReminderRequest.notificationID(for: matchID())
        XCTAssertEqual(first, MatchReminderRequest.notificationID(for: matchID()))
        XCTAssertTrue(first.hasPrefix("programme.match-reminder."))
        XCTAssertNotEqual(
            first, MatchReminderRequest.notificationID(for: matchID("match.clinton")))
    }

    func testFireDateIsMinutesBeforeKickoff() {
        let kickoff = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let fire = MatchReminderRequest.fireDate(
            kickoff: kickoff, minutesBefore: 30, now: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(fire, kickoff.addingTimeInterval(-30 * 60))
    }

    func testPastFireDateSchedulesNothing() {
        let kickoff = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertNil(
            MatchReminderRequest.fireDate(
                kickoff: kickoff, minutesBefore: 30,
                now: Date(timeIntervalSinceReferenceDate: 2_000_000)))
        XCTAssertNil(
            MatchReminderRequest.fireDate(
                kickoff: kickoff, minutesBefore: nil,
                now: Date(timeIntervalSinceReferenceDate: 0)))
    }

    func testContentNamesTeamsAndLocation() {
        var descriptor = ProgrammeSample.descriptor(opponent: "Dixie", venue: .away)
        descriptor.location = MatchLocation(name: "Abbeville High School")
        XCTAssertTrue(MatchReminderRequest.title(descriptor: descriptor).contains("Dixie"))
        let body = MatchReminderRequest.body(descriptor: descriptor, minutesBefore: 15)
        XCTAssertTrue(body.contains("15"))
        XCTAssertTrue(body.contains("Abbeville High School"))
    }

    func testSyncSchedulesFutureReminder() async {
        let fake = FakeScheduler()
        let center = MatchReminderCenter(scheduler: fake)
        let id = matchID()
        let kickoff = Date().addingTimeInterval(3600)
        await center.sync(
            matchID: id, kickoff: kickoff, minutesBefore: 30,
            title: "T", body: "B", now: Date())
        XCTAssertEqual(fake.added.count, 1)
        XCTAssertEqual(fake.added.first?.identifier, MatchReminderRequest.notificationID(for: id))
        XCTAssertNotNil(fake.added.first?.trigger as? UNCalendarNotificationTrigger)
    }

    func testSyncWithNilOrPastReminderLeavesNothingPending() async {
        let fake = FakeScheduler()
        let center = MatchReminderCenter(scheduler: fake)
        let id = matchID()
        await center.sync(
            matchID: id, kickoff: Date().addingTimeInterval(3600), minutesBefore: nil,
            title: "T", body: "B", now: Date())
        await center.sync(
            matchID: id, kickoff: Date().addingTimeInterval(600), minutesBefore: 30,
            title: "T", body: "B", now: Date())
        XCTAssertTrue(fake.added.isEmpty, "past or absent reminders must schedule nothing")
        // Both syncs still cleared the stable identifier first.
        XCTAssertEqual(fake.removed.count, 2)
    }

    func testRescheduleReplacesAndCancelRemoves() async {
        let fake = FakeScheduler()
        let center = MatchReminderCenter(scheduler: fake)
        let id = matchID()
        let expectedID = MatchReminderRequest.notificationID(for: id)
        await center.sync(
            matchID: id, kickoff: Date().addingTimeInterval(7200), minutesBefore: 60,
            title: "T", body: "B", now: Date())
        await center.sync(
            matchID: id, kickoff: Date().addingTimeInterval(3600), minutesBefore: 15,
            title: "T", body: "B", now: Date())
        XCTAssertEqual(
            fake.added.map(\.identifier), [expectedID, expectedID],
            "rescheduling reuses the stable identifier instead of stacking")
        await center.cancel(matchID: id)
        XCTAssertEqual(fake.removed.last, [expectedID])
    }
}
