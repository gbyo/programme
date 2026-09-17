import ProgrammeCore
import ProgrammeExport
import ProgrammeUI
import SwiftUI

/// Reviewing a `.programme` file opened from Files, before deciding to import it.
@available(iOS 27.0, *)
struct ArchiveDocumentView: View {
    @Bindable var document: ProgrammeArchiveDocument

    @Environment(AppModel.self) private var appModel
    @State private var importMessage: String?
    @State private var isImporting = false

    private var archive: ProgrammeArchive { document.archive }

    var body: some View {
        List {
            Section("Archive") {
                LabeledContent("Team", value: archive.manifest.teamName)
                LabeledContent("Matches", value: "\(archive.matches.count)")
                LabeledContent(
                    "Created",
                    value: archive.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Format version", value: "\(archive.manifest.schemaVersion)")
                LabeledContent("Written by", value: archive.manifest.generator)
            }

            ForEach(archive.matches, id: \.descriptor.id) { match in
                Section(match.descriptor.title) {
                    let snapshot = StatEngine.snapshot(context: match.context)
                    LabeledContent("Score", value: "\(snapshot.score.us)–\(snapshot.score.opponent)")
                    LabeledContent(
                        "Date",
                        value: match.descriptor.kickoff.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Events", value: "\(match.events.count)")
                    LabeledContent("Format", value: match.descriptor.rules.name)
                    LabeledContent("Tracked", value: match.trackedStats.count.formatted() + " categories")
                }
            }

            if let importMessage {
                Section {
                    Text(importMessage).font(.subheadline)
                }
            }
        }
        .navigationTitle("Programme Archive")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import into Programme") { Task { await importAll() } }
                    .disabled(isImporting || archive.matches.isEmpty)
            }
        }
    }

    private func importAll() async {
        guard let store = appModel.store, let teamID = appModel.teamID else {
            importMessage = "Create a team in Programme first, then import this archive."
            return
        }
        isImporting = true
        defer { isImporting = false }
        var imported = 0
        for match in archive.matches {
            if (try? await store.importMatch(match.context, teamID: teamID, seasonID: appModel.seasonID))
                != nil
            {
                imported += 1
            }
        }
        importMessage =
            imported > 0
            ? "Imported \(imported) match\(imported == 1 ? "" : "es") into your library."
            : "Programme couldn't import those matches. Nothing on this iPad was changed."
        await appModel.refreshWidgetSnapshot()
    }
}
