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

    private var segment = 0
    private var offRouteCount = 0

    public init(route: Route) {
        self.route = route
    }

    public func update(_ location: Coordinate, accuracy: Double = 10) -> GuidanceUpdate? {
        let shape = route.shape, cum = route.cumulative
        guard shape.count >= 2, route.maneuvers.count >= 2 else { return nil }

        // Search near the last snapped segment first; fall back to the whole route.
        func nearest(in range: ClosedRange<Int>) -> (seg: Int, t: Double, d: Double) {
            var best = (seg: range.lowerBound, t: 0.0, d: Double.greatestFiniteMagnitude)
            for i in range {
                let p = project(location, onto: shape[i], shape[i + 1])
                if p.distance < best.d { best = (i, p.t, p.distance) }
            }
            return best
        }
        let last = shape.count - 2
        var best = nearest(in: max(0, segment - 3)...min(last, segment + 80))
        if best.d > offRouteDistance {
            best = nearest(in: 0...last)
        }
        segment = best.seg
        let along = cum[best.seg] + best.t * (cum[best.seg + 1] - cum[best.seg])

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

/// Builds the JSON the watchapp's phone-side JavaScript fetches from 127.0.0.1.
public enum WatchStep {
    public static let idle: [String: Any] = ["active": false]

    public static func ended(reason: String) -> [String: Any] {
        ["active": false, "ended": true, "reason": reason]
    }

    public static func step(_ u: GuidanceUpdate, vietnamese: Bool, now: Date = Date()) -> [String: Any] {
        let km = String(format: "%.1f", u.remainingDistance / 1000)
        let minutes = max(1, Int((u.remainingTime / 60).rounded()))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let arrive = formatter.string(from: now.addingTimeInterval(u.remainingTime))
        return [
            "active": true,
            "maneuver": WatchManeuver(valhallaType: u.maneuver.type).rawValue,
            "distance": Int(u.distanceToManeuver.rounded()),
            "instruction": watchText(u.maneuver.instruction),
            "remaining": vietnamese ? "Còn \(km) km" : "\(km) km left",
            "eta": vietnamese ? "\(minutes) phút · Đến \(arrive)" : "\(minutes) min · Arrive \(arrive)",
        ]
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
