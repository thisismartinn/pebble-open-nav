import MapKit
import SwiftUI

struct ContentView: View {
    @StateObject private var nav = NavigationController()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                UserAnnotation()
                if let route = nav.route {
                    MapPolyline(coordinates: route.shape.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    })
                    .stroke(.blue, lineWidth: 6)
                }
            }
            .ignoresSafeArea()

            panel
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding()
        }
        .onAppear { nav.requestLocation() }
        .onChange(of: nav.phase) { _, phase in
            camera = phase == .navigating
                ? .userLocation(followsHeading: true, fallback: .automatic)
                : .userLocation(fallback: .automatic)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { nav.errorMessage != nil },
            set: { if !$0 { nav.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(nav.errorMessage ?? "")
        }
    }

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch nav.phase {
            case .idle:
                searchPanel
            case .routing:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding a route…")
                }
            case .navigating:
                guidancePanel
            case .ended(let reason):
                Text("Navigation ended").font(.title2.bold())
                Text(reason).foregroundStyle(.secondary)
                Button("New trip") { nav.reset() }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            Text(nav.watchStatus).font(.footnote).foregroundStyle(.secondary)
            if let error = nav.serverError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var searchPanel: some View {
        TextField("Search for a place or address", text: $nav.query)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.search)
            .onSubmit { nav.search() }
        Picker("Travel by", selection: $nav.costing) {
            ForEach(OpenMapServices.Costing.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        Toggle("Directions in Vietnamese", isOn: $nav.vietnamese)
        if nav.searching {
            ProgressView()
        }
        if !nav.results.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(nav.results) { place in
                        Button {
                            nav.start(to: place)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).font(.body.weight(.semibold))
                                Text(place.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        if let pbw = Bundle.main.url(forResource: "navtest", withExtension: "pbw") {
            ShareLink(item: pbw) {
                Label("Install the watchapp on your Pebble", systemImage: "applewatch")
            }
            .font(.footnote)
        }
    }

    @ViewBuilder private var guidancePanel: some View {
        if let u = nav.update {
            Text(formatDistance(u.distanceToManeuver)).font(.system(size: 44, weight: .bold))
            Text(WatchStep.watchText(u.maneuver.instruction, maxBytes: 500)).font(.title3.weight(.semibold))
            Text(String(format: "%.1f km · %d min left", u.remainingDistance / 1000,
                        max(1, Int((u.remainingTime / 60).rounded()))))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for GPS…")
            }
        }
        Button(role: .destructive) {
            nav.stop()
        } label: {
            Text("End navigation").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private func formatDistance(_ m: Double) -> String {
        m < 1000 ? "\(Int(m / 10) * 10) m" : String(format: "%.1f km", m / 1000)
    }
}

extension OpenMapServices.Costing {
    var label: String {
        switch self {
        case .motorbike: "Motorbike"
        case .car: "Car"
        case .bicycle: "Bicycle"
        case .walk: "Walk"
        }
    }
}
