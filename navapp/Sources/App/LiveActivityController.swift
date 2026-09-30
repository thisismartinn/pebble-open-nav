import Foundation

/// Shows the next turn on the Lock Screen and in the Dynamic Island.
/// SCAFFOLD: the Live Activity agent implements these; NavigationController
/// already calls them at the right moments.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    /// A route was found and navigation starts.
    func start(destinationName: String) {}

    /// Called on every guidance update (about once a second while moving).
    /// Implementations must throttle what they send to ActivityKit.
    func update(_ update: GuidanceUpdate, vietnamese: Bool) {}

    /// The trip ended (`arrived` false: stopped on the phone or cancelled).
    func end(arrived: Bool) {}
}
