import CloudKit
import Foundation

/// Durable outbox for outbound CloudKit mutations, one per database.
///
/// A local event that survived the recovery journal and SwiftData must stay
/// discoverable for cloud upload even if Programme is killed immediately
/// after recording it. Staging here persists to disk on every mutation, so
/// nothing depends on an in-memory callback surviving. Records are archived
/// with secure coding; the JSON manifest stays human-inspectable.
///
/// Deletes are intents keyed by record identity, so a delete staged after a
/// save of the same record collapses to just the delete.
public actor SyncOutbox {
    /// A staged save: the record, archived, plus the identity needed to
    /// rebuild its ID without unarchiving.
    public struct StagedSave: Codable, Hashable, Sendable {
        public var zoneName: String
        public var recordName: String
        public var recordType: String
        public var archivedRecord: Data
    }

    /// A staged delete. The owner travels along because shared-zone
    /// identities are meaningless without it.
    public struct StagedDelete: Codable, Hashable, Sendable {
        public var zoneName: String
        public var ownerName: String
        public var recordName: String
        public var recordType: String
    }

    private struct Manifest: Codable {
        var saves: [String: StagedSave]
        var deletes: [String: StagedDelete]

        static let empty = Manifest(saves: [:], deletes: [:])
    }

    private let url: URL
    private var manifest: Manifest

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } else {
            manifest = .empty
        }
    }

    private static func key(zoneName: String, recordName: String) -> String {
        zoneName + "/" + recordName
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(manifest)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: nil)
        try data.write(to: url, options: .atomic)
    }

    /// Stages a record save, superseding any staged delete of the same
    /// record (resurrecting then re-saving is just a save).
    public func stageSave(_ record: CKRecord) throws {
        try stageSaves([record])
    }

    /// Batch variant used by imports and other multi-record mutations. The
    /// manifest remains crash-durable, but one logical mutation pays for one
    /// atomic file replacement instead of rewriting the entire outbox per row.
    public func stageSaves(_ records: [CKRecord]) throws {
        guard !records.isEmpty else { return }
        for record in records {
            let zoneName = record.recordID.zoneID.zoneName
            let key = Self.key(zoneName: zoneName, recordName: record.recordID.recordName)
            let archived = try NSKeyedArchiver.archivedData(
                withRootObject: record, requiringSecureCoding: true)
            manifest.saves[key] = StagedSave(
                zoneName: zoneName, recordName: record.recordID.recordName,
                recordType: record.recordType, archivedRecord: archived)
            manifest.deletes.removeValue(forKey: key)
        }
        try persist()
    }

    /// Stages a record delete, collapsing any staged save of the same record.
    public func stageDelete(recordID: CKRecord.ID, recordType: String) throws {
        try stageDeletes([(recordID, recordType)])
    }

    /// Batch delete counterpart to stageSaves.
    public func stageDeletes(_ records: [(CKRecord.ID, String)]) throws {
        guard !records.isEmpty else { return }
        for (recordID, recordType) in records {
            let key = Self.key(
                zoneName: recordID.zoneID.zoneName, recordName: recordID.recordName)
            manifest.saves.removeValue(forKey: key)
            manifest.deletes[key] = StagedDelete(
                zoneName: recordID.zoneID.zoneName, ownerName: recordID.zoneID.ownerName,
                recordName: recordID.recordName, recordType: recordType)
        }
        try persist()
    }

    /// Drops staged intents the engine confirms sent, by record identity.
    public func removeStaged(recordNames: Set<String>) throws {
        manifest.saves = manifest.saves.filter { !recordNames.contains($0.value.recordName) }
        manifest.deletes = manifest.deletes.filter { !recordNames.contains($0.value.recordName) }
        try persist()
    }

    public var stagedSaves: [StagedSave] { Array(manifest.saves.values) }
    public var stagedDeletes: [StagedDelete] { Array(manifest.deletes.values) }
    public var isEmpty: Bool { manifest.saves.isEmpty && manifest.deletes.isEmpty }

    /// Unarchives one staged save. A record that no longer unarchives is
    /// corruption, not a silent skip: callers surface it, never drop it.
    public func unarchive(_ save: StagedSave) throws -> CKRecord {
        guard
            let record = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKRecord.self, from: save.archivedRecord)
        else {
            throw OutboxError.unreadableStagedRecord(save.recordName)
        }
        return record
    }

    public enum OutboxError: Error {
        case unreadableStagedRecord(String)
    }
}
