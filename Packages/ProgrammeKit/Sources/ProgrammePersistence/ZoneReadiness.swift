import Foundation

/// Durable record of which private team zones this device has already asked
/// CloudKit to create. The in-memory set used to forget everything on every
/// launch, re-enqueueing a zone save per team on each sync startup.
///
/// Readiness is process-local proof of a past enqueue, not proof the zone
/// exists: server-side deletions and account switches clear it (see
/// `TeamSyncService`), and the next staged work for the team re-enqueues
/// creation. Offline staging never consults it.
public actor ZoneReadiness {
    private let url: URL
    private var ready: Set<String>

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            ready = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))
        } else {
            ready = []
        }
    }

    /// Marks the zone ready, reporting whether this is the first claim.
    /// Only a first claim enqueues a zone save with the sync engine.
    @discardableResult
    public func claim(_ zoneName: String) throws -> Bool {
        let isNew = ready.insert(zoneName).inserted
        if isNew { try persist() }
        return isNew
    }

    public func isReady(_ zoneName: String) -> Bool { ready.contains(zoneName) }

    /// Forgets one zone, e.g. after a server-side zone deletion surfaces.
    public func remove(_ zoneName: String) throws {
        if ready.remove(zoneName) != nil { try persist() }
    }

    /// Forgets every zone, e.g. after an iCloud account switch. Zones
    /// re-ensure lazily the next time their teams stage sync work.
    public func resetAll() throws {
        guard !ready.isEmpty else { return }
        ready = []
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: nil)
        try JSONEncoder().encode(ready).write(to: url, options: .atomic)
    }
}
