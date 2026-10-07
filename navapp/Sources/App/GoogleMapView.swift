import CoreLocation
import GoogleMaps
import SwiftUI

/// Google's map, for the Google maps source: the route, the destination, the rider's
/// position, and Google's places, tappable while idle. It follows the rider during a trip
/// until they move the map, and again after a tap on the location button.
struct GoogleMapView: UIViewRepresentable {
    let route: Route?
    let destinationName: String?
    let location: CLLocation?
    let navigating: Bool
    /// How much of the map's bottom the sheet covers, past the safe area: Google's logo
    /// and buttons sit above it.
    let bottomInset: CGFloat
    let onPlaceTap: (_ placeID: String, _ name: String, _ coordinate: CLLocationCoordinate2D) -> Void

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        if let location {
            options.camera = GMSCameraPosition(target: location.coordinate, zoom: 15)
            context.coordinator.centered = true
        }
        let map = GMSMapView(options: options)
        map.isMyLocationEnabled = true
        map.isTrafficEnabled = true
        map.settings.myLocationButton = true
        map.settings.compassButton = true
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        let c = context.coordinator
        c.onPlaceTap = navigating ? nil : onPlaceTap
        map.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let padding = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        if map.padding != padding { map.padding = padding }

        // The route and destination, redrawn only when the route changes.
        let routeID = route.map { "\($0.shape.count) \($0.totalLength) \($0.totalTime)" }
        if routeID != c.routeID {
            c.routeID = routeID
            c.line?.map = nil
            c.marker?.map = nil
            c.line = nil
            c.marker = nil
            if let route {
                let path = GMSMutablePath()
                for p in route.shape { path.add(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)) }
                let line = GMSPolyline(path: path)
                line.strokeWidth = 6
                line.strokeColor = .systemBlue
                line.map = map
                c.line = line
                if let end = route.shape.last {
                    let marker = GMSMarker(position: CLLocationCoordinate2D(latitude: end.lat, longitude: end.lon))
                    marker.title = destinationName
                    marker.map = map
                    c.marker = marker
                }
            }
        }

        // Camera: on the rider when the map first gets a position, and following them,
        // heading up, during a trip.
        if navigating != c.navigating {
            c.navigating = navigating
            c.following = navigating
        }
        // Only for a new fix: this also runs on every other change, e.g. the sheet moving.
        guard let location, location.timestamp != c.lastFix else { return }
        c.lastFix = location.timestamp
        if c.navigating, c.following {
            let bearing = location.course >= 0 ? location.course : map.camera.bearing
            map.animate(to: GMSCameraPosition(target: location.coordinate, zoom: 17, bearing: bearing, viewingAngle: 0))
        } else if !c.centered {
            c.centered = true
            map.animate(to: GMSCameraPosition(target: location.coordinate, zoom: 15))
        }
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        var onPlaceTap: ((String, String, CLLocationCoordinate2D) -> Void)?
        var routeID: String?
        var line: GMSPolyline?
        var marker: GMSMarker?
        var navigating = false
        var following = false
        var centered = false
        var lastFix: Date?

        func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
            if gesture { following = false }
        }

        func didTapMyLocationButton(for mapView: GMSMapView) -> Bool {
            following = navigating
            return false  // and let the map centre on the rider
        }

        func mapView(_ mapView: GMSMapView, didTapPOIWithPlaceID placeID: String, name: String,
                     location: CLLocationCoordinate2D) {
            onPlaceTap?(placeID, name, location)
        }
    }
}
