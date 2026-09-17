import Foundation
import Observation
import ProgrammeCore
import SwiftUI

enum SidebarDestination: String, Hashable, Identifiable, CaseIterable {
    case today
    case matches
    case roster
    case season
    case exports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .matches: "Matches"
        case .roster: "Roster"
        case .season: "Season Stats"
        case .exports: "Exports"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "sun.horizon"
        case .matches: "calendar"
        case .roster: "person.3"
        case .season: "chart.bar.xaxis"
        case .exports: "square.and.arrow.up"
        }
    }
}

/// Everything reachable inside Programme, whether from a tap or a link.
enum AppRoute: Hashable {
    case match(MatchID)
    case player(PlayerID)
    case season(SeasonID?)
    case eventLog(MatchID)
}

/// One navigation system for taps, deep links, App Intents and Spotlight.
/// Nothing navigates by reaching into a view.
@MainActor
@Observable
final class NavigationModel {
    var sidebar: SidebarDestination? = .today
    var isSidebarCollapsed = false
    var columnVisibility: NavigationSplitViewVisibility = .automatic

    var todayPath = NavigationPath()
    var matchesPath = NavigationPath()
    var rosterPath = NavigationPath()
    var seasonPath = NavigationPath()
    var exportsPath = NavigationPath()

    /// The live scorer takes over the window rather than living in a column.
    var isShowingLiveMatch = false
    var pendingMatchToOpen: MatchID?
    var errorToShow: ProgrammeError?
    var isPresentingNewMatch = false
    var isPresentingSettings = false

    func presentLiveMatch() {
        isShowingLiveMatch = true
        // Give the whole window to scoring.
        columnVisibility = .detailOnly
    }

    func dismissLiveMatch() {
        isShowingLiveMatch = false
        columnVisibility = .automatic
    }

    func open(_ route: AppRoute) {
        switch route {
        case .match(let id):
            sidebar = .matches
            matchesPath = NavigationPath()
            matchesPath.append(AppRoute.match(id))
        case .player(let id):
            sidebar = .roster
            rosterPath = NavigationPath()
            rosterPath.append(AppRoute.player(id))
        case .season(let id):
            sidebar = .season
            seasonPath = NavigationPath()
            if id != nil { seasonPath.append(AppRoute.season(id)) }
        case .eventLog(let id):
            sidebar = .matches
            matchesPath = NavigationPath()
            matchesPath.append(AppRoute.match(id))
            matchesPath.append(AppRoute.eventLog(id))
        }
    }

    func path(for destination: SidebarDestination) -> Binding<NavigationPath> {
        switch destination {
        case .today: Binding(get: { self.todayPath }, set: { self.todayPath = $0 })
        case .matches: Binding(get: { self.matchesPath }, set: { self.matchesPath = $0 })
        case .roster: Binding(get: { self.rosterPath }, set: { self.rosterPath = $0 })
        case .season: Binding(get: { self.seasonPath }, set: { self.seasonPath = $0 })
        case .exports: Binding(get: { self.exportsPath }, set: { self.exportsPath = $0 })
        }
    }

    /// `programme://match/{uuid}`, `programme://player/{uuid}`, `programme://live`.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "programme" else { return false }
        let host = url.host()
        let identifier = url.pathComponents.first { $0 != "/" }

        switch host {
        case "match":
            guard let identifier, let uuid = UUID(uuidString: identifier) else { return false }
            open(.match(MatchID(uuid)))
            return true
        case "player":
            guard let identifier, let uuid = UUID(uuidString: identifier) else { return false }
            open(.player(PlayerID(uuid)))
            return true
        case "team", "season":
            open(.season(nil))
            return true
        case "live":
            if let identifier, let uuid = UUID(uuidString: identifier) {
                pendingMatchToOpen = MatchID(uuid)
            } else {
                isShowingLiveMatch = true
            }
            return true
        case "today":
            sidebar = .today
            return true
        case "newmatch":
            isPresentingNewMatch = true
            return true
        default:
            return false
        }
    }

    static func url(for route: AppRoute) -> URL? {
        switch route {
        case .match(let id): URL(string: "programme://match/\(id.rawValue.uuidString)")
        case .player(let id): URL(string: "programme://player/\(id.rawValue.uuidString)")
        case .season: URL(string: "programme://season")
        case .eventLog(let id): URL(string: "programme://match/\(id.rawValue.uuidString)")
        }
    }
}
