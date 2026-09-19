import CloudKit
import Foundation
import ProgrammeCore

/// Identity scheme for Programme's CloudKit collaboration layer.
///
/// One Team maps to one stable custom record zone; every entity maps to one
/// record whose name derives from stable Programme IDs (UUIDs), never from
/// user-entered strings such as player or team names.
///
/// This file defines naming only. Field mapping lives in `Records.swift`,
/// merge policy in `EventMerge.swift`, and synchronization in later work.
/// Nothing here touches the network.
public enum TeamZone {
    /// Stable zone name for a team, e.g. `team_1A2B…`. Parses back to the
    /// owning TeamID so incoming shares and zones stay attributable.
    public static func zoneName(for teamID: TeamID) -> String {
        "team_\(teamID.rawValue.uuidString)"
    }

    public static func zoneID(for teamID: TeamID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName(for: teamID), ownerName: CKCurrentUserDefaultName)
    }

    /// Zone ID for a team zone owned by someone else: used when resolving
    /// the zone-wide share of a team that was shared with this user. The
    /// owner name comes from the shared-database zone list, never guessed.
    public static func zoneID(for teamID: TeamID, ownerName: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName(for: teamID), ownerName: ownerName)
    }

    public static func teamID(forZoneName zoneName: String) -> TeamID? {
        guard zoneName.hasPrefix("team_") else { return nil }
        guard let uuid = UUID(uuidString: String(zoneName.dropFirst("team_".count))) else {
            return nil
        }
        return TeamID(uuid)
    }

    /// Stable record name for an entity inside its team zone, e.g.
    /// `match_…`. The prefix keeps record types greppable; the UUID keeps
    /// identity stable and free of user-entered text.
    public static func recordName(prefix: String, id: UUID) -> String {
        "\(prefix)_\(id.uuidString)"
    }
}
