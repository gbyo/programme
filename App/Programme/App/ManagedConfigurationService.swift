import Foundation
import ManagedApp
import Observation
import ProgrammeCore

/// Observes MDM-delivered app configuration, if any.
///
/// `ManagedAppConfigurationProvider` yields nil on unmanaged devices, so
/// this service rests at `.unmanaged` and MDM is never required. Updates
/// arrive while the app runs; consumers read `configuration` directly.
@MainActor
@Observable
final class ManagedConfigurationService {
    var configuration = ManagedProgrammeConfiguration.unmanaged
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { await observe() }
    }

    private func observe() async {
        let provider = ManagedAppConfigurationProvider()
        for await delivered in await provider.configurations(
            ManagedProgrammeConfiguration.self)
        {
            configuration = delivered ?? .unmanaged
        }
    }
}
