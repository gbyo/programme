import XCTest

@testable import Programme

/// Diagnostics must never change behavior and must never carry content.
/// These tests pin both: measurement is a pure passthrough, and the state
/// vocabulary is a fixed set of coarse labels with no room for names,
/// scores, notes, or roster content.
@MainActor
final class DiagnosticsTests: XCTestCase {
    struct ProbeError: Error {}

    func testSyncMeasureReturnsWorkResult() {
        var runs = 0
        let result = ProgrammeSignposts.measure("test") {
            runs += 1
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(runs, 1, "measurement must run its work exactly once")
    }

    func testSyncMeasureRethrows() {
        XCTAssertThrowsError(
            try ProgrammeSignposts.measure("test") { throw ProbeError() }
        ) { error in
            XCTAssertTrue(error is ProbeError, "measurement must not alter errors")
        }
    }

    func testAsyncMeasureReturnsWorkResult() async {
        var runs = 0
        let result = await ProgrammeSignposts.measure("test") {
            runs += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(runs, 1, "measurement must run its work exactly once")
    }

    func testAsyncMeasureRethrows() async {
        do {
            _ = try await ProgrammeSignposts.measure("test") { throw ProbeError() }
            XCTFail("Expected ProbeError to propagate.")
        } catch is ProbeError {
            // Expected: diagnostics never swallow or rewrite failures.
        } catch {
            XCTFail("Unexpected error type: \(error).")
        }
    }

    func testWorkflowVocabularyIsFixedAndCoarse() {
        XCTAssertEqual(
            Set(WorkflowState.allCases.map(\.rawValue)),
            ["browsing", "preparingMatch", "liveScoring", "periodBreak", "finalizing"])
    }

    func testOperationVocabularyIsFixedAndCoarse() {
        XCTAssertEqual(
            Set(OperationState.allCases.map(\.rawValue)),
            ["rosterRecognition", "archiveImport", "export", "cloudSync"])
    }

    func testMetricsStartIsIdempotentAndSafe() {
        // Must be safe to call twice (app launch + tests) and must not throw.
        ProgrammeMetrics.start()
        ProgrammeMetrics.start()
    }

    func testStateReportsAreSafe() {
        // Safe on every OS: real reports where StateReporting exists, silent
        // no-ops on the iOS 26 fallback path.
        for state in WorkflowState.allCases {
            ProgrammeStateReporter.reportWorkflow(state)
        }
        for operation in OperationState.allCases {
            ProgrammeStateReporter.reportOperation(operation)
        }
        ProgrammeStateReporter.reportOperation(nil)
    }
}
