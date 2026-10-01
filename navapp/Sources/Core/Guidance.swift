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
    /// The maneuver to show: the next one ahead, or from about 30 m before it the one
    /// after it (see `Guidance.switchLead`).
    public let maneuver: ValhallaManeuver
    /// Index of `maneuver` in the route's maneuvers.
    public let maneuverIndex: Int
    public let distanceToManeuver: Double
    /// The next maneuver actually ahead and the distance to it (for a roundabout, to its
    /// exit): the shown one, except in the last metres before it.
    public let cornerIndex: Int
    public let distanceToCorner: Double
    public let remainingDistance: Double
    public let remainingTime: Double
    public let distanceFromRoute: Double
    /// Distance along the route of the snapped fix, in metres.
    public let along: Double
    /// Speed along the route towards the next maneuver in m/s: 0 when unknown, standing
    /// still, or not making progress along the route.
    public let speed: Double
    /// When the GPS fix these numbers come from was taken.
    public let fixTime: Date
    public let arrived: Bool
    public let needsReroute: Bool
}

/// Follows a route from GPS fixes: snaps each fix to the route line and finds
/// the next maneuver ahead.
public final class Guidance {
    public let route: Route
    public var arrivalRadius = 20.0
    /// Further from the route than this (or than the fix's accuracy, if worse), a fix is
    /// re-acquired anywhere on the route and doesn't count as having arrived.
    public var corridor = 40.0
    /// A reroute takes `offRouteFixes` fixes in a row further than this from the route
    /// (or than their accuracy, if worse) while the GPS reports at least `offRouteMinSpeed`.
    /// Standing still doesn't count: a GPS warming up indoors drifts 10-30 m.
    public var offRouteDistance = 25.0
    public var offRouteFixes = 2
    public var offRouteMinSpeed = 1.0

    /// The step after the next maneuver is shown from this far before it, plus a second
    /// of travel to cover the delay until the watch hears of it, at most `maxSwitchLead`.
    /// The watch's new-step buzz then says "now".
    public var switchLead = 30.0
    public var maxSwitchLead = 50.0
    /// How long a corner's own step stays up, at least, before the one after it replaces it.
    public var minStepTime = 3.0

    /// How far ahead along the route a fix may snap between two updates, on top of
    /// the distance expected from the speed and the time since the last fix.
    public var maxJumpAhead = 200.0

    /// Ground speed in m/s, for dead reckoning between fixes. Carry it over to the
    /// guidance for a new route after a reroute, so the watch keeps predicting.
    public var speed = 0.0

    /// When the fix the route was requested from was taken. The first update then
    /// allows for the distance covered since then, as for any gap between fixes.
    public var startTime: Date?

    private var along = 0.0
    /// Dead-reckoned position when the snapped one has fallen well behind it.
    private var predicted = 0.0
    private var lastTime: Date?
    private var lastDistanceFromRoute = 0.0
    /// Recent (time, along) pairs for estimating the speed when the GPS has none.
    private var history: [(time: Date, along: Double)] = []
    private var offRouteCount = 0
    private var shownIndex = 0
    /// When `shownIndex` last changed.
    private var shownSince: Date?

    public init(route: Route) {
        self.route = route
    }

    /// - Parameters:
    ///   - course: direction of travel in degrees from north, when known.
    ///     Used to avoid snapping onto the opposite carriageway of a divided road.
    ///   - speed: the GPS speed in m/s, when valid. Otherwise the speed is estimated
    ///     from progress along the route.
    ///   - reportedSpeed: the speed Core Location reports in m/s (negative: unknown), even
    ///     when too inaccurate for `speed`. Tells whether the rider is moving, for rerouting.
    ///     Defaults to `speed`.
    ///   - time: when the fix was taken.
    public func update(_ location: Coordinate, accuracy: Double = 10, course: Double? = nil,
                       speed gpsSpeed: Double? = nil, reportedSpeed: Double? = nil,
                       time: Date = Date()) -> GuidanceUpdate? {
        let shape = route.shape, cum = route.cumulative
        guard shape.count >= 2, route.maneuvers.count >= 2 else { return nil }

        // Where we expect to be by now, from the speed. After a GPS gap the fix may be
        // far ahead of where we were, and without this it would be held back (or stuck
        // beyond the window) until it drifted off the route. Dead reckoning carries on
        // from `predicted` while the snapped position lags behind it, e.g. held on a
        // corner of a tight loop, but never more than 60 m ahead of the snapped position.
        let elapsed = (lastTime ?? startTime).map { min(max(time.timeIntervalSince($0), 0), 60) } ?? 0
        let expected = elapsed * (self.speed + (gpsSpeed ?? self.speed)) / 2
        let reference = min(max(along, predicted), along + 60) + expected

        /// Angle between the course and segment `i`, in degrees (0...180).
        func courseOffset(_ i: Int, _ course: Double) -> Double {
            let a = shape[i], b = shape[i + 1]
            let bearing = atan2((b.lon - a.lon) * cos(a.lat * .pi / 180), b.lat - a.lat) * 180 / .pi
            return abs((bearing - course + 540).truncatingRemainder(dividingBy: 360) - 180)
        }
        func facingAway(_ i: Int) -> Bool {
            guard let course, cum[i + 1] - cum[i] > 1 else { return false }
            return courseOffset(i, course) > 100
        }
        // Nearest segment, optionally limited to a stretch of route around where we
        // were last time, so a fix can't jump past an upcoming U-turn onto the way back.
        // Jumping further ahead than expected also costs a little, so without a
        // heading (slow or stopped) the fix still prefers staying on the stretch it was on.
        func nearest(from lower: Double?, to upper: Double?, penalizeJumps: Bool) -> (seg: Int, t: Double, d: Double) {
            var best = (seg: 0, t: 0.0, d: Double.greatestFiniteMagnitude)
            var bestScore = Double.greatestFiniteMagnitude
            for i in 0..<(shape.count - 1) {
                if let lower, cum[i + 1] < lower { continue }
                if let upper, cum[i] > upper { break }
                let p = project(location, onto: shape[i], shape[i + 1])
                let jump = cum[i] + p.t * (cum[i + 1] - cum[i]) - reference
                var score = p.distance + (facingAway(i) ? 1000 : 0)
                if penalizeJumps, jump > 30 { score += (jump - 30) * 0.5 }
                if score < bestScore {
                    bestScore = score
                    best = (i, p.t, p.distance)
                }
            }
            return best
        }
        // The first fix is penalised too, from the route's start plus the distance
        // expected since `startTime`, so a slow rider near an upcoming U-turn isn't
        // snapped onto the way back. A rider already well past the start still snaps
        // there: with no nearby alternative the penalty changes nothing, and beyond
        // the window the fix is re-acquired anywhere.
        var best = nearest(from: along - 30, to: max(along + maxJumpAhead, reference + expected / 2 + 50),
                           penalizeJumps: true)
        var reacquired = false
        if best.d > corridor {
            best = nearest(from: nil, to: nil, penalizeJumps: false)  // re-acquire anywhere, e.g. after a detour
            reacquired = true
        }
        let prevAlong = along
        along = cum[best.seg] + best.t * (cum[best.seg + 1] - cum[best.seg])
        // Keep the dead-reckoned lead only while this fix falls short of the distance
        // expected since the last one, e.g. held on a corner. Measured from the last
        // snapped position rather than from `reference`, which the lead itself pushes
        // ahead: otherwise the lead would keep itself going, even when stopped.
        let progress = along - prevAlong
        let lagging = progress < expected - 10
        predicted = !reacquired && along < reference - 30 && lagging ? reference : along
        let firstFix = lastTime == nil
        updateSpeed(gpsSpeed, time: time, restart: reacquired || elapsed > 30)
        lastTime = time

        // What the watch counts down with: the speed along the route. The GPS speed is
        // projected on the route direction when the course is known, the best fit
        // within 10 m of the snapped position so a corner doesn't count as a sideways
        // move (the estimate from progress is along the route already). It's 0 while
        // the snapped position isn't advancing and the fix is moving away from the
        // route, e.g. riding straight on past a turn.
        var routeSpeed = speed
        if let course, gpsSpeed != nil {
            var fit: Double?
            var i = best.seg
            while i > 0, cum[i] > along - 10 { i -= 1 }
            while i < shape.count - 1, cum[i] <= along + 10 {
                if cum[i + 1] - cum[i] > 1 { fit = max(fit ?? -1, cos(courseOffset(i, course) * .pi / 180)) }
                i += 1
            }
            routeSpeed *= fit ?? 1
        }
        if !firstFix, elapsed > 0, progress < 0.1, best.d > lastDistanceFromRoute { routeSpeed = 0 }
        routeSpeed = max(0, routeSpeed)
        lastDistanceFromRoute = best.d

        // Next maneuver ahead of us (index 0 is the "start" instruction). Shortly before
        // it the one after it is shown instead, so the rider sees what comes next while
        // turning. Once shown it stays, unless the fix falls back well before the corner,
        // so GPS jitter or braking for the turn doesn't flick the watch between the two.
        // A roundabout is passed only at its exit (`parseRoute` merged the exit maneuver
        // into it), so "exit 2" stays up while riding round; its distance shows 0 there.
        let maneuvers = route.maneuvers
        func start(_ i: Int) -> Double { cum[min(maneuvers[i].beginShapeIndex, cum.count - 1)] }
        func corner(_ i: Int) -> Double {
            maneuvers[i].type == 26 ? cum[min(maneuvers[i].endShapeIndex, cum.count - 1)] : start(i)
        }
        let nextIndex = (1..<maneuvers.count).first { corner($0) > along + 0.5 } ?? maneuvers.count - 1
        let toCorner = max(0, corner(nextIndex) - along)
        let lead = min(switchLead + routeSpeed, maxSwitchLead)  // + 1 s of travel
        // The corner's own step must have been up for `minStepTime` first: a new route (trip
        // start or reroute) can begin within the lead of its first turn, which would otherwise
        // never be shown.
        let seen = shownIndex > nextIndex
            || (shownIndex == nextIndex && time.timeIntervalSince(shownSince ?? time) >= minStepTime)
        var index = nextIndex + 1 < maneuvers.count && toCorner <= lead && seen ? nextIndex + 1 : nextIndex
        // Never back to an earlier step unless the fix is well before the corner passed last,
        // also with corners closer together than the lead.
        if index < shownIndex, corner(shownIndex - 1) - along <= maxSwitchLead + 15 { index = shownIndex }
        if index != shownIndex { shownSince = time }
        shownIndex = index
        let toManeuver = max(0, start(shownIndex) - along)
        let remaining = max(0, route.totalLength - along)

        // A fix without a speed (Core Location's -1) neither counts nor resets.
        if best.d <= max(offRouteDistance, accuracy) {
            offRouteCount = 0
        } else if let reported = reportedSpeed ?? gpsSpeed, reported >= 0 {
            offRouteCount = reported >= offRouteMinSpeed ? offRouteCount + 1 : 0
        }
        let arrived = nextIndex == maneuvers.count - 1 && toCorner <= arrivalRadius
            && best.d <= max(corridor, accuracy)

        return GuidanceUpdate(
            maneuver: maneuvers[shownIndex],
            maneuverIndex: shownIndex,
            distanceToManeuver: toManeuver,
            cornerIndex: nextIndex,
            distanceToCorner: toCorner,
            remainingDistance: remaining,
            remainingTime: route.totalLength > 0 ? route.totalTime * remaining / route.totalLength : 0,
            distanceFromRoute: best.d,
            along: along,
            speed: routeSpeed,
            fixTime: time,
            arrived: arrived,
            needsReroute: offRouteCount >= offRouteFixes
        )
    }

    /// The GPS speed when there is one. Otherwise progress along the route over the
    /// last few seconds, which averages out most of the GPS jitter, lightly smoothed.
    private func updateSpeed(_ gpsSpeed: Double?, time: Date, restart: Bool) {
        if restart { history.removeAll() }
        history.append((time, along))
        history.removeAll { time.timeIntervalSince($0.time) > 5 }
        if let gpsSpeed {
            speed = max(0, gpsSpeed)
        } else if let first = history.first, time.timeIntervalSince(first.time) >= 2 {
            let measured = max(0, (along - first.along) / time.timeIntervalSince(first.time))
            speed += (measured - speed) * 0.5
        }
    }
}

/// Settings every watch payload carries.
public struct WatchContext: Sendable {
    /// Phone language. The nav app is the watch's only reliable source for it:
    /// the Pebble iOS app is English-only and reports e.g. "en_VN" on a Vietnamese phone.
    public var vietnamese: Bool
    /// Light watch theme (easier to read in sunlight).
    public var light: Bool
    /// The theme follows sunrise/sunset. The watch then guesses by the time of day
    /// at launch instead of reusing a saved theme that may be hours old.
    public var automaticTheme: Bool

    public init(vietnamese: Bool, light: Bool, automaticTheme: Bool = false) {
        self.vietnamese = vietnamese
        self.light = light
        self.automaticTheme = automaticTheme
    }

    var fields: [String: Any] {
        ["lang": vietnamese ? "vi" : "en", "theme": light ? "light" : "dark", "themeAuto": automaticTheme]
    }
}

/// Builds the JSON the watchapp's phone-side JavaScript fetches from 127.0.0.1.
/// Every payload carries `poll`: the suggested time in ms until the watch asks again.
public enum WatchStep {
    /// Further from the route than this, the watch stops counting the distance down
    /// (speed 0) and asks every second: the rider may be turning off, and riding on
    /// no longer brings the maneuver closer.
    static let countdownCorridor = 15.0

    public static func idle(_ ctx: WatchContext) -> [String: Any] {
        ctx.fields.merging(["active": false, "poll": 3000]) { $1 }
    }

    /// A trip has started but there's no route or GPS fix yet.
    public static func routing(_ ctx: WatchContext) -> [String: Any] {
        ctx.fields.merging(["active": false, "routing": true, "poll": 1000]) { $1 }
    }

    /// The trip is over. `arrived` false: stopped on the phone.
    public static func ended(arrived: Bool, _ ctx: WatchContext) -> [String: Any] {
        ctx.fields.merging(["active": false, "ended": true, "arrived": arrived, "poll": 3000]) { $1 }
    }

    /// The next step, with every number as of the GPS fix (`fixTime`) so the watch
    /// can count down from there.
    /// - Parameter routeGeneration: goes up with each new route or reroute, so `stepId`
    ///   changes with every step, even when two turns in a row have the same text.
    public static func step(_ u: GuidanceUpdate, routeGeneration: Int, _ ctx: WatchContext) -> [String: Any] {
        let speed = u.distanceFromRoute > countdownCorridor ? 0 : max(0, u.speed)
        return ctx.fields.merging([
            "active": true,
            "stepId": routeGeneration * 1000 + u.maneuverIndex,
            "maneuver": WatchManeuver(valhallaType: u.maneuver.type).rawValue,
            "distance": Int(u.distanceToManeuver.rounded()),
            "instruction": watchText(u.maneuver.instruction),
            "remainM": Int(u.remainingDistance.rounded()),
            "remainS": Int(u.remainingTime.rounded()),
            // cm/s precision as a Decimal, so the JSON says 9.37 rather than 9.3699999999999992
            "speed": Decimal(Int((speed * 100).rounded())) / 100,
            "fixTime": Int64((u.fixTime.timeIntervalSince1970 * 1000).rounded()),
            "poll": poll(u),
        ]) { $1 }
    }

    /// Every second near a maneuver or off the route, every 3s within 1 km of one,
    /// otherwise every 10s. The corner being taken counts too: once the step after it
    /// is shown, that maneuver may be far away, but a missed turn must reach the watch fast.
    static func poll(_ u: GuidanceUpdate) -> Int {
        let near = min(u.distanceToManeuver, u.distanceToCorner)
        if near < 300 || u.distanceFromRoute > countdownCorridor { return 1000 }
        return near < 1000 ? 3000 : 10000
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
