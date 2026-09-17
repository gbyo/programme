import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import ProgrammeUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Roster import with a review step.
///
/// Nothing is written until the mapping is confirmed, and Programme only skips
/// the mapping step when every column was recognised without guessing.
struct RosterImportView: View {
    let initialText: String?

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var rawText = ""
    @State private var preview: RosterImportPreview?
    @State private var isShowingFileImporter = false
    @State private var isShowingScanner = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let preview {
                mappingStep(preview)
            } else {
                inputStep
            }
        }
        .navigationTitle("Import Roster")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if preview != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(preview?.players.count ?? 0)") { Task { await commit() } }
                        .disabled((preview?.players.isEmpty ?? true))
                        .fontWeight(.semibold)
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        ) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    rawText = text
                    analyze()
                } else {
                    errorMessage = "Programme couldn't read that file. Try copying the rows and pasting them instead."
                }
            case .failure:
                errorMessage = "Programme couldn't open that file."
            }
        }
        .sheet(isPresented: $isShowingScanner) {
            RosterScannerView { text in
                rawText = text
                isShowingScanner = false
                analyze()
            }
        }
        .onAppear {
            if let initialText {
                rawText = initialText
                analyze()
            }
        }
    }

    private var inputStep: some View {
        Form {
            Section {
                Button("Choose a CSV File…", systemImage: "folder") { isShowingFileImporter = true }
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Button("Scan a Printed Roster…", systemImage: "camera.viewfinder") {
                        isShowingScanner = true
                    }
                }
            } header: {
                Text("From a file")
            }

            Section {
                TextEditor(text: $rawText)
                    .frame(minHeight: 200)
                    .font(.system(.footnote, design: .monospaced))
            } header: {
                Text("Or paste a table")
            } footer: {
                Text("Copy rows from a spreadsheet and paste them here. Commas or tabs both work, and a header row is detected automatically.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Programme.Palette.caution)
                }
            }

            Section {
                Button("Continue") { analyze() }
                    .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func mappingStep(_ preview: RosterImportPreview) -> some View {
        List {
            Section {
                ForEach(Array(preview.headers.enumerated()), id: \.offset) { index, header in
                    Picker(
                        header,
                        selection: Binding(
                            get: { preview.mapping[index] ?? .ignore },
                            set: { newValue in
                                var updated = preview
                                updated.mapping[index] = newValue
                                self.preview = updated
                            })
                    ) {
                        ForEach(RosterColumn.allCases) { column in
                            Text(column.label).tag(column)
                        }
                    }
                }
            } header: {
                Text("Columns")
            } footer: {
                Text(
                    preview.mappingIsUnambiguous
                        ? "Programme recognised every column. Check the preview below and import."
                        : "Programme guessed these. Check them before importing.")
            }

            Section("Preview") {
                ForEach(preview.rows) { row in
                    HStack(spacing: 12) {
                        Image(
                            systemName: row.isSelected
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(row.isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .onTapGesture { toggle(row) }

                        if let player = preview.player(from: row) {
                            Text(player.jerseyNumber.map { "#\($0)" } ?? "—")
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(player.fullName).font(.body)
                                Text(
                                    [player.position?.label, player.classYear].compactMap(\.self)
                                        .joined(separator: " · ")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(row.problem ?? "Can't read this row")
                                .font(.subheadline)
                                .foregroundStyle(Programme.Palette.caution)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(row) }
                }
            }

            Section {
                Button("Start Over", role: .destructive) { self.preview = nil }
            }
        }
    }

    private func toggle(_ row: RosterImportRow) {
        guard var preview else { return }
        guard let index = preview.rows.firstIndex(where: { $0.id == row.id }) else { return }
        preview.rows[index].isSelected.toggle()
        self.preview = preview
    }

    private func analyze() {
        let result = RosterImporter.preview(csv: rawText)
        guard !result.rows.isEmpty else {
            errorMessage = "Programme couldn't find any rows in that. Check that each player is on their own line."
            return
        }
        errorMessage = nil
        preview = result
    }

    private func commit() async {
        guard let store = appModel.store, let teamID = appModel.teamID, let preview else { return }
        do {
            try await store.addPlayers(teamID: teamID, preview.players)
            dismiss()
        } catch {
            errorMessage = "Programme couldn't save those players. Nothing was changed. Try again."
        }
    }
}

/// Optional camera import. Programme reads the text and hands it to the same
/// review step as a CSV — the camera never writes anything directly.
struct RosterScannerView: UIViewControllerRepresentable {
    var onText: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        try? controller.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private var lines: [String] = []
        let onText: (String) -> Void

        init(onText: @escaping (String) -> Void) { self.onText = onText }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .text(let text) = item { lines.append(text.transcript) }
            }
            guard !lines.isEmpty else { return }
            onText(lines.joined(separator: "\n"))
        }
    }
}
