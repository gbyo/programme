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

    func testCloudKitEntitlementRecognition() {
        XCTAssertTrue(CloudKitEntitlement.includesCloudKit(["CloudKit"]))
        XCTAssertTrue(CloudKitEntitlement.includesCloudKit(["CloudKit-Anonymous"]))
        XCTAssertTrue(CloudKitEntitlement.includesCloudKit(["CloudDocuments", "CloudKit"]))
        XCTAssertFalse(CloudKitEntitlement.includesCloudKit(["CloudDocuments"]))
        XCTAssertFalse(CloudKitEntitlement.includesCloudKit([]))
        XCTAssertFalse(CloudKitEntitlement.includesCloudKit(nil))
    }

    @MainActor
    func testMonitorDoesNotConstructContainerWithoutEntitlement() async {
        let monitor = CloudKitAccountMonitor(
            makeContainer: {
                fatalError("CKContainer must not be constructed without the entitlement")
            },
            hasCloudKitEntitlement: { false }
        )

        await monitor.refresh()

        XCTAssertEqual(monitor.state, .temporarilyUnavailable)
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
}
