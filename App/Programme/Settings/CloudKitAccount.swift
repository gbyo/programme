import CloudKit
import Foundation
import Observation
import Security

/// Programme's CloudKit availability, derived from Apple's account state —
/// never from `ubiquityIdentityToken`, which answers a different question
/// (ubiquity container access) than "is the private CloudKit database
/// usable". Unknown until the first check completes; launch and scoring
/// never wait on it.
enum CloudKitAccountState: Hashable, Sendable {
    case unknown
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable

    /// Pure seam over `CKAccountStatus` so the mapping stays testable
    /// without signing into iCloud.
    static func map(_ status: CKAccountStatus) -> Self {
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable, .couldNotDetermine: return .temporarilyUnavailable
        @unknown default: return .temporarilyUnavailable
        }
    }

    /// Whether private-database CloudKit work (sharing, replication) may
    /// start. Everything else — scoring, recovery, browsing — runs
    /// regardless.
    var isUsable: Bool { self == .available }
}


/// Reads the *signed process* entitlement rather than trusting the source
/// .entitlements file. Xcode/provisioning may legitimately strip a requested
/// capability when the active profile does not grant it.
enum CloudKitEntitlement {
    static let servicesKey = "com.apple.developer.icloud-services"

    static func isPresent() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, servicesKey as CFString, nil),
            let services = value as? [String]
        else { return false }
        return includesCloudKit(services)
    }

    static func includesCloudKit(_ services: [String]?) -> Bool {
        guard let services else { return false }
        return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
    }
}

/// Observes `CKContainer.accountStatus()` and re-checks whenever the
/// system posts account-change notifications while Programme runs.
@MainActor
@Observable
final class CloudKitAccountMonitor {
    var state: CloudKitAccountState = .unknown
    /// Fires once per transition into `.available` (initial refresh and
    /// `CKAccountChanged` updates alike). Unavailable and unknown states
    /// deliberately trigger nothing.
    var onBecameAvailable: (() -> Void)?

    private let makeContainer: @Sendable () -> CKContainer
    private let hasCloudKitEntitlement: @Sendable () -> Bool
    private var started = false
    private var observer: (any NSObjectProtocol)?

    init(
        makeContainer: @escaping @Sendable () -> CKContainer = { CKContainer.default() },
        hasCloudKitEntitlement: @escaping @Sendable () -> Bool = {
            CloudKitEntitlement.isPresent()
        }
    ) {
        self.makeContainer = makeContainer
        self.hasCloudKitEntitlement = hasCloudKitEntitlement
    }

    /// Begins observation. Fire-and-forget: callers must never await CloudKit
    /// readiness on launch or scoring paths.
    func start() {
        guard !started else { return }
        started = true
        Task { await refresh() }
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        let previous = state
        // CKContainer traps before accountStatus() can throw when the signed
        // process lacks the CloudKit entitlement. Treat that as unavailable
        // instead: local scoring and recovery must never depend on signing.
        guard hasCloudKitEntitlement() else {
            state = .temporarilyUnavailable
            return
        }
        do {
            state = CloudKitAccountState.map(try await makeContainer().accountStatus())
        } catch {
            state = .temporarilyUnavailable
        }
        if Self.becameAvailable(previous: previous, current: state) {
            onBecameAvailable?()
        }
    }

    /// Pure transition seam: only entering `.available` fires, so sign-in
    /// starts replication once while unavailable states stay silent.
    /// Covered directly; the container call itself needs a real account.
    static func becameAvailable(
        previous: CloudKitAccountState, current: CloudKitAccountState
    ) -> Bool {
        current == .available && previous != .available
    }
}

/// Buffers share-invitation metadata that arrives before the app is ready
/// to accept it. `userDidAcceptCloudKitShareWith` can fire at launch,
/// before SwiftUI installs the acceptance closure — without a buffer that
/// invitation is silently dropped.
final class InvitationBuffer<Element>: @unchecked Sendable {
    private var items: [Element] = []
    private let lock = NSLock()

    func stage(_ element: Element) {
        lock.withLock { items.append(element) }
    }

    /// Drains everything staged so far, exactly once per call.
    func drain() -> [Element] {
        lock.withLock {
            defer { items.removeAll() }
            return items
        }
    }

    var isEmpty: Bool {
        lock.withLock { items.isEmpty }
    }
}
