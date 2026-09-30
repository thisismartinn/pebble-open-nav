import CoreLocation
import Foundation

/// Ties GPS, routing and guidance together, and publishes each step to the
/// local server the Pebble watchapp polls. GPS runs only during a trip.
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
        case step(GuidanceUpdate)
        case ended(String)
    }

    @Published var phase: Phase = .idle
    @Published var query = ""
    @Published var results: [OpenMapServices.Place] = []
    @Published var searching = false
    /// The last query that finished searching, to tell "no results" from "not searched yet".
    @Published var lastSearch: String?
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
    @Published var watchStatus = ""
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
    private var destination: OpenMapServices.Place?
    /// Identifies the current trip, so a route request from an earlier trip
    /// that finishes late is ignored.
    private var tripID: UUID?
    private var lastReroute = Date.distantPast
    private var statusTimer: Timer?
    private var shutdownTask: Task<Void, Never>?
    private var payload: WatchPayload = .idle
    /// The theme last sent to the watch; re-checked every second so Automatic
    /// follows sunset even when nothing else is being published.
    private var sentLight: Bool?

    /// After a trip ends, keep running this long so the watch (polling every
    /// 3 s) can still fetch "ended" with the phone locked. Stopping GPS lets
    /// iOS suspend the app.
    private static let endedGracePeriod: UInt64 = 15_000_000_000

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.serverStateChanged(state) }
        }
        publish(.idle)
        server.start()
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

    // MARK: Search

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = String(localized: "Location is off for Nav Test. Turn it on in Settings to get directions.")
        default: manager.requestLocation()
        }
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            lastSearch = nil
            return
        }
        searching = true
        let near = location.map { Coordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        Task {
            defer { searching = false }
            do {
                results = try await OpenMapServices.search(text, near: near)
                lastSearch = text
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Trip

    func start(to place: OpenMapServices.Place) {
        shutdownTask?.cancel()
        shutdownTask = nil
        destination = place
        destinationName = place.name
        results = []
        lastSearch = nil
        query = ""
        route = nil
        update = nil
        guidance = nil
        tripID = UUID()
        phase = .routing
        awaitingFix = true
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
        stopGPS()
    }

    func stop() {
        finish(reason: String(localized: "Stopped on phone"))
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
        Task { await fetchRoute(from: fix.coordinate, trip: trip) }
    }

    private func fetchRoute(from start: CLLocationCoordinate2D, trip: UUID?) async {
        guard let trip, trip == tripID, let destination else { return }
        do {
            let route = try await OpenMapServices.route(
                from: Coordinate(lat: start.latitude, lon: start.longitude),
                to: destination.coordinate, costing: costing,
                language: vietnamese ? "vi-VN" : "en-US")
            guard trip == tripID else { return }  // trip ended or replaced meanwhile
            self.route = route
            guidance = Guidance(route: route)
            phase = .navigating
            if let location { handle(location) }
        } catch {
            guard trip == tripID else { return }
            if phase == .routing {
                errorMessage = error.localizedDescription
                cancel()
            }
            // A failed reroute keeps the current route; the next off-route fix retries.
        }
    }

    private func handle(_ fix: CLLocation) {
        location = fix
        if phase == .routing, awaitingFix, isUsable(fix, maxAge: 10) {
            routeFrom(fix)
            return
        }
        guard phase == .navigating, let guidance, isUsable(fix, maxAge: 10) else { return }
        let here = Coordinate(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude)
        let course = fix.course >= 0 && fix.speed > 2 && fix.courseAccuracy >= 0 && fix.courseAccuracy < 45
            ? fix.course : nil
        guard let u = guidance.update(here, accuracy: fix.horizontalAccuracy, course: course) else { return }
        update = u
        if u.arrived {
            finish(reason: String(localized: "You have arrived"))
            return
        }
        publish(.step(u))
        if u.needsReroute, Date().timeIntervalSince(lastReroute) > 15 {
            lastReroute = Date()
            let trip = tripID
            Task { await fetchRoute(from: fix.coordinate, trip: trip) }
        }
    }

    private func finish(reason: String) {
        publish(.ended(reason))
        phase = .ended(reason)
        guidance = nil
        tripID = nil
        awaitingFix = false
        shutdownTask?.cancel()
        shutdownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.endedGracePeriod)
            guard let self, !Task.isCancelled, self.tripID == nil else { return }
            self.stopGPS()
        }
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
        switch payload {
        case .idle: server.publish(WatchStep.idle(ctx))
        case .routing: server.publish(WatchStep.routing(ctx))
        case .step(let u): server.publish(WatchStep.step(u, ctx))
        case .ended(let reason): server.publish(WatchStep.ended(reason: reason, ctx))
        }
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

    private func refreshWatchStatus() {
        let stats = server.pollStats
        guard let last = stats.last else {
            watchStatus = String(localized: "Not connected yet. Open Nav Test on your Pebble.")
            return
        }
        let ago = Int(Date().timeIntervalSince(last))
        let gap = Int(stats.maxGap)
        watchStatus = String(localized: "Checked in \(ago) s ago · \(stats.count) times · longest gap \(gap) s")
    }
}

extension NavigationController: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in self.handle(fix) }
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
