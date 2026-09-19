import PhotosUI
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
    let teamID: TeamID
    let initialText: String?

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var rawText = ""
    @State private var preview: RosterImportPreview?
    @State private var isShowingFileImporter = false
    @State private var isShowingScanner = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isRecognizingPhoto = false
    @State private var isInterpreting = false
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
                Button("Choose CSV or Text File…", systemImage: "folder") { isShowingFileImporter = true }
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    rawText = text
                    analyze()
                }
                if appModel.managed.configuration.isAutomatedRosterExtractionAllowed {
                    if RosterInterpreter.isAvailable {
                        Button("Interpret with On-Device Model…", systemImage: "apple.intelligence") {
                            Task { await interpretWithModel() }
                        }
                        .disabled(
                            rawText.isEmpty || isInterpreting
                                || !RosterInterpreter.isLocaleSupported)
                        if !RosterInterpreter.isLocaleSupported {
                            Text(
                                "Model-assisted import doesn't support this device's language yet. File and paste still work."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else if let reason = RosterInterpreter.unavailabilityMessage {
                        Text("\(reason) File and paste import still work.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if appModel.managed.configuration.isAutomatedRosterExtractionAllowed {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button("Scan a Printed Roster…", systemImage: "camera.viewfinder") {
                            isShowingScanner = true
                        }
                    }
                    PhotosPicker(
                        selection: $photoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label("Choose Photo or Screenshot…", systemImage: "photo")
                    }
                    .disabled(isRecognizingPhoto)
                } else {
                    Label(
                        "Camera and photo import are disabled by this device's management. File and paste still work.",
                        systemImage: "lock.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                if isRecognizingPhoto {
                    HStack {
                        ProgressView()
                        Text("Reading photo…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Import")
            }

            Section {
                TextEditor(text: $rawText)
                    .frame(minHeight: 200)
                    .font(.system(.footnote, design: .monospaced))
            } header: {
                Text("Or paste a table")
            } footer: {
                Text(
                    "Copy rows from a spreadsheet and paste them here. Commas or tabs both work, and a header row is detected automatically."
                )
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
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await loadPhoto(from: item) }
        }
    }

    /// Loads only the photo the person picked (PhotosPicker grants access to
    /// that single item — never the whole library) and recognizes roster
    /// text into the same review pipeline as every other source. A failure
    /// leaves all existing state untouched: the roster changes only when a
    /// preview is confirmed below.
    private func loadPhoto(from item: PhotosPickerItem) async {
        isRecognizingPhoto = true
        errorMessage = nil
        ProgrammeStateReporter.reportOperation(.rosterRecognition)
        defer {
            isRecognizingPhoto = false
            ProgrammeStateReporter.reportOperation(nil)
        }
        let data: Data?
        do {
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            errorMessage =
                "Programme couldn't load that photo. Nothing was changed — if it lives in iCloud, check the connection and try again."
            return
        }
        guard let data else {
            errorMessage =
                "Programme couldn't load that photo. Nothing was changed — try a different image."
            return
        }
        do {
            rawText = try await RosterPhotoRecognizer.recognizeText(in: data)
            analyze()
        } catch let failure as RosterPhotoRecognizer.Failure {
            errorMessage = failure.errorDescription
        } catch {
            errorMessage =
                "Programme couldn't read that photo. Nothing was changed — try a clearer image."
        }
    }

    private func mappingStep(_ preview: RosterImportPreview) -> some View {
        List(selection: selectedRows) {
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
                    .selectionDisabled()
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
                    .tag(row.id)
                }
            }

            Section {
                Button("Start Over", role: .destructive) { self.preview = nil }
                    .selectionDisabled()
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    private var selectedRows: Binding<Set<UUID>> {
        Binding(
            get: { Set(preview?.rows.filter(\.isSelected).map(\.id) ?? []) },
            set: { selection in
                guard var preview else { return }
                for index in preview.rows.indices {
                    preview.rows[index].isSelected = selection.contains(preview.rows[index].id)
                }
                self.preview = preview
            })
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

    /// Optional on-device interpretation. Its output lands in the same
    /// review step as every other import and is never written directly.
    /// Interprets a snapshot of the current text. The input stays editable
    /// while the model runs; if the text changed underneath (paste, scan,
    /// edit), the stale result is quietly discarded instead of replacing
    /// the newer preview. Cancelled and superseded runs never write.
    private func interpretWithModel() async {
        // Below-the-UI enforcement: the button hides under this policy,
        // but execution refuses too.
        guard appModel.managed.configuration.isAutomatedRosterExtractionAllowed else {
            return
        }
        guard RosterInterpreter.isLocaleSupported else {
            errorMessage =
                "Model-assisted import doesn't support this device's language. The rule-based import still works."
            return
        }
        let source = rawText
        isInterpreting = true
        defer { isInterpreting = false }
        do {
            let result = try await RosterInterpreter.interpret(source)
            // The text moved on while the model worked: drop this result.
            guard source == rawText else { return }
            guard !result.rows.isEmpty else {
                errorMessage = "The on-device model found no players in that."
                return
            }
            errorMessage = nil
            preview = result
        } catch {
            // A late failure after an edit is also stale, not an error.
            guard source == rawText else { return }
            errorMessage =
                "The on-device model couldn't read that. The rule-based import still works."
        }
    }

    private func commit() async {
        guard let store = appModel.store, let preview else { return }
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
