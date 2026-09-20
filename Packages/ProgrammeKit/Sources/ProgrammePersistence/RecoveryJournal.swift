import Foundation
import ProgrammeCore

/// The version of the journal format. Written into every header so an older
/// journal left behind by a previous build is recognised rather than misread.
public let programmeJournalVersion = 1

public struct JournalHeader: Codable, Hashable, Sendable {
    public var version: Int
    public var descriptor: MatchDescriptor
    public var roster: RosterSnapshot
    public var opponentRoster: RosterSnapshot
    public var openedAt: Date

    public init(
        version: Int = programmeJournalVersion,
        descriptor: MatchDescriptor,
        roster: RosterSnapshot,
        opponentRoster: RosterSnapshot,
        openedAt: Date = Date()
    ) {
        self.version = version
        self.descriptor = descriptor
        self.roster = roster
        self.opponentRoster = opponentRoster
        self.openedAt = openedAt
    }
}

public enum JournalLine: Codable, Hashable, Sendable {
    case header(JournalHeader)
    case effect(MatchEffect)
    case closed(Date)
}

/// An append-only write-ahead log that sits alongside the SwiftData store.
///
/// This exists because a stat keeper cannot be asked to re-watch a match. Every
/// recorded event is appended and flushed to disk before the UI reports success,
/// so a crash, a force-quit or a battery death costs at most the event in flight.
/// The journal is also completely self-describing: a match can be reconstructed
/// from its journal alone, with no database.
public final class RecoveryJournal: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var handles: [UUID: FileHandle] = [:]

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appending(path: "Programme/Recovery", directoryHint: .isDirectory)
    }

    public static func makeDefault() throws -> RecoveryJournal {
        try RecoveryJournal(directory: try defaultDirectory())
    }

    private func url(for matchID: MatchID) -> URL {
        directory.appending(path: "\(matchID.rawValue.uuidString).journal")
    }

    public func exists(for matchID: MatchID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: matchID).path(percentEncoded: false))
    }

    /// Begin (or reopen) the journal for a match. Writing the header is what
    /// makes the journal independently replayable.
    public func open(
        matchID: MatchID, descriptor: MatchDescriptor, roster: RosterSnapshot,
        opponentRoster: RosterSnapshot
    ) throws {
        let fileURL = url(for: matchID)
        let fileManager = FileManager.default
        let isNew = !fileManager.fileExists(atPath: fileURL.path(percentEncoded: false))
        if isNew {
            fileManager.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        }
        if isNew {
            try write(
                .header(
                    JournalHeader(
                        descriptor: descriptor, roster: roster, opponentRoster: opponentRoster)),
                to: matchID)
        }
    }

    /// Append one committed action and flush it once. The on-disk representation
    /// remains one JournalLine per effect for backward-compatible replay, but
    /// all of the action's bytes are written together before the single fsync.
    public func append(_ effects: [MatchEffect], for matchID: MatchID) throws {
        guard !effects.isEmpty else { return }
        var data = Data()
        for effect in effects {
            var line = try ProgrammeCoding.encoder.encode(JournalLine.effect(effect))
            line.append(0x0A)
            data.append(line)
        }
        try write(data, to: matchID)
    }

    private func write(_ line: JournalLine, to matchID: MatchID) throws {
        var data = try ProgrammeCoding.encoder.encode(line)
        data.append(0x0A)
        try write(data, to: matchID)
    }

    private func write(_ data: Data, to matchID: MatchID) throws {
        lock.lock()
        defer { lock.unlock() }
        let handle = try handleLocked(for: matchID)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        // Push the complete action past the app's buffers before success returns.
        fsync(handle.fileDescriptor)
    }

    private func handleLocked(for matchID: MatchID) throws -> FileHandle {
        if let handle = handles[matchID.rawValue] { return handle }
        let fileURL = url(for: matchID)
        if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        handles[matchID.rawValue] = handle
        return handle
    }

    /// Replay a journal into a match context. Tolerates a truncated final line,
    /// which is what a crash mid-write looks like.
    public func recover(matchID: MatchID) throws -> MatchContext? {
        let fileURL = url(for: matchID)
        guard let contents = try? Data(contentsOf: fileURL), !contents.isEmpty else { return nil }
        var context: MatchContext?
        for lineData in contents.split(separator: 0x0A) {
            guard let line = try? ProgrammeCoding.decoder.decode(JournalLine.self, from: Data(lineData))
            else { continue }
            switch line {
            case .header(let header):
                context = MatchContext(
                    descriptor: header.descriptor,
                    roster: header.roster,
                    opponentRoster: header.opponentRoster)
            case .effect(let effect):
                guard var current = context else { continue }
                MatchEngine.apply([effect], to: &current)
                context = current
            case .closed:
                break
            }
        }
        return context
    }

    /// Everything the journal knows without replaying: used by the launch check.
    public func summary(matchID: MatchID) -> JournalSummary? {
        let fileURL = url(for: matchID)
        guard let contents = try? Data(contentsOf: fileURL) else { return nil }
        var header: JournalHeader?
        var eventCount = 0
        var lastEventAt: Date?
        var closed = false
        for lineData in contents.split(separator: 0x0A) {
            guard let line = try? ProgrammeCoding.decoder.decode(JournalLine.self, from: Data(lineData))
            else { continue }
            switch line {
            case .header(let value): header = value
            case .effect(let effect):
                if case .appendEvent(let event) = effect {
                    eventCount += 1
                    lastEventAt = event.recordedAt
                }
            case .closed: closed = true
            }
        }
        guard let header else { return nil }
        return JournalSummary(
            matchID: matchID, descriptor: header.descriptor, eventCount: eventCount,
            lastEventAt: lastEventAt, isClosed: closed)
    }

    /// Journals for every match that was left open.
    public func openJournals() -> [JournalSummary] {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "journal",
                let uuid = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            else { return nil }
            return summary(matchID: MatchID(uuid))
        }
        .filter { !$0.isClosed }
        .sorted { ($0.lastEventAt ?? .distantPast) > ($1.lastEventAt ?? .distantPast) }
    }

    /// Mark a match complete. The journal is kept until maintenance clears it,
    /// so a finalized match can still be reconstructed if the store is damaged.
    public func close(matchID: MatchID) throws {
        try write(.closed(Date()), to: matchID)
        lock.lock()
        defer { lock.unlock() }
        try? handles[matchID.rawValue]?.close()
        handles[matchID.rawValue] = nil
    }

    public func discard(matchID: MatchID) {
        lock.lock()
        try? handles[matchID.rawValue]?.close()
        handles[matchID.rawValue] = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: url(for: matchID))
    }

    /// Remove journals for matches closed more than `age` ago. Opportunistic
    /// foreground upkeep only; never required for correctness. Recovery never
    /// depends on this running: every journal stays replayable until it is
    /// pruned, and pruning only removes journals already marked closed.
    /// Returns the number of journals removed, so callers can decide whether
    /// anything downstream needs to react (nothing in the widgets reads
    /// recovery journals, so pruning alone never refreshes them).
    @discardableResult
    public func pruneClosedJournals(olderThan age: TimeInterval = 60 * 60 * 24 * 30) -> Int {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }
        var removed = 0
        for file in files where file.pathExtension == "journal" {
            guard let uuid = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            guard let summary = summary(matchID: MatchID(uuid)), summary.isClosed else { continue }
            let modified =
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
            if Date().timeIntervalSince(modified) > age {
                try? FileManager.default.removeItem(at: file)
                removed += 1
            }
        }
        return removed
    }
}

/// Testable policy for closed-journal housekeeping. Pruning is tiny work that
/// used to be scheduled as a recurring background processing task; it now
/// runs opportunistically at naturally occurring foreground points (launch,
/// scorer close, moving to the background). The policy keeps that cheap by
/// throttling scans to `minimumInterval` while preserving the retention
/// window, and it never touches anything the widgets read.
public struct JournalUpkeepPolicy: Hashable, Sendable {
    /// Closed journals older than this are removed. Defaults to 30 days.
    public var retention: TimeInterval
    /// Minimum time between upkeep scans. Defaults to 24 hours.
    public var minimumInterval: TimeInterval

    public init(
        retention: TimeInterval = 60 * 60 * 24 * 30,
        minimumInterval: TimeInterval = 60 * 60 * 24
    ) {
        self.retention = retention
        self.minimumInterval = minimumInterval
    }

    /// Whether a scan is due. Always due when upkeep has never run.
    public func isDue(now: Date, lastRunAt: Date?) -> Bool {
        guard let lastRunAt else { return true }
        return now.timeIntervalSince(lastRunAt) >= minimumInterval
    }

    /// Prune closed journals older than `retention`. Returns the number
    /// removed. Open journals are never touched.
    @discardableResult
    public func perform(on journal: RecoveryJournal) -> Int {
        journal.pruneClosedJournals(olderThan: retention)
    }
}

public struct JournalSummary: Hashable, Sendable, Identifiable {
    public var matchID: MatchID
    public var descriptor: MatchDescriptor
    public var eventCount: Int
    public var lastEventAt: Date?
    public var isClosed: Bool

    public var id: MatchID { matchID }
}
