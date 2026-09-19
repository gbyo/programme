import AppIntents
import CoreSpotlight
import Foundation
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
        let teams = try await store.teams()
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
        let teams = try await store.teams()
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
        appModel.navigation.isPresentingNewMatch = true
    }

    func startScoring(matchID: MatchID) async {
        await appModel.openLiveSession(matchID: matchID)
    }

    func liveScoreSummary() -> String? {
        guard let session = appModel.liveSession else { return nil }
        return
            "\(session.descriptor.teamShortName) \(session.snapshot.score.us), \(session.descriptor.opponentShortName) \(session.snapshot.score.opponent). \(session.clock.displayText) in the \(session.clock.periodLongLabel)."
    }

    /// Keep Spotlight in step with the library. Indexing is a convenience, so a
    /// failure here never surfaces to the person or blocks anything.
    func reindexSpotlight() async {
        guard let matchEntities = try? await matches(), let playerEntities = try? await players() else {
            return
        }
        try? await CSSearchableIndex.default().indexAppEntities(matchEntities)
        try? await CSSearchableIndex.default().indexAppEntities(playerEntities)
    }
}
