import Foundation

/// A single event rendered for reading: the event log, the recent-event strip,
/// the Live Activity and the printed stat sheet all use this, so the phrasing of
/// a goal is written exactly once.
public struct EventDescription: Identifiable, Hashable, Sendable {
    public var id: EventID
    public var time: MatchTime
    public var timeText: String
    public var title: String
    public var detail: String
    public var secondaryDetail: String?
    public var scoreText: String?
    public var symbolName: String
    public var category: EventCategory
    public var side: TeamSide?
    public var needsAttribution: Bool
    public var isVoided: Bool
    public var wasEdited: Bool
    public var accessibilityLabel: String

    /// "31:14 · GOAL · #9 Carter · Assist #7 Williams · 1–0"
    public var oneLine: String {
        var parts = [timeText, title, detail]
        if let secondaryDetail { parts.append(secondaryDetail) }
        if let scoreText { parts.append(scoreText) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public enum MatchNarrator {

    /// Describe every event in a match, in order, with the running score as it
    /// stood after each one.
    public static func describeAll(context: MatchContext, includeVoided: Bool = false) -> [EventDescription] {
        let events = includeVoided ? context.events.chronological : context.activeEvents
        var score = SidePair(repeating: 0)
        var descriptions: [EventDescription] = []
        for event in events {
            if event.isActive, case .shot(let shot) = event.payload, shot.outcome.isGoal {
                score[shot.scoringSide] += 1
            }
            descriptions.append(describe(event, context: context, scoreAfter: score))
        }
        return descriptions
    }

    public static func describe(
        _ event: MatchEvent,
        context: MatchContext,
        scoreAfter: SidePair<Int>? = nil
    ) -> EventDescription {
        let rules = context.rules
        let timeText = event.time.displayText(rules: rules)
        let side = event.payload.side

        func name(_ ref: PlayerRef, side: TeamSide?) -> String {
            switch ref {
            case .player(let id):
                let roster = context.roster(for: side ?? .us)
                return roster[id]?.shortLabel ?? context.opponentRoster[id]?.shortLabel ?? "Unknown"
            case .unidentified:
                return "Player unknown"
            case .untracked:
                return context.descriptor.shortName(for: side ?? .opponent)
            }
        }

        var title = ""
        var detail = ""
        var secondary: String?
        var scoreText: String?
        var symbol = event.category.symbolName

        switch event.payload {
        case .shot(let shot):
            let who = name(shot.shooter, side: shot.side)
            switch shot.outcome {
            case .goal:
                title = shot.isOwnGoal ? "OWN GOAL" : "GOAL"
                detail = who
                if shot.isOwnGoal {
                    secondary = "Credited to \(context.descriptor.shortName(for: shot.scoringSide))"
                } else if let assist = shot.assist {
                    secondary = "Assist \(name(assist, side: shot.side))"
                } else {
                    secondary = "Unassisted"
                }
                if shot.phase == .penaltyKick { secondary = "Penalty kick" }
                if let scoreAfter { scoreText = "\(scoreAfter.us)–\(scoreAfter.opponent)" }
                symbol = "soccerball.inverse"
            case .saved:
                title = "Shot on Goal"
                detail = who
                if let keeper = shot.goalkeeper {
                    secondary = "Saved by \(name(keeper, side: shot.side.opposite))"
                } else {
                    secondary = "Saved"
                }
                symbol = "hand.raised.fill"
            case .offTarget:
                title = "Shot"
                detail = who
                secondary = "Off target"
            case .blocked:
                title = "Shot"
                detail = who
                secondary = "Blocked"
            case .woodwork:
                title = "Shot"
                detail = who
                secondary = "Post or crossbar"
            }
            if let location = shot.location, context.profile.tracks(.shotLocations) {
                secondary = [secondary, location.zoneDescription].compactMap(\.self).joined(separator: " · ")
            }

        case .corner(let action):
            title = "Corner"
            detail =
                action.player == .untracked
                ? context.descriptor.shortName(for: action.side) : name(action.player, side: action.side)

        case .steal(let action):
            title = "Steal"
            detail = name(action.player, side: action.side)

        case .foul(let action):
            title = "Foul"
            detail = name(action.player, side: action.side)

        case .offside(let action):
            title = "Offside"
            detail = name(action.player, side: action.side)

        case .card(let card):
            title = card.card.label
            detail = name(card.player, side: card.side)
            secondary = card.reason
            symbol = card.card.isDismissal ? "rectangle.portrait.fill" : "rectangle.portrait"

        case .substitution(let sub):
            title = "Substitution"
            detail = substitutionDetail(sub, context: context)
            if let keeper = sub.goalkeeperAfter {
                secondary = "\(context.roster(for: sub.side)[keeper]?.shortLabel ?? "Unknown") in goal"
            }

        case .goalkeeperChanged(let side, let keeper):
            title = "Goalkeeper"
            detail = "\(name(keeper, side: side)) in goal"
            symbol = "hand.raised.fill"

        case .lineupSet(let lineup):
            title = "Lineup"
            detail = "\(lineup.onField.count) players"
            if let keeper = lineup.goalkeeper {
                secondary = "\(context.roster(for: lineup.side)[keeper]?.shortLabel ?? "Unknown") in goal"
            }
            symbol = "person.3.fill"

        case .periodStarted(let period):
            title = "\(rules.period(at: period)?.longLabel ?? "Period \(period)") begins"
            symbol = "play.fill"

        case .periodEnded(let period):
            title = "\(rules.period(at: period)?.longLabel ?? "Period \(period)") ends"
            if let scoreAfter { scoreText = "\(scoreAfter.us)–\(scoreAfter.opponent)" }
            symbol = "pause.fill"

        case .clockAdjusted(let adjustment):
            title = "Clock adjusted"
            let from = MatchTime(period: adjustment.period, secondsElapsed: adjustment.fromSeconds)
            let to = MatchTime(period: adjustment.period, secondsElapsed: adjustment.toSeconds)
            detail = "\(from.displayText(rules: rules)) → \(to.displayText(rules: rules))"
            secondary = adjustment.reason
            symbol = "clock.arrow.trianglehead.counterclockwise.rotate.90"

        case .shootoutAttempt(let attempt):
            title = attempt.scored ? "Shootout Goal" : "Shootout Miss"
            detail = name(attempt.taker, side: attempt.side)
            secondary = "Attempt \(attempt.order)"
            symbol = attempt.scored ? "checkmark.circle.fill" : "xmark.circle"

        case .matchFinalized:
            title = "Match finalized"
            symbol = "flag.checkered"

        case .note(let text):
            title = "Note"
            detail = text
            symbol = "text.quote"
        }

        let teamPrefix = side.map { context.descriptor.shortName(for: $0) }
        var accessibility = [timeText, teamPrefix, title, detail, secondary, scoreText]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if event.payload.awaitsAttribution { accessibility += ", needs player attribution" }
        if event.isVoided { accessibility += ", deleted" }

        return EventDescription(
            id: event.id,
            time: event.time,
            timeText: timeText,
            title: title,
            detail: detail,
            secondaryDetail: secondary,
            scoreText: scoreText,
            symbolName: symbol,
            category: event.category,
            side: side,
            needsAttribution: event.payload.awaitsAttribution,
            isVoided: event.isVoided,
            wasEdited: event.revision > 1,
            accessibilityLabel: accessibility
        )
    }

    /// A batched substitution reads as the relationships it actually is —
    /// "#13 Ferrer for #11 Trotter; #14 Hollis for #6 Kinard" — rather than two
    /// unrelated lists. `playersOut[n]` is replaced by `playersIn[n]`, so the
    /// pairing is recoverable from the stored event without a schema change.
    ///
    /// Unequal counts remain legal: the engine allows a side to play short, and
    /// the leftovers are narrated as plain arrivals or departures rather than
    /// being forced into a pair they do not belong to.
    static func substitutionDetail(_ sub: SubstitutionEvent, context: MatchContext) -> String {
        let roster = context.roster(for: sub.side)
        func label(_ id: PlayerID) -> String { roster[id]?.shortLabel ?? "Unknown" }

        let paired = min(sub.playersOut.count, sub.playersIn.count)
        var clauses = (0..<paired).map { "\(label(sub.playersIn[$0])) for \(label(sub.playersOut[$0]))" }
        if sub.playersOut.count > paired {
            clauses.append(sub.playersOut[paired...].map(label).joined(separator: ", ") + " off")
        }
        if sub.playersIn.count > paired {
            clauses.append(sub.playersIn[paired...].map(label).joined(separator: ", ") + " on")
        }
        return clauses.joined(separator: "; ")
    }
}
