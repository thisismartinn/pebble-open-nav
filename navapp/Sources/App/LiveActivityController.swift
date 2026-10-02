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

    /// A trip starts: call while the app is in front, because iOS only starts a
    /// Live Activity from the foreground. Shows "Finding a route…" until
    /// `start` and the first guidance update, which can then arrive in the
    /// background (e.g. the phone was locked while routing).
    func begin(destinationName: String) {
        self.destinationName = destinationName
        lastSent = nil
        nextAttempt = .distantPast
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        activity = nil  // a trip started over another one: its activity goes with the leftovers
        #endif
        endLeftovers()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        request(.routingPlaceholder())
        #endif
    }

    /// A route was found and navigation starts. The activity from `begin` is
    /// kept and the first guidance update, which follows within a second or so,
    /// replaces its placeholder in place. If `begin` was refused, that update
    /// requests one instead (only while the app is in front).
    func start(destinationName: String) {
        self.destinationName = destinationName
        lastSent = nil
        nextAttempt = .distantPast
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        if activity?.attributes.destinationName != destinationName {
            activity = nil  // not this trip's (no `begin`): it goes with the leftovers
        }
        #endif
        endLeftovers()
    }

    /// Called on every guidance update (about once a second while moving).
    /// Sends only when the maneuver or the rounded distance changes, or every 30 s,
    /// which also keeps pushing the stale date forward.
    func update(_ update: GuidanceUpdate, vietnamese: Bool) {
        // `vietnamese` isn't needed: the widget localizes its own texts, and the
        // instruction (`InstructionText`) is already in the route's language, the phone's.
        guard destinationName != nil else { return }
        let state = Self.state(for: update)
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard let activity else {
            request(state)
            return
        }
        if let last = lastSent, !last.state.routing, last.state.symbol == state.symbol,
           last.state.instruction == state.instruction, last.state.distance == state.distance,
           Date().timeIntervalSince(last.at) < 30 {
            return
        }
        lastSent = (state, Date())
        let content = Self.content(state)
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
        NavActivityState(symbol: symbolName(update.icon),
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
        case .none, .straight, .roundaboutStraight: "arrow.up"
        case .left, .roundaboutLeft: "arrow.turn.up.left"
        case .right, .roundaboutRight: "arrow.turn.up.right"
        case .slightLeft, .keepLeft, .rampLeft: "arrow.up.left"
        case .slightRight, .keepRight, .rampRight: "arrow.up.right"
        case .sharpLeft: "arrow.down.left"
        case .sharpRight: "arrow.down.right"
        // It turns left; iOS 17 has no mirrored one
        case .uturnLeft, .uturnRight, .roundaboutUturn: "arrow.uturn.down"
        case .mergeLeft, .mergeRight: "arrow.merge"
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
    /// If no update comes for this long (the app was killed or crashed mid-trip),
    /// the widget stops showing the last turn as if it were current.
    private static let staleAfter: TimeInterval = 90

    private static func content(_ state: NavActivityState) -> ActivityContent<NavActivityState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))
    }

    /// iOS only starts a Live Activity while the app is in the foreground. If it
    /// was refused (e.g. Live Activities are off, or `begin` wasn't called), this
    /// is retried on a later update once the app is back in front.
    private func request(_ state: NavActivityState) {
        guard let destinationName, Date() >= nextAttempt,
              UIApplication.shared.applicationState == .active else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            nextAttempt = Date().addingTimeInterval(30)  // turned off in Settings; check again later
            return
        }
        do {
            activity = try Activity<NavActivityAttributes>.request(attributes: NavActivityAttributes(destinationName: destinationName),
                                                                   content: Self.content(state),
                                                                   pushType: nil)
            lastSent = (state, Date())
        } catch {
            nextAttempt = Date().addingTimeInterval(30)
        }
    }
    #endif
}
