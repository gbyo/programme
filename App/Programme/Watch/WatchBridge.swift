import Foundation
import ProgrammeCore
import WatchConnectivity

/// Companion-state bridge for the read-only Watch app.
///
/// Uses `updateApplicationContext` semantics: the latest snapshot
/// replaces its predecessor, delivery is opportunistic, and nothing is
/// ever streamed tick-by-tick. The Watch renders its clock locally from
/// the snapshot's anchor. Pushes happen where the widget snapshot already
/// refreshes (session changes, workspace reloads), so companionship costs
/// no new observation points. Silent when no Watch is paired or the
/// companion app is not installed.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    private static let snapshotKey = "programme.watchSnapshot"
    private var activated = false

    override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        activated = true
    }

    /// Delivers the latest glanceable state. No-op without a paired,
    /// companion-installed Watch; stale snapshots are simply replaced by
    /// the next push — the Watch never asks twice a second.
    func push(_ snapshot: WatchSnapshot) {
        guard activated else { return }
        let session = WCSession.default
        guard session.isPaired, session.isWatchAppInstalled else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? session.updateApplicationContext([Self.snapshotKey: data])
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    #if os(iOS)
        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
        nonisolated func sessionDidDeactivate(_ session: WCSession) {
            // Re-activation re-attaches the delegate; see WCSession docs.
            session.delegate = self
            session.activate()
        }
    #endif
}
