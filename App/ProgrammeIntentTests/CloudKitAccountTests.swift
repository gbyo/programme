import CloudKit
import XCTest

@testable import Programme

/// CloudKit availability mapping and invitation buffering, without signing
/// into iCloud: the mapping is a pure seam, and the buffer is generic.
/// `CKShare.Metadata` has no public initializer (like `CKShare.Participant`,
/// which the codebase already treats as server-only), so the buffer's
/// exactly-once semantics are covered with a stand-in element type.
final class CloudKitAccountTests: XCTestCase {
    func testAccountStatusMapping() {
        XCTAssertEqual(CloudKitAccountState.map(.available), .available)
        XCTAssertEqual(CloudKitAccountState.map(.noAccount), .noAccount)
        XCTAssertEqual(CloudKitAccountState.map(.restricted), .restricted)
        XCTAssertEqual(
            CloudKitAccountState.map(.temporarilyUnavailable), .temporarilyUnavailable)
        XCTAssertEqual(
            CloudKitAccountState.map(.couldNotDetermine), .temporarilyUnavailable)
    }

    func testOnlyAvailableUnlocksCloudKitWork() {
        XCTAssertTrue(CloudKitAccountState.available.isUsable)
        XCTAssertFalse(CloudKitAccountState.unknown.isUsable)
        XCTAssertFalse(CloudKitAccountState.noAccount.isUsable)
        XCTAssertFalse(CloudKitAccountState.restricted.isUsable)
        XCTAssertFalse(CloudKitAccountState.temporarilyUnavailable.isUsable)
    }

    func testInvitationBufferDrainsExactlyOnce() {
        let buffer = InvitationBuffer<String>()
        XCTAssertTrue(buffer.isEmpty)
        buffer.stage("first")
        buffer.stage("second")
        XCTAssertFalse(buffer.isEmpty)
        XCTAssertEqual(buffer.drain(), ["first", "second"])
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.drain(), [])
        // Late arrivals after a drain form the next batch.
        buffer.stage("third")
        XCTAssertEqual(buffer.drain(), ["third"])
    }

    func testBecomingAvailableFiresFromEveryNonUsableState() {
        for previous: CloudKitAccountState in [
            .unknown, .noAccount, .restricted, .temporarilyUnavailable,
        ] {
            XCTAssertTrue(
                CloudKitAccountMonitor.becameAvailable(previous: previous, current: .available),
                "Entering available from \(previous) should start replication")
        }
    }

    func testStayingAvailableOrLeavingNeverRefires() {
        XCTAssertFalse(
            CloudKitAccountMonitor.becameAvailable(previous: .available, current: .available))
        for current: CloudKitAccountState in [
            .unknown, .noAccount, .restricted, .temporarilyUnavailable,
        ] {
            XCTAssertFalse(
                CloudKitAccountMonitor.becameAvailable(previous: .available, current: current),
                "Leaving available for \(current) must not restart replication")
            XCTAssertFalse(
                CloudKitAccountMonitor.becameAvailable(
                    previous: .temporarilyUnavailable, current: current))
        }
    }

    func testShareErrorCopyDistinguishesOfflineFromSignedOut() {
        XCTAssertEqual(
            TeamShareError.iCloudUnavailable(.noAccount).errorDescription,
            "Sign in to iCloud in Settings to share this team.")
        XCTAssertEqual(
            TeamShareError.iCloudUnavailable(.restricted).errorDescription,
            "This device doesn't allow iCloud sharing, so this team can't be shared from here.")
        for state: CloudKitAccountState in [.unknown, .temporarilyUnavailable, .available] {
            let copy = TeamShareError.iCloudUnavailable(state).errorDescription ?? ""
            XCTAssertFalse(
                copy.localizedCaseInsensitiveContains("sign in"),
                "An offline scorer must never be told to sign in (\(state))")
        }
    }
}
