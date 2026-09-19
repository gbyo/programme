import Foundation
import ManagedApp
import Observation
import ProgrammeCore

extension Notification.Name {
    /// Posted on the main actor whenever the MDM-delivered configuration
    /// changes while the app runs. The notification carries no values —
    /// observers re-read `ManagedConfigurationService.configuration`.
    /// Values are never posted because managed payloads can name teams and
    /// policies that should not fan out through NotificationCenter.
    static let managedConfigurationChanged = Notification.Name(
        "com.gbyo.programme.managedConfigurationChanged")
}

/// Observes MDM-delivered app configuration, if any.
///
/// `ManagedAppConfigurationProvider` yields nil on unmanaged devices, so
/// this service rests at `.unmanaged` and MDM is never required. Updates
/// arrive while the app runs; consumers read `configuration` directly.
///
/// Bootstrap awaits the initial value via
/// `startAndAwaitInitialConfiguration()` so the first automatic team
/// selection sees the MDM suggestion instead of persisting a fallback first.
/// Apple documents that `configurations` yields the current configuration
/// immediately when iteration begins, so awaiting the first element does
/// not stall launch; suspension frees the actor while waiting.
@MainActor
@Observable
final class ManagedConfigurationService {
    var configuration = ManagedProgrammeConfiguration.unmanaged
    private var started = false

    /// Fire-and-forget observation for previews and surfaces that never
    /// gate a first automatic selection on management.
    func start() {
        Task { await startAndAwaitInitialConfiguration() }
    }

    /// Starts observation and returns once the initial managed value has
    /// been applied. Later updates keep arriving through `configuration`
    /// and the change notification.
    func startAndAwaitInitialConfiguration() async {
        guard !started else { return }
        started = true
        let provider = ManagedAppConfigurationProvider()
        let configs = await provider.configurations(ManagedProgrammeConfiguration.self)
        var iterator = configs.makeAsyncIterator()
        // The sequence documents `Never` as its failure; the `try` only
        // satisfies the `AsyncIteratorProtocol` requirement.
        if let first = try? await iterator.next() {
            configuration = first ?? .unmanaged
        }
        Task { await observe() }
    }

    private func observe() async {
        let provider = ManagedAppConfigurationProvider()
        for await delivered in await provider.configurations(
            ManagedProgrammeConfiguration.self)
        {
            configuration = delivered ?? .unmanaged
            NotificationCenter.default.post(name: .managedConfigurationChanged, object: nil)
        }
    }
}
