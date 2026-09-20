import Foundation
import SwiftData
import Synchronization
import Testing

@testable import ProgrammeCore
@testable import ProgrammeExport
@testable import ProgrammePersistence

@Suite("The recovery journal survives interruption")
struct RecoveryJournalTests {

    private func makeJournal() throws -> (RecoveryJournal, URL) {
        let directory = URL.temporaryDirectory.appending(path: "programme-tests-\(UUID().uuidString)")
        return (try RecoveryJournal(directory: directory), directory)
    }

    @Test("A match can be reconstructed from its journal alone")
    func replayFromJournalOnly() throws {
        let (journal, directory) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }

        var context = MatchContext(descriptor: ProgrammeSample.descriptor(), roster: ProgrammeSample.roster)
        try journal.open(
            matchID: context.descriptor.id, descriptor: context.descriptor,
            roster: context.roster, opponentRoster: .empty)

        let commands: [MatchCommand] = [
            .setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven, goalkeeper: ProgrammeSample.keeper)),
            .startNextPeriod,
        ]
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        for command in commands {
            let effects = try MatchEngine.perform(command, on: context, at: date)
            MatchEngine.apply(effects, to: &context)
            try journal.append(effects, for: context.descriptor.id)
            date = date.addingTimeInterval(1)
        }
        context.clock = ClockAnchor(period: 1, elapsedAtAnchor: 720, runningSince: nil)
        let goal = try MatchEngine.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal,
                    assist: .player(ProgrammeSample.williams))), on: context, at: date)
        MatchEngine.apply(goal, to: &context)
        try journal.append(goal, for: context.descriptor.id)

        // Nothing else exists — no database, no app state.
        let recovered = try #require(try journal.recover(matchID: context.descriptor.id))
        #expect(recovered.events.count == context.events.count)
        #expect(StatEngine.snapshot(context: recovered).score.us == 1)
        #expect(
            StatEngine.snapshot(context: recovered).player(ProgrammeSample.williams).assists == 1)
    }

    @Test("A journal truncated mid-write loses only the incomplete line")
    func toleratesTruncatedTail() throws {
        let (journal, directory) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }

        var context = MatchContext(descriptor: ProgrammeSample.descriptor(), roster: ProgrammeSample.roster)
        try journal.open(
            matchID: context.descriptor.id, descriptor: context.descriptor, roster: context.roster,
            opponentRoster: .empty)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        for command in [
            MatchCommand.setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven, goalkeeper: ProgrammeSample.keeper)),
            .startNextPeriod,
        ] {
            let effects = try MatchEngine.perform(command, on: context, at: date)
            MatchEngine.apply(effects, to: &context)
            try journal.append(effects, for: context.descriptor.id)
            date = date.addingTimeInterval(1)
        }
        let before = try #require(try journal.recover(matchID: context.descriptor.id)).events.count

        // Simulate the device dying part way through an append.
        let file = directory.appending(path: "\(context.descriptor.id.rawValue.uuidString).journal")
        var data = try Data(contentsOf: file)
        data.append(Data(#"{"effect":{"appendEvent":"#.utf8))
        try data.write(to: file)

        let recovered = try #require(try journal.recover(matchID: context.descriptor.id))
        #expect(recovered.events.count == before)
    }

    @Test("Open journals are reported for the launch recovery prompt")
    func openJournalsAreDiscoverable() throws {
        let (journal, directory) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }

        var context = MatchContext(descriptor: ProgrammeSample.descriptor(), roster: ProgrammeSample.roster)
        try journal.open(
            matchID: context.descriptor.id, descriptor: context.descriptor, roster: context.roster,
            opponentRoster: .empty)
        let effects = try MatchEngine.perform(
            .setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven, goalkeeper: ProgrammeSample.keeper)),
            on: context, at: Date())
        MatchEngine.apply(effects, to: &context)
        try journal.append(effects, for: context.descriptor.id)

        let open = journal.openJournals()
        #expect(open.count == 1)
        #expect(open.first?.descriptor.opponentName == "Dixie")
        #expect(open.first?.eventCount == 1)
        #expect(open.first?.lastEventAt != nil)

        // Once closed it no longer prompts.
        try journal.close(matchID: context.descriptor.id)
        #expect(journal.openJournals().isEmpty)
    }

    @Test("Closed journals older than the retention window are pruned")
    func pruning() throws {
        let (journal, directory) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        var context = MatchContext(descriptor: ProgrammeSample.descriptor(), roster: ProgrammeSample.roster)
        try journal.open(
            matchID: context.descriptor.id, descriptor: context.descriptor, roster: context.roster,
            opponentRoster: .empty)
        let effects = try MatchEngine.perform(
            .setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven, goalkeeper: ProgrammeSample.keeper)),
            on: context, at: Date())
        MatchEngine.apply(effects, to: &context)
        try journal.append(effects, for: context.descriptor.id)
        try journal.close(matchID: context.descriptor.id)

        #expect(journal.pruneClosedJournals(olderThan: 60 * 60 * 24) == 0)
        #expect(journal.pruneClosedJournals(olderThan: -1) == 1)
    }
}

@Suite("Closed-journal upkeep policy")
struct JournalUpkeepPolicyTests {

    private func makeJournal() throws -> (RecoveryJournal, URL) {
        let directory = URL.temporaryDirectory.appending(path: "programme-upkeep-tests-\(UUID().uuidString)")
        return (try RecoveryJournal(directory: directory), directory)
    }

    private func closedJournal(in journal: RecoveryJournal) throws {
        var context = MatchContext(descriptor: ProgrammeSample.descriptor(), roster: ProgrammeSample.roster)
        try journal.open(
            matchID: context.descriptor.id, descriptor: context.descriptor,
            roster: context.roster, opponentRoster: .empty)
        let effects = try MatchEngine.perform(
            .setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven, goalkeeper: ProgrammeSample.keeper)),
            on: context, at: Date())
        MatchEngine.apply(effects, to: &context)
        try journal.append(effects, for: context.descriptor.id)
        try journal.close(matchID: context.descriptor.id)
    }

    @Test("Upkeep is due when it has never run, then throttled by interval")
    func dueThenThrottled() {
        let policy = JournalUpkeepPolicy(minimumInterval: 60 * 60 * 24)
        let now = Date()
        #expect(policy.isDue(now: now, lastRunAt: nil))
        #expect(!policy.isDue(now: now, lastRunAt: now))
        #expect(
            !policy.isDue(now: now, lastRunAt: now.addingTimeInterval(-60 * 60 * 23)))
        #expect(policy.isDue(now: now, lastRunAt: now.addingTimeInterval(-60 * 60 * 25)))
    }

    @Test("Upkeep preserves the retention window and never prunes open journals")
    func performRespectsRetentionAndOpenJournals() throws {
        let (journal, directory) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        try closedJournal(in: journal)

        // Open journal that must survive every upkeep run. A distinct seed
        // keeps its file separate from the closed journal above.
        let openContext = MatchContext(
            descriptor: ProgrammeSample.descriptor(seed: "match.upkeep-open"),
            roster: ProgrammeSample.roster)
        try journal.open(
            matchID: openContext.descriptor.id, descriptor: openContext.descriptor,
            roster: openContext.roster, opponentRoster: .empty)

        // Freshly closed journal is inside the retention window.
        #expect(JournalUpkeepPolicy(retention: 60 * 60 * 24 * 30).perform(on: journal) == 0)
        #expect(journal.openJournals().count == 1)

        // Past the retention window only the closed journal goes.
        #expect(JournalUpkeepPolicy(retention: -1).perform(on: journal) == 1)
        #expect(journal.openJournals().count == 1)
    }
}

@Suite("SwiftData store")
struct MatchStoreTests {

    private func makeStore() throws -> MatchStore {
        let container = try ProgrammeStore.container(inMemory: true)
        return MatchStore(modelContainer: container)
    }

    @Test("A match persists and reloads with identical derived statistics")
    func persistAndReload() async throws {
        let store = try makeStore()
        let teamID = try await store.createTeam(name: ProgrammeSample.teamName, shortName: "Ninety Six")
        _ = try await store.createSeason(
            teamID: teamID, name: "2027", startDate: Date(), endDate: nil)
        try await store.addPlayers(teamID: teamID, ProgrammeSample.roster.players)
        let roster = try await store.roster(teamID: teamID)
        #expect(roster.players.count == ProgrammeSample.roster.players.count)

        let matchID = try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: "Dixie", opponentShortName: "Dixie",
            kickoff: ProgrammeSample.kickoff(), venue: .home, rules: .highSchool,
            statProfile: .maxPreps, tracking: .ourTeam, competition: "Region 2-AA", roster: roster)

        var context = try await store.context(for: matchID)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        for command in [
            MatchCommand.setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven, goalkeeper: ProgrammeSample.keeper)),
            .startNextPeriod,
        ] {
            let effects = try MatchEngine.perform(command, on: context, at: date)
            MatchEngine.apply(effects, to: &context)
            try await store.apply(effects, to: matchID)
            date = date.addingTimeInterval(1)
        }
        context.clock = ClockAnchor(period: 1, elapsedAtAnchor: 600, runningSince: nil)
        let goalEffects = try MatchEngine.perform(
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal,
                    assist: .player(ProgrammeSample.williams))), on: context, at: date)
        MatchEngine.apply(goalEffects, to: &context)
        try await store.apply(goalEffects, to: matchID)
        try await store.apply([.setClock(context.clock)], to: matchID)

        let reloaded = try await store.context(for: matchID)
        let expected = StatEngine.snapshot(context: context)
        let actual = StatEngine.snapshot(context: reloaded)
        #expect(actual.score == expected.score)
        #expect(actual.players[ProgrammeSample.carter] == expected.players[ProgrammeSample.carter])
        #expect(reloaded.descriptor.competition == "Region 2-AA")
        #expect(reloaded.profile.id == StatProfile.maxPreps.id)
    }

    @Test("Editing an event in the store replaces it rather than duplicating it")
    func editsReplace() async throws {
        let store = try makeStore()
        let teamID = try await store.createTeam(name: "Ninety Six", shortName: nil)
        try await store.addPlayers(teamID: teamID, ProgrammeSample.roster.players)
        let roster = try await store.roster(teamID: teamID)
        let matchID = try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: "Dixie", opponentShortName: nil,
            kickoff: Date(), venue: .home, rules: .highSchool, statProfile: .maxPreps,
            tracking: .ourTeam, competition: nil, roster: roster)

        var context = try await store.context(for: matchID)
        for command in [
            MatchCommand.setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven, goalkeeper: ProgrammeSample.keeper)),
            .startNextPeriod,
        ] {
            let effects = try MatchEngine.perform(command, on: context)
            MatchEngine.apply(effects, to: &context)
            try await store.apply(effects, to: matchID)
        }
        context.clock = ClockAnchor(period: 1, elapsedAtAnchor: 600, runningSince: nil)
        let shot = try MatchEngine.perform(
            .recordShot(ShotEvent(side: .us, shooter: .unidentified, outcome: .saved)), on: context)
        MatchEngine.apply(shot, to: &context)
        try await store.apply(shot, to: matchID)

        let event = try #require(context.activeEvents.last)
        let attribution = try MatchEngine.perform(
            .attribute(event.id, .primary, .player(ProgrammeSample.sanders)), on: context)
        MatchEngine.apply(attribution, to: &context)
        try await store.apply(attribution, to: matchID)

        let reloaded = try await store.context(for: matchID)
        #expect(reloaded.events.count == context.events.count)
        let snapshot = StatEngine.snapshot(context: reloaded)
        #expect(snapshot.needsReviewCount == 0)
        #expect(snapshot.player(ProgrammeSample.sanders).shotsOnGoal == 1)
    }

    @Test("Importing an archive recreates the match in the database")
    func archiveImport() async throws {
        let store = try makeStore()
        let teamID = try await store.createTeam(name: ProgrammeSample.teamName, shortName: "Ninety Six")
        try await store.addPlayers(teamID: teamID, ProgrammeSample.roster.players)

        let original = ProgrammeSample.completedContext()
        let data = try ProgrammeArchiveCoder.encode(
            ProgrammeArchive(contexts: [original], teamName: ProgrammeSample.teamName))
        let decoded = try ProgrammeArchiveCoder.decode(data)
        let imported = try #require(decoded.matches.first).context

        let matchID = try await store.importMatch(imported, teamID: teamID, seasonID: nil)
        let reloaded = try await store.context(for: matchID)

        let before = StatEngine.snapshot(context: original)
        let after = StatEngine.snapshot(context: reloaded)
        #expect(after.score == before.score)
        #expect(after.result == before.result)
        #expect(after.players == before.players)

        // Importing the same archive twice updates rather than duplicates.
        _ = try await store.importMatch(imported, teamID: teamID, seasonID: nil)
        let matches = try await store.matches()
        #expect(matches.count == 1)
    }

    @Test("A player with match history is archived rather than deleted")
    func playerWithHistoryIsArchived() async throws {
        let store = try makeStore()
        let teamID = try await store.createTeam(name: ProgrammeSample.teamName, shortName: nil)
        try await store.addPlayers(teamID: teamID, ProgrammeSample.roster.players)
        let roster = try await store.roster(teamID: teamID)
        _ = try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: "Dixie", opponentShortName: nil,
            kickoff: Date(), venue: .home, rules: .highSchool, statProfile: .maxPreps,
            tracking: .ourTeam, competition: nil, roster: roster)

        try await store.removePlayer(ProgrammeSample.carter)
        let active = try await store.roster(teamID: teamID)
        let all = try await store.roster(teamID: teamID, includeFormer: true)
        #expect(active[ProgrammeSample.carter] == nil)
        #expect(all[ProgrammeSample.carter] != nil)
    }

    @Test("Interrupted matches are discoverable at launch")
    func interruptedMatchDetection() async throws {
        let store = try makeStore()
        let teamID = try await store.createTeam(name: "Ninety Six", shortName: nil)
        try await store.addPlayers(teamID: teamID, ProgrammeSample.roster.players)
        let roster = try await store.roster(teamID: teamID)
        let matchID = try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: "Dixie", opponentShortName: nil,
            kickoff: Date(), venue: .home, rules: .highSchool, statProfile: .maxPreps,
            tracking: .ourTeam, competition: nil, roster: roster)

        #expect(try await store.interruptedMatches().isEmpty)
        try await store.apply([.setPhase(.inPeriod)], to: matchID)
        let interrupted = try await store.interruptedMatches()
        #expect(interrupted.count == 1)
        #expect(interrupted.first?.id == matchID)
    }
}

@Suite("Journal and store reconciliation")
struct JournalReconciliationTests {

    private func makeJournal() throws -> (RecoveryJournal, URL) {
        let directory = URL.temporaryDirectory.appending(path: "programme-tests-\(UUID().uuidString)")
        return (try RecoveryJournal(directory: directory), directory)
    }

    /// The rule the app applies when deciding whether to believe a journal.
    private func journalExtends(_ journaled: MatchContext?, _ stored: MatchContext) -> Bool {
        guard let journaled else { return false }
        let storedIDs = Set(stored.events.map(\.id))
        let journaledIDs = Set(journaled.events.map(\.id))
        return journaledIDs.isSuperset(of: storedIDs) && journaled.events.count > stored.events.count
    }

    @Test("A journal ahead of the store is trusted")
    func journalAheadWins() throws {
        let (journal, directory) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }

        var context = MatchContext(descriptor: ProgrammeSample.descriptor(), roster: ProgrammeSample.roster)
        try journal.open(
            matchID: context.descriptor.id, descriptor: context.descriptor, roster: context.roster,
            opponentRoster: .empty)
        for command in [
            MatchCommand.setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven, goalkeeper: ProgrammeSample.keeper)),
            .startNextPeriod,
        ] {
            let effects = try MatchEngine.perform(command, on: context)
            MatchEngine.apply(effects, to: &context)
            try journal.append(effects, for: context.descriptor.id)
        }
        // The database copy stops here; the journal carries one more event.
        let stored = context
        context.clock = ClockAnchor(period: 1, elapsedAtAnchor: 600, runningSince: nil)
        let extra = try MatchEngine.perform(
            .recordShot(ShotEvent(side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)),
            on: context)
        MatchEngine.apply(extra, to: &context)
        try journal.append(extra, for: context.descriptor.id)

        let recovered = try journal.recover(matchID: context.descriptor.id)
        #expect(journalExtends(recovered, stored))
        #expect(StatEngine.snapshot(context: try #require(recovered)).score.us == 1)
    }

    @Test("A journal belonging to a different version of the match is not trusted")
    func staleJournalIsRejected() throws {
        let (journal, directory) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }

        let descriptor = ProgrammeSample.descriptor()

        // An earlier life of this match, journaled and then abandoned.
        var old = MatchContext(descriptor: descriptor, roster: ProgrammeSample.roster)
        try journal.open(
            matchID: descriptor.id, descriptor: descriptor, roster: old.roster, opponentRoster: .empty)
        for _ in 0..<4 {
            let effects = try MatchEngine.perform(
                .setLineup(
                    LineupEvent(
                        side: .us, onField: ProgrammeSample.startingEleven,
                        goalkeeper: ProgrammeSample.keeper)), on: old)
            MatchEngine.apply(effects, to: &old)
            try journal.append(effects, for: descriptor.id)
        }

        // The match as it exists now — same identifier, different events.
        var current = MatchContext(descriptor: descriptor, roster: ProgrammeSample.roster)
        let effects = try MatchEngine.perform(
            .setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven,
                    goalkeeper: ProgrammeSample.keeper)), on: current)
        MatchEngine.apply(effects, to: &current)

        let recovered = try journal.recover(matchID: descriptor.id)
        // The stale journal has more events, but not *these* events, so it must
        // not be allowed to replace them.
        #expect((recovered?.events.count ?? 0) > current.events.count)
        #expect(journalExtends(recovered, current) == false)
    }

    @Test("Discarding a journal lets the next match start from a clean one")
    func discardResets() throws {
        let (journal, directory) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = ProgrammeSample.descriptor()
        var context = MatchContext(descriptor: descriptor, roster: ProgrammeSample.roster)
        try journal.open(
            matchID: descriptor.id, descriptor: descriptor, roster: context.roster, opponentRoster: .empty)
        let effects = try MatchEngine.perform(
            .setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven,
                    goalkeeper: ProgrammeSample.keeper)), on: context)
        MatchEngine.apply(effects, to: &context)
        try journal.append(effects, for: descriptor.id)
        #expect(journal.exists(for: descriptor.id))

        journal.discard(matchID: descriptor.id)
        #expect(!journal.exists(for: descriptor.id))
        #expect(try journal.recover(matchID: descriptor.id) == nil)

        try journal.open(
            matchID: descriptor.id, descriptor: descriptor, roster: context.roster, opponentRoster: .empty)
        #expect(try journal.recover(matchID: descriptor.id)?.events.isEmpty == true)
    }
}

@Suite("Team workspaces stay scoped to their team")
struct TeamWorkspaceTests {

    private func makeStore() throws -> MatchStore {
        let container = try ProgrammeStore.container(inMemory: true)
        return MatchStore(modelContainer: container)
    }

    private func makePlayer(first: String, last: String, number: Int) -> PlayerSnapshot {
        PlayerSnapshot(
            id: PlayerID(), firstName: first, lastName: last, jerseyNumber: number,
            position: .forward, classYear: nil, isOnRoster: true)
    }

    private func makeMatch(
        store: MatchStore, teamID: TeamID, opponent: String, roster: RosterSnapshot
    ) async throws -> MatchID {
        try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: opponent, opponentShortName: nil,
            kickoff: Date(), venue: .home, rules: .highSchool, statProfile: .maxPreps,
            tracking: .ourTeam, competition: nil, roster: roster)
    }

    @Test("Two teams retain separate rosters and matches")
    func separateRostersAndMatches() async throws {
        let store = try makeStore()
        let varsity = try await store.createTeam(name: "Varsity", shortName: "Varsity")
        let junior = try await store.createTeam(name: "Junior", shortName: "JV")
        _ = try await store.createSeason(
            teamID: varsity, name: "2027", startDate: Date(), endDate: nil)
        _ = try await store.createSeason(
            teamID: junior, name: "2027", startDate: Date(), endDate: nil)

        let varsityPlayer = makePlayer(first: "Ava", last: "Varsity", number: 10)
        let juniorPlayer = makePlayer(first: "Zoe", last: "Junior", number: 10)
        try await store.addPlayers(teamID: varsity, [varsityPlayer])
        try await store.addPlayers(teamID: junior, [juniorPlayer])

        let varsityRoster = try await store.roster(teamID: varsity)
        let juniorRoster = try await store.roster(teamID: junior)
        #expect(varsityRoster[varsityPlayer.id] != nil)
        #expect(varsityRoster[juniorPlayer.id] == nil)
        #expect(juniorRoster[juniorPlayer.id] != nil)
        #expect(juniorRoster[varsityPlayer.id] == nil)

        let varsityMatch = try await self.makeMatch(
            store: store, teamID: varsity, opponent: "Dixie", roster: varsityRoster)
        let juniorMatch = try await self.makeMatch(
            store: store, teamID: junior, opponent: "Newberry", roster: juniorRoster)

        let varsityMatches = try await store.matches(teamID: varsity)
        let juniorMatches = try await store.matches(teamID: junior)
        #expect(varsityMatches.map(\.id) == [varsityMatch])
        #expect(juniorMatches.map(\.id) == [juniorMatch])
    }

    @Test("Ownership lookups resolve each team's match, player and season")
    func ownershipLookups() async throws {
        let store = try makeStore()
        let varsity = try await store.createTeam(name: "Varsity", shortName: "Varsity")
        let junior = try await store.createTeam(name: "Junior", shortName: "JV")
        let varsitySeason = try await store.createSeason(
            teamID: varsity, name: "2027", startDate: Date(), endDate: nil)
        let juniorSeason = try await store.createSeason(
            teamID: junior, name: "2027", startDate: Date(), endDate: nil)

        let varsityPlayer = makePlayer(first: "Ava", last: "Varsity", number: 9)
        let juniorPlayer = makePlayer(first: "Zoe", last: "Junior", number: 9)
        try await store.addPlayers(teamID: varsity, [varsityPlayer])
        try await store.addPlayers(teamID: junior, [juniorPlayer])

        let varsityRoster = try await store.roster(teamID: varsity)
        let juniorRoster = try await store.roster(teamID: junior)
        let varsityMatch = try await self.makeMatch(
            store: store, teamID: varsity, opponent: "Dixie", roster: varsityRoster)
        let juniorMatch = try await self.makeMatch(
            store: store, teamID: junior, opponent: "Newberry", roster: juniorRoster)

        #expect(try await store.teamID(forMatch: varsityMatch) == varsity)
        #expect(try await store.teamID(forMatch: juniorMatch) == junior)
        #expect(try await store.teamID(forPlayer: varsityPlayer.id) == varsity)
        #expect(try await store.teamID(forPlayer: juniorPlayer.id) == junior)
        #expect(try await store.teamID(forSeason: varsitySeason) == varsity)
        #expect(try await store.teamID(forSeason: juniorSeason) == junior)
    }

    @Test("Seasons list per team and changing current affects only that team")
    func seasonsArePerTeam() async throws {
        let store = try makeStore()
        let varsity = try await store.createTeam(name: "Varsity", shortName: "Varsity")
        let junior = try await store.createTeam(name: "Junior", shortName: "JV")
        let first = try await store.createSeason(
            teamID: varsity, name: "2026", startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: nil)
        let second = try await store.createSeason(
            teamID: varsity, name: "2027", startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: nil)
        let juniorOnly = try await store.createSeason(
            teamID: junior, name: "2027", startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: nil)

        // The newest season becomes current on creation.
        #expect(try await store.currentSeasonID(teamID: varsity) == second)

        var varsitySeasons = try await store.seasons(teamID: varsity)
        #expect(Set(varsitySeasons.map(\.id)) == Set([first, second]))
        #expect(varsitySeasons.first { $0.id == second }?.isCurrent == true)
        #expect(varsitySeasons.first { $0.id == first }?.isCurrent == false)

        try await store.setCurrentSeason(teamID: varsity, seasonID: first)
        #expect(try await store.currentSeasonID(teamID: varsity) == first)
        varsitySeasons = try await store.seasons(teamID: varsity)
        #expect(varsitySeasons.first { $0.id == first }?.isCurrent == true)
        #expect(varsitySeasons.first { $0.id == second }?.isCurrent == false)

        // The other team is untouched.
        #expect(try await store.currentSeasonID(teamID: junior) == juniorOnly)
        let juniorSeasons = try await store.seasons(teamID: junior)
        #expect(juniorSeasons.map(\.id) == [juniorOnly])

        // Editing identity round-trips through TeamDetails without leaking models.
        try await store.updateTeam(
            varsity, name: "Varsity Renamed", shortName: "VAR", mascot: "Wildcats",
            primaryColorHex: "112233", secondaryColorHex: nil)
        let details = try await store.teamDetails(teamID: varsity)
        #expect(details.name == "Varsity Renamed")
        #expect(details.shortName == "VAR")
    }

    @Test("Identity projections match summaries without the counts")
    func identityProjections() async throws {
        let store = try makeStore()
        let varsity = try await store.createTeam(name: "Varsity", shortName: "VAR")
        let season = try await store.createSeason(
            teamID: varsity, name: "2026", startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: nil)
        try await store.addPlayers(teamID: varsity, ProgrammeSample.roster.players)

        let identities = try await store.teamIdentities()
        #expect(identities.map(\.id) == [varsity])
        #expect(identities.first?.name == "Varsity")
        #expect(identities.first?.shortName == "VAR")

        let seasonIdentities = try await store.seasonIdentities(teamID: varsity)
        #expect(seasonIdentities.map(\.id) == [season])
        #expect(seasonIdentities.first?.name == "2026")
        #expect(seasonIdentities.first?.isCurrent == true)

        // Summaries still carry the counts for management UI.
        let summaries = try await store.teams()
        #expect(summaries.first?.playerCount == ProgrammeSample.roster.players.count)
        #expect(summaries.first?.seasonCount == 1)
        #expect(try await store.seasons(teamID: varsity).first?.matchCount == 0)
    }
}

@Suite("Match locations are optional metadata, never scoring truth")
struct MatchLocationTests {

    private func makeStore() throws -> MatchStore {
        let container = try ProgrammeStore.container(inMemory: true)
        return MatchStore(modelContainer: container)
    }

    private func makeTeamAndRoster(_ store: MatchStore) async throws -> (TeamID, RosterSnapshot) {
        let teamID = try await store.createTeam(name: "Ninety Six", shortName: nil)
        try await store.addPlayers(teamID: teamID, ProgrammeSample.roster.players)
        return (teamID, try await store.roster(teamID: teamID))
    }

    @Test("A match created without a location reads back nil")
    func locationDefaultsToNil() async throws {
        let store = try makeStore()
        let (teamID, roster) = try await makeTeamAndRoster(store)
        let matchID = try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: "Dixie", opponentShortName: "Dixie",
            kickoff: ProgrammeSample.kickoff(), venue: .away, rules: .highSchool,
            statProfile: .maxPreps, tracking: .ourTeam, competition: nil, roster: roster)
        #expect(try await store.context(for: matchID).descriptor.location == nil)
    }

    @Test("A location round-trips through create and reload")
    func locationRoundTrip() async throws {
        let store = try makeStore()
        let (teamID, roster) = try await makeTeamAndRoster(store)
        let location = MatchLocation(
            name: "Abbeville High School", address: "701 Washington St",
            latitude: 34.178, longitude: -82.379)
        let matchID = try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: "Dixie", opponentShortName: "Dixie",
            kickoff: ProgrammeSample.kickoff(), venue: .away, rules: .highSchool,
            statProfile: .maxPreps, tracking: .ourTeam, competition: "Region 2-AA",
            location: location, roster: roster)
        let reloaded = try await store.context(for: matchID)
        #expect(reloaded.descriptor.location == location)
        #expect(reloaded.descriptor.venue == .away)
    }

    @Test("Updating configuration replaces the location without touching events")
    func updateConfigurationReplacesLocation() async throws {
        let store = try makeStore()
        let (teamID, roster) = try await makeTeamAndRoster(store)
        let matchID = try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: "Dixie", opponentShortName: "Dixie",
            kickoff: ProgrammeSample.kickoff(), venue: .away, rules: .highSchool,
            statProfile: .maxPreps, tracking: .ourTeam, competition: nil, roster: roster)
        let kickoff = ProgrammeSample.kickoff()
        let location = MatchLocation(name: "Neutral Ground")
        try await store.updateConfiguration(
            matchID: matchID, rules: .highSchool, statProfile: .maxPreps,
            tracking: .ourTeam, kickoff: kickoff, venue: .neutral,
            opponentName: "Dixie", opponentShortName: "Dixie", competition: nil,
            location: location)
        let reloaded = try await store.context(for: matchID)
        #expect(reloaded.descriptor.location == location)
        #expect(reloaded.descriptor.venue == .neutral)
    }

    @Test("A V1 store migrates with its matches intact and no location")
    func v1StoreMigrates() async throws {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "programme-v1", withExtension: "store", subdirectory: "Fixtures"))
        let workingCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("programme-v1.store")
        try FileManager.default.createDirectory(
            at: workingCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: workingCopy)

        let container = try ProgrammeStore.container(url: workingCopy)
        let store = MatchStore(modelContainer: container)
        let items = try await store.matches()
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.opponentName == "Dixie")
        #expect(item.venue == .away)
        #expect(item.competition == "Region 2-AA")
        // eventCount is a denormalised cache, never authoritative; the
        // authoritative history is asserted on the reloaded context below.

        let context = try await store.context(for: item.id)
        #expect(context.descriptor.location == nil)
        #expect(context.events.count == 3)
        // Derivation still runs over the migrated history.
        _ = StatEngine.snapshot(context: context)
    }
}

@Suite("Per-match reminder preference")
struct MatchReminderPreferenceTests {

    private func makeStore() throws -> MatchStore {
        let container = try ProgrammeStore.container(inMemory: true)
        return MatchStore(modelContainer: container)
    }

    private func makeScheduledMatch(_ store: MatchStore) async throws -> MatchID {
        let teamID = try await store.createTeam(name: "Ninety Six", shortName: nil)
        try await store.addPlayers(teamID: teamID, ProgrammeSample.roster.players)
        let roster = try await store.roster(teamID: teamID)
        return try await store.createMatch(
            teamID: teamID, seasonID: nil, opponentName: "Dixie", opponentShortName: "Dixie",
            kickoff: ProgrammeSample.kickoff(), venue: .away, rules: .highSchool,
            statProfile: .maxPreps, tracking: .ourTeam, competition: nil, roster: roster)
    }

    @Test("No reminder is the default and the descriptor never carries one")
    func reminderDefaultsToNil() async throws {
        let store = try makeStore()
        let matchID = try await makeScheduledMatch(store)
        #expect(try await store.reminderMinutesBefore(for: matchID) == nil)
        // The preference is device-local presentation state, never match
        // truth: it must not leak into the descriptor, archive, or sync.
        let descriptor = try await store.context(for: matchID).descriptor
        #expect(descriptor.location == nil)
    }

    @Test("A reminder preference round-trips and clears")
    func reminderRoundTrip() async throws {
        let store = try makeStore()
        let matchID = try await makeScheduledMatch(store)
        try await store.setReminderMinutesBefore(30, for: matchID)
        #expect(try await store.reminderMinutesBefore(for: matchID) == 30)
        try await store.setReminderMinutesBefore(nil, for: matchID)
        #expect(try await store.reminderMinutesBefore(for: matchID) == nil)
    }

    @Test("Updating configuration preserves the reminder and notifies")
    func updateConfigurationPreservesReminder() async throws {
        let store = try makeStore()
        let matchID = try await makeScheduledMatch(store)
        try await store.setReminderMinutesBefore(15, for: matchID)
        let notified = Mutex<[MatchID]>([])
        await store.setMatchChangeHandler { matchID in notified.withLock { $0.append(matchID) } }
        try await store.updateConfiguration(
            matchID: matchID, rules: .highSchool, statProfile: .maxPreps,
            tracking: .ourTeam, kickoff: ProgrammeSample.kickoff(), venue: .away,
            opponentName: "Dixie", opponentShortName: "Dixie", competition: nil)
        #expect(try await store.reminderMinutesBefore(for: matchID) == 15)
        #expect(notified.withLock { $0 } == [matchID])
    }

    @Test("Deleting a match notifies so its notification can be removed")
    func deleteMatchNotifies() async throws {
        let store = try makeStore()
        let matchID = try await makeScheduledMatch(store)
        let notified = Mutex<[MatchID]>([])
        await store.setMatchChangeHandler { matchID in notified.withLock { $0.append(matchID) } }
        try await store.deleteMatch(matchID)
        #expect(notified.withLock { $0 } == [matchID])
    }

    @Test("A V2 store migrates with its location intact and no reminder")
    func v2StoreMigrates() async throws {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "programme-v2", withExtension: "store", subdirectory: "Fixtures"))
        let workingCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("programme-v2.store")
        try FileManager.default.createDirectory(
            at: workingCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: workingCopy)

        let container = try ProgrammeStore.container(url: workingCopy)
        let store = MatchStore(modelContainer: container)
        let items = try await store.matches()
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.opponentName == "Dixie")

        let context = try await store.context(for: item.id)
        #expect(context.descriptor.location?.name == "Abbeville High School")
        #expect(try await store.reminderMinutesBefore(for: item.id) == nil)
    }
}

@Suite("Season record text projects cached results without deriving totals")
struct SeasonRecordProjectionTests {

    private func makeStore() throws -> MatchStore {
        let container = try ProgrammeStore.container(inMemory: true)
        return MatchStore(modelContainer: container)
    }

    private func makeTeamAndRoster(_ store: MatchStore) async throws -> (TeamID, RosterSnapshot) {
        let teamID = try await store.createTeam(name: "Ninety Six", shortName: nil)
        try await store.addPlayers(teamID: teamID, ProgrammeSample.roster.players)
        return (teamID, try await store.roster(teamID: teamID))
    }

    private func play(_ command: MatchCommand, on context: inout MatchContext, date: inout Date)
        throws
    {
        let effects = try MatchEngine.perform(command, on: context, at: date)
        MatchEngine.apply(effects, to: &context)
        date = date.addingTimeInterval(1)
    }

    /// Plays a match to the given score and imports it into `seasonID`,
    /// finalizing unless asked not to (a live match must not count).
    private func importMatch(
        _ store: MatchStore, teamID: TeamID, seasonID: SeasonID?, seed: String, ourGoals: Int,
        opponentGoals: Int, finalize: Bool = true
    ) async throws {
        var context = MatchContext(
            descriptor: ProgrammeSample.descriptor(seed: seed), roster: ProgrammeSample.roster)
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        try play(
            .setLineup(
                LineupEvent(
                    side: .us, onField: ProgrammeSample.startingEleven,
                    goalkeeper: ProgrammeSample.keeper)), on: &context, date: &date)
        try play(.startNextPeriod, on: &context, date: &date)
        for _ in 0..<ourGoals {
            try play(
                .recordShot(
                    ShotEvent(
                        side: .us, shooter: .player(ProgrammeSample.carter), outcome: .goal)),
                on: &context, date: &date)
        }
        for _ in 0..<opponentGoals {
            try play(
                .recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal)),
                on: &context, date: &date)
        }
        if finalize {
            try play(.finalize, on: &context, date: &date)
        }
        _ = try await store.importMatch(context, teamID: teamID, seasonID: seasonID)
    }

    @Test("Record projection matches the derived season record for wins, losses, and draws")
    func recordMatchesDerivedSeasonRecord() async throws {
        let store = try makeStore()
        let (teamID, _) = try await makeTeamAndRoster(store)
        let seasonID = try await store.createSeason(
            teamID: teamID, name: "Fall", startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: nil)

        try await importMatch(
            store, teamID: teamID, seasonID: seasonID, seed: "record.win", ourGoals: 2,
            opponentGoals: 1)
        try await importMatch(
            store, teamID: teamID, seasonID: seasonID, seed: "record.loss", ourGoals: 0,
            opponentGoals: 1)
        try await importMatch(
            store, teamID: teamID, seasonID: seasonID, seed: "record.draw", ourGoals: 1,
            opponentGoals: 1)
        // Still live: counted by neither path.
        try await importMatch(
            store, teamID: teamID, seasonID: seasonID, seed: "record.live", ourGoals: 3,
            opponentGoals: 0, finalize: false)

        #expect(try await store.seasonRecord(teamID: teamID, seasonID: seasonID) == "1-1-1")
        #expect(
            try await store.seasonRecord(teamID: teamID, seasonID: seasonID)
                == store.seasonStats(teamID: teamID, seasonID: seasonID).recordText)
    }

    @Test("Record projection respects season scope and starts at zero")
    func recordRespectsSeasonScope() async throws {
        let store = try makeStore()
        let (teamID, _) = try await makeTeamAndRoster(store)
        let firstID = try await store.createSeason(
            teamID: teamID, name: "Fall", startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: nil)
        let secondID = try await store.createSeason(
            teamID: teamID, name: "Spring", startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: nil, makeCurrent: false)

        try await importMatch(
            store, teamID: teamID, seasonID: firstID, seed: "scope.first", ourGoals: 1,
            opponentGoals: 0)
        try await importMatch(
            store, teamID: teamID, seasonID: secondID, seed: "scope.second", ourGoals: 2,
            opponentGoals: 0)

        #expect(try await store.seasonRecord(teamID: teamID, seasonID: firstID) == "1-0-0")
        #expect(try await store.seasonRecord(teamID: teamID, seasonID: secondID) == "1-0-0")
        // No season filter aggregates every finalized match, like seasonStats.
        #expect(try await store.seasonRecord(teamID: teamID, seasonID: nil) == "2-0-0")
        #expect(
            try await store.seasonRecord(teamID: teamID, seasonID: nil)
                == store.seasonStats(teamID: teamID, seasonID: nil).recordText)

        let otherTeamID = try await store.createTeam(name: "Dixie", shortName: nil)
        #expect(try await store.seasonRecord(teamID: otherTeamID, seasonID: nil) == "0-0-0")
    }
}
