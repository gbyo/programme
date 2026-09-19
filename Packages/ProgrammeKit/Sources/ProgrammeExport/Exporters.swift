import Foundation
import ProgrammeCore

// MARK: - Programme archive

public struct ProgrammeArchiveExporter: StatExporter {
    public init() {}
    public let id = "archive"
    public let name = "Programme Archive"
    public let detail = "A complete, versioned copy of the match — events, roster and configuration."
    public let fileExtension = "programme"
    public let contentTypeIdentifier = "com.gbyo.programme.archive"
    public let symbolName = "archivebox"

    public func export(_ payload: ExportPayload) throws -> Data {
        guard !payload.contexts.isEmpty else { throw ExportError.nothingToExport }
        let archive = ProgrammeArchive(contexts: payload.contexts, teamName: payload.teamName)
        return try ProgrammeArchiveCoder.encode(archive)
    }
}

// MARK: - Box score CSV

public struct BoxScoreCSVExporter: StatExporter {
    public init() {}
    public let id = "box-score"
    public let name = "Box Score (CSV)"
    public let detail = "One row per player per match. Blank cells mean the category was not tracked."
    public let fileExtension = "csv"
    public let contentTypeIdentifier = "public.comma-separated-values-text"
    public let symbolName = "tablecells"

    public func export(_ payload: ExportPayload) throws -> Data {
        guard !payload.contexts.isEmpty else { throw ExportError.nothingToExport }
        var lines: [String] = []
        lines.append(
            ExportFormatting.csvRow([
                "Date", "Opponent", "Venue", "Result", "Number", "Player", "Position", "Started",
                "Minutes", "Goals", "Assists", "Points", "Shots", "Shots on Goal", "SOG%",
                "PK Goals", "PK Attempts", "Game Winning Goals", "Corner Kicks", "Steals", "Fouls",
                "Offsides", "Yellow Cards", "Red Cards", "GK Minutes", "GK Shots on Goal Faced",
                "GK Saves", "GK Goals Allowed", "GK Save%", "GK PK Saves", "GK Shutouts",
                "GK Shared Shutouts",
            ]))

        for (context, snapshot) in zip(payload.contexts, payload.snapshots) {
            let profile = context.profile
            let date = ExportFormatting.shortDateFormatter.string(from: context.descriptor.kickoff)
            let result = snapshot.result.map { "\($0.letter) \(snapshot.score.us)-\(snapshot.score.opponent)" } ?? ""
            let roster = context.roster

            for player in roster.sortedByNumber {
                let line = snapshot.players[player.id]
                guard let line, line.appeared else { continue }
                let keeper = snapshot.keepers[player.id]
                let keeperTracked = profile.tracks(.goalkeeping) && (keeper?.secondsPlayed ?? 0) > 0

                lines.append(
                    ExportFormatting.csvRow([
                        date,
                        context.descriptor.opponentName,
                        context.descriptor.venue.label,
                        result,
                        player.jerseyNumber.map(String.init) ?? "",
                        player.fullName,
                        player.position?.label ?? "",
                        line.started ? "Y" : "N",
                        "\(line.minutesPlayed)",
                        ExportFormatting.cell(profile.value(.goals, line.goals)),
                        ExportFormatting.cell(profile.value(.assists, line.assists)),
                        ExportFormatting.cell(profile.value(.goals, line.points)),
                        ExportFormatting.cell(profile.value(.shots, line.shots)),
                        ExportFormatting.cell(profile.value(.shots, line.shotsOnGoal)),
                        profile.tracks(.shots) ? ExportFormatting.percent(line.shotAccuracy) : "",
                        ExportFormatting.cell(profile.value(.penaltyKicks, line.penaltyGoals)),
                        ExportFormatting.cell(profile.value(.penaltyKicks, line.penaltyAttempts)),
                        ExportFormatting.cell(profile.value(.goals, line.gameWinningGoals)),
                        ExportFormatting.cell(profile.value(.corners, line.corners)),
                        ExportFormatting.cell(profile.value(.steals, line.steals)),
                        ExportFormatting.cell(profile.value(.fouls, line.fouls)),
                        ExportFormatting.cell(profile.value(.offsides, line.offsides)),
                        ExportFormatting.cell(profile.value(.cards, line.yellowCards)),
                        ExportFormatting.cell(profile.value(.cards, line.redCards)),
                        keeperTracked ? "\(keeper?.minutesPlayed ?? 0)" : "",
                        keeperTracked ? "\(keeper?.shotsOnGoalFaced ?? 0)" : "",
                        keeperTracked ? "\(keeper?.saves ?? 0)" : "",
                        keeperTracked ? "\(keeper?.goalsAllowed ?? 0)" : "",
                        keeperTracked ? ExportFormatting.percent(keeper?.savePercentage) : "",
                        keeperTracked ? "\(keeper?.penaltySaves ?? 0)" : "",
                        keeperTracked ? "\(keeper?.shutouts ?? 0)" : "",
                        keeperTracked ? "\(keeper?.sharedShutouts ?? 0)" : "",
                    ]))
            }
        }
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }
}

// MARK: - Season CSV

public struct SeasonCSVExporter: StatExporter {
    public init() {}
    public let id = "season"
    public let name = "Season Totals (CSV)"
    public let detail = "Season totals per player, with how many matches tracked each category."
    public let fileExtension = "csv"
    public let contentTypeIdentifier = "public.comma-separated-values-text"
    public let symbolName = "tablecells.badge.ellipsis"

    public func export(_ payload: ExportPayload) throws -> Data {
        let season = payload.seasonStats
        guard season.matchesPlayed > 0 else { throw ExportError.nothingToExport }
        let roster = payload.combinedRoster
        var lines: [String] = []

        lines.append(
            ExportFormatting.csvRow([
                "Number", "Player", "Position", "Class", "Matches", "Starts", "Minutes", "Goals",
                "Assists", "Points", "Shots", "Shots on Goal", "SOG%", "PK Goals", "PK Attempts",
                "Game Winning Goals", "Corner Kicks", "Steals", "Fouls", "Offsides", "Yellow Cards",
                "Red Cards", "Matches Tracking Shots", "Matches Tracking Steals",
            ]))

        for stats in season.sortedPlayers {
            guard let player = roster[stats.playerID] else { continue }
            lines.append(
                ExportFormatting.csvRow([
                    player.jerseyNumber.map(String.init) ?? "",
                    player.fullName,
                    player.position?.label ?? "",
                    player.classYear ?? "",
                    "\(stats.matchesPlayed)",
                    "\(stats.starts)",
                    "\(stats.minutesPlayed)",
                    ExportFormatting.cell(stats.value(.goals, \.goals)),
                    ExportFormatting.cell(stats.value(.assists, \.assists)),
                    ExportFormatting.cell(stats.value(.goals, \.points)),
                    ExportFormatting.cell(stats.value(.shots, \.shots)),
                    ExportFormatting.cell(stats.value(.shots, \.shotsOnGoal)),
                    ExportFormatting.cell(stats.shotAccuracy),
                    ExportFormatting.cell(stats.value(.penaltyKicks, \.penaltyGoals)),
                    ExportFormatting.cell(stats.value(.penaltyKicks, \.penaltyAttempts)),
                    ExportFormatting.cell(stats.value(.goals, \.gameWinningGoals)),
                    ExportFormatting.cell(stats.value(.corners, \.corners)),
                    ExportFormatting.cell(stats.value(.steals, \.steals)),
                    ExportFormatting.cell(stats.value(.fouls, \.fouls)),
                    ExportFormatting.cell(stats.value(.offsides, \.offsides)),
                    ExportFormatting.cell(stats.value(.cards, \.yellowCards)),
                    ExportFormatting.cell(stats.value(.cards, \.redCards)),
                    "\(stats.coverage(.shots).tracked) of \(stats.matchesPlayed)",
                    "\(stats.coverage(.steals).tracked) of \(stats.matchesPlayed)",
                ]))
        }

        lines.append("")
        lines.append(ExportFormatting.csvRow(["Goalkeeping"]))
        lines.append(
            ExportFormatting.csvRow([
                "Number", "Player", "Matches", "Minutes", "Shots on Goal Faced", "Saves",
                "Goals Allowed", "Save%", "GAA", "PK Saves", "Shutouts", "Shared Shutouts", "W", "L", "T",
            ]))
        for keeper in season.sortedKeepers {
            guard let player = roster[keeper.playerID] else { continue }
            lines.append(
                ExportFormatting.csvRow([
                    player.jerseyNumber.map(String.init) ?? "",
                    player.fullName,
                    "\(keeper.matchesPlayed)",
                    "\(keeper.minutesPlayed)",
                    "\(keeper.totals.shotsOnGoalFaced)",
                    "\(keeper.totals.saves)",
                    "\(keeper.totals.goalsAllowed)",
                    ExportFormatting.cell(keeper.savePercentage),
                    ExportFormatting.cell(keeper.goalsAgainstAverage),
                    "\(keeper.totals.penaltySaves)",
                    "\(keeper.totals.shutouts)",
                    "\(keeper.totals.sharedShutouts)",
                    "\(keeper.totals.wins)",
                    "\(keeper.totals.losses)",
                    "\(keeper.totals.draws)",
                ]))
        }

        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }
}

// MARK: - MaxPreps entry summary

/// A printable sheet ordered and named to make manual entry into the MaxPreps
/// Team Admin stat screens as fast as possible.
///
/// Programme deliberately does not pretend to have a MaxPreps API. This is a
/// transcription aid. When official supplier requirements are available, a new
/// `StatExporter` implements them without touching anything else.
public struct MaxPrepsEntrySummaryExporter: StatExporter {
    public init() {}
    public let id = "maxpreps-entry"
    public let name = "MaxPreps Entry Summary"
    public let detail = "Ordered for fast manual entry in MaxPreps Team Admin."
    public let fileExtension = "txt"
    public let contentTypeIdentifier = "public.plain-text"
    public let symbolName = "list.clipboard"

    public func export(_ payload: ExportPayload) throws -> Data {
        guard let context = payload.contexts.first, let snapshot = payload.snapshots.first else {
            throw ExportError.nothingToExport
        }
        let profile = context.profile
        let roster = context.roster
        var lines: [String] = []

        lines.append("MAXPREPS ENTRY SUMMARY")
        lines.append(String(repeating: "=", count: 78))
        lines.append("\(payload.teamName)  \(context.descriptor.venue.shortLabel)  \(context.descriptor.opponentName)")
        lines.append(ExportFormatting.dateFormatter.string(from: context.descriptor.kickoff))
        let resultText = snapshot.result.map { "\($0.label) \(snapshot.score.us)-\(snapshot.score.opponent)" }
            ?? "\(snapshot.score.us)-\(snapshot.score.opponent)"
        lines.append("Final: \(resultText)")
        if snapshot.shootoutScore.us + snapshot.shootoutScore.opponent > 0 {
            lines.append("Shootout: \(snapshot.shootoutScore.us)-\(snapshot.shootoutScore.opponent)")
        }
        lines.append("")

        lines.append("TEAM TOTALS")
        lines.append(String(repeating: "-", count: 78))
        func teamRow(_ label: String, _ stat: TrackedStat, _ us: Int, _ them: Int) {
            let ours = ExportFormatting.cell(profile.value(stat, us))
            let theirs = ExportFormatting.cell(profile.value(stat, them))
            lines.append(
                "\(ExportFormatting.pad(label, 22))\(ExportFormatting.pad(ours.isEmpty ? "not tracked" : ours, 14))\(theirs.isEmpty ? "not tracked" : theirs)")
        }
        lines.append(
            "\(ExportFormatting.pad("", 22))\(ExportFormatting.pad(payload.teamShortName, 14))\(context.descriptor.opponentShortName)")
        teamRow("Goals", .goals, snapshot.team.us.goals, snapshot.team.opponent.goals)
        teamRow("Shots", .shots, snapshot.team.us.shots, snapshot.team.opponent.shots)
        teamRow("Shots on Goal", .shots, snapshot.team.us.shotsOnGoal, snapshot.team.opponent.shotsOnGoal)
        teamRow("Corner Kicks", .corners, snapshot.team.us.corners, snapshot.team.opponent.corners)
        teamRow("Steals", .steals, snapshot.team.us.steals, snapshot.team.opponent.steals)
        teamRow("Saves", .goalkeeping, snapshot.team.us.saves, snapshot.team.opponent.saves)
        teamRow("Yellow Cards", .cards, snapshot.team.us.yellowCards, snapshot.team.opponent.yellowCards)
        teamRow("Red Cards", .cards, snapshot.team.us.redCards, snapshot.team.opponent.redCards)
        lines.append("")

        lines.append("PLAYER STATISTICS  (enter in jersey order)")
        lines.append(String(repeating: "-", count: 78))
        lines.append(
            ExportFormatting.pad("#", 4) + ExportFormatting.pad("PLAYER", 20)
                + ExportFormatting.pad("MIN", 5, alignRight: true)
                + ExportFormatting.pad("G", 4, alignRight: true)
                + ExportFormatting.pad("A", 4, alignRight: true)
                + ExportFormatting.pad("PTS", 5, alignRight: true)
                + ExportFormatting.pad("SH", 5, alignRight: true)
                + ExportFormatting.pad("SOG", 5, alignRight: true)
                + ExportFormatting.pad("CK", 4, alignRight: true)
                + ExportFormatting.pad("ST", 4, alignRight: true)
                + ExportFormatting.pad("YC", 4, alignRight: true)
                + ExportFormatting.pad("RC", 4, alignRight: true))

        for player in roster.sortedByNumber {
            guard let line = snapshot.players[player.id], line.appeared else { continue }
            func cell(_ stat: TrackedStat, _ value: Int, _ width: Int) -> String {
                let text = ExportFormatting.cell(profile.value(stat, value))
                return ExportFormatting.pad(text.isEmpty ? "—" : text, width, alignRight: true)
            }
            lines.append(
                ExportFormatting.pad(player.jerseyNumber.map { "\($0)" } ?? "", 4)
                    + ExportFormatting.pad(player.fullName, 20)
                    + ExportFormatting.pad("\(line.minutesPlayed)", 5, alignRight: true)
                    + cell(.goals, line.goals, 4)
                    + cell(.assists, line.assists, 4)
                    + cell(.goals, line.points, 5)
                    + cell(.shots, line.shots, 5)
                    + cell(.shots, line.shotsOnGoal, 5)
                    + cell(.corners, line.corners, 4)
                    + cell(.steals, line.steals, 4)
                    + cell(.cards, line.yellowCards, 4)
                    + cell(.cards, line.redCards, 4))
        }
        lines.append("")

        if profile.tracks(.goalkeeping) {
            lines.append("GOALKEEPING")
            lines.append(String(repeating: "-", count: 78))
            lines.append(
                ExportFormatting.pad("#", 4) + ExportFormatting.pad("PLAYER", 20)
                    + ExportFormatting.pad("MIN", 5, alignRight: true)
                    + ExportFormatting.pad("SOGA", 6, alignRight: true)
                    + ExportFormatting.pad("SV", 5, alignRight: true)
                    + ExportFormatting.pad("GA", 5, alignRight: true)
                    + ExportFormatting.pad("SV%", 8, alignRight: true)
                    + ExportFormatting.pad("SHO", 5, alignRight: true))
            for keeper in snapshot.keepers.values.filter({ $0.side == .us && $0.secondsPlayed > 0 })
                .sorted(by: { $0.secondsPlayed > $1.secondsPlayed })
            {
                guard let player = roster[keeper.playerID] else { continue }
                lines.append(
                    ExportFormatting.pad(player.jerseyNumber.map { "\($0)" } ?? "", 4)
                        + ExportFormatting.pad(player.fullName, 20)
                        + ExportFormatting.pad("\(keeper.minutesPlayed)", 5, alignRight: true)
                        + ExportFormatting.pad("\(keeper.shotsOnGoalFaced)", 6, alignRight: true)
                        + ExportFormatting.pad("\(keeper.saves)", 5, alignRight: true)
                        + ExportFormatting.pad("\(keeper.goalsAllowed)", 5, alignRight: true)
                        + ExportFormatting.pad(
                            ExportFormatting.percent(keeper.savePercentage).isEmpty
                                ? "—" : ExportFormatting.percent(keeper.savePercentage), 8, alignRight: true)
                        + ExportFormatting.pad(
                            "\(keeper.shutouts + keeper.sharedShutouts)", 5, alignRight: true))
            }
            lines.append("")
        }

        lines.append("STAT COMPLETENESS")
        lines.append(String(repeating: "-", count: 78))
        for stat in TrackedStat.allCases.sorted(by: { $0.label < $1.label }) {
            let state = snapshot.completeness(stat)
            lines.append("\(ExportFormatting.pad(stat.label, 22))\(state.label)")
        }
        lines.append("")
        lines.append("A dash means the category was not tracked for this match. It is unknown, not zero.")
        lines.append("")
        lines.append("Generated by Programme on \(ExportFormatting.dateFormatter.string(from: payload.generatedAt)).")

        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }
}

// MARK: - Human-readable stat sheet

public struct StatSheetExporter: StatExporter {
    public init() {}
    public let id = "stat-sheet"
    public let name = "Stat Sheet"
    public let detail = "A readable summary with the event timeline."
    public let fileExtension = "txt"
    public let contentTypeIdentifier = "public.plain-text"
    public let symbolName = "doc.plaintext"

    public func export(_ payload: ExportPayload) throws -> Data {
        guard !payload.contexts.isEmpty else { throw ExportError.nothingToExport }
        var lines: [String] = []
        lines.append(payload.teamName.uppercased())
        if let seasonName = payload.seasonName { lines.append("Season \(seasonName)") }
        lines.append("")

        for (context, snapshot) in zip(payload.contexts, payload.snapshots) {
            lines.append(String(repeating: "=", count: 72))
            lines.append(
                "\(context.descriptor.teamShortName) \(snapshot.score.us) – \(snapshot.score.opponent) \(context.descriptor.opponentShortName)"
            )
            lines.append(ExportFormatting.dateFormatter.string(from: context.descriptor.kickoff))
            lines.append(
                [context.descriptor.venue.label, context.rules.name, context.startingFormation?.name]
                    .compactMap(\.self).joined(separator: " · "))
            if let competition = context.descriptor.competition { lines.append(competition) }
            lines.append("")

            lines.append(
                context.rules.clockDisplay == .countDownInPeriod
                    ? "TIMELINE  (times as shown on a counting-down scoreboard)" : "TIMELINE")
            for description in MatchNarrator.describeAll(context: context) {
                lines.append("  " + description.oneLine)
            }
            lines.append("")

            lines.append("MINUTES")
            for player in context.roster.sortedByNumber {
                guard let line = snapshot.players[player.id], line.appeared else { continue }
                var parts = ["\(line.minutesPlayed) min"]
                if line.goals > 0 { parts.append("\(line.goals) G") }
                if line.assists > 0 { parts.append("\(line.assists) A") }
                if context.profile.tracks(.shots) && line.shots > 0 {
                    parts.append("\(line.shots) SH / \(line.shotsOnGoal) SOG")
                }
                lines.append(
                    "  " + ExportFormatting.pad(player.shortLabel, 24)
                        + (line.started ? "GS  " : "    ") + parts.joined(separator: " · "))
            }
            lines.append("")
        }

        if payload.contexts.count > 1 {
            let season = payload.seasonStats
            lines.append(String(repeating: "=", count: 72))
            lines.append("SEASON TOTALS  \(season.recordText)")
            lines.append("Goals for \(season.goalsFor) · Goals against \(season.goalsAgainst) · Shutouts \(season.teamShutouts)")
            lines.append("")
            let roster = payload.combinedRoster
            for stats in season.sortedPlayers {
                guard let player = roster[stats.playerID] else { continue }
                lines.append(
                    "  " + ExportFormatting.pad(player.shortLabel, 24)
                        + ExportFormatting.pad("\(stats.matchesPlayed) GP", 8)
                        + ExportFormatting.pad("\(stats.minutesPlayed) min", 10)
                        + "\(stats.totals.goals) G · \(stats.totals.assists) A · \(stats.points) PTS")
            }
        }

        lines.append("")
        lines.append("Generated by Programme on \(ExportFormatting.dateFormatter.string(from: payload.generatedAt)).")
        lines.append("A dash or blank means the category was not tracked. It is unknown, not zero.")

        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }
}
