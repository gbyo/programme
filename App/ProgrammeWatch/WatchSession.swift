import Foundation
import Observation
import ProgrammeCore
import WatchConnectivity

/// Receives read-only match snapshots from the paired iPhone.
///
/// Delivery is `updateApplicationContext` semantics: the latest snapshot
/// replaces its predecessor, nothing streams, and the Watch renders its
/// clock locally from the snapshot's anchor. The Watch never scores,
/// edits, or finalizes.
@MainActor
@Observable
final class WatchSession: NSObject, WCSessionDelegate {
    nonisolated private static let snapshotKey = "programme.watchSnapshot"

    var snapshot: WatchSnapshot?
    private(set) var isReachable = false

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        snapshot = Self.decode(session.receivedApplicationContext[Self.snapshotKey])
        isReachable = session.isReachable
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isReachable = reachable
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let snapshot = Self.decode(applicationContext[Self.snapshotKey])
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.snapshot = snapshot
            self?.isReachable = reachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isReachable = reachable
        }
    }

    nonisolated private static func decode(_ value: Any?) -> WatchSnapshot? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }
}
