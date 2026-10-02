import Foundation

public struct Route: Sendable {
    public let shape: [Coordinate]
    public let maneuvers: [ValhallaManeuver]
    public let totalTime: Double  // s
    /// Distance along the route to each shape point, in metres.
    public let cumulative: [Double]
    /// The watch icon of each maneuver.
    public let icons: [WatchManeuver]

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
        icons = maneuvers.map { m in
            WatchManeuver(m, roundaboutTurn: m.type == 26 ? Self.turn(at: m, shape: shape, cumulative: cum) : nil)
        }
    }

    /// How far a roundabout turns the rider, in degrees, positive to the right: the heading
    /// of the last 15 m of route into it against that of the first 15 m after its exit.
    /// Nil when either stretch is under 5 m, e.g. on a route that starts in the ring.
    static func turn(at m: ValhallaManeuver, shape: [Coordinate], cumulative cum: [Double]) -> Double? {
        guard shape.count >= 2 else { return nil }
        let last = cum.count - 1
        let entry = cum[min(m.beginShapeIndex, last)], exit = cum[min(m.endShapeIndex, last)]
        func heading(_ a: Double, _ b: Double) -> Double? {
            guard b - a >= 5 else { return nil }
            return point(at: a, shape: shape, cumulative: cum).bearing(to: point(at: b, shape: shape, cumulative: cum))
        }
        guard let into = heading(max(0, entry - 15), entry), let out = heading(exit, min(cum[last], exit + 15)) else {
            return nil
        }
        return 180 - (540 - (out - into)).truncatingRemainder(dividingBy: 360)  // above -180, up to 180
    }

    /// The point `distance` metres along the route.
    static func point(at distance: Double, shape: [Coordinate], cumulative cum: [Double]) -> Coordinate {
        let i = min(max((cum.firstIndex { $0 > distance } ?? cum.count) - 1, 0), cum.count - 2)
        let length = cum[i + 1] - cum[i]
        let t = length > 0 ? min(max((distance - cum[i]) / length, 0), 1) : 0
        let a = shape[i], b = shape[i + 1]
        return Coordinate(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
    }
}

/// Maneuver codes understood by the Pebble watchapp: which icon it draws.
public enum WatchManeuver: Int, Sendable {
    case none = 0, straight, left, right, slightLeft, slightRight, uturnLeft, arrive
    case sharpLeft, sharpRight, keepLeft, keepRight, uturnRight
    case roundaboutRight, roundaboutLeft, roundaboutStraight, roundaboutUturn
    case rampLeft, rampRight, mergeLeft, mergeRight

    /// Maps a Valhalla maneuver to the watch's icon set. A roundabout shows the way it leads:
    /// `roundaboutTurn` (`Route.turn`), or without one its exit count, for right-hand
    /// traffic: the 1st exit right, the 2nd straight on, the 3rd left, then back.
    public init(_ m: ValhallaManeuver, roundaboutTurn: Double? = nil) {
        switch m.type {
        case 4, 5, 6: self = .arrive
        case 9: self = .slightRight
        case 10: self = .right
        case 11: self = .sharpRight
        case 12: self = .uturnRight
        case 13: self = .uturnLeft
        case 14: self = .sharpLeft
        case 15: self = .left
        case 16: self = .slightLeft
        case 18, 20: self = .rampRight
        case 19, 21: self = .rampLeft
        case 23: self = .keepRight
        case 24: self = .keepLeft
        case 37: self = .mergeRight
        case 38: self = .mergeLeft
        case 26:
            if let a = roundaboutTurn {
                self = abs(a) < 45 ? .roundaboutStraight : abs(a) > 135 ? .roundaboutUturn
                    : a > 0 ? .roundaboutRight : .roundaboutLeft
            } else {
                switch m.roundaboutExitCount {
                case 1?: self = .roundaboutRight
                case 3?: self = .roundaboutLeft
                case let n? where n >= 4: self = .roundaboutUturn
                default: self = .roundaboutStraight
                }
            }
        default: self = .straight  // start, continue, ramps straight, merges, ferries
        }
    }
}

public struct GuidanceUpdate: Sendable {
    /// The maneuver to show: the next one ahead, or from about 25 m before it the one
    /// after it (see `Guidance.switchLead`).
    public let maneuver: ValhallaManeuver
    /// The watch icon for `maneuver`.
    public let icon: WatchManeuver
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
    /// The fix couldn't be placed on the route: everything but `distanceFromRoute`,
    /// `fixTime` and `needsReroute` is the last placed fix's (before any, the route's
    /// start), with `speed` 0.
    public let held: Bool

    /// This update standing still, for a fix that couldn't be placed on the route.
    func holding(at time: Date, distanceFromRoute: Double, needsReroute: Bool) -> GuidanceUpdate {
        GuidanceUpdate(maneuver: maneuver, icon: icon, maneuverIndex: maneuverIndex,
                       distanceToManeuver: distanceToManeuver, cornerIndex: cornerIndex,
                       distanceToCorner: distanceToCorner, remainingDistance: remainingDistance,
                       remainingTime: remainingTime, distanceFromRoute: distanceFromRoute, along: along,
                       speed: 0, fixTime: time, arrived: false, needsReroute: needsReroute, held: true)
    }
}

/// Follows a route from GPS fixes: snaps each fix to the route line and finds
/// the next maneuver ahead.
public final class Guidance {
    public let route: Route
    public var arrivalRadius = 20.0
    /// Further from the route than this (or than the fix's accuracy, if worse), a fix is
    /// re-acquired anywhere on the route and doesn't count as having arrived. A fix still
    /// that far, or near only stretches facing the other way, isn't placed at all: the
    /// update holds the last placed one (`GuidanceUpdate.held`) instead of jumping to a
    /// far part of the route.
    public var corridor = 40.0
    /// A reroute takes `offRouteFixes` fixes in a row further than this from the route
    /// (or than their accuracy, if worse), or near only stretches of it facing the other
    /// way, while the GPS reports at least `offRouteMinSpeed`.
    /// Standing still doesn't count: a GPS warming up indoors drifts 10-30 m.
    public var offRouteDistance = 25.0
    public var offRouteFixes = 2
    public var offRouteMinSpeed = 1.0

    /// The step after the next maneuver is shown from this far before it, plus a second
    /// of travel to cover the delay until the watch hears of it, at most `maxSwitchLead`.
    /// Until the corner the watch shows its icon and counts down to the corner (`toCorner`).
    /// Not at a roundabout: its step stays up until the exit.
    public var switchLead = 25.0
    public var maxSwitchLead = 45.0
    /// How long a corner's own step stays up, at least, before the one after it replaces it,
    /// counted from when it became the next corner ahead.
    public var minStepTime = 3.0
    /// The shown step goes back to an earlier one only when the fix falls more than this
    /// before the corner passed last.
    public var goBackDistance = 65.0

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
    /// The next corner ahead, and when it last changed.
    private var cornerIndex = 0
    private var cornerSince: Date?
    /// The last update worked out from a fix: one placed on the route, or before any,
    /// the route's first fix held at its start.
    private var lastPlaced: GuidanceUpdate?

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
            abs((shape[i].bearing(to: shape[i + 1]) - course + 540).truncatingRemainder(dividingBy: 360) - 180)
        }
        func facingAway(_ i: Int) -> Bool {
            guard let course, cum[i + 1] - cum[i] > 1 else { return false }
            return courseOffset(i, course) > 100
        }
        // Nearest segment, optionally limited to a stretch of route around where we
        // were last time, so a fix can't jump past an upcoming U-turn onto the way back.
        // Jumping further ahead than expected also costs a little, so without a
        // heading (slow or stopped) the fix still prefers staying on the stretch it was on.
        func nearest(from lower: Double?, to upper: Double?,
                     penalizeJumps: Bool) -> (seg: Int, t: Double, d: Double, away: Bool) {
            var best = (seg: 0, t: 0.0, d: Double.greatestFiniteMagnitude, away: false)
            var bestScore = Double.greatestFiniteMagnitude
            for i in 0..<(shape.count - 1) {
                if let lower, cum[i + 1] < lower { continue }
                if let upper, cum[i] > upper { break }
                let p = project(location, onto: shape[i], shape[i + 1])
                let jump = cum[i] + p.t * (cum[i + 1] - cum[i]) - reference
                let away = facingAway(i)
                var score = p.distance + (away ? 1000 : 0)
                if penalizeJumps, jump > 30 { score += (jump - 30) * 0.5 }
                if score < bestScore {
                    bestScore = score
                    best = (i, p.t, p.distance, away)
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
        if best.d > corridor || best.away {
            best = nearest(from: nil, to: nil, penalizeJumps: false)  // re-acquire anywhere, e.g. after a detour
            reacquired = true
        }

        // A fix without a speed (Core Location's -1) neither counts nor resets. One near only
        // stretches facing the other way, e.g. riding back along the route, counts as off it.
        if best.d <= max(offRouteDistance, accuracy) && !best.away {
            offRouteCount = 0
        } else if let reported = reportedSpeed ?? gpsSpeed, reported >= 0 {
            offRouteCount = reported >= offRouteMinSpeed ? offRouteCount + 1 : 0
        }
        // Still beyond the corridor, or near only stretches facing the other way (e.g. a
        // reroute that starts off backwards): hold the last placed state, standing still,
        // rather than snap to a far part of the route. Off-route counting (above) goes on.
        let placed = best.d <= max(corridor, accuracy) && !best.away
        if !placed, let lastPlaced {
            if let gpsSpeed { speed = max(0, gpsSpeed) }
            return lastPlaced.holding(at: time, distanceFromRoute: best.d, needsReroute: offRouteCount >= offRouteFixes)
        }
        let prevAlong = along
        // Without a placed fix yet, the route's first one is held at its start.
        if placed { along = cum[best.seg] + best.t * (cum[best.seg + 1] - cum[best.seg]) }
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
        if !placed || (!firstFix && elapsed > 0 && progress < 0.1 && best.d > lastDistanceFromRoute) { routeSpeed = 0 }
        routeSpeed = max(0, routeSpeed)
        lastDistanceFromRoute = best.d

        // Next maneuver ahead of us (index 0 is the "start" instruction). Shortly before
        // its corner the one after it is shown instead, with the distance to the corner
        // (`toCorner` on the watch), so the rider sees what comes next while turning.
        // Once shown it stays, unless the fix falls back well before the corner, so GPS
        // jitter or braking for the turn doesn't flick the watch between the two.
        // A roundabout is passed only at its exit (`parseRoute` merged the exit maneuver
        // into it), so "exit 2" stays up while riding round; its distance shows 0 there.
        // The step after it isn't shown early.
        let maneuvers = route.maneuvers
        func start(_ i: Int) -> Double { cum[min(maneuvers[i].beginShapeIndex, cum.count - 1)] }
        func corner(_ i: Int) -> Double {
            maneuvers[i].type == 26 ? cum[min(maneuvers[i].endShapeIndex, cum.count - 1)] : start(i)
        }
        let nextIndex = (1..<maneuvers.count).first { corner($0) > along + 0.5 } ?? maneuvers.count - 1
        if nextIndex != cornerIndex {
            cornerIndex = nextIndex
            cornerSince = time
        }
        let toCorner = max(0, corner(nextIndex) - along)
        let lead = min(switchLead + routeSpeed, maxSwitchLead)  // + 1 s of travel
        // The corner's own step stays up for `minStepTime` from when it became the next corner:
        // with turns close together the next one can be within the lead as soon as the last is
        // passed, and a new route (trip start or reroute) can begin within the lead of its first.
        let seen = shownIndex > nextIndex || time.timeIntervalSince(cornerSince ?? time) >= minStepTime
        let early = nextIndex + 1 < maneuvers.count && maneuvers[nextIndex].type != 26 && toCorner <= lead && seen
        var index = early ? nextIndex + 1 : nextIndex
        // Never back to an earlier step unless the fix is well before the corner passed last,
        // also with corners closer together than the lead.
        if index < shownIndex, corner(shownIndex - 1) - along <= goBackDistance { index = shownIndex }
        shownIndex = index
        let toManeuver = max(0, start(shownIndex) - along)
        let remaining = max(0, route.totalLength - along)
        let arrived = placed && nextIndex == maneuvers.count - 1 && toCorner <= arrivalRadius

        let u = GuidanceUpdate(
            maneuver: maneuvers[shownIndex],
            icon: route.icons[shownIndex],
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
            needsReroute: offRouteCount >= offRouteFixes,
            held: !placed
        )
        lastPlaced = u
        return u
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
        var fields: [String: Any] = [
            "active": true,
            "stepId": routeGeneration * 1000 + u.maneuverIndex,
            "maneuver": u.icon.rawValue,
            "distance": Int(u.distanceToManeuver.rounded()),
            "instruction": watchText(u.maneuver.instruction),
            "remainM": Int(u.remainingDistance.rounded()),
            "remainS": Int(u.remainingTime.rounded()),
            // cm/s precision as a Decimal, so the JSON says 9.37 rather than 9.3699999999999992
            "speed": Decimal(countdownSpeed(u)) / 100,
            "fixTime": Int64((u.fixTime.timeIntervalSince1970 * 1000).rounded()),
            "poll": poll(u),
        ]
        // The step after the corner being taken, shown from `Guidance.switchLead` before
        // that corner: the watch counts down to the corner next to its icon first.
        if u.maneuverIndex > u.cornerIndex { fields["toCorner"] = Int(u.distanceToCorner.rounded()) }
        return ctx.fields.merging(fields) { $1 }
    }

    /// The speed the watch counts down with, in cm/s.
    static func countdownSpeed(_ u: GuidanceUpdate) -> Int {
        u.distanceFromRoute > countdownCorridor ? 0 : Int((max(0, u.speed) * 100).rounded())
    }

    /// Every second off the route or under 60 m from a maneuver, also standing still there,
    /// so the watch hears at once when the rider sets off. Every 2s within 300 m (3s standing
    /// still there, e.g. at a red light), every 3s within 1 km, otherwise every 10s. The
    /// corner being taken counts too: once the step after it is shown, that maneuver may be
    /// far away, but a missed turn must reach the watch fast.
    static func poll(_ u: GuidanceUpdate) -> Int {
        let near = min(u.distanceToManeuver, u.distanceToCorner)
        if u.distanceFromRoute > countdownCorridor || near < 60 { return 1000 }
        if countdownSpeed(u) == 0, near < 300 { return 3000 }
        return near < 300 ? 2000 : near < 1000 ? 3000 : 10000
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
