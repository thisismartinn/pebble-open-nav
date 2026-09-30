import CoreLocation
import Foundation

/// Place search for the destination picker. (Scaffold: Photon only; being
/// replaced by Apple Maps search with type-ahead suggestions.)
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [OpenMapServices.Place] = []
    @Published var searching = false
    /// The last query that finished searching, to tell "no results" from "not searched yet".
    @Published var lastSearch: String?
    @Published var errorMessage: String?

    /// Where to bias results; set from the controller's latest location.
    var near: CLLocation?

    func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            lastSearch = nil
            return
        }
        searching = true
        let bias = near.map { Coordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        Task {
            defer { searching = false }
            do {
                results = try await OpenMapServices.search(text, near: bias)
                lastSearch = text
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Clears the search when a trip starts.
    func reset() {
        query = ""
        results = []
        lastSearch = nil
    }
}
