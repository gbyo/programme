import Foundation
import ProgrammeCollaboration
import ProgrammeCore
import SwiftData

/// ID-preserving upserts for incoming shared records, so a fresh device or
/// a newly invited collaborator reconstructs the workspace from the zone.
///
/// Every `ensure` is idempotent by stable ID: re-applying a materialized
/// record converges (scalars refresh, structure never duplicates). Parents
/// are the caller's responsibility — the applier defers a record whose
/// parent is not local yet, so these methods throw `StoreError.teamNotFound`
/// rather than inventing parents.
///
/// Policy notes:
/// - Teams and seasons refresh mutable scalars on re-apply; `createdAt`
///   stays the local copy's own.
/// - A season arriving with `isCurrent` becomes current through the same
///   path as local season switches, unseating the previous one.
/// - Players refresh through the same snapshot path as local edits.
/// - Matches arrive with their frozen roster and config. A missing match is
///   created whole (descriptor, roster, config, phase, finalization,
///   clock). An existing match keeps its live state: only a missing
///   finalization is filled in. Phase, clock, and rosters stay under the
///   authority of the event stream and the local session, so a stale record
///   can never regress a live match.
extension MatchStore: SyncJournal {
    public func readEvents(for matchID: MatchID) throws -> [MatchEvent] {
        try context(for: matchID).events
    }

    public func locateEvent(_ eventID: EventID, inTeam teamID: TeamID) throws -> MatchID? {
        // Deletions arrive without a match reference, so the match is found
        // by scan. Deletions are rare (a descope, not a steady-state write)
        // and scoped to one team, so a linear pass is proportionate.
        for item in try matches(teamID: teamID) {
            if try context(for: item.id).events.contains(where: { $0.id == eventID }) {
                return item.id
            }
        }
        return nil
    }

    public func writeEffects(_ effects: [MatchEffect], to matchID: MatchID) throws {
        try apply(effects, to: matchID)
        onMatchChanged?(matchID)
    }

    public func teamExists(_ teamID: TeamID) throws -> Bool {
        try teams().contains { $0.id == teamID }
    }

    public func seasonExists(_ seasonID: SeasonID, inTeam teamID: TeamID) throws -> Bool {
        (try? seasons(teamID: teamID))?.contains { $0.id == seasonID } ?? false
    }

    public func playerExists(_ playerID: PlayerID, inTeam teamID: TeamID) throws -> Bool {
        guard let roster = try? roster(teamID: teamID, includeFormer: true) else { return false }
        return roster[playerID] != nil
    }

    public func matchExists(_ matchID: MatchID, inTeam teamID: TeamID) throws -> Bool {
        (try? matches(teamID: teamID))?.contains { $0.id == matchID } ?? false
    }

    public func ensureTeam(_ team: TeamRecord) throws {
        if try teams().contains(where: { $0.id == team.teamID }) {
            try updateTeam(
                team.teamID, name: team.name, shortName: team.shortName, mascot: team.mascot,
                primaryColorHex: team.primaryColorHex, secondaryColorHex: team.secondaryColorHex)
            return
        }
        let model = TeamModel(
            identifier: team.teamID.rawValue, name: team.name, shortName: team.shortName,
            mascot: team.mascot, primaryColorHex: team.primaryColorHex,
            secondaryColorHex: team.secondaryColorHex)
        modelContext.insert(model)
        try modelContext.save()
    }

    public func ensureSeason(_ season: SeasonRecord) throws {
        guard try teamExists(season.teamID) else { throw StoreError.teamNotFound }
        let rawID = season.seasonID.rawValue
        if let existing = try modelContext.fetch(
            FetchDescriptor<SeasonModel>(predicate: #Predicate { $0.identifier == rawID })
        ).first {
            existing.name = season.name
            existing.startDate = season.startDate
            existing.endDate = season.endDate
            try modelContext.save()
        } else {
            guard let team = try teamModel(season.teamID) else { throw StoreError.teamNotFound }
            let model = SeasonModel(
                identifier: season.seasonID.rawValue, name: season.name,
                startDate: season.startDate, endDate: season.endDate, isCurrent: false)
            model.team = team
            modelContext.insert(model)
            try modelContext.save()
        }
        if season.isCurrent {
            try setCurrentSeason(teamID: season.teamID, seasonID: season.seasonID)
        }
    }

    public func ensurePlayer(_ player: PlayerRecord) throws {
        guard try teamExists(player.teamID) else { throw StoreError.teamNotFound }
        if try playerExists(player.playerID, inTeam: player.teamID) {
            try updatePlayer(player.snapshot)
        } else {
            _ = try addPlayer(teamID: player.teamID, player.snapshot)
        }
    }

    public func ensureMatch(_ match: MatchRecord) throws {
        let d = match.descriptor
        guard try teamExists(d.teamID) else { throw StoreError.teamNotFound }
        let rawID = d.id.rawValue
        if let model = try modelContext.fetch(
            FetchDescriptor<MatchModel>(predicate: #Predicate { $0.identifier == rawID })
        ).first {
            // Live state wins. Only finalization fills forward: once a match
            // is finalized locally it stays finalized, and an unfinalized
            // local match adopts a remote finalization.
            if model.finalizedAt == nil, let finalizedAt = match.finalizedAt {
                model.finalizedAt = finalizedAt
                try modelContext.save()
                onMatchChanged?(d.id)
            }
            return
        }
        let model = MatchModel(
            identifier: d.id.rawValue, teamIdentifier: d.teamID.rawValue,
            opponentName: d.opponentName, opponentShortName: d.opponentShortName,
            kickoff: d.kickoff, venue: d.venue, location: d.location,
            competition: d.competition, tracking: d.tracking)
        if let seasonID = d.seasonID {
            model.season = try teamModel(d.teamID)?.seasons.first {
                $0.identifier == seasonID.rawValue
            }
        }
        model.rulesData = try ProgrammeCoding.encoder.encode(d.rules)
        model.statProfileData = try ProgrammeCoding.encoder.encode(d.statProfile)
        model.rosterData = try ProgrammeCoding.encoder.encode(match.roster)
        model.opponentRosterData = try ProgrammeCoding.encoder.encode(match.opponentRoster)
        model.phase = match.phase
        model.finalizedAt = match.finalizedAt
        model.clockAnchor = ClockAnchor(
            period: match.clockPeriod, elapsedAtAnchor: match.clockElapsed,
            runningSince: match.clockRunningSince)
        modelContext.insert(model)
        try modelContext.save()
        onMatchChanged?(d.id)
    }

    private func teamModel(_ id: TeamID) throws -> TeamModel? {
        let raw = id.rawValue
        var descriptor = FetchDescriptor<TeamModel>(predicate: #Predicate { $0.identifier == raw })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
