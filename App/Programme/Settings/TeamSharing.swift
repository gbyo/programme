import CloudKit
import ProgrammeCollaboration
import ProgrammeCore
import SwiftUI

/// Native SwiftUI share item for a team.
///
/// The exporter returns the already-prepared zone-wide share when the view
/// resolved one, and otherwise defers to the system's `prepareShare`
/// handler, which creates/saves the zone-wide CKShare on demand. Either way
/// the object handed to the system is zone-wide: the whole team workspace,
/// never a record hierarchy.
struct TeamShareItem: Transferable, Sendable {
    let teamID: TeamID
    let teamName: String
    /// The live share when the view already resolved one (the common path);
    /// nil falls back to the prepare handler below.
    let prepared: CKShare?
    let coordinator: TeamShareCoordinator
    let containerFactory: @Sendable () -> CKContainer

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation<TeamShareItem> { item in
            let container = item.containerFactory()
            if let prepared = item.prepared {
                return .existing(prepared, container: container)
            }
            return .prepareShare(container: container) {
                try await item.coordinator.prepareShare(teamID: item.teamID, teamName: item.teamName)
            }
        }
    }
}

/// Human-readable sharing failures for the Share surface.
enum TeamShareError: LocalizedError {
    case iCloudUnavailable
    case noLibrary

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "Sign in to iCloud in Settings to share this team."
        case .noLibrary:
            return "The library is not ready yet. Try again in a moment."
        }
    }
}

/// Receives the system callback when the user accepts a team invitation
/// outside the app. Forwards to AppModel, which accepts the share and
/// reloads the workspace; materialization still goes through the applier,
/// so shared content is review-gated exactly like synced content.
final class ShareAcceptanceDelegate: NSObject, UIApplicationDelegate {
    static var onAccept: ((CKShare.Metadata) -> Void)?

    func application(
        _ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        Self.onAccept?(metadata)
    }
}

/// Lightweight iCloud gate for the Share surface. Checked before resolving
/// the share item so the UI never constructs a CloudKit container just to
/// learn iCloud is off.
enum ShareAvailability {
    static var isICloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }
}
