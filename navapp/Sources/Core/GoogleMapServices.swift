import Foundation

/// Routes (Routes API) and place search (Places API, New) from Google Maps Platform, with
/// the rider's own API key. A Google route goes through the same `Route` and `Guidance` as
/// a Valhalla one: each step becomes a `ValhallaManeuver` with the Valhalla type of its turn,
/// and our own short text (`InstructionText`). Google's terms allow its content only on a
/// Google map, so the app shows these on one.
public enum GoogleMapServices {
    static let routesURL = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!
    static let placesURL = URL(string: "https://places.googleapis.com/v1/")!

    // MARK: Routing

    /// - Parameter heading: as for `OpenMapServices.route`.
    public static func route(from: Coordinate, to: Coordinate, costing: OpenMapServices.Costing,
                             vietnamese: Bool, heading: Int? = nil, key: String) async throws -> Route {
        var origin: [String: Any] = ["latLng": latLng(from)]
        if let heading { origin["heading"] = heading }
        var body: [String: Any] = [
            "origin": ["location": origin],
            "destination": ["location": ["latLng": latLng(to)]],
            "travelMode": costing.googleTravelMode,
            // English, for the street names and exit numbers parsed out of it; the texts
            // shown are our own, in the app's language.
            "languageCode": "en",
            "units": "METRIC",
        ]
        // Live traffic, for motor vehicles only (Google refuses it on foot and by bicycle).
        if costing == .motorbike || costing == .car { body["routingPreference"] = "TRAFFIC_AWARE" }
        let fields = ["routes.duration", "routes.legs.steps.distanceMeters", "routes.legs.steps.staticDuration",
                      "routes.legs.steps.polyline.encodedPolyline", "routes.legs.steps.navigationInstruction"]
        let data: Data
        do {
            data = try await send(post(routesURL, body), fields: fields, key: key)
        } catch let error as OpenMapServices.ServiceError {
            throw OpenMapServices.ServiceError(message: String(localized: "Couldn't get a route (\(error.message))"))
        }
        return try parseRoute(data, vietnamese: vietnamese)
    }

    /// Parses a computeRoutes response. The route's shape is its steps' polylines joined, so
    /// each step's start and end are indices into it, as in a Valhalla route.
    static func parseRoute(_ data: Data, vietnamese: Bool) throws -> Route {
        let decoded = try JSONDecoder().decode(RoutesResponse.self, from: data)
        guard let route = decoded.routes?.first, let steps = route.legs.first?.steps, !steps.isEmpty else {
            throw OpenMapServices.ServiceError(message: String(localized: "No route found to this place."))
        }
        var shape: [Coordinate] = []
        var maneuvers: [ValhallaManeuver] = []
        var exits: [ValhallaManeuver?] = []  // for a roundabout, the road it leads to
        for (i, step) in steps.enumerated() {
            let points = Polyline.decode(step.polyline?.encodedPolyline ?? "", precision: 1e5)
            let begin = max(shape.count - 1, 0)
            shape.append(contentsOf: shape.isEmpty ? points[...] : points.dropFirst())
            let end = max(shape.count - 1, begin)
            let text = step.navigationInstruction?.instructions ?? ""
            let type = i == 0 ? 1 : valhallaType(step.navigationInstruction?.maneuver)
            let length = (step.distanceMeters ?? 0) / 1000
            // "Continue" under 2 km is no turn to make, as in `OpenMapServices.parseRoute`.
            if [7, 8].contains(type), length < 2, i < steps.count - 1 { continue }
            let street = street(in: text)
            if type == 26 {
                // Google gives no exit point: the roundabout counts as passed at its entry, and
                // the road it leads to is named through an exit maneuver, as from Valhalla.
                maneuvers.append(ValhallaManeuver(type: 26, instruction: text, streetNames: nil,
                                                  roundaboutExitCount: exitCount(in: text),
                                                  beginShapeIndex: begin, endShapeIndex: begin,
                                                  length: length, time: seconds(step.staticDuration)))
                exits.append(street.map {
                    ValhallaManeuver(type: 27, instruction: "", streetNames: [$0], roundaboutExitCount: nil,
                                     beginShapeIndex: begin, endShapeIndex: end, length: 0, time: 0)
                })
            } else {
                maneuvers.append(ValhallaManeuver(type: type, instruction: text, streetNames: street.map { [$0] },
                                                  roundaboutExitCount: nil, beginShapeIndex: begin,
                                                  endShapeIndex: end, length: length,
                                                  time: seconds(step.staticDuration)))
                exits.append(nil)
            }
        }
        // Google has no arrival step; its last step says which side the destination is on.
        let last = steps.last?.navigationInstruction?.instructions?.lowercased() ?? ""
        let side = last.contains("destination will be on the right") ? 5
            : last.contains("destination will be on the left") ? 6 : 4
        let end = max(shape.count - 1, 0)
        maneuvers.append(ValhallaManeuver(type: side, instruction: "", streetNames: nil, roundaboutExitCount: nil,
                                          beginShapeIndex: end, endShapeIndex: end, length: 0, time: 0))
        exits.append(nil)

        for i in maneuvers.indices {
            let next = exits[i] ?? (i + 1 < maneuvers.count ? maneuvers[i + 1] : nil)
            // Without a phrase of ours (or a street for it), InstructionText falls back to
            // the service's own words: Google's first line, in English.
            maneuvers[i].instruction = String(maneuvers[i].instruction.split(separator: "\n").first ?? "")
            maneuvers[i].instruction = InstructionText.text(for: maneuvers[i], next: next, vietnamese: vietnamese)
        }
        let cumulative = Route.cumulative(shape)
        let icons = maneuvers.map { m in
            WatchManeuver(m, roundaboutTurn: m.type == 26 ? roundaboutTurn(m, shape: shape, cumulative: cumulative) : nil)
        }
        return Route(shape: shape, maneuvers: maneuvers, totalTime: seconds(route.duration), icons: icons)
    }

    /// Google's maneuver as a Valhalla maneuver type.
    static func valhallaType(_ maneuver: String?) -> Int {
        switch maneuver {
        case "TURN_SLIGHT_RIGHT": 9
        case "TURN_RIGHT": 10
        case "TURN_SHARP_RIGHT": 11
        case "UTURN_RIGHT": 12
        case "UTURN_LEFT": 13
        case "TURN_SHARP_LEFT": 14
        case "TURN_LEFT": 15
        case "TURN_SLIGHT_LEFT": 16
        case "RAMP_RIGHT": 18
        case "RAMP_LEFT": 19
        case "FORK_RIGHT": 23
        case "FORK_LEFT": 24
        case "MERGE": 25
        case "ROUNDABOUT_LEFT", "ROUNDABOUT_RIGHT": 26
        case "FERRY", "FERRY_TRAIN": 28
        case "DEPART": 1
        default: 8  // STRAIGHT, NAME_CHANGE, unspecified: continue
        }
    }

    /// How far a roundabout turns the rider, as `Route.turn` but without a known exit: the
    /// heading into it against the direction from its entry to a point 120 m on (or the
    /// step's end), past the ring of any ordinary roundabout.
    static func roundaboutTurn(_ m: ValhallaManeuver, shape: [Coordinate], cumulative cum: [Double]) -> Double? {
        guard shape.count >= 2 else { return nil }
        let entry = cum[min(m.beginShapeIndex, cum.count - 1)]
        let out = min(entry + 120, cum.last ?? entry)
        guard entry >= 5, out - entry >= 30 else { return nil }
        let point = { Route.point(at: $0, shape: shape, cumulative: cum) }
        let into = point(entry - min(15, entry)).bearing(to: point(entry))
        let away = point(entry).bearing(to: point(out))
        return 180 - (540 - (away - into)).truncatingRemainder(dividingBy: 360)
    }

    /// The road in an English instruction: "Turn right onto Đ. Láng" → "Đường Láng",
    /// "Head south on P. Huế toward …" → "Phố Huế". Nil when it names none.
    static func street(in instruction: String) -> String? {
        let line = instruction.split(separator: "\n").first.map(String.init) ?? instruction
        guard let marker = line.range(of: " onto ") ?? line.range(of: " on ", options: .backwards) else { return nil }
        var name = String(line[marker.upperBound...])
        for cut in [" toward ", " towards "] {
            if let r = name.range(of: cut) { name = String(name[..<r.lowerBound]) }
        }
        // Google abbreviates the Vietnamese street prefixes; InstructionText knows them in full
        // (and picks a street's name over its road number in "QL.32/Đường Hồ Tùng Mậu").
        name = name.replacingOccurrences(of: "(^|/)Đ\\. ", with: "$1Đường ", options: .regularExpression)
            .replacingOccurrences(of: "(^|/)P\\. ", with: "$1Phố ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// "At the roundabout, take the 2nd exit onto …" → 2.
    static func exitCount(in instruction: String) -> Int? {
        guard let r = instruction.range(of: "take the [0-9]+(st|nd|rd|th) exit", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return Int(instruction[r].filter(\.isNumber))
    }

    // MARK: Places

    /// A type-ahead suggestion; `resolve` turns it into a place.
    public struct Prediction: Hashable, Sendable {
        public let placeID: String
        public let title: String
        /// The parts of `title` that match the typed text, as character offsets.
        public let titleMatches: [Range<Int>]
        public let subtitle: String
    }

    public static func autocomplete(_ text: String, near: Coordinate?, session: String, vietnamese: Bool,
                                    key: String) async throws -> [Prediction] {
        var body: [String: Any] = ["input": text, "sessionToken": session, "languageCode": vietnamese ? "vi" : "en"]
        if let near { body["locationBias"] = bias(near) }
        let data = try await send(post(placesURL.appendingPathComponent("places:autocomplete"), body),
                                  fields: ["suggestions.placePrediction"], key: key)
        let response = try JSONDecoder().decode(AutocompleteResponse.self, from: data)
        return (response.suggestions ?? []).compactMap(\.placePrediction).map { p in
            let main = p.structuredFormat?.mainText ?? p.text
            return Prediction(placeID: p.placeId, title: main?.text ?? "",
                              titleMatches: (main?.matches ?? []).map { ($0.startOffset ?? 0)..<$0.endOffset },
                              subtitle: p.structuredFormat?.secondaryText?.text ?? "")
        }
    }

    /// The place a suggestion stands for. The session token ends the autocomplete session,
    /// which Google bills as one.
    public static func place(_ placeID: String, session: String?, vietnamese: Bool,
                             key: String) async throws -> OpenMapServices.Place {
        var components = URLComponents(url: placesURL.appendingPathComponent("places/\(placeID)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "languageCode", value: vietnamese ? "vi" : "en")]
            + (session.map { [URLQueryItem(name: "sessionToken", value: $0)] } ?? [])
        let data = try await send(URLRequest(url: components.url!),
                                  fields: ["displayName", "formattedAddress", "location"], key: key)
        guard let place = try JSONDecoder().decode(PlaceResponse.self, from: data).place else {
            throw OpenMapServices.ServiceError(message: String(localized: "Couldn't find this place."))
        }
        return place
    }

    public static func search(_ text: String, near: Coordinate?, vietnamese: Bool,
                              key: String) async throws -> [OpenMapServices.Place] {
        var body: [String: Any] = ["textQuery": text, "languageCode": vietnamese ? "vi" : "en", "pageSize": 10]
        if let near { body["locationBias"] = bias(near) }
        let data = try await send(post(placesURL.appendingPathComponent("places:searchText"), body),
                                  fields: ["places.displayName", "places.formattedAddress", "places.location"], key: key)
        return (try JSONDecoder().decode(SearchResponse.self, from: data).places ?? []).compactMap(\.place)
    }

    // MARK: Key

    /// Tries a key on what the app uses it for: a short route and a place suggestion, both
    /// in Hanoi. Nil when both work, else what Google said.
    public static func test(key: String) async -> String? {
        let a = Coordinate(lat: 21.0285, lon: 105.8542), b = Coordinate(lat: 21.0368, lon: 105.8345)
        do {
            _ = try await send(post(routesURL, [
                "origin": ["location": ["latLng": latLng(a)]],
                "destination": ["location": ["latLng": latLng(b)]],
                "travelMode": "DRIVE",
            ]), fields: ["routes.duration"], key: key)
        } catch {
            return "Routes API: \(error.localizedDescription)"
        }
        do {
            _ = try await autocomplete("Hà Nội", near: a, session: UUID().uuidString, vietnamese: false, key: key)
        } catch {
            return "Places API (New): \(error.localizedDescription)"
        }
        return nil
    }

    // MARK: Requests

    private static func latLng(_ c: Coordinate) -> [String: Double] { ["latitude": c.lat, "longitude": c.lon] }

    private static func bias(_ c: Coordinate) -> [String: Any] {
        ["circle": ["center": latLng(c), "radius": 50_000.0]]
    }

    private static func post(_ url: URL, _ body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Sends a request with the key, the response fields wanted (Google bills by them) and
    /// the app's bundle ID, which a key restricted to iOS apps is checked against.
    private static func send(_ request: URLRequest, fields: [String], key: String) async throws -> Data {
        var request = request
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fields.joined(separator: ","), forHTTPHeaderField: "X-Goog-FieldMask")
        if let id = Bundle.main.bundleIdentifier { request.setValue(id, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(GoogleError.self, from: data))?.error.message
            throw OpenMapServices.ServiceError(message: message ?? "HTTP \(status)")
        }
        return data
    }

    /// "123s" → 123.
    static func seconds(_ duration: String?) -> Double {
        Double(duration?.trimmingCharacters(in: CharacterSet(charactersIn: "s")) ?? "") ?? 0
    }
}

extension OpenMapServices.Costing {
    var googleTravelMode: String {
        switch self {
        case .motorbike: "TWO_WHEELER"
        case .car: "DRIVE"
        case .bicycle: "BICYCLE"
        case .walk: "WALK"
        }
    }
}

extension ValhallaManeuver {
    /// A maneuver made from another service's step, e.g. Google's.
    init(type: Int, instruction: String, streetNames: [String]?, roundaboutExitCount: Int?,
         beginShapeIndex: Int, endShapeIndex: Int, length: Double, time: Double) {
        self.type = type
        self.instruction = instruction
        self.verbalTransitionAlertInstruction = nil
        self.streetNames = streetNames
        self.beginStreetNames = nil
        self.roundaboutExitCount = roundaboutExitCount
        self.beginShapeIndex = beginShapeIndex
        self.endShapeIndex = endShapeIndex
        self.length = length
        self.time = time
    }
}

// MARK: Wire formats

struct RoutesResponse: Decodable {
    struct Route: Decodable {
        let duration: String?
        let legs: [Leg]
    }
    struct Leg: Decodable { let steps: [Step]? }
    struct Step: Decodable {
        struct Polyline: Decodable { let encodedPolyline: String }
        struct Instruction: Decodable {
            let maneuver: String?
            let instructions: String?
        }
        let distanceMeters: Double?
        let staticDuration: String?
        let polyline: Polyline?
        let navigationInstruction: Instruction?
    }
    let routes: [Route]?
}

struct AutocompleteResponse: Decodable {
    struct Text: Decodable {
        struct Match: Decodable {
            let startOffset: Int?  // left out when 0
            let endOffset: Int
        }
        let text: String
        let matches: [Match]?
    }
    struct Prediction: Decodable {
        struct Format: Decodable {
            let mainText: Text?
            let secondaryText: Text?
        }
        let placeId: String
        let text: Text?
        let structuredFormat: Format?
    }
    struct Suggestion: Decodable { let placePrediction: Prediction? }
    let suggestions: [Suggestion]?
}

struct PlaceResponse: Decodable {
    struct Name: Decodable { let text: String }
    struct Location: Decodable {
        let latitude: Double
        let longitude: Double
    }
    let displayName: Name?
    let formattedAddress: String?
    let location: Location?

    var place: OpenMapServices.Place? {
        guard let location else { return nil }
        let name = displayName?.text ?? formattedAddress ?? String(localized: "Unnamed place")
        let address = formattedAddress == name ? "" : formattedAddress ?? ""
        return OpenMapServices.Place(name: name, detail: address,
                                     coordinate: Coordinate(lat: location.latitude, lon: location.longitude))
    }
}

struct SearchResponse: Decodable { let places: [PlaceResponse]? }

struct GoogleError: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}
