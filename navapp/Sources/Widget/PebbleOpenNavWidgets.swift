// Widget extension entry point: the trip's Live Activity on the Lock Screen
// and in the Dynamic Island. Texts come from this extension's own
// {en,vi}.lproj/Localizable.strings and follow the phone language.
import SwiftUI
import WidgetKit

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)  // Catalyst: local type-check only
import ActivityKit

@main
struct PebbleOpenNavWidgets: WidgetBundle {
    var body: some Widget {
        NavLiveActivity()
    }
}

struct NavLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            NavLockScreenView(state: context.state, destinationName: context.attributes.destinationName)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol)
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.ended {
                        Text(NavFormat.distance(context.state.distance))
                            .font(.title2.bold())
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    NavExpandedBottomView(state: context.state,
                                          destinationName: context.attributes.destinationName)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(.tint)
            } compactTrailing: {
                if !context.state.ended {
                    Text(NavFormat.distance(context.state.distance))
                        .monospacedDigit()
                }
            } minimal: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(.tint)
            }
        }
    }
}
#endif
