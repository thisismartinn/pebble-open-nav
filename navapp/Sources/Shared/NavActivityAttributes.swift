// Shared between the app and the widget extension (Live Activity).
// SCAFFOLD: the Live Activity agent fills this in.
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)  // Catalyst: local type-check only
import ActivityKit
import Foundation

struct NavActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var placeholder: Int = 0
    }
    var destinationName: String
}
#endif
