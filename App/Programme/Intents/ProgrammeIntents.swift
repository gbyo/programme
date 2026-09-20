import AppIntents
import CoreSpotlight
import Foundation
import ProgrammeCollaboration
import ProgrammeCore
import ProgrammePersistence
import SwiftUI

// MARK: - Entities

/// A match, exposed to Shortcuts, Siri and Spotlight. Indexed across all
/// teams so an item never disappears merely because another workspace is
/// selected; the team name disambiguates shared opponents.
struct MatchEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Match" }
    static let defaultQuery = MatchEntityQuery()

    var id: UUID
    @Property(title: "Opponent") var opponent: String
    @Property(title: "Kickoff") var kickoff: Date
    @Property(title: "Score") var scoreText: String
    @Property(title: "Result") var resultText: String
    @Property(title: "Team") var teamName: String

    var displayRepresentation: DisplayRepresentation {
        let detail =
            resultText.isEmpty
            ? kickoff.formatted(date: .abbreviated, time: .shortened) : resultText
        return DisplayRepresentation(
            title: "\(opponent)",
            subtitle: "\(detail) — \(teamName)",
            image: .init(systemName: "sportscourt")
        )
    }

    init(item: MatchListItem, venueLabel: String, teamName: String = "") {
        self.id = item.id.rawValue
        self.opponent = "\(venueLabel) \(item.opponentName)"
        self.kickoff = item.kickoff
        self.scoreText = "\(item.score.us)–\(item.score.opponent)"
        self.resultText = item.resultText ?? ""
        self.teamName = teamName
    }
}

struct MatchEntityQuery: EntityQuery {
    @Dependency private var provider: ProgrammeIntentProvider

    func entities(for identifiers: [UUID]) async throws -> [MatchEntity] {
        try await provider.matches().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MatchEntity] {
        Array(try await provider.matches().prefix(8))
    }
}

struct PlayerEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Player" }
    static let defaultQuery = PlayerEntityQuery()

    var id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Jersey number") var jerseyNumber: Int?
    @Property(title: "Position") var position: String
    @Property(title: "Team") var teamName: String

    var displayRepresentation: DisplayRepresentation {
        let number = jerseyNumber.map { "#\($0) " } ?? ""
        let team = teamName.isEmpty ? "" : " — \(teamName)"
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(number)\(position)\(team)",
            image: .init(systemName: "person")
        )
    }

    init(player: PlayerSnapshot, teamName: String = "") {
        self.id = player.id.rawValue
        self.name = player.fullName
        self.jerseyNumber = player.jerseyNumber
        self.position = player.position?.label ?? ""
        self.teamName = teamName
    }
}

struct PlayerEntityQuery: EntityQuery {
    @Dependency private var provider: ProgrammeIntentProvider

    func entities(for identifiers: [UUID]) async throws -> [PlayerEntity] {
        try await provider.players().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PlayerEntity] {
        try await provider.players()
    }
}

/// Writes entity updates to the Spotlight index. The provider talks only to
/// this seam so tests can observe invalidation policy without a live
/// Spotlight database.
protocol SpotlightIndexClient: Sendable {
    func indexMatches(_ entities: [MatchEntity]) async throws
    func indexPlayers(_ entities: [PlayerEntity]) async throws
    func deleteMatchIdentifiers(_ ids: [UUID]) async throws
    func deletePlayerIdentifiers(_ ids: [UUID]) async throws
}

struct LiveSpotlightIndexClient: SpotlightIndexClient {
    func indexMatches(_ entities: [MatchEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func indexPlayers(_ entities: [PlayerEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func deleteMatchIdentifiers(_ ids: [UUID]) async throws {
        try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: ids, ofType: MatchEntity.self)
    }

    func deletePlayerIdentifiers(_ ids: [UUID]) async throws {
        try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: ids, ofType: PlayerEntity.self)
    }
}

// MARK: - Intents

/// Open a match in Programme. Deliberately opens the app rather than editing in
/// the background: statistics are official records and are only ever changed
/// where the person can see what changed.
struct OpenMatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Match"
    static let description = IntentDescription("Open a match in Programme.")
    static let openAppWhenRun = true

    @Parameter(title: "Match") var match: MatchEntity
    @Dependency private var provider: ProgrammeIntentProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        await provider.open(.match(MatchID(match.id)))
        return .result()
    }
}

/// Jump straight into scoring.
struct ScoreMatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Score Match"
    static let description = IntentDescription("Open Programme's scorer for a match.")
    static let openAppWhenRun = true

    @Parameter(title: "Match") var match: MatchEntity
    @Dependency private var provider: ProgrammeIntentProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        await provider.startScoring(matchID: MatchID(match.id))
        return .result()
    }
}

/// A read-only question. Programme never computes an official statistic anywhere
/// but in its own engine, and this just reports what that engine derived.
struct CurrentScoreIntent: AppIntent {
    static let title: LocalizedStringResource = "Current Score"
    static let description = IntentDescription("Ask Programme for the score of the match being scored.")
    static let openAppWhenRun = false

    @Dependency private var provider: ProgrammeIntentProvider

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let summary = provider.liveScoreSummary() else {
            return .result(value: "No match", dialog: "No match is being scored right now.")
        }
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct ShowSeasonStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Season Stats"
    static let description = IntentDescription("Open this season's statistics in Programme.")
    static let openAppWhenRun = true

    @Dependency private var provider: ProgrammeIntentProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        await provider.open(.season(nil))
        return .result()
    }
}

struct NewMatchIntent: AppIntent {
    static let title: LocalizedStringResource = "New Match"
    static let description = IntentDescription("Start creating a match in Programme.")
    static let openAppWhenRun = true

    @Dependency private var provider: ProgrammeIntentProvider

    @MainActor
    func perform() async throws -> some IntentResult {
        provider.presentNewMatch()
        return .result()
    }
}

#if DEBUG
    private enum ProgrammeIntentTestFixtureError: Error {
        case unavailableStore
    }

    struct SeedProgrammeIntentTestsIntent: AppIntent {
        static let title: LocalizedStringResource = "Seed Programme Intent Tests"
        static let isDiscoverable = false

        @Dependency private var provider: ProgrammeIntentProvider

        @MainActor
        func perform() async throws -> some IntentResult & ReturnsValue<String> {
            .result(value: try await provider.seedIntentTestFixture())
        }
    }

    struct ReadProgrammeIntentTestStateIntent: AppIntent {
        static let title: LocalizedStringResource = "Read Programme Intent Test State"
        static let isDiscoverable = false

        @Dependency private var provider: ProgrammeIntentProvider

        @MainActor
        func perform() async throws -> some IntentResult & ReturnsValue<String> {
            .result(value: provider.intentTestState())
        }
    }
#endif

struct ProgrammeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CurrentScoreIntent(),
            phrases: [
                "What's the score in \(.applicationName)",
                "\(.applicationName) score",
            ],
            shortTitle: "Current Score",
            systemImageName: "sportscourt")

        AppShortcut(
            intent: ShowSeasonStatsIntent(),
            phrases: [
                "Show season stats in \(.applicationName)",
                "Open \(.applicationName) season statistics",
            ],
            shortTitle: "Season Stats",
            systemImageName: "chart.bar.xaxis")

        AppShortcut(
            intent: NewMatchIntent(),
            phrases: [
                "Create a match in \(.applicationName)",
                "New \(.applicationName) match",
            ],
            shortTitle: "New Match",
            systemImageName: "plus")
    }
}

// MARK: - Provider

/// The bridge App Intents and Spotlight use to reach the running app.
/// Registered as an intent dependency at launch.
@MainActor
final class ProgrammeIntentProvider {
    private let appModel: AppModel

    init(appModel: AppModel) { self.appModel = appModel }

    /// All teams' matches so Spotlight items never disappear with a workspace
    /// switch. The selected team's matches come first for ranking.
    func matches() async throws -> [MatchEntity] {
        guard let store = appModel.store else { return [] }
        let teams = try await store.teamIdentities()
        var entities: [MatchEntity] = []
        for team in teams {
            let items = try await store.matches(teamID: team.id, limit: 60)
            entities += items.map {
                MatchEntity(item: $0, venueLabel: $0.venue.shortLabel, teamName: team.shortName)
            }
        }
        let selected = appModel.workspace.selectedTeam?.shortName
        entities.sort {
            ($0.teamName == selected ? 0 : 1, $0.kickoff)
                < ($1.teamName == selected ? 0 : 1, $1.kickoff)
        }
        return entities
    }

    func players() async throws -> [PlayerEntity] {
        guard let store = appModel.store else { return [] }
        let teams = try await store.teamIdentities()
        var entities: [PlayerEntity] = []
        for team in teams {
            let roster = try await store.roster(teamID: team.id)
            entities += roster.sortedByNumber.map {
                PlayerEntity(player: $0, teamName: team.shortName)
            }
        }
        return entities
    }

    /// Team-aware routing through the single application path. Opening a
    /// specific match/player selects its owning team first.
    func open(_ route: AppRoute) async {
        await appModel.open(route)
    }

    func presentNewMatch() {
        appModel.navigation.presentedSheet = .newMatch
    }

    func startScoring(matchID: MatchID) async {
        await appModel.openLiveSession(matchID: matchID)
    }

    func liveScoreSummary() -> String? {
        guard let session = appModel.liveSession else { return nil }
        return
            "\(session.descriptor.teamShortName) \(session.snapshot.score.us), \(session.descriptor.opponentShortName) \(session.snapshot.score.opponent). \(session.clock.displayText) in the \(session.clock.periodLongLabel)."
    }

    /// Full-library rebuild, reserved for launch repair, migration, and
    /// explicit recovery. Ordinary updates go through `noteMutation`
    /// instead. Indexing is a convenience, so a failure here never
    /// surfaces to the person or blocks anything.
    func reindexSpotlight() async {
        guard let matchEntities = try? await matches(), let playerEntities = try? await players() else {
            return
        }
        try? await spotlightClient.indexMatches(matchEntities)
        try? await spotlightClient.indexPlayers(playerEntities)
    }

    // MARK: - Incremental Spotlight indexing

    /// Writes index updates through this client: Core Spotlight in the app,
    /// a fake in tests. Failures stay silent by policy.
    var spotlightClient: SpotlightIndexClient = LiveSpotlightIndexClient()

    /// Mutations coalesce here and flush on a short debounce, so live
    /// scoring (many event writes for one match) and bulk imports each cost
    /// one team-scoped resolution instead of repeated full-library reads.
    private var pendingMatchIDs: Set<MatchID> = []
    private var pendingTeamIDs: Set<TeamID> = []
    private var pendingPlayers: [TeamID: Set<PlayerID>] = [:]
    private var pendingDeletedMatchIDs: Set<UUID> = []
    private var pendingDeletedPlayerIDs: Set<UUID> = []
    private var spotlightFlushTask: Task<Void, Never>?

    /// Records a local-truth mutation for batched Spotlight indexing.
    /// Never reads the store; resolution happens once at flush time.
    func noteMutation(_ mutation: OutboundMutation) {
        switch mutation {
        case .events(let matchID, _), .match(let matchID):
            pendingDeletedMatchIDs.remove(matchID.rawValue)
            pendingMatchIDs.insert(matchID)
        case .team(let teamID):
            pendingTeamIDs.insert(teamID)
        case .season:
            // Season names are not indexed; its matches are unaffected.
            break
        case .players(let teamID, let playerIDs):
            pendingPlayers[teamID, default: []].formUnion(playerIDs)
            pendingDeletedPlayerIDs.subtract(playerIDs.map { $0.rawValue })
        case .deletedMatch(let matchID, _, _):
            pendingMatchIDs.remove(matchID)
            pendingDeletedMatchIDs.insert(matchID.rawValue)
        case .deletedPlayers(_, let playerIDs):
            for id in playerIDs {
                for teamID in pendingPlayers.keys {
                    pendingPlayers[teamID]?.remove(id)
                }
                pendingDeletedPlayerIDs.insert(id.rawValue)
            }
        }
        scheduleSpotlightFlush()
    }

    private func scheduleSpotlightFlush() {
        spotlightFlushTask?.cancel()
        spotlightFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.flushSpotlight()
        }
    }

    /// Resolves pending IDs to entities with team-scoped reads and writes
    /// them. Full reindexing stays reserved for launch repair and explicit
    /// recovery; remote structure arrivals reindex through the workspace
    /// change path instead.
    func flushSpotlight() async {
        spotlightFlushTask?.cancel()
        spotlightFlushTask = nil
        guard let store = appModel.store else { return }
        let matchIDs = pendingMatchIDs
        let teamIDs = pendingTeamIDs
        let players = pendingPlayers
        let deletedMatches = pendingDeletedMatchIDs
        let deletedPlayers = pendingDeletedPlayerIDs
        pendingMatchIDs = []
        pendingTeamIDs = []
        pendingPlayers = [:]
        pendingDeletedMatchIDs = []
        pendingDeletedPlayerIDs = []
        let hasUpserts = !(matchIDs.isEmpty && teamIDs.isEmpty && players.isEmpty)
        guard hasUpserts || !deletedMatches.isEmpty || !deletedPlayers.isEmpty else { return }
        var teamsToLoad = teamIDs
        for teamID in players.keys {
            teamsToLoad.insert(teamID)
        }
        for matchID in matchIDs {
            if let teamID = try? await store.teamID(forMatch: matchID) {
                teamsToLoad.insert(teamID)
            }
        }
        var matchEntities: [MatchEntity] = []
        var playerEntities: [PlayerEntity] = []
        for teamID in teamsToLoad {
            let shortName = (try? await store.teamDetails(teamID: teamID))?.shortName ?? ""
            guard let items = try? await store.matches(teamID: teamID, limit: 60) else { continue }
            for item in items where matchIDs.contains(item.id) || teamIDs.contains(teamID) {
                matchEntities.append(
                    MatchEntity(item: item, venueLabel: item.venue.shortLabel, teamName: shortName))
            }
            let wantedPlayers = players[teamID]
            if teamIDs.contains(teamID) || wantedPlayers != nil {
                let roster = (try? await store.roster(teamID: teamID)) ?? .empty
                for player in roster.sortedByNumber
                where teamIDs.contains(teamID) || wantedPlayers?.contains(player.id) == true {
                    playerEntities.append(PlayerEntity(player: player, teamName: shortName))
                }
            }
        }
        try? await spotlightClient.indexMatches(matchEntities)
        try? await spotlightClient.indexPlayers(playerEntities)
        if !deletedMatches.isEmpty {
            try? await spotlightClient.deleteMatchIdentifiers(Array(deletedMatches))
        }
        if !deletedPlayers.isEmpty {
            try? await spotlightClient.deletePlayerIdentifiers(Array(deletedPlayers))
        }
    }

    #if DEBUG
        /// Seeds the app process itself for AppIntentsTesting. Those tests execute
        /// out of process, so their own AppModel/store can never be test data for
        /// entity queries or intents that the application process performs.
        func seedIntentTestFixture() async throws -> String {
            try appModel.useEphemeralStoreForTests()
            appModel.liveSession = nil
            appModel.navigation = NavigationModel()
            appModel.workspace = TeamWorkspace()

            guard let store = appModel.store else {
                throw ProgrammeIntentTestFixtureError.unavailableStore
            }

            let teamA = try await store.createTeam(name: "Ninety Six", shortName: "NX")
            let teamB = try await store.createTeam(name: "Greenwood", shortName: "GW")
            let seasonA = try await store.createSeason(
                teamID: teamA,
                name: "2026–27",
                startDate: Date(timeIntervalSince1970: 1_780_000_000),
                endDate: nil,
                makeCurrent: true)
            _ = try await store.createSeason(
                teamID: teamB,
                name: "2026–27",
                startDate: Date(timeIntervalSince1970: 1_780_000_000),
                endDate: nil,
                makeCurrent: true)

            let bellA = PlayerSnapshot(
                firstName: "Tucker", lastName: "Bell", jerseyNumber: 1, position: .goalkeeper)
            let bellB = PlayerSnapshot(
                firstName: "Tucker", lastName: "Bell", jerseyNumber: 1, position: .goalkeeper)
            let playerIDsA = try await store.addPlayers(teamID: teamA, [bellA])
            let playerIDsB = try await store.addPlayers(teamID: teamB, [bellB])

            let rosterA = try await store.roster(teamID: teamA)
            let rosterB = try await store.roster(teamID: teamB)
            let matchA = try await store.createMatch(
                teamID: teamA,
                seasonID: seasonA,
                opponentName: "Dixie",
                opponentShortName: "DIX",
                kickoff: Date(timeIntervalSince1970: 1_790_000_000),
                venue: .home,
                rules: .highSchool,
                statProfile: .maxPreps,
                tracking: .ourTeam,
                competition: nil,
                roster: rosterA)
            let matchB = try await store.createMatch(
                teamID: teamB,
                seasonID: nil,
                opponentName: "Dixie",
                opponentShortName: "DIX",
                kickoff: Date(timeIntervalSince1970: 1_791_000_000),
                venue: .away,
                rules: .highSchool,
                statProfile: .maxPreps,
                tracking: .ourTeam,
                competition: nil,
                roster: rosterB)

            await appModel.reloadWorkspace(selecting: teamA)
            await reindexSpotlight()

            return [
                teamA.rawValue.uuidString,
                teamB.rawValue.uuidString,
                matchA.rawValue.uuidString,
                matchB.rawValue.uuidString,
                playerIDsA[0].rawValue.uuidString,
                playerIDsB[0].rawValue.uuidString,
            ].joined(separator: "|")
        }

        /// Returns only state that the AppIntentsTesting process needs to verify.
        /// Keeping this behind a test-only intent preserves the process boundary.
        func intentTestState() -> String {
            [
                appModel.workspace.selectedTeamID?.rawValue.uuidString ?? "",
                appModel.navigation.section.rawValue,
                appModel.navigation.presentedSheet == .newMatch ? "1" : "0",
                appModel.liveSession?.matchID.rawValue.uuidString ?? "",
            ].joined(separator: "|")
        }
    #endif
}
