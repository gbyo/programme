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
        // Activation flushes the latest pending payload exactly once.
        XCTAssertEqual(policy.activated(), first)
        XCTAssertNil(policy.pending)
        XCTAssertNil(policy.activated())
    }

    func testLatestSnapshotWins() {
        var policy = WatchPushPolicy()
        XCTAssertNil(policy.push(Data("old".utf8), canDeliver: false))
        XCTAssertNil(policy.push(Data("new".utf8), canDeliver: false))
        XCTAssertEqual(policy.activated(), Data("new".utf8))
    }

    func testDeliverablePushSendsImmediately() {
        var policy = WatchPushPolicy()
        let payload = Data("live".utf8)
        XCTAssertEqual(policy.push(payload, canDeliver: true), payload)
        XCTAssertNil(policy.pending)
        XCTAssertNil(policy.activated())
    }
}
