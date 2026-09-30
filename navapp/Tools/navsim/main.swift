// Mac stand-in for the iPhone app: same routing, guidance and 127.0.0.1 server,
// with a simulated drive along a real Valhalla route instead of GPS.
//
//   navsim [from-lat,lon] [to-lat,lon] [--speed m/s] [--costing motorbike|car|bicycle|walk] [--en]
//          [--route-json file]   use a saved Valhalla /route response instead of fetching one
//          [--theme light|dark|auto]  watch theme (auto: light between sunrise and sunset)
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

let server = StepServer()
server.onStateChange = { state in
    if case .failed(let message) = state { print("Server on 127.0.0.1:\(StepServer.port) failed: \(message)") }
}
let light = themeOption == "auto" ? Sun.isUp(at: Date(), at: from) : themeOption == "light"
let ctx = WatchContext(vietnamese: vietnamese, light: light)
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
        print(String(format: "Route: %.0f m, %.0f s, %d maneuvers, %d shape points",
                     route.totalLength, route.totalTime, route.maneuvers.count, route.shape.count))
        let guidance = Guidance(route: route)
        var travelled = 0.0
        while true {
            let fix = position(on: route, at: min(travelled, route.totalLength))
            guard let u = guidance.update(fix) else { break }
            if u.arrived {
                server.publish(WatchStep.ended(reason: vietnamese ? "Bạn đã tới nơi" : "You have arrived", ctx))
                print("Arrived. Serving \"ended\" for 20 s.")
                break
            }
            let step = WatchStep.step(u, ctx)
            server.publish(step)
            let stats = server.pollStats
            print(String(format: "%5.0f m  next in %4.0f m  off-route %4.1f m  polls %d  | %@",
                         travelled, u.distanceToManeuver, u.distanceFromRoute, stats.count,
                         step["instruction"] as? String ?? ""))
            travelled += speed
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000_000)
        let stats = server.pollStats
        print(String(format: "Watch polled %d times, longest gap %.1f s", stats.count, stats.maxGap))
        exit(0)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}
dispatchMain()
