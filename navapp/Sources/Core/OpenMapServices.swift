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

    /// Two requests at once: one leaving now, which keeps to roads' time rules (e.g. no
    /// motorbikes at rush hour) and is the reference, and one for up to two alternatives,
    /// which Valhalla can't give for a departure time. Of the routes within 5% of the
    /// reference's time, the one with the fewest turns wins: every turn costs time at
    /// a junction that the estimate leaves out (`fewestTurns`).
    /// - Parameters:
    ///   - heading: the direction of travel at `from` (`heading(course:…)`), so the
    ///     route starts the way the rider is going rather than turning them round.
    ///   - avoiding: points on roads the rider has turned down this trip (see
    ///     `NavigationController`), kept off the route. Dropped if no route avoids them.
    public static func route(from: Coordinate, to: Coordinate, costing: Costing, language: String,
                             heading: Int? = nil, avoiding: [Coordinate] = []) async throws -> Route {
        @Sendable func request(alternatives: Bool, avoiding: [Coordinate]) async throws -> Data {
            try await post(routeRequest(from: from, to: to, costing: costing, language: language, heading: heading,
                                        leavingNow: !alternatives, alternatives: alternatives ? 2 : 0,
                                        avoiding: avoiding))
        }
        async let others = try? request(alternatives: true, avoiding: avoiding)
        let reference: Data
        do {
            reference = try await request(alternatives: false, avoiding: avoiding)
        } catch where !avoiding.isEmpty {
            reference = try await request(alternatives: false, avoiding: [])
        }
        let best = try parseRoutes(reference, language: language)[0]
        // None when they failed, e.g. with no route avoiding those roads.
        let alternatives = (await others).flatMap { try? parseRoutes($0, language: language) } ?? []
        return fewestTurns(best, among: alternatives)
    }

    /// `best`, or among `others` taking at most 5% longer, the one with the fewest turns
    /// (then the quickest).
    static func fewestTurns(_ best: Route, among others: [Route]) -> Route {
        let candidates = [best] + others.filter { $0.totalTime <= best.totalTime * 1.05 }
        return candidates.min { ($0.turns, $0.totalTime) < ($1.turns, $1.totalTime) } ?? best
    }

    private static func post(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: valhallaURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(ValhallaError.self, from: data))?.errorCode
            throw ServiceError(message: routeErrorMessage(code))
        }
        return data
    }

    /// The /route request body.
    static func routeRequest(from: Coordinate, to: Coordinate, costing: Costing, language: String,
                             heading: Int?, leavingNow: Bool = false, alternatives: Int = 0,
                             avoiding: [Coordinate] = []) -> [String: Any] {
        var origin: [String: Any] = ["lat": from.lat, "lon": from.lon]
        if let heading {
            origin["heading"] = heading
            origin["heading_tolerance"] = 45
        }
        var body: [String: Any] = [
            "locations": [origin, ["lat": to.lat, "lon": to.lon]],
            "costing": costing.rawValue,
            "directions_options": ["language": language, "units": "kilometers"],
        ]
        if leavingNow { body["date_time"] = ["type": 0] }  // depart now, in the start's local time
        if alternatives > 0 { body["alternates"] = alternatives }
        if !avoiding.isEmpty { body["exclude_locations"] = avoiding.map { ["lat": $0.lat, "lon": $0.lon] } }
        return body
    }

    /// The GPS course in whole degrees, when it's good enough to start a route by: known
    /// within 45° and moving at 2 m/s or more. Core Location gives -1 for unknown values.
    public static func heading(course: Double, courseAccuracy: Double, speed: Double) -> Int? {
        guard course >= 0, courseAccuracy >= 0, courseAccuracy < 45, speed >= 2 else { return nil }
        return Int(course.rounded()) % 360
    }

    /// Valhalla's error texts are English-only, so show our own translated message.
    static func routeErrorMessage(_ code: Int?) -> String {
        switch code {
        case 170, 171: String(localized: "There are no roads near this place.")
        case 442: String(localized: "No route found to this place.")
        case 154: String(localized: "This trip is too long to route.")
        default: String(localized: "Couldn't get a route")
        }
    }

    /// Parses a Valhalla /route response, with our own short instruction texts
    /// (`InstructionText`) in place of Valhalla's.
    /// - Parameter language: the language the route was requested in, e.g. "vi-VN".
    ///   By default the one the response says it's in.
    public static func parseRoute(_ data: Data, language: String? = nil) throws -> Route {
        try parseRoutes(data, language: language)[0]
    }

    /// The route and any alternatives in a /route response, best first.
    static func parseRoutes(_ data: Data, language: String? = nil) throws -> [Route] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ValhallaResponse.self, from: data)
        return try ([response.trip] + (response.alternates ?? []).map(\.trip)).map { try route(of: $0, language: language) }
    }

    private static func route(of trip: ValhallaResponse.Trip, language: String?) throws -> Route {
        guard let leg = trip.legs.first else { throw ServiceError(message: String(localized: "Couldn't get a route")) }
        let vietnamese = (language ?? trip.language ?? "").hasPrefix("vi")
        var maneuvers: [ValhallaManeuver] = []
        for (i, m) in leg.maneuvers.enumerated() {
            let next = i + 1 < leg.maneuvers.count ? leg.maneuvers[i + 1] : nil
            // The roundabout's text already names the exit, so its exit maneuver goes.
            // Guidance counts the roundabout as passed at its end, the exit, so its step
            // stays up until then.
            if m.type == 27, maneuvers.last?.type == 26 { continue }
            // "Continue" (or the road changing its name) under 2 km is no turn to make: the watch
            // shows the next real one instead. Valhalla adds them for e.g. a short unnamed piece
            // of road across a junction ("Continue · 845 m"). Longer ones stay, as reassurance.
            if [7, 8].contains(m.type), m.length < 2, i > 0, i < leg.maneuvers.count - 1 { continue }
            var m = m
            m.instruction = InstructionText.text(for: m, next: next, vietnamese: vietnamese)
            maneuvers.append(m)
        }
        return Route(shape: Polyline.decode(leg.shape), maneuvers: maneuvers,
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
    /// Our short text once `OpenMapServices.parseRoute` has run, Valhalla's before.
    public internal(set) var instruction: String
    /// Valhalla's spoken alert, e.g. "Turn right onto Đường Cầu Bươu.".
    public let verbalTransitionAlertInstruction: String?
    /// Names along the maneuver, and the ones where it starts when those differ.
    public let streetNames: [String]?
    public let beginStreetNames: [String]?
    /// For entering a roundabout: which exit to take.
    public let roundaboutExitCount: Int?
    public let beginShapeIndex: Int
    /// Where the maneuver ends: where the next one starts, except for a roundabout
    /// whose exit maneuver `parseRoute` dropped, where it is the exit.
    public let endShapeIndex: Int
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
        let language: String?
    }
    struct Alternate: Decodable { let trip: Trip }
    let trip: Trip
    let alternates: [Alternate]?
}

struct ValhallaError: Decodable {
    let errorCode: Int?

    enum CodingKeys: String, CodingKey { case errorCode = "error_code" }
}

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
