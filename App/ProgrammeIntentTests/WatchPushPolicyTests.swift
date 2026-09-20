import Foundation
import ProgrammeCore
import XCTest

@testable import Programme

/// The Watch push/activation state machine, without instantiating
/// `WCSession`: pre-activation pushes must be retained and flushed on
/// activation, never silently lost — and never encoded until a delivery
/// is actually attempted.
final class WatchPushPolicyTests: XCTestCase {
    private func snapshot(reviewCount: Int = 0) -> WatchSnapshot {
        WatchSnapshot(
            teamName: "Ninety Six", teamShortName: "NX", recordText: "1-0-0", reviewCount: reviewCount,
            updatedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    func testPreActivationPushIsRetainedAndFlushed() {
        var policy = WatchPushPolicy()
        let first = snapshot()
        // Cannot deliver yet: retained, nothing returned.
        XCTAssertNil(policy.push(first, canDeliver: false))
        XCTAssertEqual(policy.pending, first)
        // Activation takes the payload but keeps it pending until the
        // caller acknowledges successful delivery.
        XCTAssertEqual(policy.activated(), first)
        XCTAssertEqual(policy.pending, first)
        policy.acknowledge()
        XCTAssertNil(policy.pending)
        XCTAssertNil(policy.activated())
    }

    func testLatestSnapshotWins() {
        var policy = WatchPushPolicy()
        XCTAssertNil(policy.push(snapshot(reviewCount: 0), canDeliver: false))
        XCTAssertNil(policy.push(snapshot(reviewCount: 2), canDeliver: false))
        XCTAssertEqual(policy.activated(), snapshot(reviewCount: 2))
        policy.acknowledge()
        XCTAssertNil(policy.pending)
    }

    func testDeliverablePushStaysPendingUntilAcknowledged() {
        var policy = WatchPushPolicy()
        let payload = snapshot()
        // Returned for immediate delivery, but retained: a failed send
        // must be retryable rather than lost.
        XCTAssertEqual(policy.push(payload, canDeliver: true), payload)
        XCTAssertEqual(policy.pending, payload)
        policy.acknowledge()
        XCTAssertNil(policy.pending)
        XCTAssertNil(policy.activated())
    }

    func testFailedDeliveryRetriesInsteadOfLosing() {
        var policy = WatchPushPolicy()
        let payload = snapshot()
        XCTAssertEqual(policy.push(payload, canDeliver: true), payload)
        // No acknowledge (delivery threw): the next flush retries it.
        XCTAssertEqual(policy.activated(), payload)
    }

    @MainActor
    func testUndeliverablePushesEncodeNothing() {
        final class EncodeCounter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() {
                lock.lock()
                defer { lock.unlock() }
                count += 1
            }
        }
        let bridge = WatchBridge()
        let counter = EncodeCounter()
        bridge.encoder = { _ in
            counter.increment()
            return Data()
        }
        // No paired Watch in tests, so every push retains without encoding.
        for reviewCount in 0..<5 {
            bridge.push(snapshot(reviewCount: reviewCount))
        }
        XCTAssertEqual(counter.count, 0, "Snapshots were encoded with no delivery attempt")
    }
}
