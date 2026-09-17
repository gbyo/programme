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

        static var appModel: AppModel { AppModel() }
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
                ReviewView(session: session, stage: .constant(.pitch))
            }
        }
    }

    #Preview("Event log") {
        if let session = PreviewSupport.session(ProgrammeSample.completedContext()) {
            NavigationStack {
                EventLogView(session: session) { _ in }
            }
        }
    }

    #Preview("Substitution mode", traits: .landscapeLeft) {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            SubstitutionStage(session: session, onCommit: { _, _, _ in }, onCancel: {})
        }
    }

    #Preview("Match stats inspector") {
        if let session = PreviewSupport.session(ProgrammeSample.liveFirstHalfContext()) {
            MatchStatsInspector(session: session)
        }
    }

    #Preview("Starting lineup") {
        if let session = PreviewSupport.session(ProgrammeSample.pregameContext()) {
            NavigationStack { LineupEditorView(session: session) }
        }
    }

    // MARK: - Browsing

    #Preview("Today") {
        if let container = PreviewSupport.container() {
            NavigationStack { TodayView() }
                .environment(PreviewSupport.appModel)
                .modelContainer(container)
        }
    }

    /// The empty state a new installation actually starts in.
    #Preview("Today · empty") {
        if let container = try? ProgrammeStore.container(inMemory: true) {
            NavigationStack { TodayView() }
                .environment(PreviewSupport.appModel)
                .modelContainer(container)
        }
    }

    #Preview("Matches") {
        if let container = PreviewSupport.container() {
            NavigationStack { MatchesView() }
                .environment(PreviewSupport.appModel)
                .modelContainer(container)
        }
    }

    #Preview("Roster") {
        if let container = PreviewSupport.container() {
            NavigationStack { RosterView() }
                .environment(PreviewSupport.appModel)
                .modelContainer(container)
        }
    }

    /// An empty roster, which is where most people start.
    #Preview("Roster · empty") {
        if let container = try? ProgrammeStore.container(inMemory: true) {
            NavigationStack { RosterView() }
                .environment(PreviewSupport.appModel)
                .modelContainer(container)
        }
    }

    #Preview("New match") {
        NewMatchView()
            .environment(PreviewSupport.appModel)
    }

    #Preview("Scoreboard window") {
        ScoreboardWindow()
            .environment(PreviewSupport.appModel)
    }
#endif
