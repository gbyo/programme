import AppIntents
import ProgrammeCore
import ProgrammeExport
import ProgrammePersistence
import SwiftData
import SwiftUI

@main
struct ProgrammeApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    // System entry point for CloudKit share invitations accepted outside
    // the app. Forwards to AppModel; see ShareAcceptanceDelegate.
    @UIApplicationDelegateAdaptor(ShareAcceptanceDelegate.self) private var shareDelegate

    init() {
        // Background task handlers have to be registered before the app finishes
        // launching, or submitting a request raises.
        MaintenanceScheduler.register()
        // On-device diagnostics only: signposts, MetricKit reports kept in the
        // unified log, and coarse workflow states. Never uploaded, never PII.
        ProgrammeMetrics.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .task {
                    ShareAcceptanceDelegate.onAccept = { metadata in
                        Task { await appModel.acceptShare(metadata) }
                    }
                    await appModel.bootstrap()
                    let provider = ProgrammeIntentProvider(appModel: appModel)
                    appModel.intentProvider = provider
                    AppDependencyManager.shared.add { provider }
                    await provider.reindexSpotlight()
                }
                .onOpenURL { url in
                    Task { await appModel.handle(url: url) }
                }
        }
        .modelContainer(appModel.containerForScene)
        .commands { ProgrammeCommands(appModel: appModel) }
        .onChange(of: scenePhase) { _, phase in
            appModel.scenePhaseChanged(to: phase)
        }

        // A second window shows a large, readable scoreboard — useful on an
        // external display beside the field while the iPad stays with the scorer.
        WindowGroup(id: ProgrammeScene.scoreboard.rawValue) {
            ScoreboardWindow()
                .environment(appModel)
        }
        .defaultSize(width: 900, height: 520)

        // Opening a `.programme` file from Files gets a real document window.
        // Built on the current Document protocol, so it is gated to the release
        // that introduced it; nothing about scoring or import depends on it.
        if #available(iOS 27.0, *) {
            DocumentGroup { document in
                ArchiveDocumentView(document: document)
                    .environment(appModel)
            } makeReadableDocument: { configuration, _ in
                ProgrammeArchiveDocument()
            }
        }
    }
}

enum ProgrammeScene: String {
    case scoreboard
}
