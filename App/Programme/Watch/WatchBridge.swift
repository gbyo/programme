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
/// Pure push/activation policy: decides when a snapshot may go out and
/// retains the latest one across pre-activation pushes. Tested directly;
/// `WCSession` itself is never instantiated outside the bridge.
struct WatchPushPolicy {
    private(set) var pending: Data?

    /// Records the snapshot, delivering it only when the session may
    /// legally send. Returns the payload to deliver now, if any.
    /// Latest wins: an older pending snapshot is simply replaced.
    mutating func push(_ data: Data, canDeliver: Bool) -> Data? {
        pending = data
        guard canDeliver else { return nil }
        pending = nil
        return data
    }

    /// Flushes the latest pending snapshot on activation (and
    /// re-activation). Nothing pending means nothing to send.
    mutating func activated() -> Data? {
        defer { pending = nil }
        return pending
    }
}

@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    private static let snapshotKey = "programme.watchSnapshot"
    private var policy = WatchPushPolicy()

    override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Delivers the latest glanceable state. No-op without a paired,
    /// companion-installed Watch; pushes before activation are retained
    /// and flushed when activation completes — the first snapshot is never
    /// silently lost. Stale snapshots are simply replaced by the next push.
    func push(_ snapshot: WatchSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        guard let payload = policy.push(data, canDeliver: Self.canDeliver()) else { return }
        try? WCSession.default.updateApplicationContext([Self.snapshotKey: payload])
    }

    private nonisolated static func canDeliver() -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired
            && session.isWatchAppInstalled
    }

    private func flushPending() {
        guard let payload = policy.activated(), Self.canDeliver() else { return }
        try? WCSession.default.updateApplicationContext([Self.snapshotKey: payload])
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in self?.flushPending() }
    }

    #if os(iOS)
        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
        nonisolated func sessionDidDeactivate(_ session: WCSession) {
            // Re-activation re-attaches the delegate; see WCSession docs.
            session.delegate = self
            session.activate()
        }
    #endif
}
