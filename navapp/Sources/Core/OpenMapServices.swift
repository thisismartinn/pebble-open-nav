import Foundation

/// Routing (Valhalla) and place search (Photon). Only the start, destination
/// and search text leave the phone; no account or identifier is sent.
public enum OpenMapServices {
    public static var valhallaURL = URL(string: "https://valhalla1.openstreetmap.de/route")!
    public static var photonURL = URL(string: "https://photon.komoot.io/api/")!

    public enum Costing: String, CaseIterable, Sendable {
        case motorbike = "motor_scooter"
        case car = "auto"
        case bicycle
        case walk = "pedestrian"
    }

    public struct ServiceError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: Routing

    public static func route(from: Coordinate, to: Coordinate, costing: Costing,
                             language: String) async throws -> Route {
        let body: [String: Any] = [
            "locations": [
                ["lat": from.lat, "lon": from.lon],
                ["lat": to.lat, "lon": to.lon],
            ],
            "costing": costing.rawValue,
            "directions_options": ["language": language, "units": "kilometers"],
        ]
        var request = URLRequest(url: valhallaURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ValhallaError.self, from: data))?.error
            throw ServiceError(message: message ?? String(localized: "Couldn't get a route"))
        }
        return try parseRoute(data)
    }

    /// Parses a Valhalla /route response.
    public static func parseRoute(_ data: Data) throws -> Route {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let trip = try decoder.decode(ValhallaResponse.self, from: data).trip
        guard let leg = trip.legs.first else { throw ServiceError(message: String(localized: "Couldn't get a route")) }
        return Route(shape: Polyline.decode(leg.shape), maneuvers: leg.maneuvers,
                     totalTime: trip.summary.time)
    }

    // MARK: Search

    public struct Place: Identifiable, Sendable {
        public let id = UUID()
        public let name: String
        public let detail: String
        public let coordinate: Coordinate
    }

    public static func search(_ text: String, near: Coordinate?) async throws -> [Place] {
        var components = URLComponents(url: photonURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "limit", value: "8")]
        if let near {
            items.append(URLQueryItem(name: "lat", value: String(near.lat)))
            items.append(URLQueryItem(name: "lon", value: String(near.lon)))
        }
        components.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let result = try JSONDecoder().decode(PhotonResponse.self, from: data)
        return result.features.compactMap { f in
            guard f.geometry.coordinates.count == 2 else { return nil }
            let p = f.properties
            let street = [p.housenumber, p.street].compactMap { $0 }.joined(separator: " ")
            let detail = [street, p.district, p.city, p.country]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            return Place(name: p.name ?? (street.isEmpty ? String(localized: "Unnamed place") : street),
                         detail: detail,
                         coordinate: Coordinate(lat: f.geometry.coordinates[1],
                                                lon: f.geometry.coordinates[0]))
        }
    }
}

// MARK: Wire formats

public struct ValhallaManeuver: Decodable, Sendable {
    public let type: Int
    public let instruction: String
    public let beginShapeIndex: Int
    public let length: Double  // km
    public let time: Double  // s
}

struct ValhallaResponse: Decodable {
    struct Trip: Decodable {
        struct Summary: Decodable { let time: Double }
        struct Leg: Decodable {
            let maneuvers: [ValhallaManeuver]
            let shape: String
        }
        let legs: [Leg]
        let summary: Summary
    }
    let trip: Trip
}

struct ValhallaError: Decodable { let error: String }

struct PhotonResponse: Decodable {
    struct Feature: Decodable {
        struct Geometry: Decodable { let coordinates: [Double] }
        struct Properties: Decodable {
            let name: String?
            let street: String?
            let housenumber: String?
            let district: String?
            let city: String?
            let country: String?
        }
        let geometry: Geometry
        let properties: Properties
    }
    let features: [Feature]
}
