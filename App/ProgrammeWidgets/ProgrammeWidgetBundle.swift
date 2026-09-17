import SwiftUI
import WidgetKit

@main
struct ProgrammeWidgetBundle: WidgetBundle {
    var body: some Widget {
        MatchStatusWidget()
        SeasonRecordWidget()
        MatchLiveActivity()
    }
}
