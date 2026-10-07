import CoreLocation
import Foundation
import MapKit
import SwiftUI

/// Place search for the destination picker: suggestions as you type and a full search on
/// submit, from Apple Maps or, with the Google maps source, Google; and Photon
/// (OpenStreetMap) for queries that start with a house number ("54 Liễu Giai"), which
/// Apple Maps often misses in Vietnam. Also holds the place tapped on the map, for the
/// place card.
@MainActor
final class SearchModel: NSObject, ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    /// Type-ahead suggestions for `query`.
    @Published private(set) var suggestions: [Suggestion] = []
    /// Apple Maps (or Google) results of the last submitted search.
    @Published private(set) var results: [OpenMapServices.Place] = []
    /// Photon results for a query starting with a house number.
    @Published private(set) var addressResults: [OpenMapServices.Place] = []
    @Published private(set) var searching = false
    /// The last query that finished searching, to tell "no results" from "not searched yet".
    @Published private(set) var lastSearch: String?
    @Published var errorMessage: String?
    /// The Apple Maps place selected on the map, and the card describing it.
    @Published var selectedFeature: MapFeature?
    @Published private(set) var card: PlaceDetails?

    /// Where to bias results; set from the controller's latest location.
    var near: CLLocation? {
        didSet {
            guard let near else { return }
            if let oldValue, oldValue.distance(from: near) < 1000 { return }
            completer.region = region(around: near)
        }
    }

    private let completer = MKLocalSearchCompleter()
    private var maps: MapsProvider { .shared }
    private var vietnamese: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("vi") ?? false }
    /// Google bills a run of suggestions and the place picked from them as one session.
    private var googleSession = UUID().uuidString
    private var suggestTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var addressTask: Task<Void, Never>?
    private var lookup: MKMapItemRequest?

    /// Radius of the area results are biased to.
    private static let biasMeters: CLLocationDistance = 50_000

    override init() {
        super.init()
        completer.delegate = self
        // Addresses and places only: each suggestion then resolves to a single place.
        completer.resultTypes = [.address, .pointOfInterest]
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// True when the list should show the submitted search's results rather than suggestions.
    var showsResults: Bool { lastSearch != nil && lastSearch == trimmedQuery }

    private func region(around location: CLLocation) -> MKCoordinateRegion {
        MKCoordinateRegion(center: location.coordinate,
                           latitudinalMeters: Self.biasMeters, longitudinalMeters: Self.biasMeters)
    }

    /// "54 Liễu Giai": Apple Maps rarely knows house numbers here, so ask Photon too.
    static func startsWithHouseNumber(_ text: String) -> Bool {
        text.first?.isNumber ?? false
    }

    // MARK: Typing

    private func queryChanged() {
        let text = trimmedQuery
        // A submitted search is for the old text: drop it and show suggestions again.
        searchTask?.cancel()
        searching = false
        addressTask?.cancel()
        suggestTask?.cancel()
        guard !text.isEmpty else {
            completer.cancel()
            suggestions = []
            addressResults = []
            lastSearch = nil
            return
        }
        if maps.usesGoogle, let key = maps.key {
            // Each request is billed: wait for a short pause in typing.
            let bias = near.map { Coordinate($0.coordinate) }
            let session = googleSession, vietnamese = vietnamese
            suggestTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let found = try? await GoogleMapServices.autocomplete(text, near: bias, session: session,
                                                                      vietnamese: vietnamese, key: key)
                // Keep the last ones on a failure, as for Apple's while typing fast.
                guard !Task.isCancelled, text == trimmedQuery, let found else { return }
                suggestions = found.map(Suggestion.google)
            }
        } else {
            completer.queryFragment = text
        }
        guard Self.startsWithHouseNumber(text) else {
            addressResults = []
            return
        }
        // Photon is a shared free service: wait for a pause in typing.
        let bias = near.map { Coordinate($0.coordinate) }
        addressTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let places = try? await OpenMapServices.search(text, near: bias)
            guard !Task.isCancelled, text == trimmedQuery else { return }
            addressResults = places ?? []
        }
    }

    // MARK: Submit

    func search() {
        let text = trimmedQuery
        guard !text.isEmpty else {
            results = []
            addressResults = []
            lastSearch = nil
            return
        }
        searchTask?.cancel()
        addressTask?.cancel()
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let near { request.region = region(around: near) }
        let bias = near.map { Coordinate($0.coordinate) }
        let withPhoton = Self.startsWithHouseNumber(text)
        let google = maps.usesGoogle ? maps.key : nil
        let vietnamese = vietnamese
        searchTask = Task {
            async let apple = google == nil ? Self.appleSearch(request)
                : Self.googleSearch(text, near: bias, vietnamese: vietnamese, key: google!)
            async let photon = withPhoton ? Self.photonSearch(text, near: bias) : .success([])
            let (appleResult, photonResult) = await (apple, photon)
            // Also nothing for a query that changed meanwhile: no stale places, no alert.
            guard !Task.isCancelled, text == trimmedQuery else { return }
            searching = false
            results = (try? appleResult.get()) ?? []
            addressResults = (try? photonResult.get()) ?? []
            // One working source is enough; only complain when there's nothing to show.
            if results.isEmpty, addressResults.isEmpty {
                for case .failure(let error) in [appleResult, photonResult] {
                    errorMessage = Self.message(for: error)
                    return
                }
            }
            lastSearch = text
        }
    }

    private static func appleSearch(_ request: MKLocalSearch.Request) async -> Result<[OpenMapServices.Place], Error> {
        do {
            let response = try await MKLocalSearch(request: request).start()
            return .success(response.mapItems.map(place(from:)))
        } catch let error as MKError where error.code == .placemarkNotFound {
            return .success([])
        } catch {
            return .failure(error)
        }
    }

    private static func googleSearch(_ text: String, near: Coordinate?, vietnamese: Bool,
                                     key: String) async -> Result<[OpenMapServices.Place], Error> {
        do {
            return .success(try await GoogleMapServices.search(text, near: near, vietnamese: vietnamese, key: key))
        } catch {
            return .failure(error)
        }
    }

    private static func photonSearch(_ text: String, near: Coordinate?) async -> Result<[OpenMapServices.Place], Error> {
        do {
            return .success(try await OpenMapServices.search(text, near: near))
        } catch {
            return .failure(error)
        }
    }

    /// Resolves a tapped suggestion to a place, or nil (with an alert) if that fails.
    func resolve(_ suggestion: Suggestion) async -> OpenMapServices.Place? {
        searching = true
        defer { searching = false }
        let completion: MKLocalSearchCompletion
        switch suggestion {
        case .apple(let c): completion = c
        case .google(let prediction):
            guard let key = maps.key else { return nil }
            let session = googleSession
            googleSession = UUID().uuidString  // a place picked ends the session
            do {
                return try await GoogleMapServices.place(prediction.placeID, session: session,
                                                         vietnamese: vietnamese, key: key)
            } catch {
                errorMessage = Self.message(for: error)
                return nil
            }
        }
        let request = MKLocalSearch.Request(completion: completion)
        if let near { request.region = region(around: near) }
        do {
            let response = try await MKLocalSearch(request: request).start()
            if let item = response.mapItems.first { return Self.place(from: item) }
            errorMessage = String(localized: "Couldn't find this place.")
        } catch {
            errorMessage = Self.message(for: error)
        }
        return nil
    }

    private static func message(for error: Error) -> String {
        switch (error as? MKError)?.code {
        case .loadingThrottled: String(localized: "Too many searches in a row. Try again in a moment.")
        case .placemarkNotFound: String(localized: "Couldn't find this place.")
        default: error.localizedDescription
        }
    }

    // MARK: Map places

    /// Shows the card for a place tapped on the map: straight away with what the
    /// map knows, then with its address once Apple Maps returns the full place.
    func show(_ feature: MapFeature?) {
        lookup?.cancel()
        lookup = nil
        guard let feature else {
            card = nil
            return
        }
        card = PlaceDetails(feature: feature)
        let request = MKMapItemRequest(feature: feature)
        lookup = request
        Task {
            // On failure the card keeps the map's name and position, enough to route to.
            guard let item = try? await request.mapItem, selectedFeature == feature else { return }
            card = PlaceDetails(item: item, feature: feature)
        }
    }

    /// Shows the card for one of Google's places tapped on its map: its name at once, its
    /// address once Google returns the place.
    func showGooglePlace(id: String, name: String, coordinate: CLLocationCoordinate2D) {
        lookup?.cancel()
        lookup = nil
        selectedFeature = nil
        let details = PlaceDetails(name: name, coordinate: coordinate)
        card = details
        guard let key = maps.key else { return }
        let vietnamese = vietnamese
        Task {
            guard let place = try? await GoogleMapServices.place(id, session: nil, vietnamese: vietnamese, key: key),
                  card?.name == name, card?.coordinate.latitude == coordinate.latitude else { return }
            card?.address = place.detail.isEmpty ? nil : place.detail
        }
    }

    func dismissCard() {
        selectedFeature = nil
        show(nil)
    }

    /// Clears the search when a trip starts.
    func reset() {
        searchTask?.cancel()
        addressTask?.cancel()
        searching = false
        query = ""
        results = []
        addressResults = []
        lastSearch = nil
        dismissCard()
    }

    // MARK: Map items

    static func place(from item: MKMapItem) -> OpenMapServices.Place {
        let name = item.name ?? String(localized: "Unnamed place")
        var address = item.shortAddress ?? ""
        if address == name { address = "" }
        return OpenMapServices.Place(name: name, detail: address, coordinate: Coordinate(item.coordinate))
    }
}

extension SearchModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            // A late answer after the query was cleared (or the source changed to Google)
            // would bring back stale suggestions.
            guard !maps.usesGoogle else { return }
            suggestions = trimmedQuery.isEmpty ? [] : completer.results.map(Suggestion.apple)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Keep the last suggestions: failures while typing (often MKError.loadingThrottled
        // when typing fast) clear up on the next keystroke, and Search still reports errors.
    }
}

/// A type-ahead suggestion, from Apple Maps or Google.
enum Suggestion: Hashable {
    case apple(MKLocalSearchCompletion)
    case google(GoogleMapServices.Prediction)

    /// The title, with the typed part in bold.
    var title: AttributedString {
        switch self {
        case .apple(let c):
            var result = AttributedString(c.title)
            for value in c.titleHighlightRanges {
                guard let range = Range(value.rangeValue, in: c.title),
                      let attributed = Range(range, in: result) else { continue }
                result[attributed].inlinePresentationIntent = .stronglyEmphasized
            }
            return result
        case .google(let p):
            var result = AttributedString(p.title)
            let scalars = p.title.unicodeScalars
            for match in p.titleMatches {  // offsets in Unicode characters
                guard match.lowerBound >= 0, match.upperBound <= scalars.count else { continue }
                let lower = scalars.index(scalars.startIndex, offsetBy: match.lowerBound)
                let upper = scalars.index(scalars.startIndex, offsetBy: match.upperBound)
                guard let attributed = Range(lower..<upper, in: result) else { continue }
                result[attributed].inlinePresentationIntent = .stronglyEmphasized
            }
            return result
        }
    }

    var subtitle: String {
        switch self {
        case .apple(let c): c.subtitle
        case .google(let p): p.subtitle
        }
    }
}

/// What the place card shows for a place tapped on the map.
struct PlaceDetails {
    var name: String
    var category: String?
    var address: String?
    var coordinate: CLLocationCoordinate2D
    /// Apple Maps' own icon and colour for the place, as drawn on the map.
    var image: Image?
    var imageBackground: Color?

    init(name: String, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.coordinate = coordinate
    }

    init(feature: MapFeature) {
        name = feature.title ?? String(localized: "Unnamed place")
        category = feature.pointOfInterestCategory.flatMap(PlaceCategory.name)
        coordinate = feature.coordinate
        image = feature.image
        imageBackground = feature.backgroundColor
    }

    init(item: MKMapItem, feature: MapFeature) {
        self.init(feature: feature)
        if let itemName = item.name { name = itemName }
        if let c = item.pointOfInterestCategory.flatMap(PlaceCategory.name) { category = c }
        address = item.fullAddress
        coordinate = item.coordinate
    }

    var place: OpenMapServices.Place {
        OpenMapServices.Place(name: name, detail: address ?? "", coordinate: Coordinate(coordinate))
    }
}

fileprivate extension MKMapItem {
    /// `placemark` is deprecated on iOS 26 in favour of `location` and `address`.
    var coordinate: CLLocationCoordinate2D {
        if #available(iOS 26.0, *) { location.coordinate } else { placemark.coordinate }
    }

    var fullAddress: String? {
        if #available(iOS 26.0, *) { address?.fullAddress } else { placemark.title }
    }

    var shortAddress: String? {
        if #available(iOS 26.0, *) {
            address?.shortAddress ?? address?.fullAddress
        } else {
            placemark.title
        }
    }
}

fileprivate extension Coordinate {
    init(_ c: CLLocationCoordinate2D) {
        self.init(lat: c.latitude, lon: c.longitude)
    }
}
