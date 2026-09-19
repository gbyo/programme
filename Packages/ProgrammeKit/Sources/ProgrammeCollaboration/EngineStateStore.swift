import CloudKit
import Foundation

/// Persists each sync engine's latest serialized state across launches, as
/// Apple requires. The coordinator hands the loaded value to
/// `CKSyncEngine.Configuration`; every `stateUpdate` event overwrites it.
///
/// State is opaque engine bookkeeping (tokens, pending sets) — never match
/// content, names, or statistics.
public struct EngineStateStore: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Generic over the payload because the SDK does not expose a public
    /// initializer for `CKSyncEngine.State.Serialization`; in production the
    /// coordinator passes that type, in tests a stub. Either way the store
    /// round-trips whatever Codable value it is given, or nothing at all.
    public func load<Value: Decodable>(_ type: Value.Type = Value.self) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func save<Value: Encodable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: nil)
        try data.write(to: url, options: .atomic)
    }
}
