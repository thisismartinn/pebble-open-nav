import Foundation

public struct Route: Sendable {
    public let shape: [Coordinate]
    public let maneuvers: [ValhallaManeuver]
    public let totalTime: Double  // s
    /// Distance along the route to each shape point, in metres.
    public let cumulative: [Double]

    public var totalLength: Double { cumulative.last ?? 0 }

    public init(shape: [Coordinate], maneuvers: [ValhallaManeuver], totalTime: Double) {
        self.shape = shape
        self.maneuvers = maneuvers
        self.totalTime = totalTime
        var cum = [0.0]
        for i in 1..<max(shape.count, 1) {
            cum.append(cum[i - 1] + shape[i - 1].distance(to: shape[i]))
        }
        self.cumulative = cum
    }
}

/// Maneuver codes understood by the Pebble watchapp.
public enum WatchManeuver: Int, Sendable {
    case none = 0, straight, left, right, slightLeft, slightRight, uturn, arrive

    /// Maps Valhalla maneuver types to the watch's arrow set.
    public init(valhallaType t: Int) {
        switch t {
        case 2, 10, 11: self = .right
        case 3, 14, 15: self = .left
        case 9, 18, 20, 23, 37: self = .slightRight
        case 16, 19, 21, 24, 38: self = .slightLeft
        case 12, 13: self = .uturn
        case 4, 5, 6: self = .arrive
        default: self = .straight  // continue, ramps straight, merges, roundabouts, ferries
        }
    }
}

public struct GuidanceUpdate: Sendable {
    public let maneuver: ValhallaManeuver
    public let distanceToManeuver: Double
    public let remainingDistance: Double
    public let remainingTime: Double
    public let distanceFromRoute: Double
    public let arrived: Bool
    public let needsReroute: Bool
}

/// Follows a route from GPS fixes: snaps each fix to the route line and finds
/// the next maneuver ahead.
public final class Guidance {
    public let route: Route
    public var arrivalRadius = 20.0
    public var offRouteDistance = 40.0
    public var offRouteFixes = 3

    /// How far ahead along the route a fix may snap between two updates.
    public var maxJumpAhead = 200.0

    private var along = 0.0
    private var offRouteCount = 0

    public init(route: Route) {
        self.route = route
    }

    /// - Parameter course: direction of travel in degrees from north, when known.
    ///   Used to avoid snapping onto the opposite carriageway of a divided road.
    public func update(_ location: Coordinate, accuracy: Double = 10, course: Double? = nil) -> GuidanceUpdate? {
        let shape = route.shape, cum = route.cumulative
        guard shape.count >= 2, route.maneuvers.count >= 2 else { return nil }

        func facingAway(_ i: Int) -> Bool {
            guard let course, cum[i + 1] - cum[i] > 1 else { return false }
            let a = shape[i], b = shape[i + 1]
            let bearing = atan2((b.lon - a.lon) * cos(a.lat * .pi / 180), b.lat - a.lat) * 180 / .pi
            let diff = abs((bearing - course + 540).truncatingRemainder(dividingBy: 360) - 180)
            return diff > 100
        }
        // Nearest segment, optionally limited to a stretch of route around where we
        // were last time, so a fix can't jump past an upcoming U-turn onto the way back.
        // Jumping far ahead also costs a little, so without a heading (slow or
        // stopped) the fix still prefers staying on the stretch it was on.
        func nearest(from lower: Double?, to upper: Double?, penalizeJumps: Bool) -> (seg: Int, t: Double, d: Double) {
            var best = (seg: 0, t: 0.0, d: Double.greatestFiniteMagnitude)
            var bestScore = Double.greatestFiniteMagnitude
            for i in 0..<(shape.count - 1) {
                if let lower, cum[i + 1] < lower { continue }
                if let upper, cum[i] > upper { break }
                let p = project(location, onto: shape[i], shape[i + 1])
                let jump = cum[i] + p.t * (cum[i + 1] - cum[i]) - along
                var score = p.distance + (facingAway(i) ? 1000 : 0)
                if penalizeJumps, jump > 30 { score += (jump - 30) * 0.5 }
                if score < bestScore {
                    bestScore = score
                    best = (i, p.t, p.distance)
                }
            }
            return best
        }
        var best = nearest(from: along - 30, to: along + maxJumpAhead, penalizeJumps: true)
        if best.d > offRouteDistance {
            best = nearest(from: nil, to: nil, penalizeJumps: false)  // re-acquire anywhere, e.g. after a detour
        }
        along = cum[best.seg] + best.t * (cum[best.seg + 1] - cum[best.seg])

        // Next maneuver ahead of us (index 0 is the "start" instruction).
        let maneuvers = route.maneuvers
        let nextIndex = (1..<maneuvers.count).first {
            cum[min(maneuvers[$0].beginShapeIndex, cum.count - 1)] > along + 0.5
        } ?? maneuvers.count - 1
        let next = maneuvers[nextIndex]
        let toManeuver = max(0, cum[min(next.beginShapeIndex, cum.count - 1)] - along)
        let remaining = max(0, route.totalLength - along)

        if best.d > max(offRouteDistance, accuracy) {
            offRouteCount += 1
        } else {
            offRouteCount = 0
        }
        let arrived = nextIndex == maneuvers.count - 1 && toManeuver <= arrivalRadius
            && best.d <= max(offRouteDistance, accuracy)

        return GuidanceUpdate(
            maneuver: next,
            distanceToManeuver: toManeuver,
            remainingDistance: remaining,
            remainingTime: route.totalLength > 0 ? route.totalTime * remaining / route.totalLength : 0,
            distanceFromRoute: best.d,
            arrived: arrived,
            needsReroute: offRouteCount >= offRouteFixes
        )
    }
}

/// Settings every watch payload carries.
public struct WatchContext: Sendable {
    /// Phone language. The nav app is the watch's only reliable source for it:
    /// the Pebble iOS app is English-only and reports e.g. "en_VN" on a Vietnamese phone.
    public var vietnamese: Bool
    /// Light theme on colour watches (easier to read in sunlight).
    public var light: Bool

    public init(vietnamese: Bool, light: Bool) {
        self.vietnamese = vietnamese
        self.light = light
    }

    var fields: [String: Any] {
        ["lang": vietnamese ? "vi" : "en", "theme": light ? "light" : "dark"]
    }
}

/// Builds the JSON the watchapp's phone-side JavaScript fetches from 127.0.0.1.
public enum WatchStep {
    public static func idle(_ ctx: WatchContext) -> [String: Any] {
        ctx.fields.merging(["active": false]) { $1 }
    }

    /// A trip has started but there's no route or GPS fix yet.
    public static func routing(_ ctx: WatchContext) -> [String: Any] {
        ctx.fields.merging(["active": false, "routing": true]) { $1 }
    }

    /// Fixed 24-hour Latin digits whatever the phone's region and 12/24-hour setting,
    /// since the watch fonts only cover Latin text.
    private static let etaFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    public static func ended(reason: String, _ ctx: WatchContext) -> [String: Any] {
        ctx.fields.merging(["active": false, "ended": true, "reason": reason]) { $1 }
    }

    public static func step(_ u: GuidanceUpdate, _ ctx: WatchContext, now: Date = Date()) -> [String: Any] {
        let vietnamese = ctx.vietnamese
        var km = String(format: "%.1f", u.remainingDistance / 1000)
        if vietnamese { km = km.replacingOccurrences(of: ".", with: ",") }  // "8,4 km"
        let minutes = max(1, Int((u.remainingTime / 60).rounded()))
        let arrive = etaFormatter.string(from: now.addingTimeInterval(u.remainingTime))
        return ctx.fields.merging([
            "active": true,
            "maneuver": WatchManeuver(valhallaType: u.maneuver.type).rawValue,
            "distance": Int(u.distanceToManeuver.rounded()),
            "instruction": watchText(u.maneuver.instruction),
            "remaining": vietnamese ? "Còn \(km) km" : "\(km) km left",
            "eta": vietnamese ? "\(minutes) phút · Đến \(arrive)" : "\(minutes) min · Arrive \(arrive)",
        ]) { $1 }
    }

    /// The watch keeps 96 bytes per instruction. Trim at a character boundary
    /// so a multi-byte Vietnamese letter is never cut in half.
    static func watchText(_ instruction: String, maxBytes: Int = 90) -> String {
        var text = instruction.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(".") { text.removeLast() }
        while text.utf8.count > maxBytes { text.removeLast() }
        return text
    }
}
