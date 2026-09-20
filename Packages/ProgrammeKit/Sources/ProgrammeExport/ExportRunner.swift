import Foundation

/// One export file produced by `ExportRunner`, ready to publish on the main
/// actor. All file-system work happens inside the runner, so the caller only
/// moves values across the concurrency boundary.
public struct PreparedExport: Sendable {
    public var exporterID: String
    public var name: String
    public var detail: String
    public var symbolName: String
    public var url: URL
    public var byteCount: Int

    public init(
        exporterID: String, name: String, detail: String, symbolName: String, url: URL, byteCount: Int
    ) {
        self.exporterID = exporterID
        self.name = name
        self.detail = detail
        self.symbolName = symbolName
        self.url = url
        self.byteCount = byteCount
    }
}

public struct ExportBatchResult: Sendable {
    /// Files in exporter order. A failed format leaves no file behind.
    public var prepared: [PreparedExport]
    /// Names of formats that failed, in exporter order. Exporting never
    /// touches the match, so a failure only ever costs the file.
    public var failedExporterNames: [String]
}

/// Generates export files off the main actor.
///
/// The input is an immutable `Sendable` payload and the output is values, so
/// no SwiftUI state crosses the boundary in either direction. Formats run
/// sequentially in exporter order, preserving today's deterministic output,
/// and one format failing still produces the rest. Returns `nil` when the
/// enclosing task is cancelled.
public enum ExportRunner {
    public static func prepare(
        exporters: [any StatExporter],
        selecting ids: Set<String>,
        payload: ExportPayload,
        directory: URL = FileManager.default.temporaryDirectory.appending(
            path: "ProgrammeExports", directoryHint: .isDirectory)
    ) -> ExportBatchResult? {
        let selected = exporters.filter { ids.contains($0.id) }
        guard !selected.isEmpty else {
            return ExportBatchResult(prepared: [], failedExporterNames: [])
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ExportBatchResult(
                prepared: [],
                failedExporterNames: selected.map(\.name))
        }
        var prepared: [PreparedExport] = []
        var failed: [String] = []
        for exporter in selected {
            guard !Task.isCancelled else { return nil }
            do {
                let data = try exporter.export(payload)
                let url = directory.appending(path: exporter.filename(for: payload))
                try data.write(to: url, options: .atomic)
                prepared.append(
                    PreparedExport(
                        exporterID: exporter.id, name: exporter.name, detail: exporter.detail,
                        symbolName: exporter.symbolName, url: url, byteCount: data.count))
            } catch {
                failed.append(exporter.name)
            }
        }
        guard !Task.isCancelled else { return nil }
        return ExportBatchResult(prepared: prepared, failedExporterNames: failed)
    }
}
