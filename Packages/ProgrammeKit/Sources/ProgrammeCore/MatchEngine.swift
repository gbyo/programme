import Foundation

public enum MatchCommandError: Error, Hashable, Sendable {
    case matchFinalized
    case matchNotStarted
    case periodAlreadyRunning
    case noPeriodRunning
    case noPeriodsRemaining
    case unknownPlayer(PlayerID)
    case playerNotOnField(PlayerID)
    case playerAlreadyOnField(PlayerID)
    case tooManyPlayers(attempted: Int, maximum: Int)
    case lineupTooSmall(attempted: Int, minimum: Int)
    case duplicateInLineup(PlayerID)
    case goalkeeperNotInLineup(PlayerID)
    case shootoutNotAvailable
    case eventNotFound(EventID)
    case cannotEditStructuralEvent
    case nothingToUndo

    public var message: String {
        switch self {
        case .matchFinalized:
            "This match is finalized. Reopen it to make changes."
        case .matchNotStarted:
            "The match hasn't kicked off yet."
        case .periodAlreadyRunning:
            "A period is already underway."
        case .noPeriodRunning:
            "No period is running."
        case .noPeriodsRemaining:
            "Every period in this match format has been played."
        case .unknownPlayer:
            "That player isn't on the roster for this match."
        case .playerNotOnField:
            "That player isn't on the field."
        case .playerAlreadyOnField:
            "That player is already on the field."
        case .tooManyPlayers(let attempted, let maximum):
            "That would put \(attempted) players on the field. This format allows \(maximum)."
        case .lineupTooSmall(let attempted, let minimum):
            "A lineup needs at least \(minimum) players. You've selected \(attempted)."
        case .duplicateInLineup:
            "A player can only appear once in the lineup."
        case .goalkeeperNotInLineup:
            "The goalkeeper has to be one of the players on the field."
        case .shootoutNotAvailable:
            "This match format doesn't use a shootout."
        case .eventNotFound:
            "That event is no longer in the match."
        case .cannotEditStructuralEvent:
            "Period and lineup events are changed from the match controls."
        case .nothingToUndo:
            "There's nothing to undo."
        }
    }
}

/// The result of a command: a list of changes to apply to the match. Keeping
/// this a value means commands are testable without persistence, and the
/// persistence layer has exactly one place to make writes durable.
public enum MatchEffect: Hashable, Sendable, Codable {
    case appendEvent(MatchEvent)
    case replaceEvent(MatchEvent)
    case setClock(ClockAnchor)
    case setPhase(MatchPhase)
    case setFinalized(Date?)
}

public enum MatchCommand: Hashable, Sendable {
    case setLineup(LineupEvent)
    case startNextPeriod
    case endCurrentPeriod
    case startClock
    case stopClock
    case adjustClock(toSeconds: Int, reason: String?)
    case recordShot(ShotEvent)
    case recordCorner(side: TeamSide, player: PlayerRef)
    case recordSteal(side: TeamSide, player: PlayerRef)
    case recordFoul(side: TeamSide, player: PlayerRef)
    case recordOffside(side: TeamSide, player: PlayerRef)
    case recordCard(CardEvent)
    case substitute(SubstitutionEvent)
    case changeGoalkeeper(side: TeamSide, goalkeeper: PlayerRef)
    case recordShootoutAttempt(ShootoutAttemptEvent)
    case addNote(String)
    case finalize
    case reopen
}

public enum AttributionSlot: String, Hashable, Sendable {
    case primary
    case assist
    case goalkeeper
}

public enum EventEditCommand: Hashable, Sendable {
    case void(EventID)
    case restore(EventID)
    case changeTime(EventID, MatchTime)
    case attribute(EventID, AttributionSlot, PlayerRef)
    case replacePayload(EventID, EventPayload, summary: String)
    case setNote(EventID, String?)
}

/// Validates domain commands and turns them into events.
///
/// Every mutation of a match goes through here. Nothing else is allowed to
/// construct a `MatchEvent`, which is what keeps impossible statistical
/// combinations out of the record: a goal is a shot outcome, a save is an
/// opponent shot outcome, and neither can contradict the other.
public enum MatchEngine {

    // MARK: - Commands

    public static func perform(
        _ command: MatchCommand,
        on context: MatchContext,
        at date: Date = Date()
    ) throws -> [MatchEffect] {
        if context.phase == .finalized {
            switch command {
            case .reopen: break
            default: throw MatchCommandError.matchFinalized
            }
        }

        switch command {

        case .setLineup(let lineup):
            try validateLineup(lineup, context: context)
            let time = context.hasStarted ? context.currentTime(at: date) : .kickoff
            return [.appendEvent(makeEvent(context, time: time, date: date, payload: .lineupSet(lineup)))]

        case .startNextPeriod:
            guard context.phase != .inPeriod else { throw MatchCommandError.periodAlreadyRunning }
            let next = nextPeriodIndex(context)
            guard context.rules.period(at: next) != nil else { throw MatchCommandError.noPeriodsRemaining }
            let time = MatchTime(period: next, secondsElapsed: 0)
            return [
                .appendEvent(makeEvent(context, time: time, date: date, payload: .periodStarted(period: next))),
                .setClock(ClockAnchor(period: next, elapsedAtAnchor: 0, runningSince: date)),
                .setPhase(.inPeriod),
            ]

        case .endCurrentPeriod:
            guard context.phase == .inPeriod else { throw MatchCommandError.noPeriodRunning }
            let period = context.clock.period
            let time = context.clock.matchTime(at: date)
            let nextPhase = phaseAfterEnding(period: period, context: context)
            return [
                .appendEvent(makeEvent(context, time: time, date: date, payload: .periodEnded(period: period))),
                .setClock(context.clock.stopped(at: date)),
                .setPhase(nextPhase),
            ]

        case .startClock:
            guard context.phase == .inPeriod else { throw MatchCommandError.noPeriodRunning }
            return [.setClock(context.clock.started(at: date))]

        case .stopClock:
            guard context.phase == .inPeriod else { throw MatchCommandError.noPeriodRunning }
            return [.setClock(context.clock.stopped(at: date))]

        case .adjustClock(let toSeconds, let reason):
            guard context.hasStarted else { throw MatchCommandError.matchNotStarted }
            let period = context.clock.period
            let from = Int(context.clock.elapsed(at: date).rounded(.down))
            let payload = ClockAdjustmentEvent(
                period: period, fromSeconds: from, toSeconds: max(0, toSeconds), reason: reason)
            // The adjustment is recorded at the corrected time, and historical
            // event timestamps are deliberately left untouched.
            let time = MatchTime(period: period, secondsElapsed: max(0, toSeconds))
            return [
                .appendEvent(makeEvent(context, time: time, date: date, payload: .clockAdjusted(payload))),
                .setClock(context.clock.adjusted(to: TimeInterval(max(0, toSeconds)), at: date)),
            ]

        case .recordShot(let shot):
            try requireStarted(context)
            var shot = shot
            if shot.goalkeeper == nil {
                shot.goalkeeper = defendingGoalkeeperRef(for: shot, context: context, at: date)
            }
            if !shot.outcome.isGoal { shot.assist = nil }
            return [.appendEvent(makeEvent(context, date: date, payload: .shot(shot)))]

        case .recordCorner(let side, let player):
            try requireStarted(context)
            return [
                .appendEvent(
                    makeEvent(context, date: date, payload: .corner(TeamActionEvent(side: side, player: player))))
            ]

        case .recordSteal(let side, let player):
            try requireStarted(context)
            return [
                .appendEvent(
                    makeEvent(context, date: date, payload: .steal(TeamActionEvent(side: side, player: player))))
            ]

        case .recordFoul(let side, let player):
            try requireStarted(context)
            return [
                .appendEvent(
                    makeEvent(context, date: date, payload: .foul(TeamActionEvent(side: side, player: player))))
            ]

        case .recordOffside(let side, let player):
            try requireStarted(context)
            return [
                .appendEvent(
                    makeEvent(context, date: date, payload: .offside(TeamActionEvent(side: side, player: player))))
            ]

        case .recordCard(let card):
            try requireStarted(context)
            return [.appendEvent(makeEvent(context, date: date, payload: .card(card)))]

        case .substitute(let sub):
            try requireStarted(context)
            try validateSubstitution(sub, context: context, at: date)
            return [.appendEvent(makeEvent(context, date: date, payload: .substitution(sub)))]

        case .changeGoalkeeper(let side, let keeper):
            try requireStarted(context)
            if let id = keeper.playerID, context.roster(for: side)[id] == nil, side == .us {
                throw MatchCommandError.unknownPlayer(id)
            }
            return [
                .appendEvent(
                    makeEvent(context, date: date, payload: .goalkeeperChanged(side: side, goalkeeper: keeper)))
            ]

        case .recordShootoutAttempt(let attempt):
            guard context.rules.shootoutAvailable else { throw MatchCommandError.shootoutNotAvailable }
            let period = context.rules.periods.first { $0.kind == .shootout }?.index ?? context.clock.period
            let time = MatchTime(period: period, secondsElapsed: attempt.order)
            return [
                .appendEvent(makeEvent(context, time: time, date: date, payload: .shootoutAttempt(attempt)))
            ]

        case .addNote(let text):
            return [.appendEvent(makeEvent(context, date: date, payload: .note(text)))]

        case .finalize:
            var effects: [MatchEffect] = []
            if context.phase == .inPeriod {
                effects.append(contentsOf: try perform(.endCurrentPeriod, on: context, at: date))
            }
            effects.append(.appendEvent(makeEvent(context, date: date, payload: .matchFinalized)))
            effects.append(.setPhase(.finalized))
            effects.append(.setFinalized(date))
            return effects

        case .reopen:
            guard context.phase == .finalized else { return [] }
            var events = context.events
            if let index = events.lastIndex(where: {
                if case .matchFinalized = $0.payload { return $0.isActive } else { return false }
            }) {
                var event = events[index]
                event.voidedAt = date
                events[index] = event.appendingRevision(kind: .voided, summary: "Match reopened", at: date)
                return [
                    .replaceEvent(events[index]), .setPhase(.awaitingFinalization), .setFinalized(nil),
                ]
            }
            return [.setPhase(.awaitingFinalization), .setFinalized(nil)]
        }
    }

    // MARK: - Edits

    public static func perform(
        _ edit: EventEditCommand,
        on context: MatchContext,
        at date: Date = Date()
    ) throws -> [MatchEffect] {
        switch edit {
        case .void(let id):
            var event = try find(id, in: context)
            guard !event.payload.isStructural else { throw MatchCommandError.cannotEditStructuralEvent }
            event.voidedAt = date
            return [.replaceEvent(event.appendingRevision(kind: .voided, summary: "Deleted", at: date))]

        case .restore(let id):
            var event = try find(id, in: context)
            event.voidedAt = nil
            return [.replaceEvent(event.appendingRevision(kind: .restored, summary: "Restored", at: date))]

        case .changeTime(let id, let time):
            var event = try find(id, in: context)
            let summary = "Time changed from \(event.time.clockText) to \(time.clockText)"
            event.time = time
            return [.replaceEvent(event.appendingRevision(kind: .timeChanged, summary: summary, at: date))]

        case .attribute(let id, let slot, let ref):
            var event = try find(id, in: context)
            let side = event.payload.side ?? .us
            let label = context.roster(for: side).label(for: ref)
            event.payload = try applying(ref, slot: slot, to: event.payload)
            let summary =
                switch slot {
                case .primary: "Attributed to \(label)"
                case .assist: "Assist credited to \(label)"
                case .goalkeeper: "Goalkeeper set to \(label)"
                }
            return [.replaceEvent(event.appendingRevision(kind: .attributed, summary: summary, at: date))]

        case .replacePayload(let id, let payload, let summary):
            var event = try find(id, in: context)
            event.payload = payload
            return [.replaceEvent(event.appendingRevision(kind: .edited, summary: summary, at: date))]

        case .setNote(let id, let text):
            var event = try find(id, in: context)
            event.note = text
            return [
                .replaceEvent(
                    event.appendingRevision(
                        kind: .edited, summary: text == nil ? "Note removed" : "Note added", at: date))
            ]
        }
    }

    // MARK: - Undo / redo

    /// The event a plain Undo would remove: the most recently recorded active
    /// event, excluding finalization which has its own deliberate reversal.
    public static func undoTarget(_ context: MatchContext) -> MatchEvent? {
        context.events
            .filter { $0.isActive && !isFinalization($0) }
            .max { $0.sequence < $1.sequence }
    }

    /// The event a Redo would restore.
    public static func redoTarget(_ context: MatchContext) -> MatchEvent? {
        context.events
            .filter { $0.isVoided && !isFinalization($0) }
            .max { ($0.voidedAt ?? .distantPast) < ($1.voidedAt ?? .distantPast) }
    }

    /// Undo is immediate and never asks for confirmation. Undoing a period
    /// transition also restores the clock and phase, so a mis-tapped
    /// "End Period" costs one tap to fix.
    public static func undo(_ context: MatchContext, at date: Date = Date()) throws -> [MatchEffect] {
        guard var event = undoTarget(context) else { throw MatchCommandError.nothingToUndo }
        event.voidedAt = date
        let voided = event.appendingRevision(kind: .voided, summary: "Undone", at: date)
        var effects: [MatchEffect] = [.replaceEvent(voided)]

        switch event.payload {
        case .periodEnded(let period):
            effects.append(
                .setClock(
                    ClockAnchor(
                        period: period, elapsedAtAnchor: TimeInterval(event.time.secondsElapsed),
                        runningSince: nil)))
            effects.append(.setPhase(.inPeriod))

        case .periodStarted(let period):
            let previous = period - 1
            if previous >= 1 {
                let end =
                    context.activeEvents.last {
                        if case .periodEnded(let p) = $0.payload { return p == previous } else { return false }
                    }?.time.secondsElapsed ?? context.rules.period(at: previous)?.scheduledDuration ?? 0
                effects.append(
                    .setClock(ClockAnchor(period: previous, elapsedAtAnchor: TimeInterval(end), runningSince: nil)))
                effects.append(.setPhase(.periodBreak))
            } else {
                effects.append(.setClock(ClockAnchor(period: 1)))
                effects.append(.setPhase(.scheduled))
            }

        default:
            break
        }
        return effects
    }

    public static func redo(_ context: MatchContext, at date: Date = Date()) throws -> [MatchEffect] {
        guard let event = redoTarget(context) else { throw MatchCommandError.nothingToUndo }
        return try perform(.restore(event.id), on: context, at: date)
    }

    // MARK: - Applying effects

    public static func apply(_ effects: [MatchEffect], to context: inout MatchContext) {
        for effect in effects {
            switch effect {
            case .appendEvent(let event):
                context.events.append(event)
            case .replaceEvent(let event):
                if let index = context.events.firstIndex(where: { $0.id == event.id }) {
                    context.events[index] = event
                } else {
                    context.events.append(event)
                }
            case .setClock(let clock):
                context.clock = clock
            case .setPhase(let phase):
                context.phase = phase
            case .setFinalized(let date):
                context.finalizedAt = date
            }
        }
    }

    // MARK: - Helpers

    static func isFinalization(_ event: MatchEvent) -> Bool {
        if case .matchFinalized = event.payload { return true }
        return false
    }

    static func find(_ id: EventID, in context: MatchContext) throws -> MatchEvent {
        guard let event = context.events.first(where: { $0.id == id }) else {
            throw MatchCommandError.eventNotFound(id)
        }
        return event
    }

    static func makeEvent(
        _ context: MatchContext,
        time: MatchTime? = nil,
        date: Date,
        payload: EventPayload
    ) -> MatchEvent {
        MatchEvent(
            matchID: context.descriptor.id,
            time: time ?? context.currentTime(at: date),
            sequence: context.nextSequence,
            recordedAt: date,
            payload: payload
        )
    }

    static func requireStarted(_ context: MatchContext) throws {
        guard context.hasStarted else { throw MatchCommandError.matchNotStarted }
    }

    static func nextPeriodIndex(_ context: MatchContext) -> Int {
        (context.startedPeriods.max() ?? 0) + 1
    }

    /// Goals scored, computed directly from shot outcomes. Used for phase
    /// transitions without building a full snapshot.
    public static func score(_ context: MatchContext) -> SidePair<Int> {
        var score = SidePair(repeating: 0)
        for event in context.activeEvents {
            if case .shot(let shot) = event.payload, shot.outcome.isGoal {
                score[shot.scoringSide] += 1
            }
        }
        return score
    }

    static func phaseAfterEnding(period: Int, context: MatchContext) -> MatchPhase {
        let rules = context.rules
        let score = score(context)
        let tied = score.us == score.opponent
        guard let descriptor = rules.period(at: period) else { return .awaitingFinalization }

        switch descriptor.kind {
        case .regulation:
            if period < rules.regulationPeriods { return .periodBreak }
            if tied && (rules.overtimePeriods > 0 || rules.shootoutAvailable) { return .periodBreak }
            return .awaitingFinalization
        case .overtime:
            if rules.overtimeIsSuddenDeath && !tied { return .awaitingFinalization }
            let lastOvertime = rules.regulationPeriods + rules.overtimePeriods
            if period < lastOvertime { return .periodBreak }
            if tied && rules.shootoutAvailable { return .periodBreak }
            return .awaitingFinalization
        case .shootout:
            return .awaitingFinalization
        }
    }

    /// The goalkeeper who should be credited with facing a shot, resolved at the
    /// moment of recording so the scorer never has to pick one.
    static func defendingGoalkeeperRef(
        for shot: ShotEvent, context: MatchContext, at date: Date
    ) -> PlayerRef? {
        let defending = shot.scoringSide.opposite
        let timeline = LineupEngine.build(context: context, asOf: context.currentTime(at: date))
        if let id = timeline.currentGoalkeeper(side: defending) { return .player(id) }
        return defending == .us ? nil : .untracked
    }

    static func validateLineup(_ lineup: LineupEvent, context: MatchContext) throws {
        let rules = context.rules
        guard Set(lineup.onField).count == lineup.onField.count else {
            let seen = lineup.onField.reduce(into: (Set<PlayerID>(), PlayerID?.none)) { partial, id in
                if partial.0.contains(id) { partial.1 = id } else { partial.0.insert(id) }
            }
            throw MatchCommandError.duplicateInLineup(seen.1 ?? lineup.onField[0])
        }
        guard lineup.onField.count <= rules.playersPerSide else {
            throw MatchCommandError.tooManyPlayers(
                attempted: lineup.onField.count, maximum: rules.playersPerSide)
        }
        guard lineup.onField.count >= rules.minimumPlayersPerSide else {
            throw MatchCommandError.lineupTooSmall(
                attempted: lineup.onField.count, minimum: rules.minimumPlayersPerSide)
        }
        if lineup.side == .us {
            for id in lineup.onField where context.roster[id] == nil {
                throw MatchCommandError.unknownPlayer(id)
            }
        }
        if let keeper = lineup.goalkeeper, !lineup.onField.contains(keeper) {
            throw MatchCommandError.goalkeeperNotInLineup(keeper)
        }
    }

    static func validateSubstitution(
        _ sub: SubstitutionEvent, context: MatchContext, at date: Date
    ) throws {
        guard sub.side == .us || context.descriptor.tracking == .bothTeams else { return }
        let timeline = LineupEngine.build(context: context, asOf: context.currentTime(at: date))
        let onField = timeline.currentlyOnField(side: sub.side)

        if sub.side == .us {
            for id in sub.playersOut + sub.playersIn where context.roster[id] == nil {
                throw MatchCommandError.unknownPlayer(id)
            }
        }
        for id in sub.playersOut where !onField.contains(id) {
            throw MatchCommandError.playerNotOnField(id)
        }
        for id in sub.playersIn where onField.contains(id) {
            throw MatchCommandError.playerAlreadyOnField(id)
        }
        let resulting = onField.count - sub.playersOut.count + sub.playersIn.count
        if resulting > context.rules.playersPerSide {
            throw MatchCommandError.tooManyPlayers(
                attempted: resulting, maximum: context.rules.playersPerSide)
        }
        if let keeper = sub.goalkeeperAfter {
            let after = onField.subtracting(sub.playersOut).union(sub.playersIn)
            guard after.contains(keeper) else { throw MatchCommandError.goalkeeperNotInLineup(keeper) }
        }
    }

    static func applying(_ ref: PlayerRef, slot: AttributionSlot, to payload: EventPayload) throws
        -> EventPayload
    {
        switch (payload, slot) {
        case (.shot(var shot), .primary):
            shot.shooter = ref
            return .shot(shot)
        case (.shot(var shot), .assist):
            shot.assist = ref
            return .shot(shot)
        case (.shot(var shot), .goalkeeper):
            shot.goalkeeper = ref
            return .shot(shot)
        case (.corner(var action), _):
            action.player = ref
            return .corner(action)
        case (.steal(var action), _):
            action.player = ref
            return .steal(action)
        case (.foul(var action), _):
            action.player = ref
            return .foul(action)
        case (.offside(var action), _):
            action.player = ref
            return .offside(action)
        case (.card(var card), _):
            card.player = ref
            return .card(card)
        case (.shootoutAttempt(var attempt), .primary):
            attempt.taker = ref
            return .shootoutAttempt(attempt)
        case (.shootoutAttempt(var attempt), .goalkeeper):
            attempt.goalkeeper = ref
            return .shootoutAttempt(attempt)
        case (.goalkeeperChanged(let side, _), _):
            return .goalkeeperChanged(side: side, goalkeeper: ref)
        default:
            throw MatchCommandError.cannotEditStructuralEvent
        }
    }
}
