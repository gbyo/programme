#if DEBUG
    import ProgrammeCore
    import ProgrammePersistence
    import ProgrammeUI
    import SwiftData
    import SwiftUI

    /// Preview scaffolding. Nothing in the application depends on any of this.
    @MainActor
    enum PreviewSupport {

        static func journal() -> RecoveryJournal? {
            try? RecoveryJournal(
                directory: FileManager.default.temporaryDirectory
                    .appending(path: "programme-previews/\(UUID().uuidString)"))
        }

        static func container() -> ModelContainer? {
            try? ProgrammeStore.previewContainer()
        }

        static func session(_ context: MatchContext) -> LiveMatchSession? {
            guard let container = try? ProgrammeStore.container(inMemory: true),
                let journal = journal()
            else { return nil }
            return LiveMatchSession(
                context: context, store: MatchStore(modelContainer: container), journal: journal,
                appModel: nil)
        }

        /// An app model whose own store holds the sample team, so browsing
        /// previews read the same container their views fetch through.
        static var appModel: AppModel {
            makeAppModel()
        }

        static func makeAppModel(includeLiveMatch: Bool = false) -> AppModel {
            let model = AppModel()
            if let container = model.container {
                try? ProgrammeStore.seedSampleData(
                    into: container.mainContext, includeLiveMatch: includeLiveMatch)
            }
            return model
        }

        /// The sample team as the selected workspace, so section roots render.
        static func seededAppModel(includeLiveMatch: Bool = false) -> AppModel {
            let model = makeAppModel(includeLiveMatch: includeLiveMatch)
            Task { @MainActor in
                guard let store = model.store else { return }
                model.workspace.teams = (try? await store.teamIdentities()) ?? []
                model.workspace.selectedTeamID = ProgrammeSample.teamID
                model.workspace.currentSeasonID = try? await store.currentSeasonID(
                    teamID: ProgrammeSample.teamID)
                model.workspace.viewedStatsSeasonID = model.workspace.currentSeasonID
            }
            return model
        }
    }

    /// A live match on a full-width iPad: the layout Programme is designed around.
    #Preview("Live · first half", traits: .landscapeLeft) {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            LiveMatchView(session: session)
                .environment(PreviewSupport.appModel)
        }
    }

    #Preview("Live · dark", traits: .landscapeLeft) {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            LiveMatchView(session: session)
                .environment(PreviewSupport.appModel)
                .preferredColorScheme(.dark)
        }
    }

    /// A narrow window, as in Stage Manager or Split View. Content collapses;
    /// touch targets do not shrink.
    #Preview("Live · narrow window") {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            LiveMatchView(session: session)
                .environment(PreviewSupport.appModel)
                .frame(width: 560, height: 820)
        }
    }

    #Preview("Live · large text", traits: .landscapeLeft) {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            LiveMatchView(session: session)
                .environment(PreviewSupport.appModel)
                .environment(\.dynamicTypeSize, .accessibility1)
        }
    }

    /// Before kickoff, with the lineup confirmed.
    #Preview("Live · pregame", traits: .landscapeLeft) {
        if let session = PreviewSupport.session(ProgrammeSample.pregameContext()) {
            LiveMatchView(session: session)
                .environment(PreviewSupport.appModel)
        }
    }

    /// Halftime with an unresolved attribution — the state the review flow exists for.
    #Preview("Halftime · with a warning") {
        if let session = PreviewSupport.session(ProgrammeSample.halftimeContext()) {
            NavigationStack {
                PeriodBreakView(
                    session: session, onReview: {}, onContinue: {}, onShootout: {}, onFinalize: {})
            }
        }
    }

    #Preview("Finalize") {
        if let session = PreviewSupport.session(ProgrammeSample.completedContext()) {
            NavigationStack {
                FinalizeView(session: session) {}
            }
        }
    }

    #Preview("Needs review") {
        if let session = PreviewSupport.session(ProgrammeSample.halftimeContext()) {
            NavigationStack {
                ReviewView(session: session)
            }
        }
    }

    #Preview("Event log") {
        if let session = PreviewSupport.session(ProgrammeSample.completedContext()) {
            NavigationStack {
                EventLogView(session: session)
            }
        }
    }

    // MARK: - Substitution
    //
    // Two presentations of one draft. The phone previews exercise the pushed
    // flow; the iPad previews exercise the pair-aware columns, including the
    // narrowest regular-width window Programme supports.

    #Preview("Substitution · iPhone portrait") {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            SubstitutionStage(
                session: session, presentation: .navigation, onCommit: { _, _, _ in }, onCancel: {})
        }
    }

    #Preview("Substitution · iPhone landscape", traits: .landscapeLeft) {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            SubstitutionStage(
                session: session, presentation: .navigation, onCommit: { _, _, _ in }, onCancel: {})
        }
    }

    #Preview("Substitution · iPhone large text") {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            SubstitutionStage(
                session: session, presentation: .navigation, onCommit: { _, _, _ in }, onCancel: {}
            )
            .environment(\.dynamicTypeSize, .accessibility2)
        }
    }

    /// iPad mini portrait: the narrowest window that still gets the columns.
    #Preview("Substitution · iPad mini portrait") {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            SubstitutionStage(
                session: session, presentation: .columns, onCommit: { _, _, _ in }, onCancel: {}
            )
            .frame(width: 744, height: 1_133)
        }
    }

    #Preview("Substitution · iPad mini landscape", traits: .landscapeLeft) {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            SubstitutionStage(
                session: session, presentation: .columns, onCommit: { _, _, _ in }, onCancel: {}
            )
            .frame(width: 1_133, height: 744)
        }
    }

    /// A large iPad landscape workspace, at the width the centre column actually
    /// gets in the three-column layout.
    #Preview("Substitution · large iPad workspace", traits: .landscapeLeft) {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            SubstitutionStage(
                session: session, presentation: .columns, onCommit: { _, _, _ in }, onCancel: {}
            )
            .frame(width: 700, height: 1_000)
        }
    }

    /// The whole scorer on a phone, which is where the composer is a sheet.
    #Preview("Live · iPhone portrait") {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            LiveMatchView(session: session)
                .environment(PreviewSupport.appModel)
        }
    }

    #Preview("Match stats inspector") {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            NavigationStack { MatchStatsInspector(session: session, onClose: {}) }
        }
    }

    #Preview("Starting lineup") {
        if let session = PreviewSupport.session(ProgrammeSample.pregameContext()) {
            NavigationStack { LineupEditorView(session: session) }
        }
    }

    // MARK: - Browsing

    #Preview("Home") {
        NavigationStack { HomeView(teamID: ProgrammeSample.teamID) }
            .environment(PreviewSupport.seededAppModel())
    }

    #Preview("Home · current match") {
        NavigationStack { HomeView(teamID: ProgrammeSample.teamID) }
            .environment(PreviewSupport.seededAppModel(includeLiveMatch: true))
    }

    #Preview("Matches") {
        NavigationStack { MatchesView(teamID: ProgrammeSample.teamID) }
            .environment(PreviewSupport.seededAppModel())
    }

    #Preview("Roster") {
        NavigationStack { RosterView(teamID: ProgrammeSample.teamID) }
            .environment(PreviewSupport.seededAppModel())
    }

    #Preview("New match") {
        NewMatchView(teamID: ProgrammeSample.teamID)
            .environment(PreviewSupport.seededAppModel())
    }

    #Preview("Scoreboard window") {
        ScoreboardWindow()
            .environment(PreviewSupport.appModel)
    }
#endif
