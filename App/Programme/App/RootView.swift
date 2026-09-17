import ProgrammeCore
import ProgrammePersistence
import SwiftData
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
        .safeAreaInset(edge: .top) {
            // An inset rather than an overlay: an unfinished match is important
            // enough to move the interface down rather than cover it.
            if !appModel.recoveryCandidates.isEmpty && !navigation.isShowingLiveMatch {
                RecoveryBanner()
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .alert(item: $navigation.errorToShow) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK")))
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
}

/// Shown when Programme finds a match that was being scored when it last closed.
struct RecoveryBanner: View {
    @Environment(AppModel.self) private var appModel
    @State private var selected: RecoverableMatch?

    var body: some View {
        VStack(spacing: 10) {
            ForEach(appModel.recoveryCandidates) { candidate in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Resume \(candidate.title)")
                            .font(.headline)
                        Text(recoveryDetail(candidate))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Review") { selected = candidate }
                        .buttonStyle(.bordered)
                    Button("Resume") {
                        Task { await appModel.openLiveSession(matchID: candidate.matchID) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.separator.opacity(0.6))
                )
            }
        }
        .sheet(item: $selected) { candidate in
            RecoveryReviewView(candidate: candidate)
        }
    }

    private func recoveryDetail(_ candidate: RecoverableMatch) -> String {
        var parts: [String] = []
        if let date = candidate.lastEventAt {
            parts.append("Last event \(date.matchTimeText)")
        }
        parts.append("\(candidate.eventCount) events safely stored")
        if !candidate.isInDatabase {
            parts.append("Recovered from Programme's backup log")
        }
        return parts.joined(separator: " · ")
    }
}
