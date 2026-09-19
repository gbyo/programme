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

    @Test("Sharing is invitation-only: specified recipients, no public link")
    func sharingOptionsAreInvitationOnly() {
        let options = TeamSharingOptions.invitationOnly
        #expect(options.allowedParticipantAccessOptions == .specifiedRecipientsOnly)
        #expect(!options.allowedParticipantAccessOptions.contains(.anyoneWithLink))
        // View and Edit, matching Owner/Can-view/Can-make-changes roles.
        #expect(options.allowedParticipantPermissionOptions == .any)
    }

    @Test("Owned and shared teams resolve share records in different databases")
    func shareScopeZones() {
        let owned = TeamZone.zoneID(for: teamID)
        #expect(owned.ownerName == CKCurrentUserDefaultName)
        let shared = TeamZone.zoneID(for: teamID, ownerName: "sharerRecordName")
        #expect(shared.zoneName == owned.zoneName)
        #expect(shared.ownerName == "sharerRecordName")
        #expect(TeamShareScope.shared(ownerName: "a") != TeamShareScope.shared(ownerName: "b"))
    }

    @Test("Only unknown-item means not shared; other failures stay unavailable")
    func lookupErrorMapping() {
        // ShareLookup carries a CKShare, so compare by case, not equality.
        func isNotShared(_ lookup: ShareLookup) -> Bool {
            if case .notShared = lookup { return true }
            return false
        }
        func isUnavailable(_ lookup: ShareLookup) -> Bool {
            if case .unavailable = lookup { return true }
            return false
        }
        #expect(isNotShared(TeamShareCoordinator.mapLookupError(CKError(.unknownItem))))
        #expect(
            isNotShared(
                TeamShareCoordinator.mapLookupError(
                    NSError(
                        domain: CKErrorDomain,
                        code: CKError.Code.unknownItem.rawValue))))
        #expect(isUnavailable(TeamShareCoordinator.mapLookupError(CKError(.networkFailure))))
        #expect(isUnavailable(TeamShareCoordinator.mapLookupError(CKError(.notAuthenticated))))
        #expect(
            isUnavailable(
                TeamShareCoordinator.mapLookupError(
                    NSError(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN)))))
    }

    @Test("Participant identity never comes from the display name")
    func participantIdentitiesAreStable() {
        #expect(
            TeamShareCoordinator.participantID(recordName: "abc", email: nil, phone: nil, fallback: "0") == "user:abc")
        #expect(
            TeamShareCoordinator.participantID(recordName: nil, email: "a@example.com", phone: nil, fallback: "1")
                == "email:a@example.com")
        #expect(
            TeamShareCoordinator.participantID(recordName: nil, email: nil, phone: "+1555", fallback: "2")
                == "phone:+1555")
        #expect(
            TeamShareCoordinator.participantID(recordName: nil, email: nil, phone: nil, fallback: "3") == "invited:3")
        // Same visible name, different people: identities differ.
        let first = ShareParticipant(
            id: TeamShareCoordinator.participantID(recordName: "user-one", email: nil, phone: nil, fallback: "0"),
            displayName: "Alex", role: .collaborator, isCurrentUser: false, accepted: true)
        let second = ShareParticipant(
            id: TeamShareCoordinator.participantID(recordName: "user-two", email: nil, phone: nil, fallback: "1"),
            displayName: "Alex", role: .viewer, isCurrentUser: false, accepted: false)
        #expect(first.id != second.id)
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
