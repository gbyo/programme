import EventKit
import EventKitUI
import SwiftUI
import UIKit

/// Presents Apple's event editor prefilled for a scheduled match.
///
/// Least-privilege path: presenting `EKEventEditViewController` does not
/// require requesting broad calendar access. The system editor owns the
/// calendar choice, final edits, alerts, and saving or canceling — Programme
/// never recreates that form and never touches the event database directly.
struct SystemCalendarEditor: UIViewControllerRepresentable {
    let draft: CalendarEventDraft
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.location = draft.location
        event.notes = draft.notes
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        @Binding var isPresented: Bool

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func eventEditViewController(
            _ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction
        ) {
            // Saved, canceled, or deleted: the match is untouched either way.
            // Programme holds no calendar state, so there is nothing to sync.
            isPresented = false
        }
    }
}
