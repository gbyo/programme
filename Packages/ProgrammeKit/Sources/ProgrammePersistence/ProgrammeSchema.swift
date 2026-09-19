import Foundation
import ProgrammeCore
import SwiftData

public enum ProgrammeSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            SchemaV1Models.TeamModel.self, SchemaV1Models.SeasonModel.self,
            SchemaV1Models.PlayerModel.self, SchemaV1Models.MatchModel.self,
            SchemaV1Models.MatchEventModel.self,
        ]
    }
}

/// V2 adds the optional `locationData` column on matches. Every match created
/// before locations existed migrates with a nil location, which the domain
/// reads as "no location chosen" — scoring never requires one.
public enum ProgrammeSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            SchemaV2Models.TeamModel.self, SchemaV2Models.SeasonModel.self,
            SchemaV2Models.PlayerModel.self, SchemaV2Models.MatchModel.self,
            SchemaV2Models.MatchEventModel.self,
        ]
    }
}

/// V3 adds the optional `reminderMinutesBefore` column on matches. Older
/// stores migrate with nil, which reads as "no reminder" — a purely
/// additive lightweight migration.
public enum ProgrammeSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [TeamModel.self, SeasonModel.self, PlayerModel.self, MatchModel.self, MatchEventModel.self]
    }
}

public enum ProgrammeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [ProgrammeSchemaV1.self, ProgrammeSchemaV2.self, ProgrammeSchemaV3.self]
    }
    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ProgrammeSchemaV1.self, toVersion: ProgrammeSchemaV2.self),
            .lightweight(fromVersion: ProgrammeSchemaV2.self, toVersion: ProgrammeSchemaV3.self),
        ]
    }
}

public enum ProgrammeStore {
    public static var schema: Schema { Schema(versionedSchema: ProgrammeSchemaV3.self) }

    /// The on-disk container. Local-first: no account, no network, no CloudKit
    /// requirement. Scoring a match never touches any of those.
    public static func container(
        inMemory: Bool = false,
        url: URL? = nil,
        cloudKit: Bool = false
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let url {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: cloudKit ? .automatic : .none
            )
        }
        return try ModelContainer(
            for: schema, migrationPlan: ProgrammeMigrationPlan.self, configurations: [configuration])
    }

    /// A container preloaded with the sample team, season and matches. Used by
    /// previews and by the "explore with sample data" path on first run.
    @MainActor
    public static func previewContainer() throws -> ModelContainer {
        let container = try container(inMemory: true)
        try seedSampleData(into: container.mainContext)
        return container
    }

    @MainActor
    public static func seedSampleData(into context: ModelContext, includeLiveMatch: Bool = false) throws {
        // Idempotent: seeding twice must not duplicate or resurrect anything.
        let sampleTeamID = ProgrammeSample.teamID.rawValue
        var existing = FetchDescriptor<TeamModel>(
            predicate: #Predicate { $0.identifier == sampleTeamID })
        existing.fetchLimit = 1
        if try context.fetch(existing).first != nil { return }

        let team = TeamModel(
            identifier: ProgrammeSample.teamID.rawValue,
            name: ProgrammeSample.teamName,
            shortName: ProgrammeSample.teamShortName,
            mascot: "Wildcats",
            primaryColorHex: "1F3A5F",
            secondaryColorHex: "C8A44B"
        )
        context.insert(team)

        for snapshot in ProgrammeSample.roster.players {
            let player = PlayerModel(
                identifier: snapshot.id.rawValue,
                firstName: snapshot.firstName,
                lastName: snapshot.lastName,
                jerseyNumber: snapshot.jerseyNumber,
                position: snapshot.position,
                classYear: snapshot.classYear
            )
            player.team = team
            context.insert(player)
        }

        let season = SeasonModel(
            identifier: ProgrammeSample.seasonID.rawValue,
            name: "2027",
            startDate: ProgrammeSample.kickoff(daysFromNow: -40),
            isCurrent: true
        )
        season.team = team
        context.insert(season)

        for matchContext in ProgrammeSample.seasonContexts() {
            try insert(context: matchContext, into: context, season: season)
        }

        if includeLiveMatch {
            // Its own identifier: the sample season already contains a finished
            // match against the same opponent.
            try insert(
                context: ProgrammeSample.liveFirstHalfContext(seed: "match.live"), into: context,
                season: season)
        }

        // An upcoming match, so Today has something to prepare.
        let upcoming = ProgrammeSample.upcomingDescriptor()
        let upcomingContext = MatchContext(descriptor: upcoming, roster: ProgrammeSample.roster)
        try insert(context: upcomingContext, into: context, season: season)

        try context.save()
    }

    @MainActor
    static func insert(context matchContext: MatchContext, into modelContext: ModelContext, season: SeasonModel)
        throws
    {
        let model = MatchModel(
            identifier: matchContext.descriptor.id.rawValue,
            teamIdentifier: matchContext.descriptor.teamID.rawValue,
            opponentName: matchContext.descriptor.opponentName,
            opponentShortName: matchContext.descriptor.opponentShortName,
            kickoff: matchContext.descriptor.kickoff,
            venue: matchContext.descriptor.venue,
            competition: matchContext.descriptor.competition,
            tracking: matchContext.descriptor.tracking
        )
        model.season = season
        try MatchMapper.write(context: matchContext, into: model)
        modelContext.insert(model)
        for event in matchContext.events {
            let eventModel = try MatchEventModel(event: event)
            eventModel.match = model
            modelContext.insert(eventModel)
        }
        let snapshot = StatEngine.snapshot(context: matchContext)
        MatchMapper.writeCache(snapshot: snapshot, into: model)
    }
}
