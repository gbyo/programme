import Foundation

/// Deterministic fixtures for previews, tests and first-run exploration.
///
/// Every identifier is derived from a stable string, so a preview rendered twice
/// shows the same players and a snapshot test does not churn. Nothing in the
/// application is built around these values.
public enum ProgrammeSample {

    /// A stable UUID for a given name. Not cryptographic — just repeatable.
    public static func id(_ seed: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(seed.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        var state = hash
        for index in 0..<16 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes[index] = UInt8(truncatingIfNeeded: state)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static let teamID = TeamID(id("team.ninety-six"))
    public static let seasonID = SeasonID(id("season.2027"))

    public static let teamName = "Ninety Six Boys Soccer"
    public static let teamShortName = "Ninety Six"

    public static func playerID(_ name: String) -> PlayerID { PlayerID(id("player.\(name)")) }

    private static func player(
        _ first: String, _ last: String, _ number: Int, _ position: PlayerPosition, _ year: String
    ) -> PlayerSnapshot {
        PlayerSnapshot(
            id: playerID("\(first).\(last)"),
            firstName: first,
            lastName: last,
            jerseyNumber: number,
            position: position,
            classYear: year
        )
    }

    public static let roster = RosterSnapshot(players: [
        player("Eli", "Whitfield", 1, .goalkeeper, "Senior"),
        player("Marcus", "Odom", 2, .defender, "Junior"),
        player("Tyrell", "Boyd", 3, .defender, "Senior"),
        player("Aiden", "Pruitt", 4, .defender, "Sophomore"),
        player("Sam", "Alvarez", 5, .defender, "Senior"),
        player("Noah", "Kinard", 6, .midfielder, "Junior"),
        player("Chris", "Williams", 7, .midfielder, "Senior"),
        player("Drew", "Mabry", 8, .midfielder, "Junior"),
        player("Jalen", "Carter", 9, .forward, "Senior"),
        player("Beau", "Sanders", 10, .forward, "Junior"),
        player("Micah", "Trotter", 11, .forward, "Sophomore"),
        player("Owen", "Ridgeway", 12, .midfielder, "Sophomore"),
        player("Luis", "Ferrer", 13, .defender, "Junior"),
        player("Kade", "Hollis", 14, .midfielder, "Freshman"),
        player("Theo", "Nance", 15, .forward, "Sophomore"),
        player("Grant", "Ellison", 16, .defender, "Junior"),
        player("Isaiah", "Fowler", 17, .midfielder, "Senior"),
        player("Peyton", "Vaughn", 18, .forward, "Freshman"),
        player("Cole", "Brannon", 22, .goalkeeper, "Sophomore"),
        player("Rhett", "Lanier", 24, .defender, "Freshman"),
    ])

    public static var keeper: PlayerID { playerID("Eli.Whitfield") }
    public static var backupKeeper: PlayerID { playerID("Cole.Brannon") }
    public static var carter: PlayerID { playerID("Jalen.Carter") }
    public static var williams: PlayerID { playerID("Chris.Williams") }
    public static var sanders: PlayerID { playerID("Beau.Sanders") }
    public static var mabry: PlayerID { playerID("Drew.Mabry") }
    public static var ridgeway: PlayerID { playerID("Owen.Ridgeway") }
    public static var trotter: PlayerID { playerID("Micah.Trotter") }

    /// The eleven who normally start.
    public static var startingEleven: [PlayerID] {
        [
            playerID("Eli.Whitfield"), playerID("Marcus.Odom"), playerID("Tyrell.Boyd"),
            playerID("Aiden.Pruitt"), playerID("Sam.Alvarez"), playerID("Noah.Kinard"),
            playerID("Chris.Williams"), playerID("Drew.Mabry"), playerID("Jalen.Carter"),
            playerID("Beau.Sanders"), playerID("Micah.Trotter"),
        ]
    }

    public static func kickoff(daysFromNow: Int = 0, hour: Int = 19) -> Date {
        var components = DateComponents()
        components.year = 2027
        components.month = 2
        components.day = 18 + daysFromNow
        components.hour = hour
        components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 1_800_000_000)
    }

    public static func descriptor(
        opponent: String = "Dixie",
        venue: Venue = .home,
        rules: MatchRules = .highSchool,
        profile: StatProfile = .maxPreps,
        daysFromNow: Int = 0,
        seed: String = "match.dixie"
    ) -> MatchDescriptor {
        MatchDescriptor(
            id: MatchID(id(seed)),
            teamID: teamID,
            seasonID: seasonID,
            teamName: teamName,
            teamShortName: teamShortName,
            opponentName: opponent,
            opponentShortName: opponent,
            kickoff: kickoff(daysFromNow: daysFromNow),
            venue: venue,
            rules: rules,
            statProfile: profile,
            tracking: .ourTeam,
            competition: "Region 2-AA"
        )
    }

    /// A match created but not yet kicked off, with the lineup confirmed.
    public static func pregameContext(seed: String = "match.dixie") -> MatchContext {
        var context = MatchContext(descriptor: descriptor(seed: seed), roster: roster)
        apply(
            .setLineup(LineupEvent(side: .us, onField: startingEleven, goalkeeper: keeper)),
            to: &context, at: kickoff(hour: 18))
        return context
    }

    /// Twenty-three minutes into the first half: two shots, a save, a goal.
    public static func liveFirstHalfContext(seed: String = "match.dixie") -> MatchContext {
        var context = pregameContext(seed: seed)
        let start = kickoff()
        apply(.startNextPeriod, to: &context, at: start)

        record(&context, at: start.addingTimeInterval(240)) {
            .recordShot(ShotEvent(side: .us, shooter: .player(carter), outcome: .offTarget))
        }
        record(&context, at: start.addingTimeInterval(430)) {
            .recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved))
        }
        record(&context, at: start.addingTimeInterval(612)) {
            .recordCorner(side: .us, player: .player(williams))
        }
        record(&context, at: start.addingTimeInterval(770)) {
            .recordShot(
                ShotEvent(
                    side: .us, shooter: .player(carter), outcome: .goal, assist: .player(williams),
                    location: PitchPoint(x: 0.86, y: 0.54)))
        }
        record(&context, at: start.addingTimeInterval(1_020)) {
            .recordShot(ShotEvent(side: .us, shooter: .unidentified, outcome: .saved))
        }
        record(&context, at: start.addingTimeInterval(1_180)) {
            .substitute(SubstitutionEvent(side: .us, playersOut: [mabry], playersIn: [ridgeway]))
        }
        record(&context, at: start.addingTimeInterval(1_310)) {
            .recordSteal(side: .us, player: .player(sanders))
        }
        // Leave the clock running so the live scorer opens onto a moving match.
        context.clock = ClockAnchor(
            period: 1, elapsedAtAnchor: 1_421, runningSince: Date())
        return context
    }

    /// The first half is over with one event still awaiting attribution.
    public static func halftimeContext(seed: String = "match.dixie") -> MatchContext {
        var context = liveFirstHalfContext(seed: seed)
        context.clock = ClockAnchor(period: 1, elapsedAtAnchor: 2_400, runningSince: nil)
        let end = kickoff().addingTimeInterval(2_700)
        apply(.endCurrentPeriod, to: &context, at: end)
        return context
    }

    /// A completed match: 3–1, a shutout-free second half, everything attributed.
    public static func completedContext(
        opponent: String = "Dixie",
        seed: String = "match.dixie",
        daysFromNow: Int = 0,
        finalScore: (us: Int, them: Int) = (3, 1)
    ) -> MatchContext {
        var context = MatchContext(
            descriptor: descriptor(opponent: opponent, daysFromNow: daysFromNow, seed: seed),
            roster: roster)
        let start = kickoff(daysFromNow: daysFromNow)
        apply(
            .setLineup(LineupEvent(side: .us, onField: startingEleven, goalkeeper: keeper)),
            to: &context, at: start.addingTimeInterval(-1_800))
        apply(.startNextPeriod, to: &context, at: start)

        var scored = 0
        var conceded = 0
        let scorers = [carter, sanders, trotter, carter]
        let assisters: [PlayerID?] = [williams, nil, williams, mabry]

        for minute in [7, 19, 31] where scored < finalScore.us {
            record(&context, at: start.addingTimeInterval(TimeInterval(minute * 60))) {
                .recordShot(
                    ShotEvent(
                        side: .us, shooter: .player(scorers[scored]), outcome: .goal,
                        assist: assisters[scored].map(PlayerRef.player),
                        location: PitchPoint(x: 0.82 + Double(scored) * 0.03, y: 0.4 + Double(scored) * 0.1)))
            }
            scored += 1
        }
        record(&context, at: start.addingTimeInterval(700)) {
            .recordShot(ShotEvent(side: .us, shooter: .player(sanders), outcome: .saved))
        }
        record(&context, at: start.addingTimeInterval(1_500)) {
            .recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved))
        }
        record(&context, at: start.addingTimeInterval(1_900)) {
            .recordCorner(side: .us, player: .player(williams))
        }

        context.clock = ClockAnchor(period: 1, elapsedAtAnchor: 2_400, runningSince: nil)
        apply(.endCurrentPeriod, to: &context, at: start.addingTimeInterval(2_450))
        apply(.startNextPeriod, to: &context, at: start.addingTimeInterval(3_000))

        record(&context, at: start.addingTimeInterval(3_400)) {
            .substitute(
                SubstitutionEvent(side: .us, playersOut: [trotter, mabry], playersIn: [ridgeway, playerID("Kade.Hollis")]))
        }
        while conceded < finalScore.them {
            record(&context, at: start.addingTimeInterval(TimeInterval(3_600 + conceded * 420))) {
                .recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .goal))
            }
            conceded += 1
        }
        while scored < finalScore.us {
            record(&context, at: start.addingTimeInterval(TimeInterval(4_200 + scored * 300))) {
                .recordShot(
                    ShotEvent(
                        side: .us, shooter: .player(scorers[min(scored, scorers.count - 1)]), outcome: .goal,
                        assist: .player(williams)))
            }
            scored += 1
        }
        record(&context, at: start.addingTimeInterval(4_500)) {
            .recordCard(CardEvent(side: .us, player: .player(playerID("Tyrell.Boyd")), card: .yellow))
        }
        record(&context, at: start.addingTimeInterval(4_800)) {
            .recordShot(ShotEvent(side: .opponent, shooter: .untracked, outcome: .saved))
        }
        record(&context, at: start.addingTimeInterval(4_900)) {
            .substitute(SubstitutionEvent(side: .us, playersOut: [keeper], playersIn: [backupKeeper], goalkeeperAfter: backupKeeper))
        }

        context.clock = ClockAnchor(period: 2, elapsedAtAnchor: 2_400, runningSince: nil)
        apply(.endCurrentPeriod, to: &context, at: start.addingTimeInterval(5_400))
        apply(.finalize, to: &context, at: start.addingTimeInterval(5_500))
        return context
    }

    /// Several finished matches, for season pages and charts.
    public static func seasonContexts() -> [MatchContext] {
        [
            completedContext(opponent: "Dixie", seed: "match.dixie", daysFromNow: -14, finalScore: (3, 1)),
            completedContext(opponent: "Ware Shoals", seed: "match.ware", daysFromNow: -10, finalScore: (2, 0)),
            completedContext(opponent: "Abbeville", seed: "match.abbeville", daysFromNow: -6, finalScore: (1, 2)),
            completedContext(opponent: "Emerald", seed: "match.emerald", daysFromNow: -3, finalScore: (4, 2)),
        ]
    }

    public static func upcomingDescriptor() -> MatchDescriptor {
        descriptor(opponent: "Clinton", venue: .home, daysFromNow: 5, seed: "match.clinton")
    }

    // MARK: - Fixture helpers

    private static func apply(_ command: MatchCommand, to context: inout MatchContext, at date: Date) {
        if let effects = try? MatchEngine.perform(command, on: context, at: date) {
            MatchEngine.apply(effects, to: &context)
        }
    }

    /// Records a command as if the clock had been running to `date`.
    private static func record(
        _ context: inout MatchContext, at date: Date, _ command: () -> MatchCommand
    ) {
        let elapsedInPeriod = elapsed(in: context, at: date)
        let saved = context.clock
        context.clock = ClockAnchor(
            period: context.clock.period, elapsedAtAnchor: elapsedInPeriod, runningSince: nil)
        apply(command(), to: &context, at: date)
        context.clock = saved
    }

    private static func elapsed(in context: MatchContext, at date: Date) -> TimeInterval {
        let period = context.clock.period
        let periodStart = context.activeEvents.last {
            if case .periodStarted(let p) = $0.payload { return p == period } else { return false }
        }?.recordedAt
        guard let periodStart else { return 0 }
        return max(0, date.timeIntervalSince(periodStart))
    }
}
