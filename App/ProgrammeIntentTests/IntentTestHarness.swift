import AppIntents
import Foundation
import ProgrammeCore
import ProgrammePersistence

@testable import Programme

/// Shared fixture for intent tests: two local teams that collide on purpose —
/// both have played "Dixie", and both carry a "#1 Tucker Bell" — inside an
/// ephemeral store, exercising the real provider and the real navigation path.
///
/// Nothing here duplicates routing logic; every test below goes through
/// `ProgrammeIntentProvider` and `AppModel.open(_:)`.
@MainActor
struct IntentTestHarness {
    struct Seed {
        let teamA: TeamID
        let teamB: TeamID
        let seasonA: SeasonID
        let matchA: MatchID
        let matchB: MatchID
        let playerA: PlayerID
        let playerB: PlayerID
    }

    let appModel: AppModel
    let provider: ProgrammeIntentProvider
    let seed: Seed

    /// Builds the harness and registers its provider as the process-wide intent
    /// dependency, mirroring what `ProgrammeApp` does at launch.
    enum HarnessError: Error {
        case noStore
    }

    static func make() async throws -> IntentTestHarness {
        let appModel = AppModel()
        try appModel.useEphemeralStoreForTests()
        guard let store = appModel.store else {
            throw HarnessError.noStore
        }

        let teamA = try await store.createTeam(name: "Ninety Six", shortName: "NX")
        let teamB = try await store.createTeam(name: "Greenwood", shortName: "GW")
        let seasonA = try await store.createSeason(
            teamID: teamA, name: "2026–27", startDate: Date(timeIntervalSince1970: 1_780_000_000),
            endDate: nil, makeCurrent: true)
        _ = try await store.createSeason(
            teamID: teamB, name: "2026–27", startDate: Date(timeIntervalSince1970: 1_780_000_000),
            endDate: nil, makeCurrent: true)

        // Same name and number on both teams, but distinct identities — that is
        // exactly the collision the disambiguation tests need.
        let bellA = PlayerSnapshot(
            firstName: "Tucker", lastName: "Bell", jerseyNumber: 1, position: .goalkeeper)
        let bellB = PlayerSnapshot(
            firstName: "Tucker", lastName: "Bell", jerseyNumber: 1, position: .goalkeeper)
        let playerIDsA = try await store.addPlayers(teamID: teamA, [bellA])
        let playerIDsB = try await store.addPlayers(teamID: teamB, [bellB])

        let rosterA = try await store.roster(teamID: teamA)
        let rosterB = try await store.roster(teamID: teamB)
        let matchA = try await store.createMatch(
            teamID: teamA, seasonID: seasonA,
            opponentName: "Dixie", opponentShortName: "DIX",
            kickoff: Date(timeIntervalSince1970: 1_790_000_000),
            venue: .home, rules: .highSchool, statProfile: .maxPreps,
            tracking: .ourTeam, competition: nil, roster: rosterA)
        let matchB = try await store.createMatch(
            teamID: teamB, seasonID: nil,
            opponentName: "Dixie", opponentShortName: "DIX",
            kickoff: Date(timeIntervalSince1970: 1_791_000_000),
            venue: .away, rules: .highSchool, statProfile: .maxPreps,
            tracking: .ourTeam, competition: nil, roster: rosterB)

        await appModel.reloadWorkspace(selecting: teamA)

        let provider = ProgrammeIntentProvider(appModel: appModel)
        appModel.intentProvider = provider
        AppDependencyManager.shared.add { provider }

        return IntentTestHarness(
            appModel: appModel, provider: provider,
            seed: Seed(
                teamA: teamA, teamB: teamB, seasonA: seasonA,
                matchA: matchA, matchB: matchB,
                playerA: playerIDsA[0], playerB: playerIDsB[0]))
    }

    /// Starts from the other team so tests can prove cross-team navigation
    /// selects the owning team first.
    func selectTeamB() async {
        await appModel.selectTeam(seed.teamB)
    }
}
