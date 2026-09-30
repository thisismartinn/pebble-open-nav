import MapKit
import SwiftUI

/// Card for a place tapped on the map, like Apple Maps: name, category,
/// distance and address, with a prominent Go button.
struct PlaceCard: View {
    let details: PlaceDetails
    /// Distance from the user, already formatted; nil until there's a location.
    let distance: String?
    @Binding var costing: OpenMapServices.Costing
    let onGo: () -> Void
    let onClose: () -> Void

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    if let image = details.image {
                        image
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(details.imageBackground ?? .red, in: Circle())
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.name)
                            .font(.title2.bold())
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Button(action: onGo) {
                    Label("Go", systemImage: costing.symbolName)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if let address = details.address, !address.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Address")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(address)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section("Route Options") {
                TransportPicker(costing: $costing)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { closeButton }
        }
    }

    /// "Restaurant · 1.2 km"
    private var subtitle: String {
        [details.category, distance].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var closeButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: onClose)
        } else {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close")
        }
    }
}

/// Names for Apple Maps place categories. MapKit has no localized names for
/// them, so the common ones are translated here; others show no category.
enum PlaceCategory {
    static func name(_ category: MKPointOfInterestCategory) -> String? {
        switch category {
        case .airport: String(localized: "Airport")
        case .amusementPark: String(localized: "Amusement Park")
        case .aquarium: String(localized: "Aquarium")
        case .atm: String(localized: "ATM")
        case .bakery: String(localized: "Bakery")
        case .bank: String(localized: "Bank")
        case .beach: String(localized: "Beach")
        case .brewery: String(localized: "Brewery")
        case .cafe: String(localized: "Cafe")
        case .campground: String(localized: "Campground")
        case .carRental: String(localized: "Car Rental")
        case .evCharger: String(localized: "EV Charger")
        case .fireStation: String(localized: "Fire Station")
        case .fitnessCenter: String(localized: "Gym")
        case .foodMarket: String(localized: "Market")
        case .gasStation: String(localized: "Gas Station")
        case .hospital: String(localized: "Hospital")
        case .hotel: String(localized: "Hotel")
        case .laundry: String(localized: "Laundry")
        case .library: String(localized: "Library")
        case .marina: String(localized: "Marina")
        case .movieTheater: String(localized: "Movie Theater")
        case .museum: String(localized: "Museum")
        case .nationalPark: String(localized: "National Park")
        case .nightlife: String(localized: "Bar")
        case .park: String(localized: "Park")
        case .parking: String(localized: "Parking")
        case .pharmacy: String(localized: "Pharmacy")
        case .police: String(localized: "Police")
        case .postOffice: String(localized: "Post Office")
        case .publicTransport: String(localized: "Public Transport")
        case .restaurant: String(localized: "Restaurant")
        case .restroom: String(localized: "Restroom")
        case .school: String(localized: "School")
        case .stadium: String(localized: "Stadium")
        case .store: String(localized: "Store")
        case .theater: String(localized: "Theater")
        case .university: String(localized: "University")
        case .zoo: String(localized: "Zoo")
        default: newerName(category)
        }
    }

    /// Categories added in iOS 18.
    private static func newerName(_ category: MKPointOfInterestCategory) -> String? {
        guard #available(iOS 18.0, *) else { return nil }
        switch category {
        case .automotiveRepair: return String(localized: "Repair Shop")
        case .beauty: return String(localized: "Beauty Salon")
        case .landmark: return String(localized: "Landmark")
        case .musicVenue: return String(localized: "Music Venue")
        case .spa: return String(localized: "Spa")
        default: return nil
        }
    }
}
