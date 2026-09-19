import CloudKit
import Foundation
import Observation
import ProgrammeCollaboration
import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import ProgrammeUI
import SwiftData
import SwiftUI
import TipKit

/// Per-team New Match defaults, keyed by TeamID in UserDefaults.
/// No schema migration: these are local UI preferences, not match truth.
/// Global scoring preferences (haptics, keep-awake, confirm) stay global.
@MainActor
enum TeamMatchDefaults {
    private static func key(_ field: String, teamID: TeamID) -> String {
        "programme.team.\(teamID.rawValue.uuidString).\(field)"
    }

    static func load(teamID: TeamID) -> (
        profileID: String, rulesName: String, tracking: OpponentTrackingMode
    ) {
        let defaults = UserDefaults.standard
        let profile =
            defaults.string(forKey: key("statProfile", teamID: teamID))
            ?? StatProfile.maxPreps.id
        let rules =
            defaults.string(forKey: key("rulesPreset", teamID: teamID))
            ?? MatchRules.highSchool.name
        let trackingRaw = defaults.string(forKey: key("opponentTracking", teamID: teamID))
        let tracking =
            trackingRaw.flatMap(OpponentTrackingMode.init(rawValue:))
            ?? .ourTeam
        return (profile, rules, tracking)
    }

    static func save(
        teamID: TeamID, profileID: String, rulesName: String, tracking: OpponentTrackingMode
    ) {
        let defaults = UserDefaults.standard
        defaults.set(profileID, forKey: key("statProfile", teamID: teamID))
        defaults.set(rulesName, forKey: key("rulesPreset", teamID: teamID))
        defaults.set(tracking.rawValue, forKey: key("opponentTracking", teamID: teamID))
    }
}

/// The selected-team source of truth. Team is workspace context in which the
/// four sections (Home/Matches/Roster/Stats) operate.
@MainActor
@Observable
final class TeamWorkspace {
    var teams: [TeamListItem] = []
    var selectedTeamID: TeamID?
    /// Current season belongs to the team; used by Home, New Match, default
    /// Matches filtering, player stats and widgets.
    var currentSeasonID: SeasonID?
    /// Viewed stats season is temporary UI state. Viewing an old season never
    /// changes which season is current.
    var viewedStatsSeasonID: SeasonID?

    private static let selectedTeamKey = "programme.selectedTeamID"

    var selectedTeam: TeamListItem? {
        guard let selectedTeamID else { return nil }
        return teams.first { $0.id == selectedTeamID }
    }

    var hasTeam: Bool { selectedTeamID != nil }

    static func restoredSelection(from teams: [TeamListItem]) -> TeamID? {
        guard
            let raw = UserDefaults.standard.string(forKey: selectedTeamKey),
            let uuid = UUID(uuidString: raw)
        else { return nil }
        let id = TeamID(uuid)
        return teams.contains(where: { $0.id == id }) ? id : nil
    }

    func persistSelection() {
        if let selectedTeamID {
            UserDefaults.standard.set(
                selectedTeamID.rawValue.uuidString, forKey: Self.selectedTeamKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedTeamKey)
        }
    }
}

/// Application-level state and services.
///
/// Owns the database, the recovery journal, the one live scoring session and
/// the team workspace. Feature state lives with the feature. The live
/// scorer's MatchContext remains the source of truth while scoring; browsing
/// selection never redefines it.
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
    var workspace = TeamWorkspace()
    /// Bumped on every observed store write so browsing lists refetch.
    /// Views combine this with their team/season ids in `.task(id:)`.
    var storeRevision = 0
    /// Set once at launch; used by App Intents, Spotlight and Shortcuts.
    var intentProvider: ProgrammeIntentProvider?
    private let storeObserver = StoreChangeObserver()
    /// Device-local kickoff reminders. Permission is requested only from the
    /// explicit Remind Me action, never at launch.
    let reminderCenter = MatchReminderCenter()

    // MARK: - Team sharing

    /// Built lazily so the app never constructs a CloudKit container on
    /// launch paths (previews, intent tests, iCloud-off devices) that never
    /// share.
    private var shareCoordinator: TeamShareCoordinator?

    private func sharing() throws -> TeamShareCoordinator {
        if let shareCoordinator { return shareCoordinator }
        let url = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        .appending(path: "Programme/Sharing/shared-zones.json")
        let coordinator = TeamShareCoordinator(
            makeContainer: { CKContainer.default() }, sharedZones: try SharedZoneStore(url: url))
        shareCoordinator = coordinator
        return coordinator
    }

    /// Resolves the SwiftUI share item for a team. Pre-resolves the live
    /// zone-wide share when one exists so the system presents it directly
    /// (`.existing`); otherwise the item's prepare handler creates and saves
    /// it on demand. Throws a human-readable error when iCloud is
    /// unavailable or the library is not ready.
    func teamShareItem(teamID: TeamID) async throws -> TeamShareItem {
        guard ShareAvailability.isICloudAvailable else { throw TeamShareError.iCloudUnavailable }
        guard let store else { throw TeamShareError.noLibrary }
        let details = try await store.teamDetails(teamID: teamID)
        let coordinator = try sharing()
        let prepared = await coordinator.existingShare(teamID: teamID)
        return TeamShareItem(
            teamID: teamID, teamName: details.name, prepared: prepared,
            coordinator: coordinator
        ) {
            CKContainer.default()
        }
    }

    /// Who currently has access to a shared team. Empty when the team is
    /// not shared. Display only — edits happen in the system share sheet.
    func teamParticipants(teamID: TeamID) async -> [ShareParticipant] {
        guard let coordinator = try? sharing() else { return [] }
        return await coordinator.participants(teamID: teamID)
    }

    /// Revokes the team's share for everyone. Local truth is untouched.
    func stopSharing(teamID: TeamID) async throws {
        try await sharing().stopSharing(teamID: teamID)
    }

    /// Accepts an invitation, then reloads the workspace. Nothing
    /// materializes here: shared content still lands through the applier, so
    /// review-gating applies unchanged.
    func acceptShare(_ metadata: CKShare.Metadata) async {
        if let coordinator = try? sharing() {
            try? await coordinator.accept(metadata)
        }
        await reloadWorkspace(selecting: workspace.selectedTeamID)
    }

    /// If the on-disk store cannot be opened at all, the app still launches into
    /// an in-memory one so it can explain what happened instead of crashing.
    private static let fallbackContainer: ModelContainer? = try? ProgrammeStore.container(inMemory: true)

    var containerForScene: ModelContainer {
        container ?? Self.fallbackContainer
            ?? {
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

    /// Reconciles the pending kickoff notification with the stored
    /// preference after a kickoff change, and clears it after a deletion
    /// (where the context lookup fails) or finalization.
    func syncReminder(for matchID: MatchID) async {
        guard let store else { return }
        guard let minutes = try? await store.reminderMinutesBefore(for: matchID),
            let context = try? await store.context(for: matchID),
            context.phase == .scheduled
        else {
            await reminderCenter.cancel(matchID: matchID)
            return
        }
        let descriptor = context.descriptor
        await reminderCenter.sync(
            matchID: matchID, kickoff: descriptor.kickoff, minutesBefore: minutes,
            title: MatchReminderRequest.title(descriptor: descriptor),
            body: MatchReminderRequest.body(descriptor: descriptor, minutesBefore: minutes))
    }

    // MARK: - Testing

    /// Test seam for intent tests: replace the library with an empty
    /// in-memory store (and a throwaway journal) so tests exercise the real
    /// team-aware routing without touching the on-disk library.
    func useEphemeralStoreForTests() throws {
        let container = try ProgrammeStore.container(inMemory: true)
        self.container = container
        self.store = MatchStore(modelContainer: container)
        self.journal = try RecoveryJournal(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "ProgrammeIntentTests/\(UUID().uuidString)"))
    }

    func bootstrap() async {
        guard !isReady else { return }
        defer { isReady = true }
        guard let container, let store else { return }

        // Keep pending reminder notifications in sync with kickoff changes
        // and deletions, whoever initiates them.
        await store.setMatchChangeHandler { [weak self] matchID in
            Task { [weak self] in await self?.syncReminder(for: matchID) }
        }

        try? Tips.configure([
            .displayFrequency(.weekly),
            .datastoreLocation(.applicationDefault),
        ])

        await reloadWorkspace(selecting: nil)
        if launchOptions.opensLiveMatch {
            let items = (try? await store.matches(limit: 60)) ?? []
            if let live = items.first(where: \.isInterrupted) {
                await openLiveSession(matchID: live.id)
            }
        }
        await refreshRecoveryCandidates()
        await refreshWidgetSnapshot()

        storeObserver.start(container: container) { [weak self] in
            await self?.noteStoreChanged()
            await self?.refreshWidgetSnapshot()
            await self?.refreshRecoveryCandidates()
        }
    }

    /// Reload teams and resolve selection. When `selecting` is non-nil (a new
    /// team was just created), select it.
    func reloadWorkspace(selecting preferred: TeamID? = nil) async {
        guard let store else { return }
        let teams = (try? await store.teams()) ?? []
        workspace.teams = teams
        guard !teams.isEmpty else {
            workspace.selectedTeamID = nil
            workspace.currentSeasonID = nil
            workspace.viewedStatsSeasonID = nil
            workspace.persistSelection()
            return
        }
        let restored: TeamID?
        if let preferred, teams.contains(where: { $0.id == preferred }) {
            restored = preferred
        } else {
            restored = TeamWorkspace.restoredSelection(from: teams) ?? teams.first?.id
        }
        workspace.selectedTeamID = restored
        workspace.persistSelection()
        if let selected = restored {
            workspace.currentSeasonID = try? await store.currentSeasonID(teamID: selected)
            workspace.viewedStatsSeasonID = workspace.currentSeasonID
        }
        navigation.section = .home
        navigation.clearTeamScopedPaths()
        await refreshWidgetSnapshot()
    }

    /// Select another team workspace. Keeps the section, clears pushed
    /// team-specific state, resolves the new current season and resets the
    /// viewed stats season.
    func selectTeam(_ teamID: TeamID) async {
        guard let store else { return }
        guard workspace.teams.contains(where: { $0.id == teamID }) else { return }
        guard workspace.selectedTeamID != teamID else { return }
        workspace.selectedTeamID = teamID
        workspace.persistSelection()
        workspace.currentSeasonID = try? await store.currentSeasonID(teamID: teamID)
        workspace.viewedStatsSeasonID = workspace.currentSeasonID
        navigation.clearTeamScopedPaths()
        await refreshWidgetSnapshot()
    }

    /// Loads the fictional Ninety Six team and four played matches so the app can
    /// be explored without entering a roster first. Always explicit, never
    /// automatic, and the rest of Programme knows nothing about it.
    func loadSampleData() async {
        guard let container, let store else { return }
        do {
            try ProgrammeStore.seedSampleData(into: container.mainContext)
            // Select the sample team explicitly rather than relying on ordering.
            let teams = (try? await store.teams()) ?? []
            let sample = teams.first { $0.id == ProgrammeSample.teamID } ?? teams.first
            await reloadWorkspace(selecting: sample?.id)
        } catch {
            navigation.errorToShow = ProgrammeError(
                title: "Couldn't load the sample team",
                message: "Nothing was changed. You can still create your own team.",
                underlying: error)
        }
    }

    // MARK: - Team-aware routing

    /// Database-aware routing above the pure navigation model. Selecting a
    /// match/player/season first selects its owning team.
    func open(_ route: AppRoute) async {
        guard let store else {
            navigation.open(route)
            return
        }
        switch route {
        case .match(let id):
            if let owner = try? await store.teamID(forMatch: id) {
                await ensureTeamSelected(owner)
            }
            navigation.open(route)
        case .player(let id):
            if let owner = try? await store.teamID(forPlayer: id) {
                await ensureTeamSelected(owner)
            }
            navigation.open(route)
        case .season(let id):
            if let id {
                if let owner = try? await store.teamID(forSeason: id) {
                    await ensureTeamSelected(owner)
                }
                // Viewing a historical season never marks it current.
                workspace.viewedStatsSeasonID = id
            }
            navigation.open(route)
        case .eventLog:
            navigation.open(route)
        }
    }

    func handle(url: URL) async -> Bool {
        guard url.scheme == "programme" else { return false }
        let host = url.host()
        let identifier = url.pathComponents.first { $0 != "/" }
        switch host {
        case "match":
            guard let identifier, let uuid = UUID(uuidString: identifier) else { return false }
            await open(.match(MatchID(uuid)))
            return true
        case "player":
            guard let identifier, let uuid = UUID(uuidString: identifier) else { return false }
            await open(.player(PlayerID(uuid)))
            return true
        case "team", "season":
            if let identifier, let uuid = UUID(uuidString: identifier) {
                await open(.season(SeasonID(uuid)))
            } else {
                navigation.section = .stats
            }
            return true
        case "live":
            if let identifier, let uuid = UUID(uuidString: identifier) {
                await openLiveSession(matchID: MatchID(uuid))
            } else {
                navigation.isShowingLiveMatch = true
            }
            return true
        case "today", "home":
            navigation.section = .home
            return true
        case "newmatch":
            navigation.isPresentingNewMatch = true
            return true
        default:
            return navigation.handle(url: url)
        }
    }

    private func ensureTeamSelected(_ teamID: TeamID) async {
        if workspace.selectedTeamID != teamID {
            await selectTeam(teamID)
        }
    }

    // MARK: - Recovery

    func refreshRecoveryCandidates() async {
        guard let store else { return }
        let interrupted = (try? await store.interruptedMatches()) ?? []
        let journals = journal?.openJournals() ?? []

        var candidates: [RecoverableMatch] = []
        for item in interrupted {
            let summary = journals.first { $0.matchID == item.id }
            // Use the match's own team identity, never the selected workspace.
            let title: String
            if let context = try? await store.context(for: item.id) {
                title = context.descriptor.title
            } else {
                title = "\(item.venue.shortLabel) \(item.opponentName)"
            }
            candidates.append(
                RecoverableMatch(
                    matchID: item.id,
                    title: title,
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
                    title: summary.descriptor.title,
                    eventCount: summary.eventCount,
                    lastEventAt: summary.lastEventAt,
                    isInDatabase: false))
        }
        recoveryCandidates = candidates
    }

    func dismissRecovery(for matchID: MatchID) {
        recoveryCandidates.removeAll { $0.matchID == matchID }
    }

    private func noteStoreChanged() {
        storeRevision += 1
    }

    // MARK: - Live session

    func openLiveSession(matchID: MatchID) async {
        guard let store, let journal else { return }
        if liveSession?.matchID == matchID { return }
        do {
            var context: MatchContext
            if try await store.matchExists(matchID) {
                context = try await ProgrammeSignposts.measure("loadContext") {
                    try await store.context(for: matchID)
                }
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
            } else if let journaled = try? journal.recover(matchID: matchID) {
                // Journal-only recovery: import into the journal's own team,
                // never into whichever workspace happens to be selected.
                let ownerID = journaled.descriptor.teamID
                let ownerTeams = (try? await store.teams()) ?? []
                guard ownerTeams.contains(where: { $0.id == ownerID }) else {
                    throw StoreError.teamNotFound
                }
                let ownerSeason = (try? await store.currentSeasonID(teamID: ownerID)) ?? journaled.descriptor.seasonID
                _ = try await store.importMatch(journaled, teamID: ownerID, seasonID: ownerSeason)
                context = journaled
            } else {
                throw StoreError.matchNotFound
            }
            // Resuming a stored match selects its owning team first, so closing
            // the scorer returns to the correct workspace.
            let ownerID = context.descriptor.teamID
            let ownerTeams = (try? await store.teams()) ?? []
            if ownerTeams.contains(where: { $0.id == ownerID }) {
                await ensureTeamSelected(ownerID)
            }
            let session = ProgrammeSignposts.measure("openSession") {
                LiveMatchSession(context: context, store: store, journal: journal, appModel: self)
            }
            liveSession = session
            ProgrammeStateReporter.reportWorkflow(.liveScoring)
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
        ProgrammeStateReporter.reportWorkflow(.browsing)
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

    // MARK: - Widgets (selected-team scoped)

    /// The widget snapshot represents the currently selected team. While a
    /// match is live, its team identity comes from the live session's
    /// MatchContext, not from browsing state.
    func refreshWidgetSnapshot() async {
        guard let store, let selectedTeamID = workspace.selectedTeamID else { return }
        await ProgrammeSignposts.measure("widgetRefresh") {
            await self.refreshWidgetSnapshotBody(store: store, selectedTeamID: selectedTeamID)
        }
    }

    private func refreshWidgetSnapshotBody(store: MatchStore, selectedTeamID: TeamID) async {
        let currentSeasonID = workspace.currentSeasonID
        let details = try? await store.teamDetails(teamID: selectedTeamID)
        let teamName = details?.name ?? workspace.selectedTeam?.name ?? "Programme"
        let teamShort = details?.shortName ?? workspace.selectedTeam?.shortName ?? "Programme"
        let matches = (try? await store.matches(teamID: selectedTeamID, limit: 40)) ?? []
        let season = try? await store.seasonStats(teamID: selectedTeamID, seasonID: currentSeasonID)

        let live: ProgrammeWidgetSnapshot.LiveMatch? = liveSession.map { session in
            ProgrammeWidgetSnapshot.LiveMatch(
                matchID: session.matchID.rawValue.uuidString,
                teamShortName: session.descriptor.teamShortName,
                opponentShortName: session.context.descriptor.opponentShortName,
                scoreUs: session.snapshot.score.us,
                scoreOpponent: session.snapshot.score.opponent,
                periodLabel: session.context.currentPeriod?.shortLabel ?? "",
                clockText: session.clock.displayText,
                isClockRunning: session.clock.isRunning,
                needsReviewCount: session.snapshot.needsReviewCount,
                lastEventText: session.lastEventDescription?.oneLine)
        }

        let upcoming =
            matches
            .filter { $0.phase == .scheduled && $0.kickoff > Date().addingTimeInterval(-7_200) }
            .sorted { $0.kickoff < $1.kickoff }
            .first
            .map {
                ProgrammeWidgetSnapshot.UpcomingMatch(
                    matchID: $0.id.rawValue.uuidString, opponentShortName: $0.opponentName,
                    venueLabel: $0.venue.shortLabel, kickoff: $0.kickoff)
            }

        let recent =
            matches
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
                teamShortName: teamShort,
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
