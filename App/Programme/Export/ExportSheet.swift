import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import ProgrammeUI
import SwiftUI

/// A produced file, held on disk so it can be shared, saved or previewed.
struct GeneratedExport: Identifiable, Hashable {
    let id = UUID()
    var exporterID: String
    var name: String
    var detail: String
    var symbolName: String
    var url: URL
    var byteCount: Int
}

/// Choose formats, generate them, then share.
///
/// Exports are always user-initiated. Nothing leaves the iPad on its own.
struct ExportSheet: View {
    let payload: ExportPayload
    let exporters: [any StatExporter]

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var generated: [GeneratedExport] = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(exporters, id: \.id) { exporter in
                    Button {
                        toggle(exporter.id)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: selection.contains(exporter.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(
                                    selection.contains(exporter.id)
                                        ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            Image(systemName: exporter.symbolName)
                                .frame(width: 24)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exporter.name).font(.body.weight(.medium))
                                Text(exporter.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Formats")
            } footer: {
                Text(
                    "Categories this match didn't track are written as blanks, not zeros, so nothing you never recorded is published as a number."
                )
            }

            if !generated.isEmpty {
                Section("Ready to Share") {
                    ForEach(generated) { file in
                        HStack(spacing: 14) {
                            Image(systemName: file.symbolName)
                                .frame(width: 24)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.body.weight(.medium))
                                Text("\(file.url.lastPathComponent) · \(byteText(file.byteCount))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: file.url) {
                                Image(systemName: "square.and.arrow.up")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if generated.count > 1 {
                        ShareLink(items: generated.map(\.url)) {
                            Label("Share All \(generated.count) Files", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .programmePrimaryAction()
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Programme.Palette.caution)
                }
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isWorking ? "Preparing…" : "Prepare") { generate() }
                    .disabled(selection.isEmpty || isWorking)
                    .fontWeight(.semibold)
            }
        }
        .onAppear {
            if selection.isEmpty, let first = exporters.first { selection = [first.id] }
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func generate() {
        isWorking = true
        errorMessage = nil
        var results: [GeneratedExport] = []
        var failures: [String] = []

        for exporter in exporters where selection.contains(exporter.id) {
            do {
                let data = try exporter.export(payload)
                let directory = FileManager.default.temporaryDirectory
                    .appending(path: "ProgrammeExports", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appending(path: exporter.filename(for: payload))
                try data.write(to: url, options: .atomic)
                results.append(
                    GeneratedExport(
                        exporterID: exporter.id, name: exporter.name, detail: exporter.detail,
                        symbolName: exporter.symbolName, url: url, byteCount: data.count))
            } catch {
                failures.append(exporter.name)
            }
        }

        generated = results
        isWorking = false
        if !failures.isEmpty {
            // Never imply data loss: the match is untouched by a failed export.
            errorMessage =
                "Programme couldn't create \(failures.joined(separator: " and ")). Your match is safe. Try exporting again."
        }
    }

    private func byteText(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// The Exports destination: recent files, archive import, and a season backup.
struct ExportsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var contexts: [MatchContext] = []
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var importResult: ImportOutcome?
    @State private var isTargeted = false

    struct ImportOutcome: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var isError: Bool
    }

    var body: some View {
        List {
            Section {
                Button {
                    isExporting = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export Season").font(.body.weight(.medium))
                            Text("\(contexts.count) finalized matches · CSV, stat sheet, PDF, archive")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(contexts.isEmpty)

                Button {
                    isImporting = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import a Programme Archive").font(.body.weight(.medium))
                            Text("Restore matches from a .programme file")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            } header: {
                Text("Backup and Transfer")
            } footer: {
                Text(
                    "A Programme archive contains everything needed to rebuild a match — events, roster, configuration and revision history — independently of this iPad."
                )
            }

            Section("MaxPreps") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Programme exports a MaxPreps Entry Summary")
                        .font(.body.weight(.medium))
                    Text(
                        "It lists your players in jersey order using MaxPreps' own stat names, so Team Admin entry is a straight transcription. Programme does not connect to MaxPreps or scrape it, and it never invents an integration that doesn't exist."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Exports")
        .dropDestination(for: ProgrammeArchiveTransfer.self) { items, _ in
            guard let item = items.first else { return false }
            Task { await importArchive(item.archive) }
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $isExporting) {
            NavigationStack {
                ExportSheet(
                    payload: ExportPayload(
                        teamName: appModel.teamName, teamShortName: appModel.teamShortName,
                        contexts: contexts),
                    exporters: ProgrammeExporters.all)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.programmeArchive, .json]) { result in
            switch result {
            case .success(let url):
                Task { await importFile(at: url) }
            case .failure:
                importResult = ImportOutcome(
                    title: "Couldn't open that file",
                    message: "Programme couldn't read the file you chose. Nothing was changed.",
                    isError: true)
            }
        }
        .alert(item: $importResult) { outcome in
            Alert(
                title: Text(outcome.title), message: Text(outcome.message),
                dismissButton: .default(Text("OK")))
        }
        .task { await load() }
    }

    private func load() async {
        guard let store = appModel.store, let teamID = appModel.teamID else { return }
        let items = (try? await store.matches(teamID: teamID)) ?? []
        var loaded: [MatchContext] = []
        for item in items where item.phase == .finalized {
            if let context = try? await store.context(for: item.id) { loaded.append(context) }
        }
        contexts = loaded.sorted { $0.descriptor.kickoff < $1.descriptor.kickoff }
    }

    private func importFile(at url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let archive = try ProgrammeArchiveCoder.decode(data)
            await importArchive(archive)
        } catch let error as ArchiveError {
            importResult = ImportOutcome(
                title: "Couldn't import that archive", message: error.message, isError: true)
        } catch {
            importResult = ImportOutcome(
                title: "Couldn't read that file",
                message: "Programme couldn't read the archive. Nothing on this iPad was changed.",
                isError: true)
        }
    }

    private func importArchive(_ archive: ProgrammeArchive) async {
        guard let store = appModel.store, let teamID = appModel.teamID else {
            importResult = ImportOutcome(
                title: "Create a team first",
                message: "Programme needs a team to import matches into.", isError: true)
            return
        }
        var imported = 0
        for match in archive.matches {
            if (try? await store.importMatch(match.context, teamID: teamID, seasonID: appModel.seasonID)) != nil {
                imported += 1
            }
        }
        await load()
        await appModel.refreshWidgetSnapshot()
        importResult = ImportOutcome(
            title: imported > 0 ? "Imported" : "Nothing imported",
            message: imported > 0
                ? "\(imported) match\(imported == 1 ? "" : "es") from \(archive.manifest.teamName) are now in your library."
                : "That archive didn't contain any matches Programme could read.",
            isError: imported == 0)
    }
}
