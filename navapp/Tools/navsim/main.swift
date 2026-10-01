// Mac stand-in for the iPhone app: same routing, guidance and 127.0.0.1 server,
// with a simulated drive along a real Valhalla route instead of GPS.
//
//   navsim [from-lat,lon] [to-lat,lon] [--speed m/s] [--costing motorbike|car|bicycle|walk] [--en]
//          [--route-json file]   use a saved Valhalla /route response instead of fetching one
//          [--theme light|dark|auto]  watch theme (auto: light between sunrise and sunset)
//   navsim --replay trip-log.csv --route-json file
//          feeds a trip log's GPS fixes through guidance and prints what the watch would get
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
let speed = Double(option("--speed") ?? "12") ?? 12
let costing = OpenMapServices.Costing(rawValue: [
    "motorbike": "motor_scooter", "car": "auto", "bicycle": "bicycle", "walk": "pedestrian",
][option("--costing") ?? "motorbike"] ?? "motor_scooter") ?? .motorbike
let routeFile = option("--route-json")
let replayFile = option("--replay")
let themeOption = option("--theme") ?? "auto"  // light | dark | auto (sunrise/sunset at the start)
let vietnamese = !args.contains("--en")
args.removeAll { $0 == "--en" }

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

/// Feeds the fixes of a trip log (`TripLog`) through guidance against `route`, as fast as
/// it can, and prints for each what the watch would be sent. Ends with the step switches,
/// the reroutes the app would have asked for (15s apart, as in the app) and the poll hints.
func replay(_ path: String, route: Route) throws {
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    // Only fix rows are read, and they hold no quoted commas, so a plain split will do.
    let header = lines.first?.split(separator: ",", omittingEmptySubsequences: false).map(String.init) ?? []
    let columns = ["time", "event", "lat", "lon", "accuracy", "speed", "course", "detail"].map { header.firstIndex(of: $0) }
    guard columns.allSatisfy({ $0 != nil }) else { throw OpenMapServices.ServiceError(message: "Not a trip log: \(path)") }
    let index = columns.map { $0! }

    let guidance = Guidance(route: route)
    let ctx = WatchContext(vietnamese: vietnamese, light: false)
    var start: Date?, shown: Int?, lastReroute = -Double.infinity
    var switches: [String] = [], reroutes: [String] = [], polls: [Int: Int] = [:], backwards = 0
    print(" time  shown next  to shown  to corner  off-route  speed   poll  reroute")
    for line in lines.dropFirst() {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count > index.max()!, f[index[1]] == "fix", f[index[7]] != "skipped",
              let t = Double(f[index[0]]), let lat = Double(f[index[2]]), let lon = Double(f[index[3]]),
              let accuracy = Double(f[index[4]]), let speed = Double(f[index[5]]),
              let course = Double(f[index[6]]) else { continue }
        let time = Date(timeIntervalSince1970: t)
        if start == nil {
            start = time
            guidance.startTime = time  // the route was requested from this fix
        }
        // The log has no speed or course accuracy: take any valid speed, and the course above 2 m/s.
        guard let u = guidance.update(Coordinate(lat: lat, lon: lon), accuracy: accuracy,
                                      course: course >= 0 && speed > 2 ? course : nil,
                                      speed: speed >= 0 ? speed : nil, reportedSpeed: speed, time: time) else { break }
        let offset = time.timeIntervalSince(start!)
        let step = WatchStep.step(u, routeGeneration: 1, ctx)
        let poll = step["poll"] as? Int ?? 0
        polls[poll, default: 0] += 1
        var note = ""
        if let shown, u.maneuverIndex != shown {
            if u.maneuverIndex < shown { backwards += 1 }
            // Ahead of the corner as intended, or only once past it (e.g. after a GPS gap).
            let at = u.cornerIndex < u.maneuverIndex ? String(format: "%.0f m", u.distanceToCorner) : "the corner"
            note = String(format: "  step %d -> %d at %@", shown, u.maneuverIndex, at)
            switches.append(String(format: "+%.0fs %d->%d at %@", offset, shown, u.maneuverIndex, at))
        }
        shown = u.maneuverIndex
        if u.needsReroute, offset - lastReroute > 15 {
            lastReroute = offset
            note += "  REROUTE"
            reroutes.append(String(format: "+%.0fs", offset))
        }
        print(String(format: "%5.0fs  %3d %4d  %6.0f m  %7.0f m  %7.1f m  %5.2f  %5d  %@%@", offset, u.maneuverIndex,
                     u.cornerIndex, u.distanceToManeuver, u.distanceToCorner, u.distanceFromRoute,
                     (step["speed"] as? NSNumber)?.doubleValue ?? 0, poll, u.needsReroute ? "yes" : "no", note))
        if u.arrived {
            print("Arrived.")
            break
        }
    }
    print("Step switches (distance to the corner): " + (switches.isEmpty ? "none" : switches.joined(separator: ", ")))
    print("Shown step went back \(backwards) times")
    print("Reroutes requested: " + (reroutes.isEmpty ? "none" : reroutes.joined(separator: ", ")))
    print("Poll hints: " + polls.keys.sorted().map { "\($0) ms ×\(polls[$0]!)" }.joined(separator: ", "))
}

if let replayFile {
    do {
        guard let routeFile else { throw OpenMapServices.ServiceError(message: "--replay needs --route-json") }
        try replay(replayFile, route: OpenMapServices.parseRoute(Data(contentsOf: URL(fileURLWithPath: routeFile))))
        exit(0)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
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
            route = try await OpenMapServices.route(from: from, to: to, costing: costing,
                                                    language: vietnamese ? "vi-VN" : "en-US")
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
