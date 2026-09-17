import Foundation
import ProgrammeCore
import SwiftData

/// Translates between persistent models and the domain's value types.
/// Model objects never leave this boundary.
public enum MatchMapper {

    public static func descriptor(from model: MatchModel, teamName: String, teamShortName: String) throws
        -> MatchDescriptor
    {
        let rules =
            (try? ProgrammeCoding.decoder.decode(MatchRules.self, from: model.rulesData)) ?? .highSchool
        let profile =
            (try? ProgrammeCoding.decoder.decode(StatProfile.self, from: model.statProfileData)) ?? .maxPreps
        return MatchDescriptor(
            id: model.matchID,
            teamID: TeamID(model.teamIdentifier),
            seasonID: model.season.map { SeasonID($0.identifier) },
            teamName: teamName,
            teamShortName: teamShortName,
            opponentName: model.opponentName,
            opponentShortName: model.opponentShortName,
            kickoff: model.kickoff,
            venue: model.venue,
            rules: rules,
            statProfile: profile,
            tracking: model.tracking,
            competition: model.competition
        )
    }

    public static func roster(from model: MatchModel) -> RosterSnapshot {
        (try? ProgrammeCoding.decoder.decode(RosterSnapshot.self, from: model.rosterData)) ?? .empty
    }

    public static func opponentRoster(from model: MatchModel) -> RosterSnapshot {
        (try? ProgrammeCoding.decoder.decode(RosterSnapshot.self, from: model.opponentRosterData)) ?? .empty
    }

    public static func context(
        from model: MatchModel, teamName: String, teamShortName: String
    ) throws -> MatchContext {
        let descriptor = try descriptor(from: model, teamName: teamName, teamShortName: teamShortName)
        let events = try model.events.map { try $0.domainEvent() }
        return MatchContext(
            descriptor: descriptor,
            roster: roster(from: model),
            opponentRoster: opponentRoster(from: model),
            events: events,
            clock: model.clockAnchor,
            phase: model.phase,
            finalizedAt: model.finalizedAt
        )
    }

    /// Write configuration and state back onto the model. Does not touch events.
    public static func write(context: MatchContext, into model: MatchModel) throws {
        model.teamIdentifier = context.descriptor.teamID.rawValue
        model.opponentName = context.descriptor.opponentName
        model.opponentShortName = context.descriptor.opponentShortName
        model.kickoff = context.descriptor.kickoff
        model.venueRaw = context.descriptor.venue.rawValue
        model.competition = context.descriptor.competition
        model.trackingRaw = context.descriptor.tracking.rawValue
        model.rulesData = try ProgrammeCoding.encoder.encode(context.rules)
        model.statProfileData = try ProgrammeCoding.encoder.encode(context.profile)
        model.rosterData = try ProgrammeCoding.encoder.encode(context.roster)
        model.opponentRosterData = try ProgrammeCoding.encoder.encode(context.opponentRoster)
        model.clockAnchor = context.clock
        model.phase = context.phase
        model.finalizedAt = context.finalizedAt
        model.updatedAt = Date()
    }

    /// Refresh the denormalised values that list screens read. These are a cache
    /// of derived state, never a source of truth.
    public static func writeCache(snapshot: MatchSnapshot, into model: MatchModel) {
        model.cachedScoreUs = snapshot.score.us
        model.cachedScoreOpponent = snapshot.score.opponent
        model.cachedResultRaw = snapshot.result?.rawValue
        model.cachedEventCount = snapshot.totalEventCount
        model.cachedNeedsReviewCount = snapshot.needsReviewCount
        model.updatedAt = Date()
    }
}
