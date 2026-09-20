import ProgrammeCore
import SwiftUI

/// Programme's shell.
///
/// Browsing is one adaptive `TabView`: SwiftUI renders a bottom tab bar on
/// iPhone and an adaptable tab/sidebar presentation on iPad. The live scorer
/// replaces the whole browsing shell while a match is being scored.
struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCreatingTeam = false

    var body: some View {
        @Bindable var navigation = appModel.navigation

        Group {
            if let session = appModel.liveSession, navigation.isShowingLiveMatch {
                LiveMatchView(session: session)
                    .transition(.opacity)
            } else if appModel.workspace.selectedTeamID == nil {
                firstRun
            } else {
                tabShell
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: navigation.isShowingLiveMatch)
        .alert(
            navigation.errorToShow?.title ?? "",
            isPresented: Binding(
                get: { navigation.errorToShow != nil },
                set: { if !$0 { navigation.errorToShow = nil } }),
            presenting: navigation.errorToShow
        ) { _ in
            Button("OK", role: .cancel) { navigation.errorToShow = nil }
        } message: { error in
            Text(error.message)
        }
        .sheet(isPresented: $navigation.isPresentingNewMatch) {
            if let teamID = appModel.workspace.selectedTeamID {
                NewMatchView(teamID: teamID)
            }
        }
        .sheet(isPresented: $navigation.isPresentingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $navigation.isPresentingManageTeams) {
            NavigationStack { ManageTeamsView(presentation: .sheet) }
        }
        .sheet(isPresented: $navigation.isPresentingNewTeam) {
            NavigationStack { TeamSetupView() }
        }
        .sheet(isPresented: $isCreatingTeam) {
            NavigationStack { TeamSetupView(onCreated: nil) }
        }
        .task(id: navigation.pendingMatchToOpen) {
            guard let matchID = navigation.pendingMatchToOpen else { return }
            navigation.pendingMatchToOpen = nil
            await appModel.openLiveSession(matchID: matchID)
        }
    }

    private var firstRun: some View {
        FirstRunView(isCreatingTeam: $isCreatingTeam)
    }

    /// Four fixed sections. Each keeps its own NavigationStack/NavigationPath
    /// so switching tabs preserves where the person was; switching teams
    /// clears team-specific paths.
    private var tabShell: some View {
        @Bindable var navigation = appModel.navigation

        return TabView(selection: $navigation.section) {
            Tab(AppSection.home.title, systemImage: AppSection.home.symbolName, value: AppSection.home) {
                sectionStack(for: .home)
            }
            Tab(
                AppSection.matches.title, systemImage: AppSection.matches.symbolName,
                value: AppSection.matches
            ) {
                sectionStack(for: .matches)
            }
            Tab(AppSection.roster.title, systemImage: AppSection.roster.symbolName, value: AppSection.roster) {
                sectionStack(for: .roster)
            }
            Tab(AppSection.stats.title, systemImage: AppSection.stats.symbolName, value: AppSection.stats) {
                sectionStack(for: .stats)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarBottomBar {
            // Workspace context, not a fifth destination: the team scopes
            // every tab, so it sits pinned in the sidebar's bottom
            // workspace area. The bottom bar only appears when the TabView
            // shows a sidebar, and owns its own spacing — no manual
            // padding, backgrounds, or selected-state chrome.
            SidebarTeamSwitcher()
                .accessibilityIdentifier("sidebar.teamSwitcher")
        }
        .id(appModel.workspace.selectedTeamID)
    }

    @ViewBuilder
    private func sectionStack(for section: AppSection) -> some View {
        @Bindable var navigation = appModel.navigation
        NavigationStack(path: navigation.path(for: section)) {
            sectionRoot(for: section)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .match(let id): MatchDetailView(matchID: id)
                    case .player(let id): PlayerDetailView(playerID: id)
                    case .season(let id):
                        if let teamID = appModel.workspace.selectedTeamID {
                            SeasonStatsView(teamID: teamID, seasonID: id)
                        }
                    case .eventLog(let id): MatchEventLogScreen(matchID: id)
                    }
                }
        }
    }

    @ViewBuilder
    private func sectionRoot(for section: AppSection) -> some View {
        if let teamID = appModel.workspace.selectedTeamID {
            switch section {
            case .home: HomeView(teamID: teamID)
            case .matches: MatchesView(teamID: teamID)
            case .roster: RosterView(teamID: teamID)
            case .stats:
                SeasonStatsView(
                    teamID: teamID, seasonID: appModel.workspace.viewedStatsSeasonID)
            }
        }
    }
}

/// Native team switching. Team is workspace context, not a destination, and
/// each adaptive presentation gets the interaction that fits its space —
/// all driven by `tabBarPlacement`, which tells content how the TabView is
/// currently represented. Used at the root of each section.
struct TeamSwitcherTitle: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.tabBarPlacement) private var tabBarPlacement
    let sectionTitle: String

    private var teamName: String { appModel.workspace.selectedTeam?.name ?? "" }

    @ViewBuilder
    func body(content: Content) -> some View {
        if tabBarPlacement == .sidebar {
            // The sidebar bottom bar owns team switching; the navigation
            // bar carries only the section title with default title
            // behavior.
            content
                .navigationTitle(sectionTitle)
        } else if tabBarPlacement == .topBar {
            // Collapsed iPad top bar: the adaptive tabs and section actions
            // already fill the bar, so team switching is a compact
            // icon-only Menu. Default title behavior otherwise.
            content
                .navigationTitle(sectionTitle)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        TopBarTeamSwitcher()
                    }
                }
        } else {
            // Bottom tabs, nil, and any other placement: the native title
            // context pattern. `navigationSubtitle` is the documented place
            // for context alongside a title, and `toolbarTitleMenu` opens
            // from a tap on that title — destination on top, workspace
            // beneath it. Default display mode lets SwiftUI own the
            // large-to-compact scroll transition.
            content
                .navigationTitle(sectionTitle)
                .navigationSubtitle(teamName)
                .toolbarTitleMenu {
                    TeamSwitcherMenu()
                }
        }
    }
}

extension View {
    func teamWorkspaceTitle(_ title: String) -> some View {
        modifier(TeamSwitcherTitle(sectionTitle: title))
    }
}

/// Sidebar workspace switcher: a native Label-style Menu (icon, one
/// truncated line, native menu indicator) so the pinned bottom item reads
/// as interactive, not passive text. Presentation-only; `TeamSwitcherMenu`
/// owns the entries. VoiceOver hears the team name as a menu plus the
/// switch hint. The soccerball symbol is the workspace mark: it is already
/// used for the first-run identity and stays distinct from the Home,
/// Matches, Roster, and Stats destination icons.
struct SidebarTeamSwitcher: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Menu {
            TeamSwitcherMenu()
        } label: {
            Label(
                appModel.workspace.selectedTeam?.name ?? "Programme",
                systemImage: "soccerball"
            )
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .menuIndicator(.visible)
        .accessibilityHint("Switch team")
    }
}

/// Collapsed-top-bar workspace switcher: the same menu entries behind a
/// compact icon-only control, so long team names can never consume toolbar
/// width beside the adaptive tabs. The visible label is icon-only; the full
/// "Switch team, <name>" semantics ride on the accessibility label, and the
/// opened Menu still checkmarks the current team.
struct TopBarTeamSwitcher: View {
    @Environment(AppModel.self) private var appModel

    private var teamName: String? { appModel.workspace.selectedTeam?.name }

    var body: some View {
        Menu {
            TeamSwitcherMenu()
        } label: {
            Label("Switch Team", systemImage: "soccerball")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(teamName.map { "Switch team, \($0)" } ?? "Switch team")
        .accessibilityIdentifier("topbar.teamSwitcher")
    }
}

struct TeamSwitcherMenu: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ForEach(appModel.workspace.teams) { team in
            Button {
                Task { await appModel.selectTeam(team.id) }
            } label: {
                if team.id == appModel.workspace.selectedTeamID {
                    Label(team.name, systemImage: "checkmark")
                } else {
                    Text(team.name)
                }
            }
        }
        Divider()
        Button("Add Team…", systemImage: "plus") {
            appModel.navigation.isPresentingNewTeam = true
        }
        Button("Manage Teams…", systemImage: "person.3") {
            appModel.navigation.isPresentingManageTeams = true
        }
    }
}

/// Keyboard commands. A scorer with a hardware keyboard should not have to
/// reach for the screen for the common actions.
struct ProgrammeCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Match…") { appModel.navigation.isPresentingNewMatch = true }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Last Event") { appModel.liveSession?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(appModel.liveSession?.canUndo != true)
            Button("Redo") { appModel.liveSession?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(appModel.liveSession?.canRedo != true)
        }
        // The live shortcuts are single unmodified keys, which is right for
        // someone scoring with a keyboard and wrong for discoverability. Listing
        // them here means the system's own shortcut overlay and the menu teach
        // them, without the touch interface depending on any of it.
        CommandMenu("Record") {
            liveAction("Goal", key: "g", kind: .goal)
            liveAction("Shot on Goal", key: "s", kind: .shotOnGoal, requires: .shots)
            liveAction("Shot", key: "h", kind: .shot, requires: .shots)
            liveAction("Save", key: "v", kind: .save, requires: .goalkeeping)
            liveAction("Corner", key: "c", kind: .corner, requires: .corners)
            Divider()
            liveAction("Substitution", key: "b", kind: .substitution)
        }
        CommandMenu("Match") {
            Button("Start or Stop Clock") { appModel.liveSession?.toggleClock() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(appModel.liveSession?.phase != .inPeriod)
            Button("End Period") { appModel.liveSession?.endCurrentPeriod() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(appModel.liveSession?.phase != .inPeriod)
            Button("Start Next Period") { appModel.liveSession?.startNextPeriod() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(appModel.liveSession?.canStartNextPeriod != true)
            Divider()
            Button("Close Scorer") {
                Task { await appModel.closeLiveSession() }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(appModel.liveSession == nil)
        }
    }

    /// Menu entries route through the same request the palette uses, so a goal
    /// recorded from the keyboard asks for the scorer and the assist exactly as a
    /// tapped one does. There is one implementation of what a goal means.
    private func liveAction(
        _ title: String, key: KeyEquivalent, kind: LiveActionRequest.Kind,
        requires stat: TrackedStat? = nil
    ) -> some View {
        Button(title) {
            appModel.liveSession?.requestedAction = LiveActionRequest(kind: kind)
        }
        .keyboardShortcut(key, modifiers: [])
        .disabled(!isAvailable(stat))
    }

    private func isAvailable(_ stat: TrackedStat?) -> Bool {
        guard let session = appModel.liveSession, session.phase.isLive else { return false }
        guard let stat else { return true }
        return session.profile.tracks(stat)
    }
}
