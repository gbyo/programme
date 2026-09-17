import Foundation
import ProgrammeCore
import SwiftData

/// A Sendable summary of a match, for lists and for handing across actors.
public struct MatchListItem: Identifiable, Hashable, Sendable {
    public var id: MatchID
    public var opponentName: String
    public var kickoff: Date
    public var venue: Venue
    public var phase: MatchPhase
    public var score: SidePair<Int>
    public var result: MatchResult?
    public var eventCount: Int
    public var needsReviewCount: Int
    public var competition: String?
    public var seasonName: String?

    public var isInterrupted: Bool {
        phase == .inPeriod || phase == .periodBreak || phase == .awaitingFinalization
    }

    /// "W 3–1" once played, otherwise the kickoff.
    public var resultText: String? {
        guard phase == .finalized, let result else { return nil }
        return "\(result.letter) \(score.us)–\(score.opponent)"
    }
}

public struct TeamListItem: Identifiable, Hashable, Sendable {
    public var id: TeamID
    public var name: String
    public var shortName: String
    public var playerCount: Int
    public var seasonCount: Int
}

public enum StoreError: Error, Sendable {
    case teamNotFound
    case matchNotFound
    case playerNotFound
    case playerHasMatchHistory(String)
    case noCurrentSeason
}

/// All database work that should not happen on the main actor.
///
/// Live scoring keeps its state in memory and writes through here, so recording
/// an event never waits on a fetch. The UI reads browsing lists with `@Query`
/// against the main context; everything that mutates goes through this actor.
@ModelActor
public actor MatchStore {

    // MARK: - Teams

    public func createTeam(
        name: String, shortName: String?, mascot: String? = nil,
        primaryColorHex: String? = nil, secondaryColorHex: String? = nil
    ) throws -> TeamID {
        let team = TeamModel(
            name: name, shortName: shortName, mascot: mascot,
            primaryColorHex: primaryColorHex, secondaryColorHex: secondaryColorHex)
        modelContext.insert(team)
        try modelContext.save()
        return team.teamID
    }

    public func teams() throws -> [TeamListItem] {
        let descriptor = FetchDescriptor<TeamModel>(sortBy: [SortDescriptor(\.name)])
        return try modelContext.fetch(descriptor).map {
            TeamListItem(
                id: $0.teamID, name: $0.name, shortName: $0.shortName,
                playerCount: $0.players.filter(\.isOnRoster).count, seasonCount: $0.seasons.count)
        }
    }

    public func updateTeam(
        _ teamID: TeamID, name: String, shortName: String, mascot: String?,
        primaryColorHex: String?, secondaryColorHex: String?
    ) throws {
        guard let team = try team(teamID) else { throw StoreError.teamNotFound }
        team.name = name
        team.shortName = shortName
        team.mascot = mascot
        team.primaryColorHex = primaryColorHex
        team.secondaryColorHex = secondaryColorHex
        try modelContext.save()
    }

    // MARK: - Seasons

    public func createSeason(
        teamID: TeamID, name: String, startDate: Date, endDate: Date?, makeCurrent: Bool = true
    ) throws -> SeasonID {
        guard let team = try team(teamID) else { throw StoreError.teamNotFound }
        if makeCurrent {
            for season in team.seasons { season.isCurrent = false }
        }
        let season = SeasonModel(
            name: name, startDate: startDate, endDate: endDate, isCurrent: makeCurrent)
        season.team = team
        modelContext.insert(season)
        try modelContext.save()
        return season.seasonID
    }

    public func currentSeasonID(teamID: TeamID) throws -> SeasonID? {
        guard let team = try team(teamID) else { throw StoreError.teamNotFound }
        let season = team.seasons.first(where: \.isCurrent) ?? team.seasons.max { $0.startDate < $1.startDate }
        return season.map { SeasonID($0.identifier) }
    }

    // MARK: - Roster

    public func roster(teamID: TeamID, includeFormer: Bool = false) throws -> RosterSnapshot {
        guard let team = try team(teamID) else { throw StoreError.teamNotFound }
        let players = team.players.filter { includeFormer || $0.isOnRoster }.map(\.snapshot)
        return RosterSnapshot(players: players)
    }

    @discardableResult
    public func addPlayer(teamID: TeamID, _ snapshot: PlayerSnapshot) throws -> PlayerID {
        guard let team = try team(teamID) else { throw StoreError.teamNotFound }
        let player = PlayerModel(
            identifier: snapshot.id.rawValue,
            firstName: snapshot.firstName,
            lastName: snapshot.lastName,
            jerseyNumber: snapshot.jerseyNumber,
            position: snapshot.position,
            classYear: snapshot.classYear,
            isOnRoster: snapshot.isOnRoster
        )
        player.team = team
        modelContext.insert(player)
        try modelContext.save()
        return player.playerID
    }

    /// Bulk insert for CSV and camera import. One save, so a 30-player import is
    /// a single transaction.
    @discardableResult
    public func addPlayers(teamID: TeamID, _ snapshots: [PlayerSnapshot]) throws -> [PlayerID] {
        guard let team = try team(teamID) else { throw StoreError.teamNotFound }
        var ids: [PlayerID] = []
        for snapshot in snapshots {
            let player = PlayerModel(
                identifier: snapshot.id.rawValue,
                firstName: snapshot.firstName,
                lastName: snapshot.lastName,
                jerseyNumber: snapshot.jerseyNumber,
                position: snapshot.position,
                classYear: snapshot.classYear,
                isOnRoster: snapshot.isOnRoster
            )
            player.team = team
            modelContext.insert(player)
            ids.append(player.playerID)
        }
        try modelContext.save()
        return ids
    }

    public func updatePlayer(_ snapshot: PlayerSnapshot) throws {
        guard let player = try player(snapshot.id) else { throw StoreError.playerNotFound }
        player.firstName = snapshot.firstName
        player.lastName = snapshot.lastName
        player.jerseyNumber = snapshot.jerseyNumber
        player.position = snapshot.position
        player.classYear = snapshot.classYear
        player.isOnRoster = snapshot.isOnRoster
        try modelContext.save()
    }

    /// Players who appear in a played match are archived rather than deleted, so
    /// no historical match loses a name.
    public func removePlayer(_ playerID: PlayerID) throws {
        guard let player = try player(playerID) else { throw StoreError.playerNotFound }
        let appearsInAMatch = try matchesReferencing(playerID)
        if appearsInAMatch > 0 {
            player.isOnRoster = false
        } else {
            modelContext.delete(player)
        }
        try modelContext.save()
    }

    private func matchesReferencing(_ playerID: PlayerID) throws -> Int {
        let matches = try modelContext.fetch(FetchDescriptor<MatchModel>())
        var count = 0
        for match in matches {
            let roster = MatchMapper.roster(from: match)
            if roster[playerID] != nil { count += 1 }
        }
        return count
    }

    // MARK: - Matches

    public func createMatch(
        teamID: TeamID,
        seasonID: SeasonID?,
        opponentName: String,
        opponentShortName: String?,
        kickoff: Date,
        venue: Venue,
        rules: MatchRules,
        statProfile: StatProfile,
        tracking: OpponentTrackingMode,
        competition: String?,
        roster: RosterSnapshot,
        opponentRoster: RosterSnapshot = .empty
    ) throws -> MatchID {
        guard let team = try team(teamID) else { throw StoreError.teamNotFound }
        let model = MatchModel(
            teamIdentifier: teamID.rawValue,
            opponentName: opponentName,
            opponentShortName: opponentShortName,
            kickoff: kickoff,
            venue: venue,
            competition: competition,
            tracking: tracking
        )
        if let seasonID {
            model.season = team.seasons.first { $0.identifier == seasonID.rawValue }
        } else {
            model.season = team.seasons.first(where: \.isCurrent)
        }
        model.rulesData = try ProgrammeCoding.encoder.encode(rules)
        model.statProfileData = try ProgrammeCoding.encoder.encode(statProfile)
        model.rosterData = try ProgrammeCoding.encoder.encode(roster)
        model.opponentRosterData = try ProgrammeCoding.encoder.encode(opponentRoster)
        modelContext.insert(model)
        try modelContext.save()
        return model.matchID
    }

    public func context(for matchID: MatchID) throws -> MatchContext {
        guard let model = try match(matchID) else { throw StoreError.matchNotFound }
        guard let team = try team(TeamID(model.teamIdentifier)) else { throw StoreError.teamNotFound }
        return try MatchMapper.context(from: model, teamName: team.name, teamShortName: team.shortName)
    }

    /// Persist a batch of effects. Called after the in-memory session has
    /// already applied them, so the scorer never waits on the database.
    public func apply(_ effects: [MatchEffect], to matchID: MatchID) throws {
        guard let model = try match(matchID) else { throw StoreError.matchNotFound }
        for effect in effects {
            switch effect {
            case .appendEvent(let event):
                let eventModel = try MatchEventModel(event: event)
                eventModel.match = model
                modelContext.insert(eventModel)
            case .replaceEvent(let event):
                if let existing = model.events.first(where: { $0.identifier == event.id.rawValue }) {
                    try existing.update(from: event)
                } else {
                    let eventModel = try MatchEventModel(event: event)
                    eventModel.match = model
                    modelContext.insert(eventModel)
                }
            case .setClock(let clock):
                model.clockAnchor = clock
            case .setPhase(let phase):
                model.phase = phase
            case .setFinalized(let date):
                model.finalizedAt = date
            }
        }
        model.updatedAt = Date()
        try modelContext.save()
    }

    /// Refresh the denormalised list values from an authoritative snapshot.
    public func updateCache(matchID: MatchID, from snapshot: MatchSnapshot) throws {
        guard let model = try match(matchID) else { throw StoreError.matchNotFound }
        MatchMapper.writeCache(snapshot: snapshot, into: model)
        try modelContext.save()
    }

    public func updateConfiguration(
        matchID: MatchID, rules: MatchRules, statProfile: StatProfile,
        tracking: OpponentTrackingMode, kickoff: Date, venue: Venue,
        opponentName: String, opponentShortName: String, competition: String?
    ) throws {
        guard let model = try match(matchID) else { throw StoreError.matchNotFound }
        model.rulesData = try ProgrammeCoding.encoder.encode(rules)
        model.statProfileData = try ProgrammeCoding.encoder.encode(statProfile)
        model.trackingRaw = tracking.rawValue
        model.kickoff = kickoff
        model.venueRaw = venue.rawValue
        model.opponentName = opponentName
        model.opponentShortName = opponentShortName
        model.competition = competition
        model.updatedAt = Date()
        try modelContext.save()
    }

    public func updateMatchRoster(matchID: MatchID, roster: RosterSnapshot, opponentRoster: RosterSnapshot)
        throws
    {
        guard let model = try match(matchID) else { throw StoreError.matchNotFound }
        model.rosterData = try ProgrammeCoding.encoder.encode(roster)
        model.opponentRosterData = try ProgrammeCoding.encoder.encode(opponentRoster)
        try modelContext.save()
    }

    public func deleteMatch(_ matchID: MatchID) throws {
        guard let model = try match(matchID) else { throw StoreError.matchNotFound }
        modelContext.delete(model)
        try modelContext.save()
    }

    public func matches(teamID: TeamID? = nil, seasonID: SeasonID? = nil, limit: Int? = nil) throws
        -> [MatchListItem]
    {
        var descriptor = FetchDescriptor<MatchModel>(sortBy: [SortDescriptor(\.kickoff, order: .reverse)])
        if let limit { descriptor.fetchLimit = limit }
        let models = try modelContext.fetch(descriptor)
        return models
            .filter { model in
                if let teamID, model.teamIdentifier != teamID.rawValue { return false }
                if let seasonID, model.season?.identifier != seasonID.rawValue { return false }
                return true
            }
            .map(listItem(from:))
    }

    public func interruptedMatches() throws -> [MatchListItem] {
        try matches().filter(\.isInterrupted)
    }

    /// Everything a season page needs, computed on this actor so the main thread
    /// never derives a season's worth of statistics.
    public func seasonSummaries(teamID: TeamID, seasonID: SeasonID?) throws -> [MatchStatSummary] {
        guard let team = try team(teamID) else { throw StoreError.teamNotFound }
        let models = try modelContext.fetch(FetchDescriptor<MatchModel>())
        var summaries: [MatchStatSummary] = []
        for model in models where model.teamIdentifier == teamID.rawValue {
            if let seasonID, model.season?.identifier != seasonID.rawValue { continue }
            guard model.phase == .finalized else { continue }
            let context = try MatchMapper.context(
                from: model, teamName: team.name, teamShortName: team.shortName)
            let snapshot = StatEngine.snapshot(context: context)
            summaries.append(
                MatchStatSummary(
                    snapshot: snapshot, tracked: context.profile.tracked, isFinalized: true))
        }
        return summaries
    }

    public func seasonStats(teamID: TeamID, seasonID: SeasonID?) throws -> SeasonStats {
        SeasonEngine.aggregate(try seasonSummaries(teamID: teamID, seasonID: seasonID))
    }

    /// Snapshot a single match without keeping the model around.
    public func snapshot(for matchID: MatchID) throws -> MatchSnapshot {
        StatEngine.snapshot(context: try context(for: matchID))
    }

    /// Replace a match's entire event list. Used by archive import and by
    /// journal recovery when the journal is ahead of the database.
    public func replaceEvents(matchID: MatchID, with events: [MatchEvent]) throws {
        guard let model = try match(matchID) else { throw StoreError.matchNotFound }
        for existing in model.events { modelContext.delete(existing) }
        model.events = []
        for event in events {
            let eventModel = try MatchEventModel(event: event)
            eventModel.match = model
            modelContext.insert(eventModel)
        }
        try modelContext.save()
    }

    /// Insert a complete match reconstructed from an archive or a journal.
    @discardableResult
    public func importMatch(_ context: MatchContext, teamID: TeamID, seasonID: SeasonID?) throws -> MatchID {
        guard let team = try team(teamID) else { throw StoreError.teamNotFound }
        let existing = try match(context.descriptor.id)
        let model =
            existing
            ?? MatchModel(
                identifier: context.descriptor.id.rawValue,
                teamIdentifier: teamID.rawValue,
                opponentName: context.descriptor.opponentName,
                opponentShortName: context.descriptor.opponentShortName,
                kickoff: context.descriptor.kickoff,
                venue: context.descriptor.venue,
                competition: context.descriptor.competition,
                tracking: context.descriptor.tracking
            )
        if existing == nil {
            if let seasonID {
                model.season = team.seasons.first { $0.identifier == seasonID.rawValue }
            } else {
                model.season = team.seasons.first(where: \.isCurrent)
            }
            modelContext.insert(model)
        }
        try MatchMapper.write(context: context, into: model)
        // An archive carries the team identifier it was written with. Re-home the
        // match onto the team it is being imported into, so a roster shared
        // between two schools' iPads still loads.
        model.teamIdentifier = teamID.rawValue
        for existingEvent in model.events { modelContext.delete(existingEvent) }
        model.events = []
        for event in context.events {
            let eventModel = try MatchEventModel(event: event)
            eventModel.match = model
            modelContext.insert(eventModel)
        }
        MatchMapper.writeCache(snapshot: StatEngine.snapshot(context: context), into: model)
        try modelContext.save()
        return model.matchID
    }

    public func matchExists(_ matchID: MatchID) throws -> Bool {
        try match(matchID) != nil
    }

    // MARK: - Lookup helpers

    private func team(_ id: TeamID) throws -> TeamModel? {
        let raw = id.rawValue
        var descriptor = FetchDescriptor<TeamModel>(predicate: #Predicate { $0.identifier == raw })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func player(_ id: PlayerID) throws -> PlayerModel? {
        let raw = id.rawValue
        var descriptor = FetchDescriptor<PlayerModel>(predicate: #Predicate { $0.identifier == raw })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func match(_ id: MatchID) throws -> MatchModel? {
        let raw = id.rawValue
        var descriptor = FetchDescriptor<MatchModel>(predicate: #Predicate { $0.identifier == raw })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func listItem(from model: MatchModel) -> MatchListItem {
        MatchListItem(
            id: model.matchID,
            opponentName: model.opponentName,
            kickoff: model.kickoff,
            venue: model.venue,
            phase: model.phase,
            score: SidePair(us: model.cachedScoreUs, opponent: model.cachedScoreOpponent),
            result: model.result,
            eventCount: model.cachedEventCount,
            needsReviewCount: model.cachedNeedsReviewCount,
            competition: model.competition,
            seasonName: model.season?.name
        )
    }
}
