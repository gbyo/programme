import CloudKit
import ProgrammeCollaboration
import ProgrammeCore
import SharedWithYou
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

    /// The container for the collaboration view. Evaluated only when the
    /// view actually presents sharing UI, never on launch paths.
    func container() -> CKContainer { containerFactory() }

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

/// Display labels for participant roles. Kept in the UI layer: roles are
/// display-only and never persisted.
extension ShareParticipant {
    var roleLabel: String {
        switch role {
        case .owner: return "Owner"
        case .collaborator: return "Can make changes"
        case .viewer: return "Can view"
        }
    }
}

/// Apple's native collaboration control for an already-shared team:
/// participant faces, active count, and the system Manage Share flow
/// (participants, permissions, settings, stop sharing). A narrow
/// UIViewRepresentable because SwiftUI exposes no equivalent view.
/// `ShareLink` remains the initial sharing path; this takes over once a
/// share exists.
struct CollaborationView: UIViewRepresentable {
    let share: CKShare
    let container: CKContainer
    let teamName: String

    func makeUIView(context: Context) -> SWCollaborationView {
        let provider = NSItemProvider()
        provider.registerCKShare(share, container: container)
        let view = SWCollaborationView(itemProvider: provider)
        view.headerTitle = teamName
        return view
    }

    func updateUIView(_ view: SWCollaborationView, context: Context) {}
}

/// Concise sync state for team detail. Local scoring and recovery stay
/// authoritative in every state — "offline" or "needs review" never means
/// unsafe, only that shared copies may lag or need a human look.
enum TeamSyncState: Hashable, Sendable {
    case synced
    case syncing
    case offline
    case unavailable
    case needsReview(Int)

    var label: String {
        switch self {
        case .synced: return "Synced"
        case .syncing: return "Syncing…"
        case .offline: return "Offline — changes saved locally"
        case .unavailable: return "iCloud unavailable"
        case .needsReview(let count): return "Needs Review (\(count))"
        }
    }

    var systemImage: String {
        switch self {
        case .synced: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .offline: return "icloud.slash"
        case .unavailable: return "icloud.slash"
        case .needsReview: return "exclamationmark.icloud"
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
