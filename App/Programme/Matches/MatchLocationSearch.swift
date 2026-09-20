import Foundation
import MapKit
import ProgrammeCore
import SwiftUI

/// Bridges Apple's venue search into Programme's optional match location.
///
/// Uses `MKLocalSearchCompleter` for system autocomplete behavior and
/// `MKLocalSearch` to resolve the chosen result. Nothing here requests the
/// scorer's own location: searching for a venue never justifies locating
/// the user. Search needs internet; when it fails the match simply has no
/// location, which is always a valid state.
@MainActor
@Observable
final class LocationSearchModel {
    var query = ""
    var completions: [MKLocalSearchCompletion] = []
    var isSearching = false
    var searchError: String?

    private let completer = MKLocalSearchCompleter()
    private var delegate: CompleterDelegate?

    init() {
        let delegate = CompleterDelegate { [weak self] completions in
            Task { @MainActor in self?.completions = completions }
        }
        self.delegate = delegate
        completer.delegate = delegate
        // Deliberately no region from the user's location: no permission
        // request merely to search for a venue.
    }

    func queryChanged(_ text: String) {
        query = text
        searchError = nil
        completer.queryFragment = text
    }

    /// Resolves one autocomplete result to a storable location.
    func resolve(_ completion: MKLocalSearchCompletion) async -> MatchLocation? {
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = [completion.title, completion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard let items = try? await MKLocalSearch(request: request).start(),
            let item = items.mapItems.first
        else {
            searchError = "Programme couldn't look up that place. Check your connection — the match is unaffected."
            return nil
        }
        let coordinate = item.location.coordinate
        return MatchLocation(
            name: item.name ?? completion.title,
            address: item.address?.fullAddress,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude)
    }

    fileprivate final class CompleterDelegate: NSObject, MKLocalSearchCompleterDelegate {
        let onUpdate: ([MKLocalSearchCompletion]) -> Void

        init(onUpdate: @escaping ([MKLocalSearchCompletion]) -> Void) {
            self.onUpdate = onUpdate
        }

        func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
            onUpdate(completer.results)
        }

        func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
            onUpdate([])
        }
    }
}

/// Optional venue value row. A match without a location is complete and
/// scorable; the row only opens the picker when the scorer wants a place.
struct LocationPickerLink: View {
    @Binding var selection: MatchLocation?

    var body: some View {
        NavigationLink {
            VenuePickerView(selection: $selection)
        } label: {
            if let selection {
                LabeledContent("Location") {
                    Text(selection.name)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                LabeledContent("Location") {
                    Text("Add Location")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("matchLocation.search")
    }
}

/// Focused venue lookup. Native `.searchable` presentation with a List of
/// MapKit completions; only the selected completion resolves, and
/// selecting returns to New Match. Never requests the user's location.
struct VenuePickerView: View {
    @Binding var selection: MatchLocation?
    @Environment(\.dismiss) private var dismiss
    @State private var model = LocationSearchModel()

    var body: some View {
        List {
            if let selection {
                Section {
                    LabeledContent("Selected") {
                        Text(selection.name)
                            .multilineTextAlignment(.trailing)
                    }
                    if let address = selection.address {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Remove Location", role: .destructive) {
                        self.selection = nil
                    }
                    .accessibilityIdentifier("matchLocation.clear")
                }
            }
            if model.isSearching {
                ProgressView("Looking up…")
            }
            ForEach(model.completions, id: \.self) { completion in
                Button {
                    Task {
                        if let resolved = await model.resolve(completion) {
                            selection = resolved
                            dismiss()
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(completion.title)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("matchLocation.result")
            }
            if let searchError = model.searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.query.isEmpty && selection == nil && !model.isSearching {
                ContentUnavailableView(
                    "Search for a Venue", systemImage: "mappin.and.ellipse",
                    description: Text(
                        "Optional. The match works offline without one — search needs internet."))
            }
        }
        .searchable(text: $model.query, prompt: "Search for a venue")
        .textInputAutocapitalization(.words)
        .onChange(of: model.query) { _, text in model.queryChanged(text) }
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
    }
}
