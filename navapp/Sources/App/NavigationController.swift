import CoreLocation
import Foundation

/// Ties GPS, routing and guidance together, and publishes each step to the
/// local server the Pebble watchapp polls. GPS runs only during a trip.
@MainActor
final class NavigationController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle, routing, navigating
        case ended(String)
    }

    @Published var phase: Phase = .idle
    @Published var query = ""
    @Published var results: [OpenMapServices.Place] = []
    @Published var searching = false
    @Published var errorMessage: String?
    @Published var costing: OpenMapServices.Costing = .motorbike
    @Published var vietnamese = Locale.preferredLanguages.first?.hasPrefix("vi") ?? false
    @Published var route: Route?
    @Published var update: GuidanceUpdate?
    @Published var location: CLLocation?
    @Published var watchStatus = ""
    @Published var serverError: String?

    private let manager = CLLocationManager()
    private let server = StepServer()
    private var guidance: Guidance?
    private var destination: OpenMapServices.Place?
    private var lastReroute = Date.distantPast
    private var statusTimer: Timer?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        do {
            try server.start()
        } catch {
            serverError = "The watch link couldn't start: \(error.localizedDescription)"
        }
        refreshWatchStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWatchStatus() }
        }
    }

    // MARK: Search

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: errorMessage = "Location is off for Nav Test. Turn it on in Settings."
        default: manager.requestLocation()
        }
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            return
        }
        searching = true
        let near = location.map { Coordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        Task {
            defer { searching = false }
            do {
                results = try await OpenMapServices.search(text, near: near)
                if results.isEmpty { errorMessage = "No places found for \"\(text)\"." }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Trip

    func start(to place: OpenMapServices.Place) {
        guard let here = location else {
            errorMessage = "Still finding your location. Try again in a moment."
            requestLocation()
            return
        }
        destination = place
        results = []
        phase = .routing
        server.resetStats()
        server.publish(WatchStep.idle)
        startGPS()
        Task { await fetchRoute(from: here.coordinate) }
    }

    func stop() {
        finish(reason: vietnamese ? "Đã dừng trên điện thoại" : "Stopped on phone")
    }

    /// Back to search. The watch keeps getting "ended" until the next trip
    /// starts, so it still closes even if it polls late.
    func reset() {
        phase = .idle
        route = nil
        update = nil
        destination = nil
    }

    private func fetchRoute(from start: CLLocationCoordinate2D) async {
        guard let destination else { return }
        do {
            let route = try await OpenMapServices.route(
                from: Coordinate(lat: start.latitude, lon: start.longitude),
                to: destination.coordinate, costing: costing,
                language: vietnamese ? "vi-VN" : "en-US")
            guard phase == .routing || phase == .navigating else { return }  // ended meanwhile
            self.route = route
            guidance = Guidance(route: route)
            phase = .navigating
            if let location { handle(location) }
        } catch {
            errorMessage = error.localizedDescription
            if phase == .routing {
                phase = .idle
                stopGPS()
            }
        }
    }

    private func handle(_ fix: CLLocation) {
        location = fix
        guard phase == .navigating, let guidance,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy < 100 else { return }
        let here = Coordinate(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude)
        guard let u = guidance.update(here, accuracy: fix.horizontalAccuracy) else { return }
        update = u
        if u.arrived {
            finish(reason: vietnamese ? "Bạn đã tới nơi" : "You have arrived")
            return
        }
        server.publish(WatchStep.step(u, vietnamese: vietnamese))
        if u.needsReroute, Date().timeIntervalSince(lastReroute) > 15 {
            lastReroute = Date()
            Task { await fetchRoute(from: fix.coordinate) }
        }
    }

    private func finish(reason: String) {
        server.publish(WatchStep.ended(reason: reason))
        phase = .ended(reason)
        guidance = nil
        stopGPS()
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

    private func refreshWatchStatus() {
        let stats = server.pollStats
        guard let last = stats.last else {
            watchStatus = "Watch not connected yet. Open Nav Test on your Pebble."
            return
        }
        let ago = Int(Date().timeIntervalSince(last))
        watchStatus = "Watch checked in \(ago) s ago · \(stats.count) times · longest gap \(Int(stats.maxGap)) s"
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
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            default: break
            }
        }
    }
}
