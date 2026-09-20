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
///
/// The pending value stays a typed snapshot: encoding happens only when a
/// delivery is actually attempted, so devices with no Watch destination
/// never pay serialization per push.
struct WatchPushPolicy {
    private(set) var pending: WatchSnapshot?

    /// Records the snapshot, delivering it only when the session may
    /// legally send. Returns the snapshot to deliver now, if any.
    /// Latest wins: an older pending snapshot is simply replaced. The
    /// snapshot stays pending until the caller acknowledges successful
    /// delivery, so a failed send is retried instead of lost.
    mutating func push(_ snapshot: WatchSnapshot, canDeliver: Bool) -> WatchSnapshot? {
        pending = snapshot
        guard canDeliver else { return nil }
        return snapshot
    }

    /// Takes the latest pending snapshot for an activation flush without
    /// clearing it; `acknowledge()` clears it after delivery succeeds.
    mutating func activated() -> WatchSnapshot? {
        pending
    }

    /// Clears the pending snapshot after `updateApplicationContext`
    /// succeeds. Never called on failure, so the next attempt retries.
    mutating func acknowledge() {
        pending = nil
    }
}

@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    private static let snapshotKey = "programme.watchSnapshot"
    private var policy = WatchPushPolicy()

    /// Encodes a snapshot for delivery. A seam so tests can count encodes
    /// without a live Watch session.
    var encoder: @Sendable (WatchSnapshot) throws -> Data = { try JSONEncoder().encode($0) }

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
    /// Encoding happens only when delivery is actually attempted.
    func push(_ snapshot: WatchSnapshot) {
        guard let pending = policy.push(snapshot, canDeliver: Self.canDeliver()) else { return }
        deliver(pending)
    }

    private func deliver(_ snapshot: WatchSnapshot) {
        guard let data = try? encoder(snapshot) else { return }
        do {
            try WCSession.default.updateApplicationContext([Self.snapshotKey: data])
            policy.acknowledge()
        } catch {
            // Delivery failed; the snapshot stays pending so the next
            // push or activation flush retries it.
        }
    }

    private nonisolated static func canDeliver() -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired
            && session.isWatchAppInstalled
    }

    private func flushPending() {
        guard let pending = policy.activated(), Self.canDeliver() else { return }
        deliver(pending)
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
