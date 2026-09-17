import Foundation
import Testing

@testable import ProgrammeCore
@testable import ProgrammeExport

@Suite("Programme archives round-trip and stay readable")
struct ArchiveTests {

    @Test("A match survives an archive round trip with identical statistics")
    func roundTrip() throws {
        let original = ProgrammeSample.completedContext()
        let archive = ProgrammeArchive(contexts: [original], teamName: ProgrammeSample.teamName)
        let data = try ProgrammeArchiveCoder.encode(archive)
        let decoded = try ProgrammeArchiveCoder.decode(data)
        let restored = try #require(decoded.matches.first).context

        #expect(restored.events.count == original.events.count)
        #expect(restored.descriptor == original.descriptor)
        #expect(restored.phase == original.phase)

        let before = StatEngine.snapshot(context: original)
        let after = StatEngine.snapshot(context: restored)
        #expect(before.score == after.score)
        #expect(before.result == after.result)
        #expect(before.players == after.players)
        #expect(before.keepers == after.keepers)
        #expect(before.completeness == after.completeness)
    }

    @Test("The tracked/untracked distinction survives the round trip")
    func trackedDistinctionSurvives() throws {
        var context = ProgrammeSample.completedContext()
        context.descriptor.statProfile = .scoreOnly
        let data = try ProgrammeArchiveCoder.encode(
            ProgrammeArchive(contexts: [context], teamName: ProgrammeSample.teamName))
        let restored = try #require(ProgrammeArchiveCoder.decode(data).matches.first)

        #expect(Set(restored.trackedStats) == Set(StatProfile.scoreOnly.tracked.map(\.rawValue)))
        let snapshot = StatEngine.snapshot(context: restored.context)
        #expect(snapshot.completeness(.steals) == .notTracked)
        #expect(snapshot.completeness(.goals) == .complete)
    }

    @Test("Revision history and voided events are preserved")
    func revisionsSurvive() throws {
        var context = ProgrammeSample.liveFirstHalfContext()
        let goal = try #require(
            context.activeEvents.first {
                if case .shot(let shot) = $0.payload { return shot.outcome.isGoal }
                return false
            })
        let effects = try MatchEngine.perform(
            .attribute(goal.id, .assist, .player(ProgrammeSample.mabry)), on: context)
        MatchEngine.apply(effects, to: &context)
        let undone = try MatchEngine.undo(context)
        MatchEngine.apply(undone, to: &context)

        let data = try ProgrammeArchiveCoder.encode(
            ProgrammeArchive(contexts: [context], teamName: ProgrammeSample.teamName))
        let restored = try #require(ProgrammeArchiveCoder.decode(data).matches.first).context

        let restoredGoal = try #require(restored.events.first { $0.id == goal.id })
        #expect(restoredGoal.revision == 2)
        #expect(restoredGoal.revisions.contains { $0.kind == .attributed })
        #expect(restored.events.contains { $0.isVoided })
    }

    @Test("A whole season archives and restores as one file")
    func seasonArchive() throws {
        let contexts = ProgrammeSample.seasonContexts()
        let data = try ProgrammeArchiveCoder.encode(
            ProgrammeArchive(contexts: contexts, teamName: ProgrammeSample.teamName))
        let decoded = try ProgrammeArchiveCoder.decode(data)
        #expect(decoded.matches.count == 4)
        #expect(decoded.manifest.matchCount == 4)

        let before = SeasonEngine.aggregate(
            contexts.map {
                MatchStatSummary(
                    snapshot: StatEngine.snapshot(context: $0), tracked: $0.profile.tracked,
                    isFinalized: true)
            })
        let after = SeasonEngine.aggregate(
            decoded.matches.map { archived in
                MatchStatSummary(
                    snapshot: StatEngine.snapshot(context: archived.context),
                    tracked: archived.context.profile.tracked, isFinalized: true)
            })
        #expect(before.recordText == after.recordText)
        #expect(before.goalsFor == after.goalsFor)
        #expect(before.players == after.players)
    }

    @Test("A file that is not a Programme archive is rejected clearly")
    func rejectsForeignFile() throws {
        let data = try #require(#"{"hello":"world"}"#.data(using: .utf8))
        #expect(throws: ArchiveError.notAProgrammeArchive) {
            _ = try ProgrammeArchiveCoder.decode(data)
        }
    }

    @Test("An archive from a newer Programme is refused with a useful message")
    func refusesNewerSchema() throws {
        var archive = ProgrammeArchive(
            contexts: [ProgrammeSample.completedContext()], teamName: ProgrammeSample.teamName)
        archive.manifest.schemaVersion = programmeArchiveSchemaVersion + 1
        let data = try ProgrammeArchiveCoder.encode(archive)

        #expect(
            throws: ArchiveError.schemaTooNew(
                found: programmeArchiveSchemaVersion + 1, supported: programmeArchiveSchemaVersion)
        ) {
            _ = try ProgrammeArchiveCoder.decode(data)
        }
    }

    @Test("Unknown keys written by a future build are ignored rather than fatal")
    func toleratesUnknownKeys() throws {
        let archive = ProgrammeArchive(
            contexts: [ProgrammeSample.completedContext()], teamName: ProgrammeSample.teamName)
        let data = try ProgrammeArchiveCoder.encode(archive)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["futureSection"] = ["something": "new"]
        var manifest = try #require(object["manifest"] as? [String: Any])
        manifest["futureField"] = 42
        object["manifest"] = manifest
        let mutated = try JSONSerialization.data(withJSONObject: object)

        let decoded = try ProgrammeArchiveCoder.decode(mutated)
        #expect(decoded.matches.count == 1)
    }
}

@Suite("Exporters")
struct ExporterTests {

    private var payload: ExportPayload {
        ExportPayload(
            teamName: ProgrammeSample.teamName,
            teamShortName: ProgrammeSample.teamShortName,
            seasonName: "2027",
            contexts: [ProgrammeSample.completedContext()]
        )
    }

    @Test("Every exporter produces non-empty output for a completed match")
    func allExportersProduceOutput() throws {
        for exporter in ProgrammeExporters.forMatch() {
            let data = try exporter.export(payload)
            #expect(!data.isEmpty, "\(exporter.name) produced no data")
        }
    }

    @Test("An untracked category exports as a blank cell, never as zero")
    func untrackedExportsBlank() throws {
        var context = ProgrammeSample.completedContext()
        context.descriptor.statProfile = .scoreOnly
        let payload = ExportPayload(teamName: ProgrammeSample.teamName, contexts: [context])
        let csv = try #require(String(data: try ProgrammeExporters.boxScoreCSV.export(payload), encoding: .utf8))

        let header = try #require(csv.split(separator: "\n").first).split(separator: ",").map(String.init)
        let stealsIndex = try #require(header.firstIndex(of: "Steals"))
        let row = try #require(csv.split(separator: "\n").dropFirst().first)
        let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[stealsIndex].isEmpty)

        // The same match under MaxPreps tracking reports a real zero.
        let tracked = ExportPayload(
            teamName: ProgrammeSample.teamName, contexts: [ProgrammeSample.completedContext()])
        let trackedCSV = try #require(
            String(data: try ProgrammeExporters.boxScoreCSV.export(tracked), encoding: .utf8))
        let trackedRow = try #require(trackedCSV.split(separator: "\n").dropFirst().first)
        let trackedFields = trackedRow.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(trackedFields[stealsIndex] == "0")
    }

    @Test("The MaxPreps summary names every category and its completeness")
    func maxPrepsSummaryIsComplete() throws {
        let text = try #require(String(data: try ProgrammeExporters.maxPreps.export(payload), encoding: .utf8))
        #expect(text.contains("MAXPREPS ENTRY SUMMARY"))
        #expect(text.contains("STAT COMPLETENESS"))
        #expect(text.contains("Not tracked") || text.contains("Complete"))
        #expect(text.contains("unknown, not zero"))
        for player in ProgrammeSample.startingEleven {
            let name = try #require(ProgrammeSample.roster[player]).fullName
            #expect(text.contains(name), "missing \(name)")
        }
    }

    @Test("The PDF stat sheet is a valid PDF document")
    func pdfIsValid() throws {
        let data = try ProgrammeExporters.pdf.export(payload)
        #expect(data.count > 1_000)
        #expect(data.prefix(5) == Data("%PDF-".utf8))
        #expect(String(data: data.suffix(1_024), encoding: .isoLatin1)?.contains("%%EOF") == true)
    }

    @Test("Filenames are readable and unique per format")
    func filenames() {
        let names = ProgrammeExporters.forMatch().map { $0.filename(for: payload) }
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.contains("Ninety-Six") })
    }

    @Test("Exporting nothing reports a clear error rather than an empty file")
    func emptyExportFails() {
        let empty = ExportPayload(teamName: "Ninety Six", contexts: [])
        for exporter in ProgrammeExporters.forMatch() {
            #expect(throws: (any Error).self) { _ = try exporter.export(empty) }
        }
    }
}

@Suite("Roster import")
struct RosterImportTests {

    @Test("A headed CSV maps without asking")
    func headedCSV() {
        let csv = """
            Number,Name,Position,Class
            9,Jalen Carter,F,Senior
            1,Eli Whitfield,GK,Senior
            7,"Williams, Chris",M,Senior
            """
        let preview = RosterImporter.preview(csv: csv)
        #expect(preview.hasHeaderRow)
        #expect(preview.mappingIsUnambiguous)
        #expect(preview.rows.count == 3)

        let players = preview.players
        #expect(players.count == 3)
        #expect(players[0].jerseyNumber == 9)
        #expect(players[0].firstName == "Jalen")
        #expect(players[0].lastName == "Carter")
        #expect(players[0].position == .forward)
        #expect(players[1].position == .goalkeeper)
        // "Last, First" is handled as well as "First Last".
        #expect(players[2].firstName == "Chris")
        #expect(players[2].lastName == "Williams")
    }

    @Test("A tab-separated paste is recognised")
    func pastedTable() {
        let text = "#\tPlayer\tPos\n10\tBeau Sanders\tF\n4\tAiden Pruitt\tD"
        let preview = RosterImporter.preview(csv: text)
        #expect(preview.rows.count == 2)
        #expect(preview.players.first?.jerseyNumber == 10)
        #expect(preview.players.first?.lastName == "Sanders")
    }

    @Test("A headerless file still produces a reviewable guess")
    func headerlessFile() {
        let csv = "9,Jalen Carter\n1,Eli Whitfield"
        let preview = RosterImporter.preview(csv: csv)
        #expect(!preview.hasHeaderRow)
        // Programme never imports a guessed mapping silently.
        #expect(!preview.mappingIsUnambiguous)
        #expect(preview.players.count == 2)
        #expect(preview.players.first?.jerseyNumber == 9)
    }

    @Test("Rows with no name are flagged and excluded")
    func rowsWithoutNames() {
        let csv = "Number,Name\n9,Jalen Carter\n12,\n,\n"
        let preview = RosterImporter.preview(csv: csv)
        #expect(preview.rows.count == 2)
        #expect(preview.rows.filter { $0.problem != nil }.count == 1)
        #expect(preview.players.count == 1)
    }

    @Test("Quoted fields containing commas survive parsing")
    func quotedFields() {
        let csv = "Name,Notes\n\"Carter, Jalen\",\"Captain, striker\""
        let preview = RosterImporter.preview(csv: csv)
        #expect(preview.rows.first?.fields.first == "Carter, Jalen")
        #expect(preview.rows.first?.fields.last == "Captain, striker")
    }
}
