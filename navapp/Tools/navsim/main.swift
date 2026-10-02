// Mac stand-in for the iPhone app: same routing, guidance and 127.0.0.1 server,
// with a simulated drive along a real Valhalla route instead of GPS.
//
//   navsim [from-lat,lon] [to-lat,lon] [--speed m/s] [--costing motorbike|car|bicycle|walk] [--en]
//          [--route-json file]   use a saved Valhalla /route response instead of fetching one
//          [--theme light|dark|auto]  watch theme (auto: light between sunrise and sunset)
//   navsim --replay trip-log.csv --route-json file [--reroute-to lat,lon [--route-cache dir]]
//          feeds a trip log's GPS fixes through guidance and prints what the watch would get.
//          With --reroute-to, a reroute fetches a new route from the fix to there, as the app
//          would (heading included), and the replay goes on with it
//   navsim --icons route.json...
//          prints the watch icon of every maneuver
//   navsim --request-body [from-lat,lon] [to-lat,lon] [--course degrees,accuracy,speed]
//          prints the Valhalla request the app would send from a fix with that course
//
// Build (from navapp/): swiftc -O Sources/Core/*.swift Tools/navsim/main.swift -o build/navsim
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func flag(_ name: String) -> Bool {
    defer { args.removeAll { $0 == name } }
    return args.contains(name)
}
let speed = Double(option("--speed") ?? "12") ?? 12
let costing = OpenMapServices.Costing(rawValue: [
    "motorbike": "motor_scooter", "car": "auto", "bicycle": "bicycle", "walk": "pedestrian",
][option("--costing") ?? "motorbike"] ?? "motor_scooter") ?? .motorbike
let routeFile = option("--route-json")
let replayFile = option("--replay")
let rerouteOption = option("--reroute-to")
let routeCache = option("--route-cache")
let courseOption = option("--course")
let themeOption = option("--theme") ?? "auto"  // light | dark | auto (sunrise/sunset at the start)
let vietnamese = !flag("--en")
let language = vietnamese ? "vi-VN" : "en-US"
let showIcons = flag("--icons")
let showRequest = flag("--request-body")

func coordinate(_ s: String?) -> Coordinate? {
    guard let parts = s?.split(separator: ","), parts.count == 2,
          let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
    return Coordinate(lat: lat, lon: lon)
}
// Default: Kim Mã → Lotte Center, Hà Nội
let from = coordinate(args.first) ?? Coordinate(lat: 21.0300, lon: 105.8190)
let to = coordinate(args.dropFirst().first) ?? Coordinate(lat: 21.0322, lon: 105.8126)

/// Point `distance` metres along the route, with a few metres of GPS-like jitter.
func position(on route: Route, at distance: Double) -> Coordinate {
    let cum = route.cumulative
    let i = max(0, (cum.firstIndex { $0 > distance } ?? cum.count - 1) - 1)
    let segLen = cum[i + 1] - cum[i]
    let t = segLen > 0 ? (distance - cum[i]) / segLen : 0
    let a = route.shape[i], b = route.shape[i + 1]
    let jitter = { Double.random(in: -0.00003...0.00003) }  // ~3 m
    return Coordinate(lat: a.lat + (b.lat - a.lat) * t + jitter(), lon: a.lon + (b.lon - a.lon) * t + jitter())
}

func json(_ object: Any, pretty: Bool = false) -> String {
    let data = try? JSONSerialization.data(withJSONObject: object, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

/// Fetches a route with the app's request, printing it, or reads it from `routeCache` when it
/// was fetched before.
func fetchRoute(from: Coordinate, to: Coordinate, heading: Int?) async throws -> Route {
    let body = OpenMapServices.routeRequest(from: from, to: to, costing: costing, language: language, heading: heading)
    print("Valhalla request: " + json(body))
    let cached = routeCache.map {
        URL(fileURLWithPath: $0).appendingPathComponent(String(format: "route-%.6f,%.6f-%.6f,%.6f-%@-%@.json", from.lat, from.lon,
                                                               to.lat, to.lon, heading.map(String.init) ?? "any", language))
    }
    if let cached, let data = try? Data(contentsOf: cached) { return try OpenMapServices.parseRoute(data, language: language) }
    var request = URLRequest(url: OpenMapServices.valhallaURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw OpenMapServices.ServiceError(message: "Valhalla: " + String(decoding: data, as: UTF8.self))
    }
    if let cached { try? data.write(to: cached) }
    return try OpenMapServices.parseRoute(data, language: language)
}

/// Feeds the fixes of a trip log (`TripLog`) through guidance against `route`, as fast as
/// it can, and prints for each what the watch would be sent. Ends with the step switches,
/// the toCorner phases, the reroutes the app would have asked for (15s apart, as in the
/// app), the poll hints and how often the watch would poll by them.
/// - Parameter rerouteTo: where a reroute goes; without it the replay stays on `route`.
func replay(_ path: String, route first: Route, rerouteTo: Coordinate?) async throws {
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    // Only fix rows are read, and they hold no quoted commas, so a plain split will do.
    let header = lines.first?.split(separator: ",", omittingEmptySubsequences: false).map(String.init) ?? []
    let columns = ["time", "event", "lat", "lon", "accuracy", "speed", "course", "detail"].map { header.firstIndex(of: $0) }
    guard columns.allSatisfy({ $0 != nil }) else { throw OpenMapServices.ServiceError(message: "Not a trip log: \(path)") }
    let index = columns.map { $0! }
    // Older logs have no speed or course accuracy.
    let accuracyIndex = (speed: header.firstIndex(of: "speed_accuracy"), course: header.firstIndex(of: "course_accuracy"))

    var route = first, generation = 1
    var guidance = Guidance(route: route)
    let ctx = WatchContext(vietnamese: vietnamese, light: false)
    var start: Date?, shown: Int?, lastReroute = -Double.infinity
    var switches: [String] = [], reroutes: [String] = [], polls: [Int: Int] = [:], backwards = 0, held = 0
    // toCorner phases, and how long each corner had been the next one when its phase began.
    // A step's phase ends at the corner; toCorner for it again (GPS jitter at the corner) is
    // counted apart: the watch stays on the step's full screen then.
    var phaseStep: Int?, phases: [String] = [], ended: Set<Int> = [], again = 0
    var atRoundabout = 0, misplaced = 0, minWait = Double.infinity
    var corner: Int?, cornerSince = 0.0
    // The watch asks again `poll` ms after each answer, plus ~0.08 s (measured on the rides).
    var nextPoll = 0.0, hint = 1000, watchPolls = 0

    func show(_ u: GuidanceUpdate, at offset: Double) {
        let step = WatchStep.step(u, routeGeneration: generation, ctx)
        let stepId = step["stepId"] as? Int ?? 0, toCorner = step["toCorner"] as? Int
        hint = step["poll"] as? Int ?? 0
        polls[hint, default: 0] += 1
        if u.held { held += 1 }
        if stepId / 1000 * 1000 + u.cornerIndex != corner {
            corner = stepId / 1000 * 1000 + u.cornerIndex
            cornerSince = offset
        }
        var note = ""
        if let shown, stepId != shown {
            if stepId < shown { backwards += 1 }
            // Ahead of the corner as intended, or only once past it (e.g. after a GPS gap).
            let at = u.cornerIndex < u.maneuverIndex ? String(format: "%.0f m", u.distanceToCorner) : "the corner"
            note = String(format: "  step %d -> %d at %@", shown, stepId, at)
            switches.append(String(format: "+%.0fs %d->%d at %@", offset, shown, stepId, at))
        }
        shown = stepId
        if (toCorner != nil) != (u.maneuverIndex > u.cornerIndex) { misplaced += 1 }
        if let toCorner {
            if route.maneuvers[u.cornerIndex].type == 26 { atRoundabout += 1 }
            if ended.contains(stepId) {
                again += 1
            } else if phaseStep != stepId {
                phaseStep = stepId
                minWait = min(minWait, offset - cornerSince)
                phases.append(String(format: "+%.0fs %d at %d m (%.0fs)", offset, stepId, toCorner, offset - cornerSince))
            }
        } else if let step = phaseStep {
            ended.insert(step)
            phaseStep = nil
        }
        if u.held { note += "  held" }
        print(String(format: "%5.0fs  %4d %4d  %6.0f m  %7.0f m  %@  %4d  %7.1f m  %5.2f  %5.0fs  %5d  %@%@", offset, stepId,
                     u.cornerIndex, u.distanceToManeuver, u.distanceToCorner,
                     toCorner.map { String(format: "%6d m", $0) } ?? "       -", u.icon.rawValue, u.distanceFromRoute,
                     (step["speed"] as? NSNumber)?.doubleValue ?? 0, u.remainingTime, hint, u.needsReroute ? "yes" : "no", note))
    }

    print(" time  step next  to shown  to corner  toCorner  icon  off-route  speed    left   poll  reroute")
    for line in lines.dropFirst() {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count > index.max()!, f[index[1]] == "fix", f[index[7]] != "skipped",
              let t = Double(f[index[0]]), let lat = Double(f[index[2]]), let lon = Double(f[index[3]]),
              let accuracy = Double(f[index[4]]), let speed = Double(f[index[5]]),
              let course = Double(f[index[6]]) else { continue }
        let speedAccuracy = accuracyIndex.speed.flatMap { $0 < f.count ? Double(f[$0]) : nil }
        let courseAccuracy = accuracyIndex.course.flatMap { $0 < f.count ? Double(f[$0]) : nil }
        let time = Date(timeIntervalSince1970: t)
        if start == nil {
            start = time
            guidance.startTime = time  // the route was requested from this fix
        }
        let offset = time.timeIntervalSince(start!)
        while nextPoll < offset {
            watchPolls += 1
            nextPoll += Double(hint) / 1000 + 0.08
        }
        // As the app takes them; without the accuracies, any valid speed and the course above 2 m/s.
        let here = Coordinate(lat: lat, lon: lon)
        let validCourse = course >= 0 && speed > 2 && (courseAccuracy.map { $0 >= 0 && $0 < 45 } ?? true)
        let validSpeed = speed >= 0 && (speedAccuracy.map { $0 >= 0 && $0 < 3 } ?? true)
        guard var u = guidance.update(here, accuracy: accuracy, course: validCourse ? course : nil,
                                      speed: validSpeed ? speed : nil, reportedSpeed: speed, time: time) else { break }
        show(u, at: offset)
        if u.needsReroute, offset - lastReroute > 15 {
            lastReroute = offset
            reroutes.append(String(format: "+%.0fs", offset))
            print("REROUTE")
            if let rerouteTo {
                do {
                    // A course of unknown accuracy (older logs) counts as good
                    let heading = OpenMapServices.heading(course: course, courseAccuracy: courseAccuracy ?? 0, speed: speed)
                    route = try await fetchRoute(from: here, to: rerouteTo, heading: heading)
                    print(String(format: "New route: %.0f m, %.0fs, %d maneuvers", route.totalLength, route.totalTime,
                                 route.maneuvers.count))
                    let next = Guidance(route: route)
                    next.speed = guidance.speed
                    next.startTime = time
                    guidance = next
                    generation += 1
                    // The app hands the fix it rerouted from to the new route at once.
                    guard let first = guidance.update(here, accuracy: accuracy, course: validCourse ? course : nil,
                                                      speed: validSpeed ? speed : nil, reportedSpeed: speed,
                                                      time: time) else { break }
                    u = first
                    show(u, at: offset)
                } catch {
                    print("Reroute failed: \(error.localizedDescription)")
                }
            }
        }
        if u.arrived {
            print("Arrived.")
            break
        }
    }
    print("Step switches (distance to the corner): " + (switches.isEmpty ? "none" : switches.joined(separator: ", ")))
    print("Shown step went back \(backwards) times")
    print("toCorner phases (step, distance to the corner when it began, time since that corner became the next one): "
          + (phases.isEmpty ? "none" : phases.joined(separator: ", ")))
    print(String(format: "Phases at a roundabout: %d; toCorner without a step ahead of its corner or the other way round: %d; "
                 + "shortest wait for a phase: %@; toCorner again after a phase ended: %d", atRoundabout, misplaced,
                 minWait.isFinite ? String(format: "%.1fs", minWait) : "-", again))
    print("Fixes held (not placed on the route): \(held)")
    print("Reroutes requested: " + (reroutes.isEmpty ? "none" : reroutes.joined(separator: ", ")))
    print("Poll hints: " + polls.keys.sorted().map { "\($0) ms ×\(polls[$0]!)" }.joined(separator: ", "))
    print("Watch polls by the hints: \(watchPolls)")
}

if showIcons {
    for file in args {
        do {
            let route = try OpenMapServices.parseRoute(Data(contentsOf: URL(fileURLWithPath: file)))
            print("== \(file)")
            for (i, m) in route.maneuvers.enumerated() {
                let turn = m.type == 26 ? Route.turn(at: m, shape: route.shape, cumulative: route.cumulative) : nil
                let ring = m.type == 26 ? String(format: " (turns %@, exit %d)", turn.map { String(format: "%.0f°", $0) } ?? "?",
                                                 m.roundaboutExitCount ?? 0) : ""
                print(String(format: "%3d  type %2d -> %2d %@%@  %@", i, m.type, route.icons[i].rawValue,
                             "\(route.icons[i])", ring, m.instruction))
            }
        } catch {
            print("\(file): \(error.localizedDescription)")
        }
    }
    exit(0)
}

if showRequest {
    // As Core Location reports them: course and its accuracy in degrees, speed in m/s
    let c = courseOption?.split(separator: ",").compactMap { Double($0) } ?? []
    let heading = c.count == 3 ? OpenMapServices.heading(course: c[0], courseAccuracy: c[1], speed: c[2]) : nil
    print(json(OpenMapServices.routeRequest(from: from, to: to, costing: costing, language: language, heading: heading),
               pretty: true))
    exit(0)
}

if let replayFile {
    Task {
        do {
            guard let routeFile else { throw OpenMapServices.ServiceError(message: "--replay needs --route-json") }
            let route = try OpenMapServices.parseRoute(Data(contentsOf: URL(fileURLWithPath: routeFile)))
            try await replay(replayFile, route: route, rerouteTo: coordinate(rerouteOption))
            exit(0)
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}

let server = StepServer()
server.onStateChange = { state in
    if case .failed(let message) = state { print("Server on 127.0.0.1:\(StepServer.port) failed: \(message)") }
}
let light = themeOption == "auto" ? Sun.isUp(at: Date(), at: from) : themeOption == "light"
let ctx = WatchContext(vietnamese: vietnamese, light: light, automaticTheme: themeOption == "auto")
print("Watch theme: \(light ? "light" : "dark")")
server.publish(WatchStep.idle(ctx))
server.start()

Task {
    do {
        let route: Route
        if let routeFile {
            route = try OpenMapServices.parseRoute(Data(contentsOf: URL(fileURLWithPath: routeFile)))
        } else {
            route = try await OpenMapServices.route(from: from, to: to, costing: costing, language: language)
        }
        print(String(format: "Route: %.0f m, %.0fs, %d maneuvers, %d shape points",
                     route.totalLength, route.totalTime, route.maneuvers.count, route.shape.count))
        let guidance = Guidance(route: route)
        var travelled = 0.0
        while true {
            let fix = position(on: route, at: min(travelled, route.totalLength))
            // The simulated speed stands in for the GPS speed; the fix is taken now.
            guard let u = guidance.update(fix, speed: speed, time: Date()) else { break }
            if u.arrived {
                server.publish(WatchStep.ended(arrived: true, ctx))
                print("Arrived. Serving \"ended\" for 20s.")
                break
            }
            let step = WatchStep.step(u, routeGeneration: 1, ctx)
            server.publish(step)
            let stats = server.pollStats
            print(String(format: "%5.0f m  next in %4.0f m  off-route %4.1f m  %4.0f m / %4.0fs left  polls %d  | %@",
                         travelled, u.distanceToManeuver, u.distanceFromRoute, u.remainingDistance,
                         u.remainingTime, stats.count, step["instruction"] as? String ?? ""))
            travelled += speed
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000_000)
        let stats = server.pollStats
        print(String(format: "Watch polled %d times, longest gap %.1fs", stats.count, stats.maxGap))
        exit(0)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}
dispatchMain()
