import Foundation
import Observation
import ProgrammeCore
import SwiftUI

/// The top-level destinations. Team is context, not a destination:
/// the selected team scopes what each section shows.
enum AppSection: String, Hashable, Identifiable, CaseIterable {
    case home
    case matches
    case roster
    case stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .matches: "Matches"
        case .roster: "Roster"
        case .stats: "Stats"
        }
    }

    /// Navigation title for the root of each section. Stats keeps the
    /// established "Season Stats" screen title even though the tab reads Stats.
    var rootTitle: String {
        switch self {
        case .home: "Home"
        case .matches: "Matches"
        case .roster: "Roster"
        case .stats: "Season Stats"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .matches: "calendar"
        case .roster: "person.3"
        case .stats: "chart.bar.xaxis"
        }
    }
}

/// Everything reachable inside Programme, whether from a tap or a link.
enum AppRoute: Hashable {
    case match(MatchID)
    case player(PlayerID)
    case season(SeasonID?)
    case eventLog(MatchID)
    /// The review queue for one match: the focused triage screen, not the
    /// generic detail page. Resolution still runs through the scorer.
    case review(MatchID)
}

/// Navigation state: where the user is. Persistence lookups (which team owns
/// a match/player/season) live in AppModel above this model.
@MainActor
@Observable
final class NavigationModel {
    /// Selected top-level section. Presentation (bottom tabs on iPhone,
    /// adaptable tabs/sidebar on iPad) is owned by SwiftUI.
    var section: AppSection = .home

    var homePath = NavigationPath()
    var matchesPath = NavigationPath()
    var rosterPath = NavigationPath()
    var statsPath = NavigationPath()

    /// The live scorer takes over the window rather than living in a tab.
    var isShowingLiveMatch = false
    var pendingMatchToOpen: MatchID?
    var errorToShow: ProgrammeError?
    var isPresentingNewMatch = false
    var isPresentingSettings = false
    var isPresentingManageTeams = false
    var isPresentingNewTeam = false

    func presentLiveMatch() {
        isShowingLiveMatch = true
    }

    func dismissLiveMatch() {
        isShowingLiveMatch = false
    }

    /// Clear team-specific pushed state so content from one team can never
    /// remain displayed under another. Section selection is preserved.
    func clearTeamScopedPaths() {
        homePath = NavigationPath()
        matchesPath = NavigationPath()
        rosterPath = NavigationPath()
        statsPath = NavigationPath()
    }

    func open(_ route: AppRoute) {
        switch route {
        case .match(let id):
            section = .matches
            matchesPath = NavigationPath()
            matchesPath.append(AppRoute.match(id))
        case .player(let id):
            section = .roster
            rosterPath = NavigationPath()
            rosterPath.append(AppRoute.player(id))
        case .season(let id):
            section = .stats
            statsPath = NavigationPath()
            if id != nil { statsPath.append(AppRoute.season(id)) }
        case .eventLog(let id):
            section = .matches
            matchesPath = NavigationPath()
            matchesPath.append(AppRoute.match(id))
            matchesPath.append(AppRoute.eventLog(id))
        case .review(let id):
            section = .matches
            matchesPath = NavigationPath()
            matchesPath.append(AppRoute.review(id))
        }
    }

    func path(for section: AppSection) -> Binding<NavigationPath> {
        switch section {
        case .home: Binding(get: { self.homePath }, set: { self.homePath = $0 })
        case .matches: Binding(get: { self.matchesPath }, set: { self.matchesPath = $0 })
        case .roster: Binding(get: { self.rosterPath }, set: { self.rosterPath = $0 })
        case .stats: Binding(get: { self.statsPath }, set: { self.statsPath = $0 })
        }
    }

    /// `programme://match/{uuid}`, `programme://player/{uuid}`, `programme://live`.
    /// Team-aware resolution happens in AppModel; this handles only the
    /// team-independent cases synchronously.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "programme" else { return false }
        let host = url.host()
        let identifier = url.pathComponents.first { $0 != "/" }

        switch host {
        case .none: return false
        case .some("today"), .some("home"):
            section = .home
            return true
        case .some("season"), .some("team"):
            section = .stats
            return true
        case .some("newmatch"):
            isPresentingNewMatch = true
            return true
        case .some("live"):
            if let identifier, let uuid = UUID(uuidString: identifier) {
                pendingMatchToOpen = MatchID(uuid)
            } else {
                isShowingLiveMatch = true
            }
            return true
        default:
            // match/player URLs need store lookup; AppModel handles them.
            return false
        }
    }

    static func url(for route: AppRoute) -> URL? {
        switch route {
        case .match(let id): URL(string: "programme://match/\(id.rawValue.uuidString)")
        case .player(let id): URL(string: "programme://player/\(id.rawValue.uuidString)")
        case .season: URL(string: "programme://season")
        case .eventLog(let id): URL(string: "programme://match/\(id.rawValue.uuidString)")
        case .review(let id): URL(string: "programme://review/\(id.rawValue.uuidString)")
        }
    }
}
