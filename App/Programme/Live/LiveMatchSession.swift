import Foundation
import Observation
import ProgrammeCore
import ProgrammePersistence
import ProgrammeUI
import SwiftUI
import TipKit

#if os(iOS)
    import ActivityKit
#endif

/// The one coherent state holder for an active match.
///
/// Recording an event is synchronous and in memory, so the interface updates in
/// the same frame as the tap. Durability happens immediately afterwards: the
/// write-ahead journal is appended and flushed before the method returns, and the
/// SwiftData write is queued behind it in order. A scorer never waits on a disk
/// write, and never loses one either.
@MainActor
@Observable
final class LiveMatchSession {
    let matchID: MatchID
    private(set) var context: MatchContext
    private(set) var snapshot: MatchSnapshot
    private(set) var issues: [ValidationIssue]
    private(set) var lastEventDescription: EventDescription?

    /// Separate object on purpose — see `MatchClockModel`.
    let clock = MatchClockModel()

    /// The player armed for the next action. Tapping a player then an action, or
    /// an action then a player, both work; this is the first half of the former.
    var armedPlayer: PlayerID?

    /// An action requested from outside the scoring workspace — the keyboard
    /// menu in `ProgrammeCommands`. The workspace observes it and runs it through
    /// exactly the same path as a tap, so there is one implementation of what a
    /// goal means.
    var requestedAction: LiveActionRequest?

    /// A short, non-modal message shown in the scoring bar. Live play is never
    /// interrupted by an alert.
    private(set) var notice: LiveNotice?

    @ObservationIgnored private let store: MatchStore
    @ObservationIgnored private let journal: RecoveryJournal
    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var writeQueue: [MatchEffect] = []
    @ObservationIgnored private var writerTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivityUpdate = Date.distantPast

    #if os(iOS)
        @ObservationIgnored private var activity: Activity<MatchActivityAttributes>?
    #endif

    init(context: MatchContext, store: MatchStore, journal: RecoveryJournal, appModel: AppModel?) {
        self.matchID = context.descriptor.id
        self.context = context
        self.store = store
        self.journal = journal
        self.appModel = appModel
        self.snapshot = StatEngine.snapshot(context: context)
        self.issues = []
        self.issues = ValidationEngine.issues(context: context, snapshot: snapshot)
        self.lastEventDescription = Self.describeLastMeaningfulEvent(in: context)
        clock.configure(anchor: context.clock, rules: context.rules)
        try? journal.open(
            matchID: matchID, descriptor: context.descriptor, roster: context.roster,
            opponentRoster: context.opponentRoster)
        Haptics.prepare()
    }

    // MARK: - Derived conveniences

    var descriptor: MatchDescriptor { context.descriptor }
    var rules: MatchRules { context.rules }
    var profile: StatProfile { context.profile }
    var roster: RosterSnapshot { context.roster }
    var phase: MatchPhase { context.phase }

    var onFieldPlayers: [PlayerSnapshot] {
        let active = snapshot.activeLineup
        return roster.sortedByNumber.filter { active.contains($0.id) }
    }

    var benchPlayers: [PlayerSnapshot] {
        let active = snapshot.activeLineup
        let dismissed = Set(
            snapshot.players.filter { $0.value.redCards > 0 }.keys)
        return roster.activeRoster.filter { !active.contains($0.id) && !dismissed.contains($0.id) }
    }

    var dismissedPlayers: [PlayerSnapshot] {
        roster.activeRoster.filter { (snapshot.players[$0.id]?.redCards ?? 0) > 0 }
    }

    var goalkeeper: PlayerSnapshot? {
        snapshot.activeGoalkeeper.flatMap { roster[$0] }
    }

    /// The armed player, resolved. `nil` whenever nothing is armed.
    var armedPlayerSnapshot: PlayerSnapshot? {
        armedPlayer.flatMap { roster[$0] }
    }

    /// Who this category of event may be attributed to. ProgrammeCore owns the
    /// rule; the interface only asks.
    func candidates(for category: AttributionCategory, side: TeamSide = .us) -> [PlayerSnapshot] {
        AttributionEngine.candidates(
            for: category, side: side, context: context, snapshot: snapshot)
    }

    func allowsAttribution(of player: PlayerID, to category: AttributionCategory) -> Bool {
        AttributionEngine.allows(player, category: category, context: context, snapshot: snapshot)
    }

    /// Whether tapping this player in the lineup should arm them for the next
    /// action. Only players on the field can be armed: the generic player-first
    /// path is for live play, and a substitute did not take that shot. Cards and
    /// substitutions reach the bench through their own routes.
    func canArm(_ player: PlayerSnapshot) -> Bool {
        allowsAttribution(of: player.id, to: .shot)
    }

    /// Educational UI is for a scorer who is not currently executing. While the
    /// clock is running, nothing teaches.
    var showsContextualTips: Bool {
        !(phase == .inPeriod && clock.isRunning)
    }

    var needsReviewCount: Int { snapshot.needsReviewCount }

    var reviewItems: [ValidationIssue] { issues.needingReview }

    var canUndo: Bool { MatchEngine.undoTarget(context) != nil }
    var canRedo: Bool { MatchEngine.redoTarget(context) != nil }

    var canStartNextPeriod: Bool {
        guard context.phase == .scheduled || context.phase == .periodBreak else { return false }
        let next = (context.startedPeriods.max() ?? 0) + 1
        return rules.period(at: next) != nil
    }

    var nextPeriodLabel: String {
        let next = (context.startedPeriods.max() ?? 0) + 1
        return rules.period(at: next)?.longLabel ?? "Next Period"
    }

    var hasStartingLineup: Bool {
        context.activeEvents.contains {
            if case .lineupSet = $0.payload { return true } else { return false }
        }
    }

    /// Shots with a recorded location, for the pitch.
    var shotMarkers: [ShotMarker] {
        context.activeEvents.compactMap { event in
            guard case .shot(let shot) = event.payload, let location = shot.location else { return nil }
            return ShotMarker(
                id: event.id,
                point: location,
                outcome: shot.outcome,
                side: shot.side,
                label: MatchNarrator.describe(event, context: context).oneLine)
        }
    }

    // MARK: - Commands

    @discardableResult
    func run(_ command: MatchCommand, feedback: Feedback = .standard) -> Bool {
        do {
            let effects = try MatchEngine.perform(command, on: context, at: Date())
            commit(effects)
            switch feedback {
            case .standard: Haptics.recorded()
            case .goal: Haptics.goal()
            case .silent: break
            }
            return true
        } catch {
            present(error: error)
            return false
        }
    }

    @discardableResult
    func edit(_ command: EventEditCommand, message: String? = nil) -> Bool {
        do {
            let effects = try MatchEngine.perform(command, on: context, at: Date())
            commit(effects)
            Haptics.selectionChanged()
            if let message { show(notice: LiveNotice(text: message, kind: .confirmation)) }
            return true
        } catch {
            present(error: error)
            return false
        }
    }

    func undo() {
        do {
            let target = MatchEngine.undoTarget(context)
            let description = target.map { MatchNarrator.describe($0, context: context) }
            let effects = try MatchEngine.undo(context, at: Date())
            commit(effects)
            Haptics.undone()
            Task { await CorrectEventTimeTip.didUndo.donate() }
            show(
                notice: LiveNotice(
                    text: "Undid \(description?.title ?? "last event")", kind: .undo))
        } catch {
            present(error: error)
        }
    }

    func redo() {
        do {
            let effects = try MatchEngine.redo(context, at: Date())
            commit(effects)
            Haptics.recorded()
            show(notice: LiveNotice(text: "Redone", kind: .confirmation))
        } catch {
            present(error: error)
        }
    }

    // MARK: - High level actions

    /// A goal, recorded as one event that already implies a shot and a shot on goal.
    func recordGoal(
        scorer: PlayerRef, assist: PlayerRef?, phase: PlayPhase = .openPlay,
        location: PitchPoint? = nil, isOwnGoal: Bool = false, side: TeamSide = .us
    ) {
        let shot = ShotEvent(
            side: side, shooter: scorer, outcome: .goal, assist: assist, location: location,
            phase: phase, isOwnGoal: isOwnGoal)
        run(.recordShot(shot), feedback: .goal)
    }

    func recordShot(
        _ outcome: ShotOutcome, by shooter: PlayerRef, side: TeamSide = .us,
        phase: PlayPhase = .openPlay, location: PitchPoint? = nil
    ) {
        run(
            .recordShot(
                ShotEvent(
                    side: side, shooter: shooter, outcome: outcome, location: location, phase: phase)))
    }

    /// Our goalkeeper saves an opponent shot. One event: the opponent's shot on
    /// goal and our save are the same fact.
    func recordSave(phase: PlayPhase = .openPlay) {
        run(.recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved, phase: phase)))
    }

    func setStartingLineup(_ players: [PlayerID], goalkeeper: PlayerID?, formationID: String? = nil) {
        run(
            .setLineup(
                LineupEvent(
                    side: .us, onField: players, goalkeeper: goalkeeper, formationID: formationID)),
            feedback: .silent)
    }

    func substitute(out: [PlayerID], in playersIn: [PlayerID], goalkeeperAfter: PlayerID?) {
        run(
            .substitute(
                SubstitutionEvent(
                    side: .us, playersOut: out, playersIn: playersIn, goalkeeperAfter: goalkeeperAfter)))
    }

    func startNextPeriod() {
        run(.startNextPeriod, feedback: .silent)
        startOrUpdateActivity()
    }

    func endCurrentPeriod() {
        run(.endCurrentPeriod, feedback: .silent)
    }

    func toggleClock() {
        run(clock.isRunning ? .stopClock : .startClock, feedback: .silent)
    }

    func adjustClock(toSeconds seconds: Int, reason: String?) {
        run(.adjustClock(toSeconds: seconds, reason: reason), feedback: .silent)
    }

    func finalize() {
        run(.finalize, feedback: .silent)
        endActivity()
        try? journal.close(matchID: matchID)
        Task { await appModel?.refreshWidgetSnapshot() }
    }

    func reopen() {
        run(.reopen, feedback: .silent)
    }

    /// Replace the opponent roster. Only meaningful in `Both Teams` mode, where
    /// the opponent's players are attributed individually.
    func updateOpponentRoster(_ roster: RosterSnapshot) {
        context.opponentRoster = roster
        let matchID = self.matchID
        let ourRoster = context.roster
        Task { [store] in
            try? await store.updateMatchRoster(
                matchID: matchID, roster: ourRoster, opponentRoster: roster)
        }
        refreshDerivedState()
    }

    /// Resolve an event that was recorded without a jersey number.
    func attribute(eventID: EventID, slot: AttributionSlot, to ref: PlayerRef) {
        let label = context.roster.label(for: ref)
        edit(.attribute(eventID, slot, ref), message: "Attributed to \(label)")
    }

    // MARK: - Commit pipeline

    private func commit(_ effects: [MatchEffect]) {
        MatchEngine.apply(effects, to: &context)

        // Durability first: an append plus flush costs far less than a frame,
        // and it is what makes an interrupted match recoverable.
        do {
            try journal.append(effects, for: matchID)
        } catch {
            show(
                notice: LiveNotice(
                    text: "Programme couldn't write its backup log. Your match is still being saved.",
                    kind: .warning))
        }

        enqueueStoreWrite(effects)
        refreshDerivedState()
    }

    private func refreshDerivedState() {
        snapshot = StatEngine.snapshot(context: context, at: Date())
        issues = ValidationEngine.issues(context: context, snapshot: snapshot)
        lastEventDescription = Self.describeLastMeaningfulEvent(in: context)
        clock.configure(anchor: context.clock, rules: context.rules)
        startOrUpdateActivity()
    }

    private func enqueueStoreWrite(_ effects: [MatchEffect]) {
        writeQueue.append(contentsOf: effects)
        guard writerTask == nil else { return }
        writerTask = Task { [weak self] in
            while true {
                guard let self else { return }
                let batch = self.drainWriteQueue()
                if batch.isEmpty { break }
                do {
                    try await self.store.apply(batch, to: self.matchID)
                } catch {
                    // The journal already holds these events, so nothing is lost.
                    // Put them back and stop, rather than spinning on a failure
                    // that is not going to clear by itself. The next commit, or
                    // `flush()`, retries them.
                    self.writeQueue.insert(contentsOf: batch, at: 0)
                    break
                }
            }
            self?.writerTask = nil
        }
    }

    private func drainWriteQueue() -> [MatchEffect] {
        let batch = writeQueue
        writeQueue.removeAll(keepingCapacity: true)
        return batch
    }

    /// Make sure everything recorded has reached the database. Called when
    /// leaving the scorer and when the app is backgrounded.
    func flush() async {
        await writerTask?.value
        if !writeQueue.isEmpty {
            let batch = drainWriteQueue()
            try? await store.apply(batch, to: matchID)
        }
        try? await store.updateCache(matchID: matchID, from: snapshot)
    }

    // MARK: - Notices and errors

    private func present(error: any Error) {
        Haptics.rejected()
        if let commandError = error as? MatchCommandError {
            show(notice: LiveNotice(text: commandError.message, kind: .warning))
        } else {
            show(
                notice: LiveNotice(
                    text: "Programme couldn't record that. Your match is safe — try again.",
                    kind: .warning))
        }
    }

    func show(notice: LiveNotice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(notice.kind == .warning ? 5 : 3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    private static func describeLastMeaningfulEvent(in context: MatchContext) -> EventDescription? {
        let events = context.activeEvents
        guard
            let last = events.last(where: {
                switch $0.payload {
                case .note, .clockAdjusted: false
                default: true
                }
            })
        else { return nil }
        var score = SidePair(repeating: 0)
        for event in events {
            if case .shot(let shot) = event.payload, shot.outcome.isGoal {
                score[shot.scoringSide] += 1
            }
            if event.id == last.id { break }
        }
        return MatchNarrator.describe(last, context: context, scoreAfter: score)
    }

    // MARK: - Live Activity

    func startOrUpdateActivity() {
        #if os(iOS)
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            guard context.phase.isLive else {
                endActivity()
                return
            }
            let state = MatchActivityAttributes.ContentState.make(
                snapshot: snapshot, clock: context.clock, rules: rules,
                lastEventText: lastEventDescription?.oneLine)

            if let activity {
                // Throttle: the clock animates itself, so updates are only for
                // the score and the last event.
                guard Date().timeIntervalSince(lastActivityUpdate) > 1.5 else { return }
                lastActivityUpdate = Date()
                let box = ActivityBox(activity: activity)
                Task { await box.activity.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                let attributes = MatchActivityAttributes(
                    matchID: matchID.rawValue.uuidString,
                    teamName: descriptor.teamShortName,
                    opponentName: descriptor.opponentShortName,
                    venueLabel: descriptor.venue.label)
                activity = try? Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil)
                lastActivityUpdate = Date()
            }
        #endif
    }

    func endActivity() {
        #if os(iOS)
            guard let activity else { return }
            let final = MatchActivityAttributes.ContentState.make(
                snapshot: snapshot, clock: context.clock, rules: rules,
                lastEventText: lastEventDescription?.oneLine)
            let box = ActivityBox(activity: activity)
            Task {
                await box.activity.end(
                    ActivityContent(state: final, staleDate: nil), dismissalPolicy: .default)
            }
            self.activity = nil
        #endif
    }

    enum Feedback {
        case standard
        case goal
        case silent
    }
}

#if os(iOS)
    /// ActivityKit's `Activity` is a handle that is safe to use from any
    /// isolation, but it is not annotated `Sendable`. Wrapping it keeps the
    /// exception to one type instead of relaxing checking across the session.
    private struct ActivityBox<Attributes: ActivityAttributes>: @unchecked Sendable {
        let activity: Activity<Attributes>
    }
#endif

/// A live action asked for from the menu bar rather than from the palette.
/// Carrying an identity means asking for the same action twice in a row still
/// registers as two requests.
struct LiveActionRequest: Equatable, Identifiable {
    enum Kind: Equatable {
        case goal
        case shotOnGoal
        case shot
        case save
        case corner
        case substitution
    }

    let id = UUID()
    var kind: Kind

    static func == (lhs: LiveActionRequest, rhs: LiveActionRequest) -> Bool { lhs.id == rhs.id }
}

struct LiveNotice: Equatable, Identifiable {
    enum Kind: Equatable {
        case confirmation
        case undo
        case warning
    }

    let id = UUID()
    var text: String
    var kind: Kind

    static func == (lhs: LiveNotice, rhs: LiveNotice) -> Bool { lhs.id == rhs.id }
}
