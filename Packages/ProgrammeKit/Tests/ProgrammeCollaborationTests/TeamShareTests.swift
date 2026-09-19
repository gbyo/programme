import CloudKit
import Foundation
import Testing

@testable import ProgrammeCollaboration
@testable import ProgrammeCore

@Suite("Team shares are zone-wide, private, and remembered")
struct TeamShareTests {
    private let teamID = TeamID(ProgrammeSample.id("team.ninety-six"))

    @Test("A team share covers its whole zone under the well-known share name")
    func shareIsZoneWide() {
        let share = TeamShareCoordinator.makeShare(teamID: teamID, teamName: "Ninety Six")
        #expect(share.recordType == "cloudkit.share")
        // The share record lives in the team's own zone under the well-known
        // zone-wide name: one team = one zone = at most one share.
        #expect(share.recordID.zoneID.zoneName == TeamZone.zoneID(for: teamID).zoneName)
        #expect(share.recordID.recordName == CKRecordNameZoneWideShare)
        #expect(TeamShareCoordinator.shareID(for: teamID) == share.recordID)
    }

    @Test("Shares are invitation-only and carry share metadata, not Programme truth")
    func shareDefaults() {
        let share = TeamShareCoordinator.makeShare(teamID: teamID, teamName: "Ninety Six")
        #expect(share.publicPermission == .none)
        #expect(share[CKShare.SystemFieldKey.title] as? String == "Ninety Six")
        #expect(share[CKShare.SystemFieldKey.shareType] as? String == "ProgrammeTeam")
    }

    @Test("Two teams never share a share identity")
    func shareIdentitiesIsolateTeams() {
        let first = TeamShareCoordinator.shareID(for: TeamID(ProgrammeSample.id("team.a")))
        let second = TeamShareCoordinator.shareID(for: TeamID(ProgrammeSample.id("team.b")))
        #expect(first != second)
    }

    @Test("Shared zones persist across relaunch until forgotten")
    func sharedZoneStoreRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-zones-\(UUID().uuidString).json")
        let store = try SharedZoneStore(url: url)
        #expect(await store.info(for: teamID) == nil)
        let info = SharedZoneInfo(teamID: teamID, sharedAt: Date(timeIntervalSinceReferenceDate: 50))
        await store.remember(info)

        let reopened = try SharedZoneStore(url: url)
        #expect(await reopened.info(for: teamID) == info)
        await reopened.forget(teamID: teamID)
        #expect(await reopened.info(for: teamID) == nil)
    }
}
