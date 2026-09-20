import ProgrammeCore
import SwiftUI

/// Programme's shell.
///
/// Browsing is one adaptive `TabView`: SwiftUI renders a bottom tab bar on
/// iPhone and an adaptable tab/sidebar presentation on iPad. The live scorer
/// replaces the whole browsing shell while a match is being scored.
struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(UniversalSearchModel.self) private var search
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HapticPreferences.key) private var hapticsEnabled = true
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
        .environment(\.programmeHapticsEnabled, hapticsEnabled)
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
                .presentationSizing(.form)
                .presentationDragIndicator(.visible)
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
    /// clears team-specific paths. Search is not a section: every stack
    /// carries the same Programme-wide search field, and the shared
    /// `UniversalSearchModel` below owns its state.
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
            // Workspace context, not a fifth destination: team switching
            // stays pinned in the sidebar bottom area. Settings is app-level,
            // so it is a separate control rather than an unrelated item inside
            // the team menu.
            HStack(spacing: 12) {
                SidebarTeamSwitcher()
                    .accessibilityIdentifier("sidebar.teamSwitcher")
                Spacer(minLength: 8)
                ProgrammeSettingsButton()
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("sidebar.settings")
            }
        }
        // Deliberately no `.id(selectedTeamID)` here: resetting the whole
        // shell's identity on every team switch would discard the selected
        // section, the sidebar presentation, and all tab-local state.
        // Team changes drive explicitly instead — team-scoped navigation
        // paths clear in `selectTeam`, section roots reload by team, and
        // team-relative view state resets where it lives.
    }

    /// One shared search field per section, all bound to the same
    /// `UniversalSearchModel`: one universal Programme search with the
    /// system pull-down presentation, not four copied filters. The drawer
    /// stays hidden until the user pulls down (`automatic`), and scopes
    /// appear only while searching (`onSearchPresentation`).
    @ViewBuilder
    private func sectionStack(for section: AppSection) -> some View {
        @Bindable var navigation = appModel.navigation
        @Bindable var search = search
        NavigationStack(path: navigation.path(for: section)) {
            SectionSearchContainer(section: section)
                .searchable(
                    text: $search.query,
                    isPresented: $search.isPresented,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search Programme"
                )
                .searchScopes($search.scope, activation: .onSearchPresentation) {
                    ForEach(UniversalSearchScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .match(let id): MatchDetailView(matchID: id)
                    case .player(let id): PlayerDetailView(playerID: id)
                    case .season(let id):
                        if let teamID = appModel.workspace.selectedTeamID {
                            SeasonStatsView(teamID: teamID, seasonID: id)
                        }
                    case .eventLog(let id): MatchEventLogScreen(matchID: id)
                    case .review(let id): MatchReviewView(matchID: id)
                    }
                }
        }
    }
}

/// The section root with universal search overlaid: while the section's
/// search field is active the shared `UniversalSearchResults` replaces the
/// section content in place — same tab, same team, same navigation stack.
/// Cancelling clears the query and restores the browsing screen, and search
/// never changes `navigation.section`.
struct SectionSearchContainer: View {
    let section: AppSection

    @Environment(UniversalSearchModel.self) private var search
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        Group {
            if isSearching {
                UniversalSearchResults(search: search, section: section)
            } else {
                SectionRootContent(section: section)
            }
        }
        .onChange(of: isSearching) { _, searching in
            if !searching { search.query = "" }
        }
    }
}

struct SectionRootContent: View {
    let section: AppSection

    @Environment(AppModel.self) private var appModel

    var body: some View {
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
            // Collapsed iPad top bar: keep team switching compact and let the
            // system place lower-priority app settings as a secondary action.
            content
                .navigationTitle(sectionTitle)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        TopBarTeamSwitcher()
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        ProgrammeSettingsButton()
                    }
                }
        } else {
            // Bottom tabs, nil, and any other placement: the title menu is
            // strictly workspace context. Settings remains a separate app-level
            // secondary action so "Switch Team" never opens unrelated commands.
            content
                .navigationTitle(sectionTitle)
                .navigationSubtitle(teamName)
                .toolbarTitleMenu {
                    TeamSwitcherMenu()
                }
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        ProgrammeSettingsButton()
                    }
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
/// owns the entries. The symbol combines people with a switching arrow so
/// the control reads as "switch team" rather than merely "soccer." The
/// visible menu indicator reinforces that tapping the current team opens
/// choices.
struct SidebarTeamSwitcher: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Menu {
            TeamSwitcherMenu()
        } label: {
            Label(
                appModel.workspace.selectedTeam?.name ?? "Programme",
                systemImage: "person.2.arrow.trianglehead.counterclockwise"
            )
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .menuIndicator(.visible)
        .accessibilityLabel(
            appModel.workspace.selectedTeam.map { "Switch team, \($0.name)" } ?? "Switch team"
        )
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
            Label(
                "Switch Team",
                systemImage: "person.2.arrow.trianglehead.counterclockwise"
            )
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
                Task {
                    let previous = appModel.workspace.selectedTeamID
                    await appModel.selectTeam(team.id)
                    if appModel.workspace.selectedTeamID != previous {
                        Haptics.selectionChanged()
                    }
                }
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

/// App-level settings stay separate from the workspace/team menu. A semantic
/// secondary toolbar placement lets SwiftUI decide whether this appears
/// directly or in overflow as space changes.
struct ProgrammeSettingsButton: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button("Settings", systemImage: "gearshape") {
            appModel.navigation.isPresentingSettings = true
        }
    }
}

/// Keyboard commands. A scorer with a hardware keyboard should not have to
/// reach for the screen for the common actions.
struct ProgrammeCommands: Commands {
    let appModel: AppModel
    let search: UniversalSearchModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Match…") { appModel.navigation.isPresentingNewMatch = true }
                .keyboardShortcut("n", modifiers: .command)
        }
        // The conventional search shortcut, routed into the native search
        // presentation of whichever section is showing — never a fake tab.
        CommandMenu("Search") {
            Button("Search Programme") { search.isPresented = true }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { appModel.navigation.isPresentingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
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
            liveAction("Shot", key: "s", kind: .shot, requires: .shots)
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
