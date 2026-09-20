import Foundation
import Testing

@testable import ProgrammeCore
@testable import ProgrammeExport

/// Deterministic stub exporter. A struct with value configuration stays
/// `Sendable`; the gate lets the cancellation test block one export until
/// the task is cancelled.
private struct StubExporter: StatExporter, Sendable {
    var id: String
    var name: String
    var fileExtension: String = "txt"
    var contentTypeIdentifier: String = "public.plain-text"
    var symbolName: String = "doc"
    var fails: Bool = false
    var gate: (@Sendable () -> Void)?

    var detail: String { "\(name) stub" }

    func export(_ payload: ExportPayload) throws -> Data {
        gate?()
        if fails { throw CocoaError(.fileWriteUnknown) }
        return Data("\(id):\(payload.teamName)".utf8)
    }
}

@Suite("ExportRunner prepares multi-format batches off the main actor")
struct ExportRunnerTests {
    private var payload: ExportPayload {
        ExportPayload(
            teamName: ProgrammeSample.teamName,
            teamShortName: ProgrammeSample.teamShortName,
            seasonName: "2027",
            contexts: [ProgrammeSample.completedContext()])
    }

    @Test("Selected formats produce files in exporter order")
    func selectedFormatsInOrder() throws {
        let exporters: [any StatExporter] = [
            StubExporter(id: "b", name: "Beta"),
            StubExporter(id: "a", name: "Alpha"),
            StubExporter(id: "c", name: "Gamma"),
        ]
        let result = try #require(
            ExportRunner.prepare(
                exporters: exporters, selecting: ["a", "b", "c"], payload: payload))

        #expect(result.prepared.map(\.exporterID) == ["b", "a", "c"])
        #expect(result.failedExporterNames.isEmpty)
        for file in result.prepared {
            let exporter = try #require(exporters.first(where: { $0.id == file.exporterID }))
            let expected = try exporter.export(payload)
            #expect(try Data(contentsOf: file.url) == expected)
            #expect(file.byteCount == expected.count)
        }
    }

    @Test("Unselected formats are skipped")
    func unselectedSkipped() {
        let exporters: [any StatExporter] = [
            StubExporter(id: "a", name: "Alpha"),
            StubExporter(id: "b", name: "Beta"),
        ]
        let result = ExportRunner.prepare(
            exporters: exporters, selecting: ["b"], payload: payload)

        #expect(result?.prepared.map(\.exporterID) == ["b"])
        #expect(result?.failedExporterNames.isEmpty == true)
    }

    @Test("One failing format still produces the rest")
    func partialSuccess() {
        let exporters: [any StatExporter] = [
            StubExporter(id: "a", name: "Alpha"),
            StubExporter(id: "bad", name: "Broken", fails: true),
            StubExporter(id: "c", name: "Gamma"),
        ]
        let result = ExportRunner.prepare(
            exporters: exporters, selecting: ["a", "bad", "c"], payload: payload)

        #expect(result?.prepared.map(\.exporterID) == ["a", "c"])
        #expect(result?.failedExporterNames == ["Broken"])
    }

    @Test("A cancelled batch reports nothing")
    func cancellationAborts() async {
        let gate = LockedGate()
        let exporters: [any StatExporter] = [
            StubExporter(id: "a", name: "Alpha", gate: { gate.wait() })
        ]
        let payload = self.payload
        let task = Task.detached {
            ExportRunner.prepare(exporters: exporters, selecting: ["a"], payload: payload)
        }
        // Either the batch has not started and the first check catches the
        // flag, or it is blocked in the stub and the next check does. The
        // gate only ever opens after cancellation either way.
        task.cancel()
        gate.open()
        #expect(await task.value == nil)
    }
}

/// A gate the cancellation test opens only after cancelling, so the batch
/// cannot finish first no matter how the task is scheduled.
private final class LockedGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}
