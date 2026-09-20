import Foundation

public enum IssueSeverity: Int, Hashable, Sendable, Comparable, Codable {
    /// Worth knowing, never worth interrupting for.
    case info = 0
    /// Should be looked at before publishing, but the match can continue.
    case review = 1
    /// Must be resolved before the match can be finalized cleanly.
    case blocking = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .info: "Note"
        case .review: "Review"
        case .blocking: "Must Resolve"
        }
    }

    public var symbolName: String {
        switch self {
        case .info: "info.circle"
        case .review: "exclamationmark.triangle"
        case .blocking: "exclamationmark.octagon"
        }
    }
}

public enum IssueKind: String, Hashable, Sendable, Codable {
    case noLineup
    case tooManyActive
    case tooFewActive
    case eventByInactivePlayer
    case missingGoalkeeper
    case goalkeeperNotOnField
    case unresolvedAttribution
    case duplicateSubstitution
    case invalidSubstitution
    case reEntryViolation
    case selfAssist
    case eventOutsidePeriod
    case eventAfterPeriodEnd
    case periodNotEnded
    case goalkeeperStatMismatch
    case untrackedCategoryHasEvents
    case shootoutIncomplete
}

public struct ValidationIssue: Identifiable, Hashable, Sendable {
    /// Stable across recomputation so the Review list does not churn while the
    /// scorer is looking at it.
    public var id: String
    public var kind: IssueKind
    public var severity: IssueSeverity
    public var title: String
    public var detail: String
    public var time: MatchTime?
    public var eventID: EventID?
    public var playerID: PlayerID?

    public init(
        id: String,
        kind: IssueKind,
        severity: IssueSeverity,
        title: String,
        detail: String,
        time: MatchTime? = nil,
        eventID: EventID? = nil,
        playerID: PlayerID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.time = time
        self.eventID = eventID
        self.playerID = playerID
    }
}

/// Continuously answers "is this match internally coherent?".
///
/// Deliberately advisory: nothing here interrupts live scoring. Issues surface
/// through the Review affordance, and only `blocking` ones stand between a match
/// and a clean finalization.
public enum ValidationEngine {

    public static func issues(context: MatchContext, snapshot: MatchSnapshot) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let timeline = snapshot.timeline
        let rules = context.rules
        let roster = context.roster
        let events = context.activeEvents
        // Each of these scans `activeEvents`, so derive them once instead of
        // rescanning history per event or per check below.
        let startedPeriods = context.startedPeriods
        let endedPeriods = context.endedPeriods
        let startedPeriodSet = Set(startedPeriods)
        let hasStarted = !startedPeriods.isEmpty
        let appearances: [TeamSide: Set<PlayerID>] = [
            .us: timeline.appearances(side: .us),
            .opponent: timeline.appearances(side: .opponent),
        ]

        // MARK: Lineup presence

        let hasLineup = events.contains { if case .lineupSet = $0.payload { return true } else { return false } }
        if !hasLineup {
            issues.append(
                ValidationIssue(
                    id: "no-lineup",
                    kind: .noLineup,
                    severity: hasStarted ? .blocking : .review,
                    title: "No starting lineup",
                    detail: "Programme needs to know who started to calculate playing time."
                ))
        }

        // MARK: Active player counts

        if hasStarted {
            let active = timeline.currentlyOnField(side: .us)
            if active.count > rules.playersPerSide {
                issues.append(
                    ValidationIssue(
                        id: "too-many-active",
                        kind: .tooManyActive,
                        severity: .blocking,
                        title: "\(active.count) players on the field",
                        detail: "\(rules.name) allows \(rules.playersPerSide). Check recent substitutions.",
                        time: snapshot.asOf
                    ))
            } else if active.count < rules.playersPerSide && context.phase != .finalized {
                let severity: IssueSeverity = active.count < rules.minimumPlayersPerSide ? .blocking : .review
                let dismissals = snapshot.team.us.redCards
                // A team short because of a red card is legitimately short.
                if active.count + dismissals < rules.playersPerSide {
                    issues.append(
                        ValidationIssue(
                            id: "too-few-active",
                            kind: .tooFewActive,
                            severity: severity,
                            title: "\(active.count) players on the field",
                            detail:
                                "\(rules.name) expects \(rules.playersPerSide). A substitution may be missing.",
                            time: snapshot.asOf
                        ))
                }
            }
        }

        // MARK: Goalkeeper coverage

        if hasStarted, context.profile.tracks(.goalkeeping) {
            if timeline.currentGoalkeeper(side: .us) == nil, context.phase.isLive {
                issues.append(
                    ValidationIssue(
                        id: "missing-keeper",
                        kind: .missingGoalkeeper,
                        severity: .review,
                        title: "No goalkeeper on the field",
                        detail: "Goalkeeper minutes and saves cannot be attributed without one.",
                        time: snapshot.asOf
                    ))
            }
            for interval in timeline.goalkeeperIntervals where interval.side == .us {
                let onField = timeline.fieldIntervals.contains {
                    $0.playerID == interval.playerID && $0.side == .us
                        && $0.startAbsolute <= interval.startAbsolute
                        && $0.endAbsolute >= interval.startAbsolute
                }
                if !onField {
                    issues.append(
                        ValidationIssue(
                            id: "keeper-off-field-\(interval.id)",
                            kind: .goalkeeperNotOnField,
                            severity: .review,
                            title: "Goalkeeper not in the lineup",
                            detail:
                                "\(roster[interval.playerID]?.shortLabel ?? "A goalkeeper") is in goal from \(interval.start.clockText) but is not recorded as on the field.",
                            time: interval.start,
                            playerID: interval.playerID
                        ))
                }
            }

            // Goalkeeper accounting must reconcile with the team's goals conceded.
            let keeperGA = snapshot.keepers.values.filter { $0.side == .us }.reduce(0) { $0 + $1.goalsAllowed }
            if keeperGA != snapshot.score.opponent && hasStarted {
                issues.append(
                    ValidationIssue(
                        id: "keeper-ga-mismatch",
                        kind: .goalkeeperStatMismatch,
                        severity: .review,
                        title: "Goals allowed do not match the score",
                        detail:
                            "Goalkeepers are credited with \(keeperGA) goals allowed but the opponent has \(snapshot.score.opponent). A goal may have been conceded with no goalkeeper on the field.",
                        time: nil
                    ))
            }
        }

        // MARK: Per-event checks

        var substitutionState: Set<PlayerID> = []
        var lastExitPeriod: [PlayerID: Int] = [:]
        var hasSeenLineup = false

        for event in events {
            // Attribution still outstanding.
            if event.payload.awaitsAttribution {
                issues.append(
                    ValidationIssue(
                        id: "unattributed-\(event.id)",
                        kind: .unresolvedAttribution,
                        severity: .review,
                        title: "\(describe(category: event.category)) needs a player",
                        detail: "Recorded at \(event.time.clockText) without a jersey number.",
                        time: event.time,
                        eventID: event.id
                    ))
            }

            // Events attributed to a player who was not on the field.
            for ref in event.payload.playerRefs {
                guard case .player(let id) = ref else { continue }
                guard event.payload.side == .us || context.descriptor.tracking == .bothTeams else { continue }
                switch event.payload {
                case .lineupSet, .substitution, .periodStarted, .periodEnded:
                    continue
                default:
                    break
                }
                let side = event.payload.side ?? .us
                if appearances[side]?.contains(id) ?? false, !timeline.wasOnField(id, at: event.time) {
                    issues.append(
                        ValidationIssue(
                            id: "inactive-\(event.id)-\(id)",
                            kind: .eventByInactivePlayer,
                            severity: .review,
                            title: "\(roster[id]?.shortLabel ?? "Player") was not on the field",
                            detail:
                                "A \(describe(category: event.category).lowercased()) at \(event.time.clockText) is credited to a player who was on the bench. Check the substitution times.",
                            time: event.time,
                            eventID: event.id,
                            playerID: id
                        ))
                }
            }

            // A goal cannot be assisted by its own scorer.
            if case .shot(let shot) = event.payload,
                shot.outcome.isGoal,
                let scorer = shot.shooter.playerID,
                let assist = shot.assist?.playerID,
                scorer == assist
            {
                issues.append(
                    ValidationIssue(
                        id: "self-assist-\(event.id)",
                        kind: .selfAssist,
                        severity: .blocking,
                        title: "Goal assisted by its own scorer",
                        detail: "\(roster[scorer]?.shortLabel ?? "The scorer") cannot assist their own goal.",
                        time: event.time,
                        eventID: event.id
                    ))
            }

            // Time must fall inside a period that was played. A shootout is
            // exempt: it has no clock and is never "started" like a period, so
            // its kicks carry the shootout's index and an order rather than a time.
            if !event.payload.isStructural, !isShootoutAttempt(event) {
                if !startedPeriodSet.contains(event.time.period) {
                    issues.append(
                        ValidationIssue(
                            id: "outside-period-\(event.id)",
                            kind: .eventOutsidePeriod,
                            severity: .review,
                            title: "Event in a period that was not played",
                            detail:
                                "Recorded in \(rules.period(at: event.time.period)?.longLabel ?? "period \(event.time.period)"), which never started.",
                            time: event.time,
                            eventID: event.id
                        ))
                } else if let span = timeline.periods.span(event.time.period), span.isComplete,
                    event.time.secondsElapsed > span.actualDuration
                {
                    issues.append(
                        ValidationIssue(
                            id: "after-period-\(event.id)",
                            kind: .eventAfterPeriodEnd,
                            severity: .review,
                            title: "Event after the period ended",
                            detail:
                                "Recorded at \(event.time.clockText), after the period finished at \(MatchTime(period: span.period, secondsElapsed: span.actualDuration).clockText).",
                            time: event.time,
                            eventID: event.id
                        ))
                }
            }

            // Substitution coherence.
            switch event.payload {
            case .lineupSet(let lineup) where lineup.side == .us:
                substitutionState = Set(lineup.onField)
                hasSeenLineup = true

            case .substitution(let sub) where sub.side == .us:
                if sub.playersOut.count != sub.playersIn.count {
                    issues.append(
                        ValidationIssue(
                            id: "uneven-sub-\(event.id)",
                            kind: .invalidSubstitution,
                            severity: .review,
                            title: "Uneven substitution",
                            detail:
                                "\(sub.playersOut.count) out and \(sub.playersIn.count) in at \(event.time.clockText). This changes the number of players on the field.",
                            time: event.time,
                            eventID: event.id
                        ))
                }
                if hasSeenLineup {
                    for player in sub.playersOut where !substitutionState.contains(player) {
                        issues.append(
                            ValidationIssue(
                                id: "sub-out-not-on-\(event.id)-\(player)",
                                kind: .duplicateSubstitution,
                                severity: .review,
                                title: "\(roster[player]?.shortLabel ?? "Player") was already off",
                                detail: "Substituted out at \(event.time.clockText) while on the bench.",
                                time: event.time,
                                eventID: event.id,
                                playerID: player
                            ))
                    }
                    for player in sub.playersIn where substitutionState.contains(player) {
                        issues.append(
                            ValidationIssue(
                                id: "sub-in-already-on-\(event.id)-\(player)",
                                kind: .duplicateSubstitution,
                                severity: .review,
                                title: "\(roster[player]?.shortLabel ?? "Player") was already on",
                                detail: "Substituted in at \(event.time.clockText) while already on the field.",
                                time: event.time,
                                eventID: event.id,
                                playerID: player
                            ))
                    }
                    for player in sub.playersIn {
                        if let exitPeriod = lastExitPeriod[player] {
                            switch rules.reEntry {
                            case .unlimited:
                                break
                            case .none:
                                issues.append(
                                    ValidationIssue(
                                        id: "reentry-\(event.id)-\(player)",
                                        kind: .reEntryViolation,
                                        severity: .review,
                                        title: "Re-entry not permitted",
                                        detail:
                                            "\(rules.name) does not allow a substituted player to return.",
                                        time: event.time,
                                        eventID: event.id,
                                        playerID: player
                                    ))
                            case .oncePerPeriod where exitPeriod == event.time.period:
                                issues.append(
                                    ValidationIssue(
                                        id: "reentry-\(event.id)-\(player)",
                                        kind: .reEntryViolation,
                                        severity: .review,
                                        title: "Re-entry in the same period",
                                        detail:
                                            "\(rules.name) does not allow a return in the period the player left.",
                                        time: event.time,
                                        eventID: event.id,
                                        playerID: player
                                    ))
                            default:
                                break
                            }
                        }
                    }
                }
                for player in sub.playersOut {
                    substitutionState.remove(player)
                    lastExitPeriod[player] = event.time.period
                }
                for player in sub.playersIn { substitutionState.insert(player) }

            case .card(let card) where card.card.isDismissal && card.side == .us:
                if let id = card.player.playerID { substitutionState.remove(id) }

            default:
                break
            }
        }

        // MARK: Periods left open

        for period in startedPeriods where !endedPeriods.contains(period) {
            if context.currentPeriodIndex != period || context.phase == .finalized {
                issues.append(
                    ValidationIssue(
                        id: "period-open-\(period)",
                        kind: .periodNotEnded,
                        severity: .review,
                        title: "\(rules.period(at: period)?.longLabel ?? "Period \(period)") was never ended",
                        detail: "Playing time in that period falls back to its scheduled length."
                    ))
            }
        }

        // MARK: Events recorded for categories the profile does not track

        var categoriesWithEvents: Set<TrackedStat> = []
        for event in events {
            switch event.payload {
            case .corner: categoriesWithEvents.insert(.corners)
            case .steal: categoriesWithEvents.insert(.steals)
            case .card: categoriesWithEvents.insert(.cards)
            case .foul: categoriesWithEvents.insert(.fouls)
            case .offside: categoriesWithEvents.insert(.offsides)
            case .shot(let shot):
                if !shot.outcome.isGoal { categoriesWithEvents.insert(.shots) }
                if shot.phase == .penaltyKick { categoriesWithEvents.insert(.penaltyKicks) }
            default: break
            }
        }
        for stat in categoriesWithEvents where !context.profile.tracks(stat) {
            issues.append(
                ValidationIssue(
                    id: "untracked-with-events-\(stat.rawValue)",
                    kind: .untrackedCategoryHasEvents,
                    severity: .info,
                    title: "\(stat.label) were recorded but are not in this profile",
                    detail:
                        "The events are safely stored. Switch this match to a profile that tracks \(stat.label.lowercased()) to publish them."
                ))
        }

        return issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            switch ($0.time, $1.time) {
            case (let a?, let b?): return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return $0.id < $1.id
            }
        }
    }

    static func isShootoutAttempt(_ event: MatchEvent) -> Bool {
        if case .shootoutAttempt = event.payload { return true }
        return false
    }

    static func describe(category: EventCategory) -> String {
        switch category {
        case .goal: "Goal"
        case .shot: "Shot"
        case .save: "Shot on Goal"
        case .card: "Card"
        case .substitution: "Substitution"
        case .corner: "Corner"
        case .steal: "Steal"
        case .foul: "Foul"
        case .clock: "Clock change"
        case .structural: "Match event"
        }
    }
}

extension Array where Element == ValidationIssue {
    public var blocking: [ValidationIssue] { filter { $0.severity == .blocking } }
    public var needingReview: [ValidationIssue] { filter { $0.severity >= .review } }
    public var canFinalizeCleanly: Bool { !contains { $0.severity == .blocking } }
}
