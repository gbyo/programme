import Foundation
import Observation
import ProgrammePersistence
import SwiftData

/// Notices changes made to the store outside the current view — an archive
/// import, a second Programme window, the scoreboard scene — and asks the app to
/// refresh what it derives from the database.
///
/// Built on SwiftData's `HistoryObserver`, which is newer than Programme's
/// deployment target, so it is adopted behind an availability check. Programme
/// behaves identically without it: `@Query` already keeps browsing lists live,
/// and this only removes the need to refresh the widget snapshot and the
/// recovery list by hand. Nothing about scoring depends on it.
@MainActor
final class StoreChangeObserver {
    private var observer: AnyObject?
    private var onChange: (@MainActor () async -> Void)?
    private var deliveryTask: Task<Void, Never>?

    func start(container: ModelContainer, onChange: @escaping @MainActor () async -> Void) {
        guard #available(iOS 27.0, *) else { return }
        guard observer == nil else { return }
        guard
            let historyObserver = try? HistoryObserver(
                observedModels: [
                    TeamModel.self, SeasonModel.self, PlayerModel.self, MatchModel.self,
                    MatchEventModel.self,
                ],
                modelContainer: container)
        else { return }
        self.observer = historyObserver
        self.onChange = onChange
        track(historyObserver)
    }

    @available(iOS 27.0, *)
    private func track(_ historyObserver: HistoryObserver) {
        withObservationTracking {
            _ = historyObserver.eventCounter
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observer != nil else { return }

                // Observation tracking is one-shot. Re-arm immediately so
                // changes that arrive during the debounce window are not lost.
                self.track(historyObserver)

                // One logical write can touch several observed models. Coalesce
                // that burst into one derived-data refresh instead of repeating
                // widget, recovery, and search-index work for each history bump.
                self.deliveryTask?.cancel()
                self.deliveryTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                    } catch {
                        return
                    }
                    guard let self, self.observer != nil else { return }
                    await self.onChange?()
                    self.deliveryTask = nil
                }
            }
        }
    }

    func stop() {
        deliveryTask?.cancel()
        deliveryTask = nil
        observer = nil
        onChange = nil
    }
}
