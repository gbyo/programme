import CloudKit
import Foundation
import OSLog
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

    /// Resolution order: stored user value wins, otherwise the managed
    /// suggestion is a temporary fallback, otherwise the Programme default.
    /// A managed suggestion is never written through — it is re-derived
    /// from the live MDM configuration on every load.
    typealias LoadedDefaults = (
        profileID: String, rulesName: String, tracking: OpponentTrackingMode
    )

    static func load(
        teamID: TeamID, managed: ManagedProgrammeConfiguration = .unmanaged
    ) -> LoadedDefaults {
        let defaults = UserDefaults.standard
        let profile =
            defaults.string(forKey: key("statProfile", teamID: teamID))
            ?? StatProfile.maxPreps.id
        let rules =
            defaults.string(forKey: key("rulesPreset", teamID: teamID))
            ?? managed.defaultRulesName
            ?? MatchRules.highSchool.name
        let trackingRaw = defaults.string(forKey: key("opponentTracking", teamID: teamID))
        let tracking =
            trackingRaw.flatMap(OpponentTrackingMode.init(rawValue:))
            ?? managed.defaultTrackingMode
            ?? .ourTeam
        return (profile, rules, tracking)
    }

    /// Persists explicit user choices only. A field is stored whenever it
    /// differs from what was loaded: untouched fallbacks (managed or
    /// Programme defaults) compare equal and are never written, while a
    /// user picking the managed value is a real override and is stored.
    /// Callers pass back the snapshot they loaded alongside the current
    /// values, and advance it after saving (see SettingsView).
    static func save(
        teamID: TeamID,
        profileID: String,
        rulesName: String,
        tracking: OpponentTrackingMode,
        loaded: LoadedDefaults
    ) {
        let defaults = UserDefaults.standard
        if profileID != loaded.profileID {
            defaults.set(profileID, forKey: key("statProfile", teamID: teamID))
        }
        if rulesName != loaded.rulesName {
            defaults.set(rulesName, forKey: key("rulesPreset", teamID: teamID))
        }
        if tracking != loaded.tracking {
            defaults.set(tracking.rawValue, forKey: key("opponentTracking", teamID: teamID))
        }
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

    static let selectedTeamKey = "programme.selectedTeamID"
    /// True when the stored selection came from an explicit user choice
    /// (tapping a team, creating one). An automatic fallback or MDM
    /// suggestion persists its team ID with this false, so a later MDM
    /// suggestion can still apply while a real user choice always wins.
    static let explicitSelectionKey = "programme.selectedTeamID.userChosen"

    var selectedTeam: TeamListItem? {
        guard let selectedTeamID else { return nil }
        return teams.first { $0.id == selectedTeamID }
    }

    var hasTeam: Bool { selectedTeamID != nil }

    /// The stored selection, but only when a user explicitly chose it.
    /// Automatic fallbacks and applied MDM suggestions never count, so a
    /// device with no real user selection stays eligible for suggestions.
    static func restoredExplicitSelection(from teams: [TeamListItem]) -> TeamID? {
        guard UserDefaults.standard.bool(forKey: explicitSelectionKey) else { return nil }
        guard
            let raw = UserDefaults.standard.string(forKey: selectedTeamKey),
            let uuid = UUID(uuidString: raw)
        else { return nil }
        let id = TeamID(uuid)
        return teams.contains(where: { $0.id == id }) ? id : nil
    }

    /// Whether `teamID` is the explicitly user-chosen selection.
    static func isExplicitSelection(_ teamID: TeamID) -> Bool {
        guard UserDefaults.standard.bool(forKey: explicitSelectionKey) else { return false }
        let raw = UserDefaults.standard.string(forKey: selectedTeamKey)
        return raw == teamID.rawValue.uuidString
    }

    /// One-time upgrade for selections stored before provenance tracking
    /// existed: an ID with no flag. Only explicit paths persisted then, so
    /// the stored selection is marked explicit rather than left eligible
    /// for replacement by a later MDM suggestion. Fresh installs (no
    /// stored ID) and already-migrated devices are untouched.
    static func migrateSelectionProvenance() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: explicitSelectionKey) == nil,
            defaults.string(forKey: selectedTeamKey) != nil
        else { return }
        defaults.set(true, forKey: explicitSelectionKey)
    }

    func persistSelection(explicit: Bool) {
        if let selectedTeamID {
            UserDefaults.standard.set(
                selectedTeamID.rawValue.uuidString, forKey: Self.selectedTeamKey)
            UserDefaults.standard.set(explicit, forKey: Self.explicitSelectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedTeamKey)
            UserDefaults.standard.removeObject(forKey: Self.explicitSelectionKey)
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
    private static let launchLog = Logger(subsystem: "com.gbyo.programme", category: "launch")
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
    /// Backstop revision for store activity the typed mutations cannot
    /// describe: derived-cache writes, reminder preferences, and any
    /// out-of-band edit. Bumped at most once per burst by the debounced
    /// history observer, never per write. Views combine this with their
    /// team/season ids and their scope counter in `.task(id:)`.
    var storeRevision = 0
    /// Per-scope revision counters. Ignored by observation itself: views
    /// track only the returned scope's counter through `scopeRevision(_:)`,
    /// so a Team B roster write never refetches Team A's screens.
    @ObservationIgnored
    private var scopeRevisions: [InvalidationScope: ScopeRevision] = [:]
    /// Side-work coalescing. Widget and Spotlight refreshes are glanceable,
    /// not interactive: the first request runs at once, bursts collapse into
    /// one trailing refresh, and backgrounding flushes anything pending.
    private var lastWidgetRefresh = Date.distantPast
    private var pendingWidgetTask: Task<Void, Never>?
    private var lastSpotlightReindex = Date.distantPast
    private var pendingSpotlightTask: Task<Void, Never>?
    private var pendingExternalNote: Task<Void, Never>?
    private static let widgetCoalesceInterval: TimeInterval = 1.5
    private static let spotlightCoalesceInterval: TimeInterval = 4
    private static let externalCoalesceInterval: TimeInterval = 1
    /// Set once at launch; used by App Intents, Spotlight and Shortcuts.
    var intentProvider: ProgrammeIntentProvider?
    private let storeObserver = StoreChangeObserver()
    /// Device-local kickoff reminders. Permission is requested only from the
    /// explicit Remind Me action, never at launch.
    let reminderCenter = MatchReminderCenter()
    /// Read-only Watch companion bridge. Activated at bootstrap; pushes
    /// glanceable snapshots where the widget snapshot already refreshes.
    let watchBridge = WatchBridge()
    /// Optional MDM-delivered suggestions and policy. Unmanaged devices
    /// rest at `.unmanaged`: no suggestions, everything allowed.
    let managed = ManagedConfigurationService()
    /// Real CloudKit account state from `accountStatus()`, observed for
    /// runtime changes. Starts unknown; launch and scoring never wait on it.
    let cloudAccount = CloudKitAccountMonitor()
    /// Nearby read-only scoreboard. Lives for the app lifetime so the
    /// scoreboard window can display while no local session exists.
    let nearby = NearbyScoreboardService()

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
            makeContainer: {
                CKContainer(identifier: CollaborationEnvironment.containerIdentifier)
            }, sharedZones: try SharedZoneStore(url: url))
        shareCoordinator = coordinator
        return coordinator
    }

    /// Resolves the SwiftUI share item for a team. Pre-resolves the live
    /// zone-wide share when one exists so the system presents it directly
    /// (`.existing`); otherwise the item's prepare handler creates and saves
    /// it on demand. Throws a human-readable error when iCloud is
    /// unavailable or the library is not ready.
    /// Whether this device owns the team (private database, may invite and
    /// manage) or participates in someone else's share (shared database,
    /// system UI only). Resolved from the shared-zone owner list the sync
    /// layer already tracks — never by guessing, and never by treating a
    /// team as unshared merely because its share isn't in our private
    /// database.
    func shareScope(teamID: TeamID) async -> TeamShareScope {
        guard let service = try? syncing() else { return .owned }
        let owners = await service.sharedZoneOwners()
        guard let owner = owners[teamID] else { return .owned }
        return .shared(ownerName: owner)
    }

    func teamShareItem(teamID: TeamID) async throws -> TeamShareItem {
        // Looking up an existing share stays available under any policy so
        // owners can revoke (and participants can leave) through the system
        // UI when collaboration is disabled. Creating a new share is gated
        // separately in the prepare handler below. Private same-user
        // CloudKit sync is unaffected — see docs/MANAGED_CONFIGURATION.md.
        guard cloudAccount.state.isUsable else { throw TeamShareError.iCloudUnavailable }
        guard let store else { throw TeamShareError.noLibrary }
        let details = try await store.teamDetails(teamID: teamID)
        let coordinator = try sharing()
        let scope = await shareScope(teamID: teamID)
        let prepared: CKShare?
        switch await coordinator.lookupShare(teamID: teamID, scope: scope) {
        case .shared(let share):
            prepared = share
        case .notShared:
            prepared = nil
        case .unavailable:
            // A failed lookup is not proof the team is unshared: surface a
            // retryable error instead of a "Share Team…" button.
            throw TeamShareError.shareLookupFailed
        }
        return TeamShareItem(
            teamID: teamID, teamName: details.name, prepared: prepared,
            scope: scope, coordinator: coordinator,
            creationAllowed: managed.configuration.isCollaborationAllowed
        ) {
            CKContainer(identifier: CollaborationEnvironment.containerIdentifier)
        }
    }

    /// Who currently has access to a shared team. Empty when the team is
    /// not shared. Display only — edits happen in the system share sheet.
    func teamParticipants(teamID: TeamID) async -> [ShareParticipant] {
        guard let coordinator = try? sharing() else { return [] }
        return await coordinator.participants(teamID: teamID, scope: shareScope(teamID: teamID))
    }

    /// Revokes the team's share for everyone. Local truth is untouched.
    func stopSharing(teamID: TeamID) async throws {
        try await sharing().stopSharing(teamID: teamID)
    }

    /// Unresolved sync contradictions for a team with their match names.
    /// Empty when nothing needs review — the common case, and the only
    /// state this surface adds.
    func syncConflicts(teamID: TeamID) async -> [(conflict: TeamConflict, matchName: String)] {
        guard let service = try? syncing(), let store else { return [] }
        let conflicts = await service.unresolvedConflicts(teamID: teamID)
        guard !conflicts.isEmpty else { return [] }
        let names = Dictionary(
            uniqueKeysWithValues: ((try? await store.matches(teamID: teamID)) ?? []).map {
                ($0.id, $0.opponentName)
            })
        return conflicts.map { ($0, names[$0.matchID] ?? "A match") }
    }

    /// Keeps the local version of a conflicted event. Never rewrites
    /// history: the entry simply clears.
    func resolveConflict(_ conflict: TeamConflict) async {
        if let service = try? syncing() {
            try? await service.resolveConflict(eventID: conflict.eventID, inTeam: conflict.teamID)
        }
    }

    /// Concise sync state for team detail. Review comes first (actionable),
    /// then availability, then engine status. Every state leaves local
    /// scoring and recovery authoritative.
    func syncState(teamID: TeamID) async -> TeamSyncState {
        let reviewCount = await syncConflicts(teamID: teamID).count
        if reviewCount > 0 { return .needsReview(reviewCount) }
        switch cloudAccount.state {
        case .available:
            break
        case .unknown:
            // Account state not yet resolved: frame as local-safe offline,
            // never as proof iCloud is missing.
            return .offline
        case .noAccount, .restricted, .temporarilyUnavailable:
            return .unavailable
        }
        guard let service = try? syncing() else { return .offline }
        switch await service.engineStatus() {
        case .idle: return .synced
        case .syncing: return .syncing
        case .unavailable, .attentionNeeded: return .offline
        }
    }

    /// Accepts an invitation, then reloads the workspace. Nothing
    /// materializes here: shared content still lands through the applier, so
    /// review-gating applies unchanged.
    func acceptShare(_ metadata: CKShare.Metadata) async {
        // Invitations are refused while collaboration is disabled. The
        // metadata is dropped but the invitation itself stays valid in
        // CloudKit, so it can be accepted after the policy lifts. Local
        // data is untouched either way.
        guard managed.configuration.isCollaborationAllowed else { return }
        if cloudAccount.state.isUsable, let service = try? syncing() {
            try? await service.accept(metadata)
        } else if let coordinator = try? sharing() {
            try? await coordinator.accept(metadata)
        }
        // Reload-only: keep the current selection with its provenance
        // intact rather than re-marking it explicit (see reloadWorkspace).
        await reloadWorkspace()
        await startSyncIfAvailable()
    }

    // MARK: - Sync engine

    /// Built lazily for the same reason as the share coordinator: launch
    /// paths that never sync (previews, intent tests, iCloud-off devices)
    /// never construct it.
    private var syncService: TeamSyncService?

    private func syncing() throws -> TeamSyncService {
        if let syncService { return syncService }
        guard let store else { throw TeamShareError.noLibrary }
        let url = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        .appending(path: "Programme/Sync")
        let service = try TeamSyncService(store: store, directory: url) {
            CKContainer(identifier: CollaborationEnvironment.containerIdentifier)
        }
        syncService = service
        return service
    }

    /// Starts CloudKit replication when iCloud is available. Local scoring
    /// never waits on this: the service is inert until started, and every
    /// sync failure leaves local truth untouched.
    func startSyncIfAvailable() async {
        guard cloudAccount.state.isUsable else { return }
        guard let service = try? syncing() else { return }
        await store?.setMutationHandler { [weak self] mutation in
            Task { await self?.stageForSync(mutation) }
        }
        await service.setWorkspaceChangedHandler { [weak self] in
            // Reload-only: preserve the selection's provenance so an
            // automatic fallback stays eligible for MDM suggestions.
            Task { await self?.reloadWorkspace() }
        }
        await service.start()
    }

    private func stageForSync(_ mutation: OutboundMutation) async {
        await syncService?.stage(mutation)
    }

    /// If the on-disk store cannot be opened at all, the app still launches into
    /// an in-memory one so it can explain what happened instead of crashing.
    private static func fallbackContainer() -> ModelContainer? {
        do {
            return try ProgrammeStore.container(inMemory: true)
        } catch {
            // Same stderr trail as the launch path above: without it the
            // fatalError below is the only evidence and the cause is lost.
            Self.launchLog.error("Could not create fallback store: \(error, privacy: .public)")
            return nil
        }
    }

    var containerForScene: ModelContainer {
        container ?? Self.fallbackContainer()
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
                do {
                    try ProgrammeStore.seedSampleData(
                        into: container.mainContext, includeLiveMatch: launchOptions.opensLiveMatch)
                } catch {
                    // A silent skip lands on first-run onboarding with no
                    // explanation; the unified log keeps the cause instead.
                    Self.launchLog.error("Could not seed sample data: \(error, privacy: .public)")
                }
            }
        } catch {
            // The unified log keeps the underlying store error for a launch
            // failure in the field or under XCTest.
            Self.launchLog.error("Could not open library: \(error, privacy: .public)")
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

    /// Builds the glanceable Watch snapshot from the same values the
    /// widget snapshot uses, then pushes it over WatchConnectivity
    /// application context. No per-second streaming: the Watch renders
    /// its clock locally from the anchor.
    private func pushWatchSnapshot(
        teamID: TeamID, teamName: String, teamShort: String, recordText: String,
        matches: [MatchListItem], reviewCount: Int
    ) {
        let refs = matches.map {
            WatchMatchRef(
                id: $0.id, opponentShortName: $0.opponentName,
                venueLabel: $0.venue.shortLabel, kickoff: $0.kickoff, phase: $0.phase,
                resultLetter: $0.result?.letter ?? "", scoreUs: $0.score.us,
                scoreOpponent: $0.score.opponent)
        }
        let (upcoming, recent) = WatchSelection.select(from: refs)
        let live: WatchSnapshot.Live? = liveSession.map { session in
            WatchSnapshot.Live(
                matchID: session.matchID,
                teamShortName: session.descriptor.teamShortName,
                opponentShortName: session.descriptor.opponentShortName,
                scoreUs: session.snapshot.score.us, scoreOpponent: session.snapshot.score.opponent,
                clock: session.context.clock, rules: session.context.rules,
                phase: session.context.phase,
                needsReviewCount: session.snapshot.needsReviewCount,
                lastEventText: session.lastEventDescription?.oneLine)
        }
        watchBridge.push(
            WatchSnapshot(
                teamName: teamName, teamShortName: teamShort, recordText: recordText,
                live: live, upcoming: upcoming, recent: recent, reviewCount: reviewCount))
    }

    func bootstrap() async {
        guard !isReady else { return }
        defer { isReady = true }
        guard let container, let store else { return }
        // Pre-provenance selections were always user choices; mark them
        // before any reload can treat them as automatic fallbacks.
        TeamWorkspace.migrateSelectionProvenance()
        // Observation starts fire-and-forget: awaiting the first managed
        // value here stalled launch outright wherever the system
        // configuration sequence never yields (seen on the iOS 27
        // simulator despite the documented immediate first value). The
        // first automatic selection uses the plain fallback, and a managed
        // suggestion still applies on arrival through
        // managedConfigurationChanged, which only ever replaces
        // non-explicit selections — never a user choice.
        managed.start()
        // Apply later MDM suggestions only while the device still has no
        // explicit user selection. Never resets navigation or seasons, and
        // never overrides a user choice.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .managedConfigurationChanged)
            {
                await self?.applyManagedSuggestionIfNeeded()
            }
        }
        // CloudKit account state resolves in the background; launch and
        // scoring never wait on it. When the account becomes usable —
        // after the first check or a later sign-in — replication starts;
        // bootstrap's own startSyncIfAvailable call below covers the
        // already-available case.
        cloudAccount.onBecameAvailable = { [weak self] in
            Task { [weak self] in await self?.startSyncIfAvailable() }
        }
        cloudAccount.start()
        // Invitations that launched the app before the acceptance closure
        // was installed are drained here, exactly once.
        for metadata in ShareAcceptanceDelegate.drainPending() {
            await acceptShare(metadata)
        }

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
        await startSyncIfAvailable()
        if launchOptions.opensLiveMatch {
            let items = (try? await store.matches(limit: 60)) ?? []
            if let live = items.first(where: \.isInterrupted) {
                await openLiveSession(matchID: live.id)
            }
        }
        await refreshRecoveryCandidates()
        await refreshWidgetSnapshot()

        await store.setInvalidationHandler { [weak self] mutation in
            Task { await self?.handleStoreMutation(mutation) }
        }
        storeObserver.start(container: container) { [weak self] in
            self?.noteStoreActivity()
        }
    }

    /// Cached counter for a scope. A method rather than a subscript so view
    /// bodies track only the returned scope's counter, never the registry.
    func scopeRevision(_ scope: InvalidationScope) -> ScopeRevision {
        if let existing = scopeRevisions[scope] { return existing }
        let created = ScopeRevision()
        scopeRevisions[scope] = created
        return created
    }

    /// Fans a persisted mutation out to exactly the surfaces it affects.
    /// Runs for local edits, second-window writes, archive imports, and
    /// synced remote applies alike — every path reports through the store's
    /// single funnel. Match-scoped mutations resolve their team first so a
    /// Team B event never touches Team A's counters.
    private func handleStoreMutation(_ mutation: OutboundMutation) async {
        guard let store else { return }
        let teamID: TeamID?
        let matchID: MatchID?
        switch mutation {
        case .team(let id):
            (teamID, matchID) = (id, nil)
        case .season(let id, _):
            (teamID, matchID) = (id, nil)
            if workspace.selectedTeamID == id {
                workspace.currentSeasonID = try? await store.currentSeasonID(teamID: id)
            }
        case .players(let id, _), .deletedPlayers(let id, _), .deletedMatch(_, let id, _):
            (teamID, matchID) = (id, nil)
        case .match(let id), .events(let id, _):
            (teamID, matchID) = (try? await store.teamID(forMatch: id), id)
        }
        let impact = StoreInvalidation.impact(of: mutation, teamID: teamID)
        for scope in impact.scopes { scopeRevision(scope).count += 1 }
        let selectedAffected = workspace.selectedTeamID.map(impact.widgetTeamIDs.contains) ?? false
        if selectedAffected || (matchID != nil && matchID == liveSession?.matchID) {
            requestWidgetRefresh()
        }
        if impact.refreshSpotlight { requestSpotlightReindex() }
        if impact.refreshRecovery {
            Task { await refreshRecoveryCandidates() }
        }
    }

    /// StoreChangeObserver filters out authored typed MatchStore saves before
    /// reaching this backstop. External or unattributed history activity still
    /// collapses into one delayed pass so out-of-band edits cannot leave
    /// derived surfaces stale.
    private func noteStoreActivity() {
        pendingExternalNote?.cancel()
        pendingExternalNote = Task {
            try? await Task.sleep(for: .milliseconds(Int(Self.externalCoalesceInterval * 1000)))
            guard !Task.isCancelled else { return }
            noteStoreChanged()
            requestWidgetRefresh()
            requestSpotlightReindex()
            await refreshRecoveryCandidates()
        }
    }

    private func requestWidgetRefresh() {
        let now = Date()
        guard now.timeIntervalSince(lastWidgetRefresh) < Self.widgetCoalesceInterval else {
            lastWidgetRefresh = now
            Task { await refreshWidgetSnapshot() }
            return
        }
        guard pendingWidgetTask == nil else { return }
        pendingWidgetTask = Task {
            try? await Task.sleep(for: .milliseconds(Int(Self.widgetCoalesceInterval * 1000)))
            guard !Task.isCancelled else { return }
            pendingWidgetTask = nil
            lastWidgetRefresh = Date()
            await refreshWidgetSnapshot()
        }
    }

    private func requestSpotlightReindex() {
        let now = Date()
        guard now.timeIntervalSince(lastSpotlightReindex) < Self.spotlightCoalesceInterval
        else {
            lastSpotlightReindex = now
            Task { [weak self] in await self?.intentProvider?.reindexSpotlight() }
            return
        }
        guard pendingSpotlightTask == nil else { return }
        pendingSpotlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.spotlightCoalesceInterval * 1000)))
            guard !Task.isCancelled else { return }
            self?.pendingSpotlightTask = nil
            self?.lastSpotlightReindex = Date()
            await self?.intentProvider?.reindexSpotlight()
        }
    }

    /// Trailing refreshes may never fire once suspended; run anything owed
    /// before backgrounding so the widget and index never go stale silently.
    private func flushPendingSideWork() {
        if pendingExternalNote != nil {
            noteStoreChanged()
            requestWidgetRefresh()
            requestSpotlightReindex()
            Task { await refreshRecoveryCandidates() }
            pendingExternalNote?.cancel()
            pendingExternalNote = nil
        }
        if pendingWidgetTask != nil {
            pendingWidgetTask?.cancel()
            pendingWidgetTask = nil
            Task { await refreshWidgetSnapshot() }
        }
        if pendingSpotlightTask != nil {
            pendingSpotlightTask?.cancel()
            pendingSpotlightTask = nil
            Task { [weak self] in await self?.intentProvider?.reindexSpotlight() }
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
            workspace.persistSelection(explicit: false)
            return
        }
        let restored: TeamID?
        let explicit: Bool
        if let preferred, teams.contains(where: { $0.id == preferred }) {
            // Created or explicitly passed in: a real user choice.
            restored = preferred
            explicit = true
        } else if let current = workspace.selectedTeamID,
            teams.contains(where: { $0.id == current })
        {
            // Keep the current selection with its provenance intact. An
            // automatic fallback stays automatic so a later MDM suggestion
            // can still apply; an explicit choice stays explicit.
            restored = current
            explicit = TeamWorkspace.isExplicitSelection(current)
        } else {
            // An MDM suggestion only fills in for a device with no explicit
            // user selection; it never overrides one. The plain first-team
            // fallback is automatic too, never persisted as a user choice.
            let ids = teams.map(\.id)
            let stored = TeamWorkspace.restoredExplicitSelection(from: teams)
            restored =
                stored ?? managed.configuration.suggestedTeam(from: ids) ?? teams.first?.id
            explicit = stored != nil
        }
        workspace.selectedTeamID = restored
        workspace.persistSelection(explicit: explicit)
        if let selected = restored {
            workspace.currentSeasonID = try? await store.currentSeasonID(teamID: selected)
            workspace.viewedStatsSeasonID = workspace.currentSeasonID
        }
        navigation.section = .home
        navigation.clearTeamScopedPaths()
        await refreshWidgetSnapshot()
    }

    /// Applies a newly arrived MDM team suggestion, but only while the
    /// device still has no explicit user selection. Deliberately narrow:
    /// no team-list refetch, no navigation reset, no season changes beyond
    /// resolving the newly suggested team's current season. A user choice
    /// always wins and is never disturbed.
    func applyManagedSuggestionIfNeeded() async {
        guard let store else { return }
        guard TeamWorkspace.restoredExplicitSelection(from: workspace.teams) == nil else {
            return
        }
        let ids = workspace.teams.map(\.id)
        guard let suggestion = managed.configuration.suggestedTeam(from: ids),
            suggestion != workspace.selectedTeamID
        else { return }
        workspace.selectedTeamID = suggestion
        workspace.persistSelection(explicit: false)
        workspace.currentSeasonID = try? await store.currentSeasonID(teamID: suggestion)
        workspace.viewedStatsSeasonID = workspace.currentSeasonID
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
        workspace.persistSelection(explicit: true)
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
        case .review(let id):
            if let owner = try? await store.teamID(forMatch: id) {
                await ensureTeamSelected(owner)
            }
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
        case "review":
            guard let identifier, let uuid = UUID(uuidString: identifier) else { return false }
            await open(.review(MatchID(uuid)))
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
        nearby.stopAdvertising()
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
        if phase == .background {
            flushPendingSideWork()
            MaintenanceScheduler.scheduleIfNeeded()
        }
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

        // Team-wide review count: live-match attribution items plus every
        // unresolved sync contradiction on the team. Cheap here — conflicts
        // are local records and the live count is already derived.
        let reviewCount =
            (liveSession?.snapshot.needsReviewCount ?? 0)
            + (await syncConflicts(teamID: selectedTeamID).count)
        pushWatchSnapshot(
            teamID: selectedTeamID, teamName: teamName, teamShort: teamShort,
            recordText: season?.recordText ?? "0-0-0", matches: matches,
            reviewCount: reviewCount)

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
