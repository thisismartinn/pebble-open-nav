// Live Activity views. They take plain values rather than ActivityKit types,
// so they also type-check on Mac Catalyst (see scripts/typecheck.sh).
import SwiftUI

enum NavFormat {
    /// "350 m", "1.2 km" (Vietnamese "1,2 km"), following the device locale.
    static func distance(_ metres: Int) -> String {
        Measurement(value: Double(metres), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// What the activity shows instead of the next turn: the trip is over, the
/// route is still being found, or the app stopped updating it (e.g. it was
/// killed mid-trip), so the last turn may be out of date.
enum NavNotice {
    case ended(arrived: Bool)
    case routing
    case stale

    /// nil: show the next turn.
    init?(state: NavActivityState, isStale: Bool) {
        if state.ended {
            self = .ended(arrived: state.arrived)
        } else if isStale {
            self = .stale
        } else if state.routing {
            self = .routing
        } else {
            return nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .ended(let arrived): arrived ? "You have arrived" : "Navigation Ended"
        case .routing: "Finding a route…"
        case .stale: "Open PebbleOpenNav"
        }
    }

    /// The maneuver symbol, which would be out of date once stale.
    static func symbol(_ state: NavActivityState, isStale: Bool) -> String {
        !state.ended && isStale ? NavActivityState.navigationSymbol : state.symbol
    }
}

/// A notice's title over the destination name.
struct NavNoticeText: View {
    let notice: NavNotice
    let destinationName: String
    var titleFont: Font = .title3.bold()

    var body: some View {
        Text(notice.title)
            .font(titleFont)
        Text(destinationName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// "ETA 19:25 · 8.4 km" (Vietnamese "Đến 19:25 · 8,4 km").
struct NavTripSummary: View {
    let state: NavActivityState

    var body: some View {
        Text("ETA \(Text(state.arrival, style: .time)) · \(NavFormat.distance(state.remaining))")
    }
}

/// Lock Screen (and the banner on iPhones without a Dynamic Island).
struct NavLockScreenView: View {
    let state: NavActivityState
    let destinationName: String
    let isStale: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: NavNotice.symbol(state, isStale: isStale))
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(minWidth: 56)
            if let notice = NavNotice(state: state, isStale: isStale) {
                VStack(alignment: .leading, spacing: 2) {
                    NavNoticeText(notice: notice, destinationName: destinationName)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NavFormat.distance(state.distance))
                        .font(.title.bold())
                        .monospacedDigit()
                    Text(state.instruction)
                        .font(.headline)
                        .lineLimit(2)
                    NavTripSummary(state: state)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

/// Expanded Dynamic Island, below the maneuver symbol and distance.
struct NavExpandedBottomView: View {
    let state: NavActivityState
    let destinationName: String
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let notice = NavNotice(state: state, isStale: isStale) {
                NavNoticeText(notice: notice, destinationName: destinationName, titleFont: .headline)
            } else {
                Text(state.instruction)
                    .font(.headline)
                    .lineLimit(2)
                NavTripSummary(state: state)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
