import SwiftUI

@main
struct ProgrammeWatchApp: App {
    @State private var session = WatchSession()

    var body: some Scene {
        WindowGroup {
            WatchContentView(session: session)
                .task { session.activate() }
        }
    }
}
