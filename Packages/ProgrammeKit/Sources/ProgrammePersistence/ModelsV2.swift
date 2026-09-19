import Foundation
import ProgrammeCore
import SwiftData

/// Frozen V2 model graph, byte-for-byte the shape Programme shipped with
/// match locations but before per-match reminders. These types exist for one
/// job only: letting the V2 → V3 migration stage read a real V2 store.
///
/// They are nested so the entity names resolve exactly as the original
/// top-level classes did, while the live code uses the current models.
/// Do not add features here; V2 is history.
enum SchemaV2Models {

    @Model
    final class TeamModel {
        #Index<TeamModel>([\.identifier])
        #Unique<TeamModel>([\.identifier])

        var identifier: UUID = UUID()
        var name: String = ""
        var shortName: String = ""
        var mascot: String?
        var primaryColorHex: String?
        var secondaryColorHex: String?
        var createdAt: Date = Date()

        @Relationship(deleteRule: .cascade, inverse: \PlayerModel.team)
        var players: [PlayerModel] = []

        @Relationship(deleteRule: .cascade, inverse: \SeasonModel.team)
        var seasons: [SeasonModel] = []

        init() {}
    }

    @Model
    final class SeasonModel {
        #Index<SeasonModel>([\.identifier])
        #Unique<SeasonModel>([\.identifier])

        var identifier: UUID = UUID()
        var name: String = ""
        var startDate: Date = Date()
        var endDate: Date?
        var isCurrent: Bool = false
        var team: TeamModel?

        @Relationship(deleteRule: .cascade, inverse: \MatchModel.season)
        var matches: [MatchModel] = []

        init() {}
    }

    @Model
    final class PlayerModel {
        #Index<PlayerModel>([\.identifier], [\.jerseyNumber])
        #Unique<PlayerModel>([\.identifier])

        var identifier: UUID = UUID()
        var firstName: String = ""
        var lastName: String = ""
        var jerseyNumber: Int?
        var positionRaw: String?
        var classYear: String?
        var isOnRoster: Bool = true
        var createdAt: Date = Date()
        var team: TeamModel?

        init() {}
    }

    @Model
    final class MatchModel {
        #Index<MatchModel>([\.identifier], [\.kickoff])
        #Unique<MatchModel>([\.identifier])

        var identifier: UUID = UUID()
        var teamIdentifier: UUID = UUID()
        var opponentName: String = ""
        var opponentShortName: String = ""
        var kickoff: Date = Date()
        var venueRaw: String = Venue.home.rawValue
        var competition: String?
        var locationData: Data?
        // No reminderMinutesBefore: V2 predates per-match reminders.
        var trackingRaw: String = OpponentTrackingMode.ourTeam.rawValue
        var phaseRaw: String = MatchPhase.scheduled.rawValue
        var finalizedAt: Date?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        var rulesData: Data = Data()
        var statProfileData: Data = Data()
        var rosterData: Data = Data()
        var opponentRosterData: Data = Data()

        var clockPeriod: Int = 1
        var clockElapsed: Double = 0
        var clockRunningSince: Date?

        var cachedScoreUs: Int = 0
        var cachedScoreOpponent: Int = 0
        var cachedResultRaw: String?
        var cachedEventCount: Int = 0
        var cachedNeedsReviewCount: Int = 0

        var season: SeasonModel?

        @Relationship(deleteRule: .cascade, inverse: \MatchEventModel.match)
        var events: [MatchEventModel] = []

        init() {}
    }

    @Model
    final class MatchEventModel {
        #Index<MatchEventModel>([\.identifier], [\.sequence])
        #Unique<MatchEventModel>([\.identifier])

        var identifier: UUID = UUID()
        var matchIdentifier: UUID = UUID()
        var period: Int = 1
        var secondsElapsed: Int = 0
        var sequence: Int = 0
        var recordedAt: Date = Date()
        var revision: Int = 1
        var voidedAt: Date?
        var note: String?
        var categoryRaw: String = EventCategory.structural.rawValue
        var awaitsAttribution: Bool = false

        var payloadData: Data = Data()
        var revisionsData: Data = Data()

        var match: MatchModel?

        init() {}
    }
}
