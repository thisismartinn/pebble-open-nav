import CoreLocation
import Foundation

/// Ties GPS, routing and guidance together, and publishes each step to the
/// local server the Pebble watchapp polls. GPS runs only during a trip.
/// Whether the Pebble watchapp is polling, for the Pebble section of the UI.
struct WatchLinkStatus: Equatable {
    /// The watch checked in within the last 15s: it may wait 10s between check-ins far from a
    /// turn (the `poll` hint), plus the trip over Bluetooth and through the Pebble app.
    var connected = false
    /// Last check-in, if any.
    var lastCheckIn: Date?
    /// Check-ins since the watchapp was opened (or the trip started).
    var count = 0
    /// Longest gap between check-ins while the watchapp was open.
    var longestGap: TimeInterval = 0
}

/// Watch colour theme. Light is easier to read in sunlight on colour watches.
enum WatchTheme: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
}

@MainActor
final class NavigationController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle, routing, navigating
        case ended(String)
    }

    /// What the watch is currently being told, so it can be re-sent when a
    /// setting changes.
    private enum WatchPayload {
        case idle, routing
        case step(GuidanceUpdate, routeGeneration: Int)
        case ended(arrived: Bool)
    }

    @Published var phase: Phase = .idle
    @Published var errorMessage: String?
    @Published var costing: OpenMapServices.Costing = .motorbike
    /// The app follows the phone's language (Vietnamese or English); directions
    /// from Valhalla and the texts sent to the watch use the same language.
    let vietnamese = Bundle.main.preferredLocalizations.first?.hasPrefix("vi") ?? false
    @Published var route: Route?
    @Published var update: GuidanceUpdate?
    @Published var destinationName: String?
    @Published var location: CLLocation?
    /// True between starting a trip and the first accurate fix to route from.
    @Published var awaitingFix = false
    @Published var preciseLocationOff = false
    @Published var watchLink = WatchLinkStatus()
    /// The current or last trip's log (GPS fixes, guidance, watch polls), to share after a ride.
    @Published var tripLogURL: URL?
    @Published var watchTheme: WatchTheme =
        WatchTheme(rawValue: UserDefaults.standard.string(forKey: "watchTheme") ?? "") ?? .automatic {
        didSet {
            UserDefaults.standard.set(watchTheme.rawValue, forKey: "watchTheme")
            republish()
        }
    }
    @Published var serverProblem: String?

    private let manager = CLLocationManager()
    private let server = StepServer()
    private var guidance: Guidance?
    private var tripLog: TripLog?
    private var destination: OpenMapServices.Place?
    /// Identifies the current trip, so a route request from an earlier trip
    /// that finishes late is ignored.
    private var tripID: UUID?
    /// Goes up with every route or reroute accepted, across trips, so the watch's
    /// step ids never repeat.
    private var routeGeneration = 0
    private var lastReroute = Date.distantPast
    private var statusTimer: Timer?
    private var shutdownTask: Task<Void, Never>?
    private var payload: WatchPayload = .idle
    /// The theme last sent to the watch; re-checked every second so Automatic
    /// follows sunset even when nothing else is being published.
    private var sentLight: Bool?

    /// After a trip ends, keep running this long so the watch (polling every
    /// 3s) can still fetch "ended" with the phone locked. Stopping GPS lets
    /// iOS suspend the app.
    private static let endedGracePeriod: UInt64 = 15_000_000_000

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.serverStateChanged(state) }
        }
        server.onPoll = { [weak self] time, gap in
            Task { @MainActor in self?.tripLog?.poll(time: time, gap: gap) }
        }
        publish(.idle)
        server.start()
        LiveActivityController.shared.endLeftovers()  // e.g. the app was killed mid-trip
        refreshWatchStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshWatchStatus()
                if self.watchIsLight != self.sentLight { self.republish() }
            }
        }
    }

    /// Call when the app comes to the foreground.
    func appBecameActive() {
        server.start()  // no-op while it's running; restarts it if iOS reclaimed the socket
        refreshAccuracy()
        if phase == .idle { requestLocation() }
    }

    // MARK: Location

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = String(localized: "Location is off for PebbleOpenNav. Turn it on in Settings to get directions.")
        default: manager.requestLocation()
        }
    }

    // MARK: Trip

    func start(to place: OpenMapServices.Place) {
        // Now, while the app is certainly in the foreground: ActivityKit can't start
        // one from the background, e.g. after the phone is locked during routing.
        LiveActivityController.shared.begin(destinationName: place.name)
        shutdownTask?.cancel()
        shutdownTask = nil
        destination = place
        destinationName = place.name
        route = nil
        update = nil
        guidance = nil
        tripID = UUID()
        phase = .routing
        awaitingFix = true
        tripLog?.close("replaced by a new trip")
        tripLog = TripLog(destination: place.name, detail: costing.rawValue)
        tripLogURL = tripLog?.url
        server.start()
        server.resetStats()
        publish(.routing)
        startGPS()
        refreshAccuracy()
        // Route from a fresh fix: `location` may be minutes old if the app was in the background.
        if let fix = location, isUsable(fix, maxAge: 10) { routeFrom(fix) }
    }

    /// Cancels a trip that is still finding its route.
    func cancel() {
        tripID = nil
        destination = nil
        destinationName = nil
        awaitingFix = false
        phase = .idle
        publish(.idle)
        LiveActivityController.shared.end(arrived: false)
        stopGPS()
        tripLog?.event("end", "cancelled")
        closeTripLog()
    }

    func stop() {
        finish(arrived: false)
    }

    /// Back to search. The watch keeps getting "ended" until the next trip
    /// starts, so it still closes even if it polls late.
    func reset() {
        phase = .idle
        route = nil
        update = nil
        destination = nil
        destinationName = nil
    }

    private func routeFrom(_ fix: CLLocation) {
        awaitingFix = false
        let trip = tripID
        Task { await fetchRoute(from: fix, trip: trip) }
    }

    private func fetchRoute(from fix: CLLocation, trip: UUID?) async {
        guard let trip, trip == tripID, let destination else { return }
        do {
            let route = try await OpenMapServices.route(
                from: Coordinate(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude),
                to: destination.coordinate, costing: costing,
                language: vietnamese ? "vi-VN" : "en-US")
            guard trip == tripID else { return }  // trip ended or replaced meanwhile
            tripLog?.event(guidance == nil ? "route" : "reroute", String(
                format: "%.0f m, %.0fs, %d maneuvers", route.totalLength, route.totalTime, route.maneuvers.count))
            self.route = route
            let next = Guidance(route: route)
            next.speed = guidance?.speed ?? 0  // keep the watch predicting across a reroute
            next.startTime = fix.timestamp  // the rider has moved on while the route was fetched
            if costing == .walk { next.offRouteMinSpeed = 0.5 }  // walking GPS speeds hover around 1 m/s
            guidance = next
            routeGeneration += 1
            if phase == .routing { LiveActivityController.shared.start(destinationName: destinationName ?? "") }
            phase = .navigating
            if let location { handle(location) }
        } catch {
            guard trip == tripID else { return }
            tripLog?.event("route failed", error.localizedDescription)
            if phase == .routing {
                errorMessage = error.localizedDescription
                cancel()
            }
            // A failed reroute keeps the current route; the next off-route fix retries.
        }
    }

    /// Logs a fix as Core Location delivered it, before `handle` decides whether to use it.
    private func log(_ fix: CLLocation) {
        guard tripID != nil else { return }
        tripLog?.fix(time: fix.timestamp, lat: fix.coordinate.latitude, lon: fix.coordinate.longitude,
                     accuracy: fix.horizontalAccuracy, speed: fix.speed, course: fix.course,
                     detail: isUsable(fix, maxAge: 10) ? "" : "skipped")
    }

    private func handle(_ fix: CLLocation) {
        location = fix
        let usable = isUsable(fix, maxAge: 10)
        if phase == .routing, awaitingFix, usable {
            routeFrom(fix)
            return
        }
        guard phase == .navigating, let guidance, usable else { return }
        let here = Coordinate(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude)
        let course = fix.course >= 0 && fix.speed > 2 && fix.courseAccuracy >= 0 && fix.courseAccuracy < 45
            ? fix.course : nil
        // Doppler speed from the GPS; without it guidance estimates it from progress along the route.
        // The raw one, however inaccurate, still tells whether we're moving, for rerouting.
        let speed = fix.speed >= 0 && fix.speedAccuracy >= 0 && fix.speedAccuracy < 3 ? fix.speed : nil
        guard let u = guidance.update(here, accuracy: fix.horizontalAccuracy, course: course,
                                      speed: speed, reportedSpeed: fix.speed, time: fix.timestamp) else { return }
        tripLog?.guidance(u)
        update = u
        if u.arrived {
            finish(arrived: true)
            return
        }
        publish(.step(u, routeGeneration: routeGeneration))
        LiveActivityController.shared.update(u, vietnamese: vietnamese)
        if u.needsReroute, Date().timeIntervalSince(lastReroute) > 15 {
            lastReroute = Date()
            tripLog?.event("reroute requested")
            let trip = tripID
            Task { await fetchRoute(from: fix, trip: trip) }
        }
    }

    private func finish(arrived: Bool) {
        let reason = arrived ? String(localized: "You have arrived") : String(localized: "Stopped on phone")
        publish(.ended(arrived: arrived))
        tripLog?.event("end", arrived ? "arrived" : "stopped on phone")
        LiveActivityController.shared.end(arrived: arrived)
        phase = .ended(reason)
        guidance = nil
        tripID = nil
        awaitingFix = false
        shutdownTask?.cancel()
        shutdownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.endedGracePeriod)
            guard let self, !Task.isCancelled, self.tripID == nil else { return }
            self.stopGPS()
            self.closeTripLog()
        }
    }

    /// Stops logging; the file stays for sharing (`tripLogURL`).
    private func closeTripLog() {
        tripLog?.close()
        tripLog = nil
    }

    private func isUsable(_ fix: CLLocation, maxAge: TimeInterval) -> Bool {
        fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy < 100
            && -fix.timestamp.timeIntervalSinceNow < maxAge
    }

    // MARK: GPS

    private func startGPS() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        manager.activityType = .otherNavigation
        // Keeps GPS, and with it this app and its local server, running while
        // the phone is locked. Needs the "location" background mode.
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        #endif
        manager.startUpdatingLocation()
    }

    private func stopGPS() {
        manager.stopUpdatingLocation()
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        #endif
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// With Precise Location off, fixes are kilometres off and turn-by-turn can't work.
    /// Ask for full accuracy for this trip, and tell the user if it stays off.
    private func refreshAccuracy() {
        let reduced = manager.accuracyAuthorization == .reducedAccuracy
            && manager.authorizationStatus != .notDetermined
        preciseLocationOff = reduced
        if reduced, phase == .routing || phase == .navigating {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "Navigation")
        }
    }

    // MARK: Watch link

    private func publish(_ newPayload: WatchPayload) {
        payload = newPayload
        republish()
    }

    private func republish() {
        let light = watchIsLight
        sentLight = light
        let ctx = WatchContext(vietnamese: vietnamese, light: light, automaticTheme: watchTheme == .automatic)
        let body: [String: Any]
        switch payload {
        case .idle: body = WatchStep.idle(ctx)
        case .routing: body = WatchStep.routing(ctx)
        case .step(let u, let generation): body = WatchStep.step(u, routeGeneration: generation, ctx)
        case .ended(let arrived): body = WatchStep.ended(arrived: arrived, ctx)
        }
        server.publish(body)
        tripLog?.publish(body)
    }

    /// Automatic: light between sunrise and sunset where you are (6:00–18:00
    /// until there's a location). Re-evaluated on every GPS fix during a trip,
    /// so it switches at sunset mid-ride.
    var watchIsLight: Bool {
        switch watchTheme {
        case .light: return true
        case .dark: return false
        case .automatic:
            guard let c = location?.coordinate else {
                return (6..<18).contains(Calendar.current.component(.hour, from: Date()))
            }
            return Sun.isUp(at: Date(), at: Coordinate(lat: c.latitude, lon: c.longitude))
        }
    }

    private func serverStateChanged(_ state: StepServer.State) {
        switch state {
        case .running: serverProblem = nil
        case .starting: break
        case .failed(let message): serverProblem = String(localized: "The watch link stopped (\(message)). Retrying…")
        }
    }

    /// Runs every second. Assigns only on a change: every assignment to a @Published
    /// property redraws the views observing it, map included.
    private func refreshWatchStatus() {
        let stats = server.pollStats
        let status = stats.last.map {
            WatchLinkStatus(connected: Date().timeIntervalSince($0) < 15, lastCheckIn: $0,
                            count: stats.count, longestGap: stats.maxGap)
        } ?? WatchLinkStatus()
        if status != watchLink { watchLink = status }
    }
}

extension NavigationController: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in
            self.log(fix)
            self.handle(fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient GPS errors are common (e.g. indoors); the next fix recovers.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshAccuracy()
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            default: break
            }
        }
    }
}
