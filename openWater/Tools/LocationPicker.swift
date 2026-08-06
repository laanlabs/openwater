import CoreLocation
import MapKit
import OpenWaterCore
import SwiftUI

/// A place a rider has chosen — a name they will recognise plus the pin.
struct PickedPlace: Codable, Hashable {
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: Geo.Coordinate {
        Geo.Coordinate(latitude: latitude, longitude: longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    init(name: String, coordinate: Geo.Coordinate) {
        self.init(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Round-tripped through `AppStorage`, which stores strings.
    var stored: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) as? String ?? ""
    }

    static func restore(_ raw: String) -> PickedPlace? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PickedPlace.self, from: data)
    }
}

/// Pick a point by moving the map under a fixed pin.
///
/// Dragging the world beneath a stationary crosshair rather than dropping a
/// pin under a finger, because the thing you are aiming at is usually under
/// your thumb at the moment you would tap it. The guide's spots are
/// searchable from here too — most launches already have a name, and typing
/// three letters beats panning across a county.
struct LocationPickerSheet: View {

    let title: String
    let initial: Geo.Coordinate?
    let onPick: (PickedPlace) -> Void

    @Environment(SpotGuideStore.self) private var guide
    @Environment(PhoneRecorder.self) private var recorder
    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .automatic
    @State private var centre: CLLocationCoordinate2D?
    @State private var name = ""
    @State private var isNaming = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map

                // One search field, always in the hierarchy. The first
                // version swapped between a collapsed bar and an expanded
                // results view, each with its own TextField — typing "Viento"
                // registered "Vi", because the swap on the first keystroke
                // tore down the focused field and the rest of the characters
                // went nowhere.
                VStack(spacing: 0) {
                    searchField
                    if !query.isEmpty { searchResults }
                }
            }
            .safeAreaInset(edge: .bottom) { confirmBar }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await guide.load() }
            .onAppear {
                let start = initial ?? recorder.location.lastCoordinate
                if let start {
                    centre = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
                    camera = .region(MKCoordinateRegion(
                        center: centre!,
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    ))
                }
            }
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera)
            .mapControlVisibility(.hidden)
            .ignoresSafeArea(edges: .bottom)
            .onMapCameraChange(frequency: .onEnd) { context in
                centre = context.region.center
                Task { await resolveName() }
            }
            // The pin sits dead centre and never moves; the world moves under
            // it. Offset by half its height so the point, not the head, marks
            // the spot.
            .overlay {
                Image(systemName: "mappin")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.red)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                    .offset(y: -17)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    if let here = recorder.location.lastCoordinate {
                        withAnimation(.snappy) {
                            camera = .region(MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude),
                                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                            ))
                        }
                    }
                } label: {
                    Image(systemName: "location.fill")
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .padding(16)
            }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search the spot guide", text: $query)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Names that *start* with what was typed come first — "Vi" should offer
    /// Viento before Boa Vista.
    private var matches: [GuideSpot] {
        let needle = query.lowercased()
        let hits = guide.spots.filter { $0.name.lowercased().contains(needle) }
        return hits
            .sorted { a, b in
                let aStarts = a.name.lowercased().hasPrefix(needle)
                let bStarts = b.name.lowercased().hasPrefix(needle)
                if aStarts != bStarts { return aStarts }
                return a.name < b.name
            }
            .prefix(25)
            .map { $0 }
    }

    private var searchResults: some View {
        List(matches) { spot in
            Button {
                select(spot)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(spot.name).foregroundStyle(.primary)
                    Text(spot.where_)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func select(_ spot: GuideSpot) {
        name = spot.name
        centre = spot.coordinate
        withAnimation(.snappy) {
            camera = .region(MKCoordinateRegion(
                center: spot.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
        query = ""
    }

    // MARK: Naming

    /// What to call the pin: the guide's own name when the pin is close to a
    /// known launch, otherwise whatever the map calls the place. A name a
    /// rider recognises is what makes the shared message readable.
    private func resolveName() async {
        guard let centre else { return }
        let here = Geo.Coordinate(latitude: centre.latitude, longitude: centre.longitude)
        if let spot = guide.nearestSpot(to: here),
           Geo.distance(here, .init(latitude: spot.latitude, longitude: spot.longitude)) < 800 {
            name = spot.name
            return
        }
        isNaming = true
        defer { isNaming = false }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: centre.latitude, longitude: centre.longitude))
        if let placemark = placemarks?.first {
            name = placemark.name ?? placemark.locality ?? placemark.subAdministrativeArea ?? ""
        }
    }

    // MARK: Confirm

    private var confirmBar: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    if isNaming {
                        Text("Naming…").foregroundStyle(.secondary)
                    } else {
                        Text(name.isEmpty ? "Dropped pin" : name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    if let centre {
                        Text(String(format: "%.5f, %.5f", centre.latitude, centre.longitude))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Button {
                guard let centre else { return }
                onPick(PickedPlace(
                    name: name.isEmpty ? "Dropped pin" : name,
                    latitude: centre.latitude,
                    longitude: centre.longitude
                ))
                dismiss()
            } label: {
                Text("Use This Spot")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(centre == nil)
        }
        .padding(16)
        .background(.regularMaterial)
    }
}
