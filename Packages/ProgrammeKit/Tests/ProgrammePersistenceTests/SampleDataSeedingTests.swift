import Foundation
import SwiftData
import Testing

@testable import ProgrammeCore
@testable import ProgrammePersistence

// Seeding writes through the container's main context while browsing reads
// through the store actor's own context. The seeded sample team must be
// visible across that boundary, or every fresh launch lands on first-run
// onboarding instead of the sample workspace.
@Suite("Sample data seeding")
struct SampleDataSeedingTests {
    @Test("seeded teams reach the store actor")
    @MainActor
    func seedVisibleToStore() async throws {
        let container = try ProgrammeStore.container(inMemory: true)
        try ProgrammeStore.seedSampleData(into: container.mainContext)
        let store = MatchStore(modelContainer: container)
        let teams = try await store.teams()
        #expect(teams.map(\.id).contains(ProgrammeSample.teamID))
    }
}
