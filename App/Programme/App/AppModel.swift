import Foundation
import Observation
import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI
import TipKit

/// Application-level state and services.
///
/// Deliberately small. It owns the database, the recovery journal and the one
/// live scoring session, and nothing else: feature state lives with the feature.
@MainActor
@Observable
final class AppModel {
    private(set) var container: ModelContainer?
    private(set) var store: MatchStore?
    private(set) var journal: RecoveryJournal?
    private(set) var startupError: ProgrammeError?
    private(set) var isReady = false

    /// The match currently being scored. There is at most one.
    var liveSession: LiveMatchSession?

    /// Matches that were being scored when Programme last stopped. Never
    /// discarded silently.
    private(set) var recoveryCandidates: [RecoverableMatch] = []

    var navigation = NavigationModel()
    /// Set once at launch; used by App Intents, Spotlight and Shortcuts.
    var intentProvider: ProgrammeIntentProvider?
    private let storeObserver = StoreChangeObserver()
    var teamID: TeamID?
    var seasonID: SeasonID?
    var teamName: String = "Programme"
    var teamShortName: String = "Programme"

    /// If the on-disk store cannot be opened at all, the app still launches into
    /// an in-memory one so it can explain what happened instead of crashing.
    private static let fallbackContainer: ModelContainer? = try? ProgrammeStore.container(inMemory: true)

    var containerForScene: ModelContainer {
        container ?? Self.fallbackContainer ?? {
            // A container is required by the scene. If even an in-memory store
            // cannot be created the process is unusable; surface it immediately
            // rather than shipping a silently broken app.
            fatalError("Programme could not create a data store.")
        }()
    }

    /// Launch arguments used by the UI tests and by `--demo` runs. They never
    /// change behaviour unless explicitly passed.
    struct LaunchOptions {
        var isUITest = false
        var seedsSampleData = false
        var opensLiveMatch = false

        init(arguments: [String] = ProcessInfo.processInfo.arguments) {
            isUITest = arguments.contains("-programme-uitest")
            seedsSampleData = isUITest || arguments.contains("-programme-sample")
            opensLiveMatch = arguments.contains("-programme-open-live")
        }
    }

    let launchOptions = LaunchOptions()

    /// The store is opened synchronously here rather than in an async step, so
    /// there is never a moment where the scene is bound to a different, empty
    /// container while the real one is still being created.
    init() {
        do {
            let container = try ProgrammeStore.container(inMemory: launchOptions.isUITest)
            self.container = container
            self.store = MatchStore(modelContainer: container)
            // A throwaway store gets a throwaway journal. Otherwise a UI-test
            // run would append to — and later replay — the real one.
            self.journal =
                launchOptions.isUITest
                ? try? RecoveryJournal(
                    directory: FileManager.default.temporaryDirectory
                        .appending(path: "ProgrammeTestRecovery/\(UUID().uuidString)"))
                : try? RecoveryJournal.makeDefault()
            if launchOptions.seedsSampleData {
                try? ProgrammeStore.seedSampleData(
                    into: container.mainContext, includeLiveMatch: launchOptions.opensLiveMatch)
            }
        } catch {
            startupError = ProgrammeError(
                title: "Programme couldn't open its library",
                message:
                    "Your matches are still on this iPad. Restart Programme, and if this keeps happening, restore from a Programme archive.",
                underlying: error)
        }
    }

    func bootstrap() async {
        guard !isReady else { return }
        defer { isReady = true }
        guard let container, let store else { return }

        try? Tips.configure([
            .displayFrequency(.weekly),
            .datastoreLocation(.applicationDefault),
        ])

        try? await loadTeamContext(store: store)
        if launchOptions.opensLiveMatch, let teamID {
            let matches = (try? await store.matches(teamID: teamID)) ?? []
            if let live = matches.first(where: \.isInterrupted) {
                await openLiveSession(matchID: live.id)
            }
        }
        await refreshRecoveryCandidates()
        await refreshWidgetSnapshot()

        storeObserver.start(container: container) { [weak self] in
            await self?.refreshWidgetSnapshot()
            await self?.refreshRecoveryCandidates()
        }
    }

    private func loadTeamContext(store: MatchStore) async throws {
        let teams = try await store.teams()
        guard let team = teams.first else { return }
        teamID = team.id
        teamName = team.name
        teamShortName = team.shortName
        seasonID = try await store.currentSeasonID(teamID: team.id)
    }

    /// Loads the fictional Ninety Six team and four played matches so the app can
    /// be explored without entering a roster first. Always explicit, never
    /// automatic, and the rest of Programme knows nothing about it.
    func loadSampleData() async {
        guard let container else { return }
        do {
            try ProgrammeStore.seedSampleData(into: container.mainContext)
            await reloadTeamContext()
        } catch {
            navigation.errorToShow = ProgrammeError(
                title: "Couldn't load the sample team",
                message: "Nothing was changed. You can still create your own team.",
                underlying: error)
        }
    }

    func reloadTeamContext() async {
        guard let store else { return }
        try? await loadTeamContext(store: store)
        await refreshWidgetSnapshot()
    }

    // MARK: - Recovery

    func refreshRecoveryCandidates() async {
        guard let store else { return }
        let interrupted = (try? await store.interruptedMatches()) ?? []
        let journals = journal?.openJournals() ?? []

        var candidates: [RecoverableMatch] = []
        for item in interrupted {
            let summary = journals.first { $0.matchID == item.id }
            candidates.append(
                RecoverableMatch(
                    matchID: item.id,
                    title: "\(teamShortName) \(item.venue.shortLabel) \(item.opponentName)",
                    eventCount: max(item.eventCount, summary?.eventCount ?? 0),
                    lastEventAt: summary?.lastEventAt,
                    isInDatabase: true))
        }
        // A journal with no matching database row means the write-ahead log
        // outlived the store. That match is still completely recoverable.
        for summary in journals where !interrupted.contains(where: { $0.id == summary.matchID }) {
            candidates.append(
                RecoverableMatch(
                    matchID: summary.matchID,
                    title:
                        "\(summary.descriptor.teamShortName) \(summary.descriptor.venue.shortLabel) \(summary.descriptor.opponentShortName)",
                    eventCount: summary.eventCount,
                    lastEventAt: summary.lastEventAt,
                    isInDatabase: false))
        }
        recoveryCandidates = candidates
    }

    func dismissRecovery(for matchID: MatchID) {
        recoveryCandidates.removeAll { $0.matchID == matchID }
    }

    // MARK: - Live session

    func openLiveSession(matchID: MatchID) async {
        guard let store, let journal else { return }
        if liveSession?.matchID == matchID { return }
        do {
            var context: MatchContext
            if try await store.matchExists(matchID) {
                context = try await store.context(for: matchID)
                let journaled = try? journal.recover(matchID: matchID)

                // A journal is only trusted when it genuinely *extends* what the
                // database holds — every stored event present, plus more. That is
                // what a crash between the durable append and the store write
                // looks like. A journal that disagrees belongs to a different
                // version of this match (a re-import, a restored backup) and is
                // discarded rather than allowed to resurrect deleted events.
                let storedIDs = Set(context.events.map(\.id))
                let journaledIDs = Set(journaled?.events.map(\.id) ?? [])

                if let journaled, journaledIDs.isSuperset(of: storedIDs),
                    journaled.events.count > context.events.count
                {
                    try await store.replaceEvents(matchID: matchID, with: journaled.events)
                    try await store.apply(
                        [
                            .setClock(journaled.clock), .setPhase(journaled.phase),
                            .setFinalized(journaled.finalizedAt),
                        ], to: matchID)
                    context = journaled
                } else if journaled != nil, !journaledIDs.isSuperset(of: storedIDs) {
                    journal.discard(matchID: matchID)
                }
            } else if let journaled = try? journal.recover(matchID: matchID), let teamID {
                _ = try await store.importMatch(journaled, teamID: teamID, seasonID: seasonID)
                context = journaled
            } else {
                throw StoreError.matchNotFound
            }
            let session = LiveMatchSession(context: context, store: store, journal: journal, appModel: self)
            liveSession = session
            dismissRecovery(for: matchID)
            navigation.presentLiveMatch()
        } catch {
            navigation.errorToShow = ProgrammeError(
                title: "Programme couldn't open that match",
                message: "The match data is still stored. Try again, or open it from Matches.",
                underlying: error)
        }
    }

    func closeLiveSession() async {
        await liveSession?.flush()
        liveSession = nil
        navigation.isShowingLiveMatch = false
        await refreshWidgetSnapshot()
    }

    // MARK: - Scene phase

    func scenePhaseChanged(to phase: ScenePhase) {
        guard phase == .background || phase == .inactive else { return }
        // Make sure everything recorded has reached the database before the app
        // can be suspended or killed.
        Task { await liveSession?.flush() }
        if phase == .background { MaintenanceScheduler.scheduleIfNeeded() }
    }

    // MARK: - Widgets

    func refreshWidgetSnapshot() async {
        guard let store, let teamID else { return }
        let matches = (try? await store.matches(teamID: teamID, limit: 40)) ?? []
        let season = try? await store.seasonStats(teamID: teamID, seasonID: seasonID)

        let live: ProgrammeWidgetSnapshot.LiveMatch? = liveSession.map { session in
            ProgrammeWidgetSnapshot.LiveMatch(
                matchID: session.matchID.rawValue.uuidString,
                teamShortName: teamShortName,
                opponentShortName: session.context.descriptor.opponentShortName,
                scoreUs: session.snapshot.score.us,
                scoreOpponent: session.snapshot.score.opponent,
                periodLabel: session.context.currentPeriod?.shortLabel ?? "",
                clockText: session.clock.displayText,
                isClockRunning: session.clock.isRunning,
                needsReviewCount: session.snapshot.needsReviewCount,
                lastEventText: session.lastEventDescription?.oneLine)
        }

        let upcoming = matches
            .filter { $0.phase == .scheduled && $0.kickoff > Date().addingTimeInterval(-7_200) }
            .sorted { $0.kickoff < $1.kickoff }
            .first
            .map {
                ProgrammeWidgetSnapshot.UpcomingMatch(
                    matchID: $0.id.rawValue.uuidString, opponentShortName: $0.opponentName,
                    venueLabel: $0.venue.shortLabel, kickoff: $0.kickoff)
            }

        let recent = matches
            .filter { $0.phase == .finalized }
            .prefix(4)
            .map {
                ProgrammeWidgetSnapshot.RecentResult(
                    matchID: $0.id.rawValue.uuidString, opponentShortName: $0.opponentName,
                    resultLetter: $0.result?.letter ?? "", scoreUs: $0.score.us,
                    scoreOpponent: $0.score.opponent, kickoff: $0.kickoff)
            }

        Task { await intentProvider?.reindexSpotlight() }
        ProgrammeSharedContainer.write(
            ProgrammeWidgetSnapshot(
                teamName: teamName,
                teamShortName: teamShortName,
                seasonName: nil,
                recordText: season?.recordText ?? "0-0-0",
                live: live,
                upcoming: upcoming,
                recent: Array(recent)))
        WidgetRefresher.reload()
    }
}

struct RecoverableMatch: Identifiable, Hashable, Sendable {
    var matchID: MatchID
    var title: String
    var eventCount: Int
    var lastEventAt: Date?
    /// False when only the write-ahead journal survived.
    var isInDatabase: Bool

    var id: MatchID { matchID }
}

/// A user-facing error. Programme never shows a raw technical message, and never
/// implies data loss that did not happen.
struct ProgrammeError: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var message: String
    var underlying: (any Error)?

    /// Kept for the log, not for the interface.
    var technicalDetail: String? { underlying.map { String(describing: $0) } }
}
