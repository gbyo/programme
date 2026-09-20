import Foundation
import Observation
import ProgrammePersistence
import SwiftData

/// Notices changes that aren't already described by a typed MatchStore
/// mutation and asks the app to refresh what it derives from the database.
///
/// Built on SwiftData's `HistoryObserver`, which is newer than Programme's
/// deployment target, so it is adopted behind an availability check. Programme
/// behaves identically without it: `@Query` already keeps browsing lists live,
/// and this only removes the need to refresh derived surfaces by hand.
@MainActor
final class StoreChangeObserver {
    private var observer: AnyObject?
    private var onChange: (@MainActor () async -> Void)?

    func start(container: ModelContainer, onChange: @escaping @MainActor () async -> Void) {
        guard #available(iOS 27.0, *) else { return }
        guard observer == nil else { return }
        guard let tracker = try? StoreHistoryTracker(container: container) else { return }
        observer = tracker
        self.onChange = onChange
        track(tracker)

        // Catch a transaction that lands between the initial history token
        // snapshot and observation becoming active.
        Task { @MainActor [weak self, weak tracker] in
            guard let self, let tracker, self.observer === tracker else { return }
            await self.processChanges(tracker)
        }
    }

    @available(iOS 27.0, *)
    private func track(_ tracker: StoreHistoryTracker) {
        withObservationTracking {
            _ = tracker.historyObserver.eventCounter
        } onChange: { [weak self, weak tracker] in
            Task { @MainActor [weak self, weak tracker] in
                guard let self, let tracker, self.observer === tracker else { return }
                // Re-arm before asynchronous processing so another transaction
                // cannot arrive in an observation gap.
                self.track(tracker)
                await self.processChanges(tracker)
            }
        }
    }

    @available(iOS 27.0, *)
    private func processChanges(_ tracker: StoreHistoryTracker) async {
        let needsBackstop: Bool
        do {
            needsBackstop = try tracker.hasBackstopActivity(
                excluding: ProgrammeTransactionAuthor.typedMatchStoreMutation)
        } catch {
            // History inspection is only an optimization. On failure, refresh
            // conservatively rather than risk stale derived surfaces.
            needsBackstop = true
        }
        if needsBackstop {
            await onChange?()
        }
    }

    func stop() {
        observer = nil
        onChange = nil
    }
}

@available(iOS 27.0, *)
@MainActor
private final class StoreHistoryTracker {
    let historyObserver: HistoryObserver
    private let historyContext: ModelContext
    private var token: DefaultHistoryToken?

    init(container: ModelContainer) throws {
        historyContext = ModelContext(container)

        // Establish a baseline, then start observation. StoreChangeObserver
        // immediately performs a catch-up pass after observation is armed.
        var latest = HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: nil,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        latest.fetchLimit = 1
        token = try historyContext.fetchHistory(latest).first?.token

        historyObserver = try HistoryObserver(
            observedModels: [
                TeamModel.self, SeasonModel.self, PlayerModel.self, MatchModel.self,
                MatchEventModel.self,
            ],
            modelContainer: container)
    }

    func hasBackstopActivity(excluding localTypedAuthor: String) throws -> Bool {
        let predicate: Predicate<DefaultHistoryTransaction>?
        if let token {
            predicate = #Predicate { $0.token > token }
        } else {
            predicate = nil
        }

        let descriptor = HistoryDescriptor<DefaultHistoryTransaction>(predicate: predicate)
        let transactions = try historyContext.fetchHistory(descriptor)
        if let latest = transactions.last {
            token = latest.token
        }

        return transactions.contains { transaction in
            transaction.author != localTypedAuthor
        }
    }
}
