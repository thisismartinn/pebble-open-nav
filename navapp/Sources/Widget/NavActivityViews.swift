// Live Activity views. They take plain values rather than ActivityKit types,
// so they also type-check on Mac Catalyst (see scripts/typecheck.sh).
import SwiftUI

enum NavFormat {
    /// "350 m", "1.2 km" (Vietnamese "1,2 km"), following the device locale.
    static func distance(_ metres: Int) -> String {
        Measurement(value: Double(metres), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func endedTitle(arrived: Bool) -> LocalizedStringKey {
        arrived ? "You have arrived" : "Navigation Ended"
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

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: state.symbol)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(minWidth: 56)
            if state.ended {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NavFormat.endedTitle(arrived: state.arrived))
                        .font(.title3.bold())
                    Text(destinationName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if state.ended {
                Text(NavFormat.endedTitle(arrived: state.arrived))
                    .font(.headline)
                Text(destinationName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
