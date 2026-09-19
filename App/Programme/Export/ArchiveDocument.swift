import Foundation
import ProgrammeCore
import ProgrammeExport
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Programme's Info.plist as an exported type.
    static let programmeArchive = UTType(exportedAs: "com.gbyo.programme.archive")
}

/// Programme's portable archive as a Transferable value.
///
/// This is what makes `.programme` files behave like first-class documents: they
/// drag between apps, AirDrop, attach to mail and drop back onto Programme to be
/// imported. Available on every version Programme supports.
struct ProgrammeArchiveTransfer: Transferable, Sendable {
    var filename: String
    var archive: ProgrammeArchive

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .programmeArchive) { value in
            let url = FileManager.default.temporaryDirectory
                .appending(path: "\(value.filename).programme")
            try ProgrammeArchiveCoder.encode(value.archive).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        } importing: { received in
            let data = try Data(contentsOf: received.file)
            return ProgrammeArchiveTransfer(
                filename: received.file.deletingPathExtension().lastPathComponent,
                archive: try ProgrammeArchiveCoder.decode(data))
        }
        .suggestedFileName { $0.filename }
    }
}

// MARK: - SwiftUI Document

/// Programme archives as a SwiftUI document.
///
/// Built on the current `Document` protocol rather than the deprecated
/// `FileDocument`, so it is gated to the release that introduced it. Everything
/// about scoring, exporting and importing works without it — this only adds the
/// system document experience for opening a `.programme` file straight from
/// Files on a newer iPadOS.
@available(iOS 27.0, *)
struct ProgrammeArchiveReader: DocumentReader {
    typealias Source = URL
    typealias Snapshot = ProgrammeArchive

    func read(from source: sending URL, progress: consuming Subprogress) async throws
        -> sending ProgrammeArchive
    {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        return try ProgrammeArchiveCoder.decode(data)
    }
}

@available(iOS 27.0, *)
struct ProgrammeArchiveWriter: DocumentWriter {
    typealias Destination = URL
    typealias Snapshot = ProgrammeArchive

    func write(
        snapshot: sending ProgrammeArchive, to destination: sending URL,
        previous: sending ProgrammeArchive?, progress: consuming Subprogress
    ) async throws {
        let data = try ProgrammeArchiveCoder.encode(snapshot)
        try data.write(to: destination, options: .atomic)
    }
}

@available(iOS 27.0, *)
@Observable
final class ProgrammeArchiveDocument: Document {
    var archive: ProgrammeArchive

    init(archive: ProgrammeArchive = ProgrammeArchive(contexts: [], teamName: "Programme")) {
        self.archive = archive
    }

    static var readableContentTypes: [UTType] { [.programmeArchive] }
    static var writableContentTypes: [UTType] { [.programmeArchive] }

    func reader(configuration: sending ReadConfiguration) -> sending ProgrammeArchiveReader {
        ProgrammeArchiveReader()
    }

    func writer(configuration: sending WriteConfiguration) -> sending ProgrammeArchiveWriter {
        ProgrammeArchiveWriter()
    }

    @MainActor
    func apply(snapshot: sending ProgrammeArchive, previous: sending ProgrammeArchive?) async throws {
        archive = snapshot
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending ProgrammeArchive {
        archive
    }
}
