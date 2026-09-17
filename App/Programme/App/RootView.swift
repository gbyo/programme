import ProgrammeCore
import SwiftUI

/// Programme's shell.
///
/// Outside a live match this is an ordinary iPad split view. The moment a match
/// is being scored the scorer gets the whole window: the sidebar is not more
/// important than the pitch.
struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var navigation = appModel.navigation

        Group {
            if let session = appModel.liveSession, navigation.isShowingLiveMatch {
                LiveMatchView(session: session)
                    .transition(.opacity)
            } else {
                browsingShell
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
            NewMatchView()
        }
        .sheet(isPresented: $navigation.isPresentingSettings) {
            SettingsView()
        }
        .task(id: navigation.pendingMatchToOpen) {
            guard let matchID = navigation.pendingMatchToOpen else { return }
            navigation.pendingMatchToOpen = nil
            await appModel.openLiveSession(matchID: matchID)
        }
    }

    private var browsingShell: some View {
        @Bindable var navigation = appModel.navigation

        let destination = navigation.sidebar ?? .today

        return NavigationSplitView(columnVisibility: $navigation.columnVisibility) {
            SidebarView()
        } detail: {
            // Each destination keeps its own path in the navigation model, so
            // rebuilding the stack on a sidebar change restores rather than
            // loses where the person was.
            NavigationStack(path: navigation.path(for: destination)) {
                destinationView
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .match(let id): MatchDetailView(matchID: id)
                        case .player(let id): PlayerDetailView(playerID: id)
                        case .season(let id): SeasonStatsView(seasonID: id)
                        case .eventLog(let id): MatchEventLogScreen(matchID: id)
                        }
                    }
            }
            .id(destination)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var destinationView: some View {
        switch appModel.navigation.sidebar ?? .today {
        case .today: TodayView()
        case .matches: MatchesView()
        case .roster: RosterView()
        case .season: SeasonStatsView(seasonID: appModel.seasonID)
        case .exports: ExportsView()
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var navigation = appModel.navigation

        List(selection: $navigation.sidebar) {
            Section {
                ForEach(SidebarDestination.allCases) { destination in
                    Label(destination.title, systemImage: destination.symbolName)
                        .tag(destination)
                }
            } header: {
                Text(appModel.teamName)
            }
        }
        .navigationTitle("Programme")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") {
                    navigation.isPresentingSettings = true
                }
            }
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
