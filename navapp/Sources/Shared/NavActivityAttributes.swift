// Shared between the app and the widget extension (Live Activity).
import Foundation

/// What the Live Activity shows. Kept outside the ActivityKit fence so the
/// widget's views and the app's mapping also type-check on Mac Catalyst.
/// Small on purpose: ActivityKit caps a payload at 4 KB.
struct NavActivityState: Codable, Hashable, Sendable {
    /// SF Symbol for the next maneuver.
    var symbol: String
    /// Metres to the next maneuver, rounded to the step the app updates at.
    var distance: Int
    var instruction: String
    /// Metres to the destination.
    var remaining: Int
    var arrival: Date
    /// The trip is over; `arrived` false: stopped on the phone.
    var ended = false
    var arrived = false
    /// Placeholder while the route is being found: no distance or ETA yet.
    var routing = false

    /// Shown instead of a maneuver while routing, and when the activity went stale.
    static let navigationSymbol = "arrow.triangle.turn.up.right.diamond"

    static func routingPlaceholder() -> NavActivityState {
        NavActivityState(symbol: navigationSymbol, distance: 0, instruction: "", remaining: 0,
                         arrival: Date(), routing: true)
    }

    static func ended(arrived: Bool) -> NavActivityState {
        NavActivityState(symbol: arrived ? "mappin.circle.fill" : "checkmark.circle.fill",
                         distance: 0, instruction: "", remaining: 0, arrival: Date(),
                         ended: true, arrived: arrived)
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)  // Catalyst: local type-check only
import ActivityKit

struct NavActivityAttributes: ActivityAttributes {
    typealias ContentState = NavActivityState
    var destinationName: String
}
#endif
