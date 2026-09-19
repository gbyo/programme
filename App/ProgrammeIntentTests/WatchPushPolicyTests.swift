import Foundation
import XCTest

@testable import Programme

/// The Watch push/activation state machine, without instantiating
/// `WCSession`: pre-activation pushes must be retained and flushed on
/// activation, never silently lost.
final class WatchPushPolicyTests: XCTestCase {
    func testPreActivationPushIsRetainedAndFlushed() {
        var policy = WatchPushPolicy()
        let first = Data("first".utf8)
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
        XCTAssertNil(policy.push(Data("old".utf8), canDeliver: false))
        XCTAssertNil(policy.push(Data("new".utf8), canDeliver: false))
        XCTAssertEqual(policy.activated(), Data("new".utf8))
        policy.acknowledge()
        XCTAssertNil(policy.pending)
    }

    func testDeliverablePushStaysPendingUntilAcknowledged() {
        var policy = WatchPushPolicy()
        let payload = Data("live".utf8)
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
        let payload = Data("live".utf8)
        XCTAssertEqual(policy.push(payload, canDeliver: true), payload)
        // No acknowledge (delivery threw): the next flush retries it.
        XCTAssertEqual(policy.activated(), payload)
    }
}
