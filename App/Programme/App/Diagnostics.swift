import Foundation
import MetricKit
import OSLog
import StateReporting
import os

/// On-device performance and state diagnostics.
///
/// Everything here is local and non-identifying: signpost intervals carry only
/// fixed operation names, MetricKit reports are logged to the unified log and
/// never uploaded anywhere, and StateReporting labels are coarse workflow
/// states with no names, scores, notes, or roster content.
///
/// Diagnostics are never a dependency of scoring. Every measurement wrapper
/// runs its work inline and returns (or rethrows) exactly what the work
/// produced, so removing diagnostics could never change match behavior.
enum ProgrammeSignposts {
    private static let signposter = OSSignposter(subsystem: "com.gbyo.programme", category: "scoring")

    /// Runs `work` inside a signpost interval named `name`.
    ///
    /// `name` is a `StaticString` on purpose: interval names are compile-time
    /// constants, so match content can never leak into an interval.
    /// Main-actor bound: every call site is UI or session code, and binding the
    /// closure to the same isolation avoids sending MainActor state across
    /// domains just to time it.
    @discardableResult
    @MainActor
    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        try signposter.withIntervalSignpost(name) { try work() }
    }

    @discardableResult
    @MainActor
    static func measure<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        // OSSignposter only offers a scoped sync helper; async work holds the
        // interval open manually across its awaits.
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await work()
    }
}

/// Coarse workflow states reported through StateReporting. Fixed vocabulary:
/// adding a state here is a deliberate product decision, never a data field.
enum WorkflowState: String, Sendable, CaseIterable {
    case browsing
    case preparingMatch
    case liveScoring
    case periodBreak
    case finalizing
}

/// Coarse one-shot operations reported through StateReporting while running.
enum OperationState: String, Sendable, CaseIterable {
    case rosterRecognition
    case archiveImport
    case export
    case cloudSync
}

/// StateReporting is iOS 27+. All access goes through this boundary, which is
/// a silent no-op on iOS 26 — the complete fallback is simply "no state
/// reports", with signposts and MetricKit still working there.
enum ProgrammeStateReporter {
    static func reportWorkflow(_ state: WorkflowState) {
        if #available(iOS 27, *) {
            ModernDiagnostics.reportWorkflow(state)
        }
    }

    static func reportOperation(_ state: OperationState?) {
        if #available(iOS 27, *) {
            ModernDiagnostics.reportOperation(state)
        }
    }
}

@available(iOS 27, *)
private enum ModernDiagnostics {
    static let workflowReporter: StateReporter<Never, Never> = .reporter(for: "programme.workflow")
    static let operationReporter: StateReporter<Never, Never> = .reporter(for: "programme.operation")
    static let metricManager = MetricManager(enabledStateReportingDomains: [
        "programme.workflow", "programme.operation",
    ])

    static func reportWorkflow(_ state: WorkflowState) {
        workflowReporter.reportTransition(to: state.rawValue)
    }

    static func reportOperation(_ state: OperationState?) {
        operationReporter.reportTransition(to: state?.rawValue)
    }

    static func startMetricCollection() {
        Task {
            for await _ in metricManager.metricReports {
                ProgrammeMetrics.recordedMetricReport()
            }
        }
        Task {
            for await _ in metricManager.diagnosticReports {
                ProgrammeMetrics.recordedDiagnosticReport()
            }
        }
    }
}

/// MetricKit collection. Reports stay on the device: they are counted into
/// the unified log and never uploaded unless a later product decision adds an
/// explicit upload path.
/// One-shot launch guard. All state changes happen under the lock, which is
/// the documented invariant behind `@unchecked Sendable`.
private final class LaunchGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

enum ProgrammeMetrics {
    private static let log = Logger(subsystem: "com.gbyo.programme", category: "diagnostics")
    private static let launchGuard = LaunchGuard()

    /// Called once from `ProgrammeApp.init`, next to the other launch-time
    /// registrations. Safe to call again from any thread; the second call
    /// does nothing.
    static func start() {
        guard launchGuard.claim() else { return }
        ProgrammeStateReporter.reportWorkflow(.browsing)
        if #available(iOS 27, *) {
            ModernDiagnostics.startMetricCollection()
        } else {
            MXMetricManager.shared.add(legacySubscriber)
        }
    }

    /// MXMetricManager keeps a weak reference to its subscribers, so this is
    /// held statically for the life of the process.
    private static let legacySubscriber = LegacyMetricsSubscriber()

    fileprivate static func recordedMetricReport() {
        log.debug("MetricKit delivered a metric report; kept on-device.")
    }

    fileprivate static func recordedDiagnosticReport() {
        log.debug("MetricKit delivered a diagnostic report; kept on-device.")
    }

    fileprivate static var legacyLog: Logger { log }
}

/// iOS 26 fallback: the depot `MXMetricManager` subscriber API. Deprecated in
/// favor of `MetricManager`, which does not exist on iOS 26 — this branch is
/// the complete fallback there, not a migration leftover.
///
/// Stateless apart from logging (Logger is Sendable and this class holds no
/// mutable state), so cross-queue MetricKit delivery is safe. That is the
/// documented invariant behind `@unchecked Sendable`.
private final class LegacyMetricsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    func didReceive(_ payloads: [MXMetricPayload]) {
        ProgrammeMetrics.legacyLog.debug(
            "MetricKit delivered \(payloads.count) metric payload(s); kept on-device.")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        ProgrammeMetrics.legacyLog.debug(
            "MetricKit delivered \(payloads.count) diagnostic payload(s); kept on-device.")
    }
}
