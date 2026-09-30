import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)  // Catalyst: local type-check only
import ActivityKit
import UIKit
#endif

/// Shows the next turn on the Lock Screen and in the Dynamic Island.
/// NavigationController calls it at the right moments; updates keep flowing
/// while the phone is locked because the app runs background location.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    /// Set during a trip.
    private var destinationName: String?
    /// The last state handed to ActivityKit and when, for throttling.
    private var lastSent: (state: NavActivityState, at: Date)?
    /// After a failed request, don't ask again before this.
    private var nextAttempt = Date.distantPast
    /// ActivityKit calls run one after another, so an end never overtakes an update.
    private var queue: Task<Void, Never>?
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var activity: Activity<NavActivityAttributes>?
    #endif

    /// A route was found and navigation starts. The activity itself is
    /// requested with the first guidance update, which follows within a second
    /// or so, because it needs a step to show.
    func start(destinationName: String) {
        self.destinationName = destinationName
        lastSent = nil
        nextAttempt = .distantPast
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        activity = nil  // a trip started over another one: its activity goes with the leftovers
        #endif
        endLeftovers()
    }

    /// Called on every guidance update (about once a second while moving).
    /// Sends only when the maneuver or the rounded distance changes, or every 30 s.
    func update(_ update: GuidanceUpdate, vietnamese: Bool) {
        // `vietnamese` isn't needed: the widget localizes its own texts, and the
        // instruction already comes from Valhalla in the phone language.
        guard destinationName != nil else { return }
        let state = Self.state(for: update)
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard let activity else {
            request(state)
            return
        }
        if let last = lastSent, last.state.symbol == state.symbol, last.state.instruction == state.instruction,
           last.state.distance == state.distance, Date().timeIntervalSince(last.at) < 30 {
            return
        }
        lastSent = (state, Date())
        let content = ActivityContent(state: state, staleDate: nil)
        enqueue { await activity.update(content) }
        #endif
    }

    /// The trip ended (`arrived` false: stopped on the phone or cancelled).
    /// Shows the ended state and dismisses it about 10 s later.
    func end(arrived: Bool) {
        destinationName = nil
        lastSent = nil
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(state: NavActivityState.ended(arrived: arrived), staleDate: nil)
        let dismissal = ActivityUIDismissalPolicy.after(Date().addingTimeInterval(10))
        enqueue { await activity.end(content, dismissalPolicy: dismissal) }
        #endif
    }

    /// Removes activities a previous run left behind (e.g. the app was killed
    /// mid-trip). Also safe to call at launch.
    func endLeftovers() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        let current = activity?.id
        let leftovers = Activity<NavActivityAttributes>.activities.filter { $0.id != current }
        guard !leftovers.isEmpty else { return }
        enqueue {
            for old in leftovers { await old.end(nil, dismissalPolicy: .immediate) }
        }
        #endif
    }

    // MARK: Mapping

    static func state(for update: GuidanceUpdate) -> NavActivityState {
        NavActivityState(symbol: symbolName(WatchManeuver(valhallaType: update.maneuver.type)),
                         distance: roundedDistance(update.distanceToManeuver),
                         instruction: instruction(update.maneuver.instruction),
                         remaining: Int((max(0, update.remainingDistance) / 100).rounded()) * 100,
                         arrival: Date(timeIntervalSinceNow: max(0, update.remainingTime)))
    }

    /// Rounds down to the step the activity updates at: 100 m from 1 km,
    /// 50 m from 200 m, 10 m below.
    static func roundedDistance(_ metres: Double) -> Int {
        let m = max(0, metres)
        let step: Double = m >= 1000 ? 100 : m >= 200 ? 50 : 10
        return Int((m / step).rounded(.down) * step)
    }

    /// Same symbols as the trip screen (`WatchManeuver.symbolName` in ContentView).
    private static func symbolName(_ maneuver: WatchManeuver) -> String {
        switch maneuver {
        case .none, .straight: "arrow.up"
        case .left: "arrow.turn.up.left"
        case .right: "arrow.turn.up.right"
        case .slightLeft: "arrow.up.left"
        case .slightRight: "arrow.up.right"
        case .uturn: "arrow.uturn.down"
        case .arrive: "mappin.circle.fill"
        }
    }

    /// No trailing full stop, and short enough to keep the payload well under 4 KB.
    private static func instruction(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(".") { text.removeLast() }
        return String(text.prefix(150))
    }

    // MARK: ActivityKit

    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
        }
    }

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    /// iOS only starts a Live Activity while the app is in the foreground. If it
    /// was refused (e.g. the phone was locked while routing), this is retried on
    /// a later update once the app is back in front.
    private func request(_ state: NavActivityState) {
        guard let destinationName, Date() >= nextAttempt,
              UIApplication.shared.applicationState == .active else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            nextAttempt = Date().addingTimeInterval(30)  // turned off in Settings; check again later
            return
        }
        do {
            activity = try Activity<NavActivityAttributes>.request(attributes: NavActivityAttributes(destinationName: destinationName),
                                                                   content: ActivityContent(state: state, staleDate: nil),
                                                                   pushType: nil)
            lastSent = (state, Date())
        } catch {
            nextAttempt = Date().addingTimeInterval(30)
        }
    }
    #endif
}
