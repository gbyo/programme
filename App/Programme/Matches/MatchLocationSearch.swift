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

/// Optional venue picker. A match without a location is complete and
/// scorable; this row only adds a real place when the scorer wants one.
struct LocationSearchField: View {
    @Binding var selection: MatchLocation?
    @State private var model = LocationSearchModel()

    var body: some View {
        if let selection {
            LabeledContent("Location") {
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
                model.queryChanged("")
            }
            .accessibilityIdentifier("matchLocation.clear")
        } else {
            TextField("Search for a venue", text: $model.query)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("matchLocation.search")
                .onChange(of: model.query) { _, text in model.queryChanged(text) }
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
            ForEach(model.completions, id: \.self) { completion in
                Button {
                    Task {
                        if let resolved = await model.resolve(completion) {
                            selection = resolved
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
            } else {
                Text("Optional. Works offline without one — search needs internet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
