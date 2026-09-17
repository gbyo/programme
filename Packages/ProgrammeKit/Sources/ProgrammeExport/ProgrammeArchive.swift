import Foundation
import ProgrammeCore

/// The current `.programme` archive schema.
public let programmeArchiveSchemaVersion = 1

/// The oldest schema this build can still read.
public let programmeArchiveMinimumReadableVersion = 1

public struct ArchiveManifest: Codable, Hashable, Sendable {
    /// Identifies the format even if the file is renamed.
    public var format: String
    public var schemaVersion: Int
    public var createdAt: Date
    public var generator: String
    public var teamName: String
    public var matchCount: Int

    public init(
        format: String = "org.programme.archive",
        schemaVersion: Int = programmeArchiveSchemaVersion,
        createdAt: Date = Date(),
        generator: String,
        teamName: String,
        matchCount: Int
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.generator = generator
        self.teamName = teamName
        self.matchCount = matchCount
    }
}

/// One match, complete enough to be reconstructed with no database and no app
/// state. This is deliberately the same shape as `MatchContext` plus provenance.
public struct ArchivedMatch: Codable, Hashable, Sendable {
    public var descriptor: MatchDescriptor
    public var roster: RosterSnapshot
    public var opponentRoster: RosterSnapshot
    public var events: [MatchEvent]
    public var clock: ClockAnchor
    public var phase: MatchPhase
    public var finalizedAt: Date?
    /// Which categories this match was tracking, preserved so that a zero is
    /// never confused with an unknown after a round trip.
    public var trackedStats: [String]

    public init(context: MatchContext) {
        self.descriptor = context.descriptor
        self.roster = context.roster
        self.opponentRoster = context.opponentRoster
        self.events = context.events
        self.clock = context.clock
        self.phase = context.phase
        self.finalizedAt = context.finalizedAt
        self.trackedStats = context.profile.tracked.map(\.rawValue).sorted()
    }

    public var context: MatchContext {
        MatchContext(
            descriptor: descriptor,
            roster: roster,
            opponentRoster: opponentRoster,
            events: events,
            clock: clock,
            phase: phase,
            finalizedAt: finalizedAt
        )
    }
}

public struct ArchiveAttachment: Codable, Hashable, Sendable {
    public var name: String
    public var contentType: String
    public var data: Data

    public init(name: String, contentType: String, data: Data) {
        self.name = name
        self.contentType = contentType
        self.data = data
    }
}

/// A portable Programme archive. Unknown keys from a newer build are ignored
/// rather than fatal, and every field a future version might add is optional, so
/// an archive stays readable across releases.
public struct ProgrammeArchive: Codable, Hashable, Sendable {
    public var manifest: ArchiveManifest
    public var matches: [ArchivedMatch]
    public var attachments: [ArchiveAttachment]

    public init(manifest: ArchiveManifest, matches: [ArchivedMatch], attachments: [ArchiveAttachment] = []) {
        self.manifest = manifest
        self.matches = matches
        self.attachments = attachments
    }

    public init(
        contexts: [MatchContext],
        teamName: String,
        generator: String = ProgrammeArchive.defaultGenerator,
        attachments: [ArchiveAttachment] = []
    ) {
        self.manifest = ArchiveManifest(
            generator: generator, teamName: teamName, matchCount: contexts.count)
        self.matches = contexts.map(ArchivedMatch.init(context:))
        self.attachments = attachments
    }

    public static let defaultGenerator = "Programme 1.0"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.manifest = try container.decode(ArchiveManifest.self, forKey: .manifest)
        self.matches = try container.decodeIfPresent([ArchivedMatch].self, forKey: .matches) ?? []
        self.attachments =
            try container.decodeIfPresent([ArchiveAttachment].self, forKey: .attachments) ?? []
    }
}

public enum ArchiveError: Error, Sendable, Equatable {
    case notAProgrammeArchive
    case schemaTooNew(found: Int, supported: Int)
    case schemaTooOld(found: Int, minimum: Int)
    case corrupted(String)

    public var message: String {
        switch self {
        case .notAProgrammeArchive:
            "That file isn't a Programme archive."
        case .schemaTooNew(let found, let supported):
            "This archive was written by a newer version of Programme (format \(found); this version reads up to \(supported)). Update Programme to open it."
        case .schemaTooOld(let found, let minimum):
            "This archive uses an old format (\(found)) that this version can no longer read (minimum \(minimum))."
        case .corrupted(let detail):
            "Programme couldn't read that archive. \(detail)"
        }
    }
}

public enum ProgrammeArchiveCoder {

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode(_ archive: ProgrammeArchive) throws -> Data {
        try encoder.encode(archive)
    }

    /// Decode with explicit version gating, then run any migrations needed to
    /// bring an older archive up to the current shape.
    public static func decode(_ data: Data) throws -> ProgrammeArchive {
        let probe: ArchiveProbe
        do {
            probe = try decoder.decode(ArchiveProbe.self, from: data)
        } catch {
            throw ArchiveError.notAProgrammeArchive
        }
        guard probe.manifest.format == "org.programme.archive" else {
            throw ArchiveError.notAProgrammeArchive
        }
        guard probe.manifest.schemaVersion <= programmeArchiveSchemaVersion else {
            throw ArchiveError.schemaTooNew(
                found: probe.manifest.schemaVersion, supported: programmeArchiveSchemaVersion)
        }
        guard probe.manifest.schemaVersion >= programmeArchiveMinimumReadableVersion else {
            throw ArchiveError.schemaTooOld(
                found: probe.manifest.schemaVersion, minimum: programmeArchiveMinimumReadableVersion)
        }
        do {
            let archive = try decoder.decode(ProgrammeArchive.self, from: data)
            return try ArchiveMigrator.migrate(archive)
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.corrupted(String(describing: error))
        }
    }

    private struct ArchiveProbe: Decodable {
        var manifest: ArchiveManifest
    }
}

/// Brings older archives forward. Each step is isolated so adding schema 2 is a
/// new case, not a rewrite.
public enum ArchiveMigrator {
    public static func migrate(_ archive: ProgrammeArchive) throws -> ProgrammeArchive {
        var archive = archive
        while archive.manifest.schemaVersion < programmeArchiveSchemaVersion {
            switch archive.manifest.schemaVersion {
            default:
                // No migration path is defined for this version, which means the
                // constant was bumped without a stage. Fail loudly rather than
                // silently importing a half-understood archive.
                throw ArchiveError.corrupted(
                    "No migration from format \(archive.manifest.schemaVersion).")
            }
        }
        archive.manifest.schemaVersion = programmeArchiveSchemaVersion
        return archive
    }
}
