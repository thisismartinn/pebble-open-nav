import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen map with a persistent bottom sheet, like Apple Maps. Everything
/// uses stock SwiftUI components, SF Symbols and system text styles, so it
/// follows Dynamic Type, Dark Mode and the system accent colour.
struct ContentView: View {
    @StateObject private var nav = NavigationController()
    @StateObject private var search = SearchModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var detent: PresentationDetent = ContentView.collapsed
    /// The sheet's top edge in window coordinates, for the notice above it.
    @State private var sheetTop: CGFloat?

    static let collapsed = PresentationDetent.fraction(0.3)

    var body: some View {
        // Apple's places are tappable (only while idle); they open the place card.
        Map(position: $camera, selection: $search.selectedFeature) {
            UserAnnotation()
            if let route = nav.route {
                MapPolyline(coordinates: route.shape.map(\.location2D))
                    .stroke(.blue, lineWidth: 6)
                if let end = route.shape.last {
                    Marker(nav.destinationName ?? String(localized: "Destination"), coordinate: end.location2D)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .all, showsTraffic: true))
        .mapFeatureSelectionDisabled { feature in
            nav.phase != .idle || feature.kind != .pointOfInterest
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onChange(of: search.selectedFeature) { _, feature in
            search.show(feature)
            if feature != nil, detent == .large { detent = .medium }
        }
        .onReceive(nav.$location) { search.near = $0 }
        // Just above the sheet, where the eyes already are, rather than at the top of a tall screen.
        .overlay {
            GeometryReader { geometry in
                if let notice = nav.endNotice {
                    NoticeCapsule(text: notice.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        // At most a capsule's height short of the top: the sheet may be pulled up meanwhile.
                        .padding(.bottom, min(sheetTop.map { max(0, geometry.frame(in: .global).maxY - $0) + 32 } ?? 32,
                                              max(0, geometry.size.height - 60)))
                        // A short rise from the sheet's top edge while it fades in, not up from behind the sheet.
                        .transition(.asymmetric(insertion: .offset(y: 32).combined(with: .opacity), removal: .opacity))
                }
            }
            .allowsHitTesting(false)
        }
        .animation(.smooth, value: nav.endNotice)
        // Counted from when it can be seen: a ride usually ends with the phone locked.
        .task(id: "\(nav.endNotice?.id.uuidString ?? "")\(scenePhase == .active)") {
            guard let notice = nav.endNotice, scenePhase == .active else { return }
            // After the sheet has switched back to search, which moves VoiceOver's focus.
            try? await Task.sleep(for: .milliseconds(600))
            AccessibilityNotification.Announcement(notice.text).post()
            try? await Task.sleep(for: .seconds(2.4))
            if nav.endNotice == notice { nav.endNotice = nil }
        }
        .sheet(isPresented: .constant(true)) {
            TripSheet(nav: nav, search: search, detent: $detent, sheetTop: $sheetTop)
                .presentationDetents([ContentView.collapsed, .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .onAppear { nav.appBecameActive() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { nav.appBecameActive() }
        }
        .onChange(of: nav.phase) { _, phase in
            switch phase {
            case .navigating:
                camera = .userLocation(followsHeading: true, fallback: .automatic)
                detent = ContentView.collapsed
            case .routing:
                detent = ContentView.collapsed
            case .idle:
                camera = .userLocation(fallback: .automatic)
                detent = ContentView.collapsed  // the end-of-trip notice shows above the sheet
            }
        }
    }
}

private struct TripSheet: View {
    @ObservedObject var nav: NavigationController
    @ObservedObject var search: SearchModel
    @Binding var detent: PresentationDetent
    @Binding var sheetTop: CGFloat?
    @FocusState private var searchFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                switch nav.phase {
                case .idle:
                    if let card = search.card { placeCard(card) } else { searchList }
                case .routing: routingList
                case .navigating: guidanceList
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .background { WindowFrameReader { sheetTop = $0.minY } }
        // Pulling the sheet down from full height ends typing; the close button goes with it
        // unless there's a search to clear.
        .onChange(of: detent) { _, detent in
            if detent != .large { searchFocused = false }
        }
        // Alerts must come from the sheet: the view under a presented sheet can't show one.
        .alert("Something Went Wrong", isPresented: Binding(
            get: { nav.errorMessage != nil || search.errorMessage != nil },
            set: { if !$0 { nav.errorMessage = nil; search.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(nav.errorMessage ?? search.errorMessage ?? "")
        }
    }

    /// Idle has no title, like Maps: the search field heads the sheet.
    private var title: String {
        switch nav.phase {
        case .routing, .navigating: nav.destinationName ?? String(localized: "Route")
        case .idle: ""
        }
    }

    // MARK: Search

    private var searchList: some View {
        List {
            if search.searching {
                ProgressView().frame(maxWidth: .infinity)
            } else if search.showsResults {
                if !search.results.isEmpty {
                    Section("Results") { placeButtons(search.results) }
                }
                addressSection
                if search.results.isEmpty, search.addressResults.isEmpty, let searched = search.lastSearch {
                    ContentUnavailableView.search(text: searched)
                }
            } else {
                if !search.suggestions.isEmpty {
                    Section {
                        ForEach(search.suggestions, id: \.self) { suggestion in
                            Button {
                                Task {
                                    guard let place = await search.resolve(suggestion) else { return }
                                    search.reset()
                                    nav.start(to: place)
                                }
                            } label: {
                                SuggestionRow(completion: suggestion)
                            }
                            .tint(.primary)
                        }
                    }
                }
                addressSection
            }

            Section("Route Options") {
                TransportPicker(costing: $nav.costing)
            }
            precisionSection
            watchSection
        }
        .sheetGlassListBackground(detent)
        // No navigation bar while searching: it would only leave an empty gap above the
        // field, which heads the sheet as in Maps.
        .toolbar(.hidden, for: .navigationBar)
        .topBar {
            SheetSearchField(text: $search.query, focused: $searchFocused,
                             showsClose: searchFocused || !search.query.isEmpty,
                             onActivate: {
                                 searchFocused = true
                                 detent = .large
                             },
                             onSubmit: { search.search() },
                             onClose: {
                                 search.reset()
                                 searchFocused = false
                                 if detent == .large { detent = .medium }  // show the map again
                             })
        }
        .onChange(of: searchFocused) { _, active in
            if active { detent = .large }
        }
    }

    /// Photon results for a query that starts with a house number.
    @ViewBuilder private var addressSection: some View {
        if !search.addressResults.isEmpty {
            Section("Addresses from OpenStreetMap") { placeButtons(search.addressResults) }
        }
    }

    private func placeButtons(_ places: [OpenMapServices.Place]) -> some View {
        ForEach(places) { place in
            Button {
                search.reset()
                nav.start(to: place)
            } label: {
                PlaceRow(place: place)
            }
            .tint(.primary)
        }
    }

    private func placeCard(_ card: PlaceDetails) -> some View {
        let here = nav.location
        let there = CLLocation(latitude: card.coordinate.latitude, longitude: card.coordinate.longitude)
        return PlaceCard(details: card,
                         distance: here.map { Format.distance($0.distance(from: there)) },
                         costing: $nav.costing,
                         onGo: {
                             let place = card.place
                             search.reset()
                             nav.start(to: place)
                         },
                         onClose: { search.dismissCard() })
            .sheetGlassListBackground(detent)
    }

    // MARK: Trip

    private var routingList: some View {
        List {
            Section {
                Label {
                    if nav.awaitingFix {
                        Text("Getting your location…")
                    } else {
                        Text("Finding a route…")
                    }
                } icon: {
                    ProgressView()
                }
                Button("Cancel", role: .destructive) { nav.cancel() }
            }
            precisionSection
            watchSection
        }
        .sheetGlassListBackground(detent)
        .contentMargins(.top, Self.underTitle, for: .scrollContent)
    }

    private var guidanceList: some View {
        List {
            Section {
                if let u = nav.update {
                    HStack(spacing: 16) {
                        Image(systemName: u.icon.symbolName)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(minWidth: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Format.distance(u.distanceToManeuver))
                                .font(.largeTitle.bold())
                                .monospacedDigit()
                            Text(WatchStep.watchText(u.maneuver.instruction, maxBytes: 500))
                                .font(.title3)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    LabeledContent("Remaining",
                                   value: "\(Format.distance(u.remainingDistance)) · \(Format.duration(u.remainingTime))")
                    LabeledContent("Arrival") {
                        Text(Date(timeIntervalSinceNow: u.remainingTime), style: .time)
                    }
                } else {
                    Label {
                        Text("Waiting for GPS…")
                    } icon: {
                        ProgressView()
                    }
                }
            }
            Section {
                Button("End Route", role: .destructive) { nav.stop() }
            }
            precisionSection
            watchSection
        }
        .sheetGlassListBackground(detent)
        .contentMargins(.top, Self.underTitle, for: .scrollContent)
    }

    /// Space between the title bar and the first card while routing and navigating, so the
    /// card sits as far below the title as the title is below the grabber (about 23 pt).
    private static let underTitle: CGFloat = 6

    // MARK: Shared sections

    @ViewBuilder private var precisionSection: some View {
        if nav.preciseLocationOff {
            Section {
                Label("Precise Location is off, so directions can't follow you turn by turn.",
                      systemImage: "location.slash")
                #if os(iOS)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                #endif
            }
        }
    }

    private var watchSection: some View {
        Section {
            // Re-rendered every second so "5s ago" keeps counting.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                WatchLinkRow(link: nav.watchLink, now: context.date)
            }
            Picker(selection: $nav.watchTheme) {
                ForEach(WatchTheme.allCases) { Text($0.label).tag($0) }
            } label: {
                Label {
                    Text("Watch Display")
                } icon: {
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.primary)
                }
            }
            if let log = nav.tripLogURL {
                ShareLink(item: log) {
                    Label {
                        Text("Share Trip Log").foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "doc.text").foregroundStyle(.primary).opacity(0.75)
                    }
                }
            }
        } header: {
            Text("Pebble")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(versions)
                if nav.serverProblem {
                    Label("The watch link stopped. Reconnecting…", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    /// "PebbleOpenNav · v0.4 (iPhone) & v0.4 (Pebble)". The watchapp is installed on its own,
    /// so it can be older; before v0.4 it didn't say its version.
    private var versions: String {
        let phone = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard nav.watchLink.lastCheckIn != nil else { return String(localized: "PebbleOpenNav · v\(phone) (iPhone)") }
        if let watch = nav.watchLink.watchappVersion, watch.compare(phone, options: .numeric) != .orderedAscending {
            return String(localized: "PebbleOpenNav · v\(phone) (iPhone) & v\(watch) (Pebble)")
        }
        return String(localized: "PebbleOpenNav · v\(phone) (iPhone) · Pebble app not up to date")
    }
}

/// Whether the Pebble watchapp is polling: "Connected", checked in 5s ago • 62 times.
private struct WatchLinkRow: View {
    let link: WatchLinkStatus
    let now: Date

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                if link.connected {
                    Text("Connected")
                        .font(.headline)
                    Group {
                        if let last = link.lastCheckIn {
                            Text(checkIns(ago: Format.ago(last, now: now)))
                        }
                        Text("Longest gap: \(Format.elapsed(link.longestGap))")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Not connected")
                        .font(.headline)
                    Text("Open the app on your Pebble to continue")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "applewatch")
                .foregroundStyle(.primary)  // the accent blue is too faint on the glass sheet
        }
        .accessibilityElement(children: .combine)
    }

    private func checkIns(ago: String) -> String {
        link.count == 1
            ? String(localized: "Checked in \(ago) • 1 time")
            : String(localized: "Checked in \(ago) • \(link.count) times")
    }
}

/// Apple Maps type-ahead suggestion, with the typed part in bold.
private struct SuggestionRow: View {
    let completion: MKLocalSearchCompletion

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.highlighted(completion.title, completion.titleHighlightRanges))
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private static func highlighted(_ text: String, _ ranges: [NSValue]) -> AttributedString {
        var result = AttributedString(text)
        for value in ranges {
            guard let range = Range(value.rangeValue, in: text),
                  let attributed = Range(range, in: result) else { continue }
            result[attributed].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}

/// The sheet's search field. Stock parts in the system search field's look: a capsule of
/// Liquid Glass on iOS 26, the filled rounded field before. A round close button shows
/// while searching, as in Maps.
private struct SheetSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let showsClose: Bool
    /// Any tap on the capsule: it opens the search, also when the field already has focus.
    let onActivate: () -> Void
    let onSubmit: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search for a place or address", text: $text)
                    .frame(minHeight: 44)
                    .focused(focused)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .accessibilityAddTraits(.isSearchField)
                if !text.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .modifier(SearchFieldBackground())
            // The glass reacts to a touch anywhere on the capsule, its padding too, so that
            // whole area starts the search, not just the text field inside it.
            .contentShape(.capsule)
            .simultaneousGesture(TapGesture().onEnded { onActivate() })
            if showsClose {
                Button("Cancel", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .modifier(CloseButtonBackground())
                    .buttonStyle(.plain)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)  // about 9 pt below the sheet's grabber, as in Maps
        .padding(.bottom, 8)
        .animation(.smooth, value: showsClose)
    }
}

private struct CloseButtonBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(Color(.tertiarySystemFill), in: Circle())
        }
    }
}

private struct SearchFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// A short notice over the map, e.g. when a trip ends. It goes away by itself.
private struct NoticeCapsule: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .modifier(CapsuleBackground())
    }
}

/// Reports its frame in window coordinates whenever its layout changes, e.g. the sheet's
/// as its detent changes. SwiftUI's global space inside a sheet may be the sheet's own.
private struct WindowFrameReader: UIViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeUIView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateUIView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: UIView {
        var onChange: (CGRect) -> Void
        private var reported: CGRect?

        init(onChange: @escaping (CGRect) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            guard window != nil else { return }
            let frame = convert(bounds, to: nil)
            guard frame != reported else { return }
            reported = frame
            DispatchQueue.main.async { [onChange] in onChange(frame) }  // not during a view update
        }
    }
}

private struct CapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}

/// Travel mode as SF Symbols, like Apple Maps; VoiceOver reads the mode's name.
/// Meant as a List row of its own: like Maps' transport selector, it spans the
/// row's full width, with no card or padding around it.
struct TransportPicker: View {
    @Binding var costing: OpenMapServices.Costing

    var body: some View {
        Picker("Travel By", selection: $costing) {
            ForEach(OpenMapServices.Costing.allCases, id: \.self) { mode in
                Image(systemName: mode.symbolName)
                    .accessibilityLabel(mode.label)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

private struct PlaceRow: View {
    let place: OpenMapServices.Place

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                if !place.detail.isEmpty {
                    Text(place.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// On iOS 26 a partial-height sheet has a Liquid Glass background, which a List's
/// opaque background would cover. Hide it there; at full height the system makes
/// the sheet opaque, so keep the standard background. No change on iOS 17/18,
/// where sheets are opaque anyway.
private struct SheetGlassListBackground: ViewModifier {
    let detent: PresentationDetent

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollContentBackground(detent == .large ? .automatic : .hidden)
        } else {
            content
        }
    }
}

private extension View {
    func sheetGlassListBackground(_ detent: PresentationDetent) -> some View {
        modifier(SheetGlassListBackground(detent: detent))
    }

    /// Pins `content` above a list. On iOS 26 it's a bar the list scrolls under with the
    /// system's soft edge; before, an inset on the grouped background.
    @ViewBuilder func topBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                content().background(Color(.systemGroupedBackground))
            }
        }
    }
}

/// System formatters, so units and wording follow the phone's region settings.
private enum Format {
    static func distance(_ metres: Double) -> String {
        Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func duration(_ seconds: Double) -> String {
        Duration.seconds(max(60, seconds))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "38s", "2min", "6h". Seconds never take a space before the unit, in
    /// either language, so these don't use the system duration formatter.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return String(localized: "\(s)s")
        case ..<3600: return String(localized: "\(s / 60)min")
        default: return String(localized: "\(s / 3600)h")
        }
    }

    /// "5s ago", "2min ago", "6h ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let elapsed = elapsed(now.timeIntervalSince(date))
        return String(localized: "\(elapsed) ago")
    }
}

private extension Coordinate {
    var location2D: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

extension WatchManeuver {
    var symbolName: String {
        switch self {
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
}

extension WatchTheme {
    var label: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

extension OpenMapServices.Costing {
    var symbolName: String {
        switch self {
        // "motorcycle.fill" is new in iOS 18 (SF Symbols 6); iOS 17 keeps the scooter.
        case .motorbike: if #available(iOS 18, *) { "motorcycle.fill" } else { "scooter" }
        case .car: "car.fill"
        case .bicycle: "bicycle"
        case .walk: "figure.walk"
        }
    }

    var label: String {
        switch self {
        case .motorbike: String(localized: "Motorbike")
        case .car: String(localized: "Car")
        case .bicycle: String(localized: "Bicycle")
        case .walk: String(localized: "Walk")
        }
    }
}
