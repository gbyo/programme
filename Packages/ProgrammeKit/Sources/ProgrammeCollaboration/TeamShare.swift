import CloudKit
import Foundation
import ProgrammeCore

/// Invitation-only zone-wide sharing of one team's zone.
///
/// Programme maps exactly one Team to one custom record zone, so sharing a
/// team shares the zone: `CKShare(recordZoneID:)`. There is no nominated
/// root record — Team/Season/Player/Match/Event records carry Programme IDs
/// and relationship fields, not a `CKRecord.parent` hierarchy, so a
/// hierarchy-rooted share would be semantically wrong and could share only
/// part of the workspace.
///
/// Consequences of the zone-wide choice:
/// - Preparing a share never resaves or recreates the Team record (or any
///   Programme record), so `createdAt` and all other truth are untouched.
/// - At most one share exists per team: the share record carries the
///   well-known `CKRecordNameZoneWideShare` name inside the zone, which is
///   also how an existing share is found again.
/// - The share carries metadata only (title, share type, invitation-only
///   permission). Shares are private by invitation
///   (`publicPermission == .none`); there is no public link.
///
/// Sharing never moves scoring authority: everything a device receives
/// through a share still lands through `TeamSyncApplier` — contradictions
/// need review, deletions descope as voids, and statistics re-derive
/// locally. Accepting a share grants access; it never deletes, overwrites,
/// or merges anything by itself.
public actor TeamShareCoordinator: Sendable {
    private let makeContainer: @Sendable () -> CKContainer
    private let sharedZones: SharedZoneStore

    public init(makeContainer: @Sendable @escaping () -> CKContainer, sharedZones: SharedZoneStore) {
        self.makeContainer = makeContainer
        self.sharedZones = sharedZones
    }

    /// The container this coordinator shares through. Exposed so UI share
    /// items (which must be Sendable) can resolve it without capturing the
    /// coordinator's factory themselves.
    public nonisolated func container() -> CKContainer { makeContainer() }

    // MARK: - Offline builders (no network, fully tested)

    /// A private-by-invitation zone-wide share for a team, titled with the
    /// team name. Metadata only: no Programme record is touched.
    public nonisolated static func makeShare(teamID: TeamID, teamName: String) -> CKShare {
        let share = CKShare(recordZoneID: TeamZone.zoneID(for: teamID))
        share[CKShare.SystemFieldKey.title] = teamName as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = "ProgrammeTeam" as CKRecordValue
        share.publicPermission = .none
        return share
    }

    /// Record ID of the zone-wide share for a team: the well-known name in
    /// the team's own zone. One team = one zone = at most one share.
    public nonisolated static func shareID(for teamID: TeamID) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: TeamZone.zoneID(for: teamID))
    }

    // MARK: - Network paths (thin; exercised against CloudKit, not faked)

    /// Fetches the live share without creating anything. Nil when the team
    /// is not shared (or the fetch fails); never throws for "not shared".
    public func existingShare(teamID: TeamID) async -> CKShare? {
        let database = makeContainer().privateCloudDatabase
        guard let record = try? await database.record(for: Self.shareID(for: teamID)),
            let share = record as? CKShare
        else { return nil }
        return share
    }

    /// Returns the team's zone-wide share, creating zone and share on first
    /// call. Reuses the well-known share record when one exists so repeated
    /// calls never fork parallel shares — and never resaves any Programme
    /// record: only the zone (if missing) and the share itself are written.
    public func prepareShare(teamID: TeamID, teamName: String) async throws -> CKShare {
        let database = makeContainer().privateCloudDatabase
        let zoneID = TeamZone.zoneID(for: teamID)
        try await ensureZone(zoneID, in: database)
        if let existing = try await existingShare(teamID: teamID) {
            return existing
        }
        let share = Self.makeShare(teamID: teamID, teamName: teamName)
        _ = try await database.modifyRecords(
            saving: [share], deleting: [], savePolicy: .changedKeys)
        await sharedZones.remember(SharedZoneInfo(teamID: teamID, sharedAt: Date()))
        return share
    }

    /// Participants the current user is allowed to see (at minimum the owner
    /// and the current user). Display only: Apple designates the system
    /// share sheet for adding participants and changing permissions, so
    /// Programme never builds a parallel editor — this list answers "who
    /// has access" and nothing more.
    public func participants(teamID: TeamID) async -> [ShareParticipant] {
        guard let share = await existingShare(teamID: teamID) else { return [] }
        return Self.participants(of: share)
    }

    /// Maps a live share's participants to display values. Pure so the
    /// mapping stays obvious; untested because `CKShare.Participant` has no
    /// public initializer — participants only ever come from the server.
    public nonisolated static func participants(of share: CKShare) -> [ShareParticipant] {
        share.participants.map { participant in
            let name =
                participant.userIdentity.nameComponents
                .flatMap { PersonNameComponentsFormatter.localizedString(from: $0, style: .medium) }
                ?? "Invited collaborator"
            let role: ShareParticipant.Role
            if Self.isSameParticipant(participant, share.owner) {
                role = .owner
            } else if participant.permission == .readWrite {
                role = .collaborator
            } else {
                role = .viewer
            }
            let isCurrent =
                share.currentUserParticipant.map { Self.isSameParticipant(participant, $0) } ?? false
            return ShareParticipant(
                displayName: name, role: role, isCurrentUser: isCurrent,
                accepted: participant.acceptanceStatus == .accepted)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Participant identity is the iCloud user record, never object
    /// identity: fetched share graphs hand out distinct instances.
    private nonisolated static func isSameParticipant(
        _ lhs: CKShare.Participant, _ rhs: CKShare.Participant
    ) -> Bool {
        guard let lhsID = lhs.userIdentity.userRecordID,
            let rhsID = rhs.userIdentity.userRecordID
        else { return false }
        return lhsID == rhsID
    }

    /// Revokes the team's share for everyone (owner only). Deletes the
    /// well-known share record and drops the local pointer. Local event
    /// truth is untouched — every device keeps what it already has; it
    /// simply stops receiving anything new.
    public func stopSharing(teamID: TeamID) async throws {
        let database = makeContainer().privateCloudDatabase
        _ = try await database.modifyRecords(
            saving: [], deleting: [Self.shareID(for: teamID)])
        await sharedZones.forget(teamID: teamID)
    }

    /// Accepts an invitation the system delivered (via the app delegate's
    /// CloudKit-share entry point). After acceptance the shared-database
    /// sync engine picks the zone up; nothing materializes here, so
    /// review-gating in the applier applies to shared content unchanged.
    public func accept(_ metadata: CKShare.Metadata) async throws {
        let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            makeContainer().add(operation)
        }
    }

    /// The custom zone must already exist in the owner's private database
    /// before a zone-wide share can reference it.
    private func ensureZone(_ zoneID: CKRecordZone.ID, in database: CKDatabase) async throws {
        let zones = try await database.allRecordZones()
        guard !zones.contains(where: { $0.zoneID == zoneID }) else { return }
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
    }
}

/// Which teams this device has shared. Only identity (team + when) is
/// persisted — the live share (URL, participants) is always re-fetched by
/// its well-known record name, never cached as truth.
public struct SharedZoneInfo: Codable, Hashable, Sendable {
    public var teamID: TeamID
    public var sharedAt: Date

    public init(teamID: TeamID, sharedAt: Date) {
        self.teamID = teamID
        self.sharedAt = sharedAt
    }
}

/// Who has access to a shared team, for display. Role derives from the
/// live participant list; nothing here is persisted or editable.
public struct ShareParticipant: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable {
        case owner
        case collaborator
        case viewer
    }

    public var displayName: String
    public var role: Role
    public var isCurrentUser: Bool
    public var accepted: Bool

    public init(displayName: String, role: Role, isCurrentUser: Bool, accepted: Bool) {
        self.displayName = displayName
        self.role = role
        self.isCurrentUser = isCurrentUser
        self.accepted = accepted
    }
}

public actor SharedZoneStore: Sendable {
    private let url: URL
    private var zones: [TeamID: SharedZoneInfo]

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let stored = try JSONDecoder().decode([SharedZoneInfo].self, from: Data(contentsOf: url))
            zones = Dictionary(uniqueKeysWithValues: stored.map { ($0.teamID, $0) })
        } else {
            zones = [:]
        }
    }

    public func remember(_ info: SharedZoneInfo) {
        zones[info.teamID] = info
        try? persist()
    }

    public func info(for teamID: TeamID) -> SharedZoneInfo? { zones[teamID] }

    /// The local pointer is gone; the server-side share itself is revoked
    /// through the sharing UI, never implicitly here.
    public func forget(teamID: TeamID) {
        zones.removeValue(forKey: teamID)
        try? persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try JSONEncoder().encode(Array(zones.values)).write(to: url, options: .atomic)
    }
}
