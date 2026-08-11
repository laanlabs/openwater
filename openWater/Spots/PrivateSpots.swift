import CoreLocation
import MapKit
import OpenWaterCore
import SwiftUI

/// A spot that never leaves the phone.
///
/// The guide is public and human-reviewed, which is right for a launch
/// everybody shares and wrong for the sandbar only you know about, or the
/// stretch in front of a friend's house. A private spot is the other path:
/// no submission, no review, no server — a name and a coordinate in local
/// storage, listed with the favorites, and the conditions sheet gives it
/// the same stations, forecasts and cams every guide spot gets.
struct PrivateSpot: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let latitude: Double
    let longitude: Double
    let createdAt: Date
    /// Degrees true from the beach out toward open water. Optional twice
    /// over: old saved spots decode without it, and nobody is made to
    /// answer a question they are unsure of — the surf screens fall back
    /// to their proxy and say so.
    var shoreFacingDeg: Double?

    var coordinate: Geo.Coordinate {
        Geo.Coordinate(latitude: latitude, longitude: longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Adding one

/// The save dialog: a map to confirm the where, and a name the geocoder
/// drafts so the rider only has to correct it, not compose it.
struct AddPrivateSpotSheet: View {

    let coordinate: Geo.Coordinate

    @Environment(SpotGuideStore.self) private var guide
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hasFacing = false
    @State private var facing: Double = 270
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude),
                        latitudinalMeters: 1200, longitudinalMeters: 1200
                    ))) {
                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: coordinate.latitude, longitude: coordinate.longitude
                        )) {
                            PrivateSpotPin()
                        }
                        .annotationTitles(.hidden)
                    }
                    .frame(height: 150)
                    .allowsHitTesting(false)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    TextField("Name this spot", text: $name)
                        .focused($nameIsFocused)
                } footer: {
                    Text("Private to this phone. It lives in your favorites with the same nearby stations, forecasts and cams as any spot — nothing is submitted to the guide.")
                }

                Section {
                    Toggle("Set which way the beach faces", isOn: $hasFacing.animation())
                    if hasFacing {
                        ShoreFacingControl(facing: $facing)
                    }
                } footer: {
                    Text(hasFacing
                         ? "Stand on the sand, look at the water — that bearing. It is what turns a forecast wind into \"offshore\" and tells the surf screens which swell can actually reach this beach."
                         : "Optional, and worth it for surf: with a facing, the forecast can say offshore or onshore against this beach rather than guessing from the swell.")
                }
            }
            .navigationTitle("New private spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guide.addPrivateSpot(PrivateSpot(
                            id: UUID(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude,
                            createdAt: Date(),
                            shoreFacingDeg: hasFacing ? facing : nil
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { await suggestName() }
        }
        .presentationDetents([.medium, .large])
    }

    /// Drafts a name from the reverse geocoder, preferring the things that
    /// name an area of water or land over `name`, which is usually a street
    /// address — the same lesson `RouteNamer` learned. Only fills the field
    /// while it is still empty, so a rider who started typing is never
    /// overwritten by a slow geocode landing late.
    private func suggestName() async {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
        guard let placemark = placemarks?.first else { return }
        let suggestion = placemark.areasOfInterest?.first
            ?? placemark.subLocality
            ?? placemark.inlandWater
            ?? placemark.ocean
            ?? placemark.locality
            ?? placemark.name
        if name.isEmpty, let suggestion {
            name = suggestion
        }
    }
}

// MARK: - Which way the beach faces

/// The one-drag compass: an arrow pointing from the sand out to sea, and a
/// slider to swing it. Deliberately not auto-derived from map data — a
/// wrong guess would wear the same confidence as a right one, and the rider
/// standing on the beach knows the answer better than any coastline vector.
struct ShoreFacingControl: View {

    @Binding var facing: Double

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(Color(.systemGray4), lineWidth: 1)
                    .frame(width: 92, height: 92)
                ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(Double(index) * -90))
                        .offset(y: -54)
                        .rotationEffect(.degrees(Double(index) * 90))
                }
                Image(systemName: "arrow.up")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(facing))
                Text("water")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tint)
                    .offset(y: -54)
                    .rotationEffect(.degrees(facing))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)

            HStack {
                Slider(value: $facing, in: 0...359, step: 1)
                Text("\(Format.cardinal(facing)) \(Int(facing))°")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
            }
        }
    }
}

/// Editing the facing on a spot that already exists — the context menu's
/// door to the same control the save dialog offers.
struct ShoreFacingSheet: View {

    let spot: PrivateSpot

    @Environment(SpotGuideStore.self) private var guide
    @Environment(\.dismiss) private var dismiss

    @State private var hasFacing: Bool
    @State private var facing: Double

    init(spot: PrivateSpot) {
        self.spot = spot
        _hasFacing = State(initialValue: spot.shoreFacingDeg != nil)
        _facing = State(initialValue: spot.shoreFacingDeg ?? 270)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("This beach has a facing", isOn: $hasFacing.animation())
                    if hasFacing {
                        ShoreFacingControl(facing: $facing)
                    }
                } footer: {
                    Text("Stand on the sand, look at the water — that bearing. The surf screens use it to judge the wind against this beach and to gate swell that cannot reach it.")
                }
            }
            .navigationTitle(spot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guide.setShoreFacing(spot.id, to: hasFacing ? facing : nil)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - In the favorites list

/// The favorites row for a private spot: name, that it is private, and the
/// wind — the same "is it on?" glance the guide favorites get.
struct PrivateSpotCard: View {

    let spot: PrivateSpot
    let reading: WindReading?
    let distanceMetres: Double?
    let units: UnitPreferences

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(spot.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // The badge wears the same navy-on-wash the BEST chips
                    // do, and must not be the thing that truncates — the
                    // name gives way, the badge never does.
                    Text("PRIVATE")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.harbourNavy)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.tintWash, in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let reading {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(reading.speedKn.rounded()))kn")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(reading.isFiring ? AnyShapeStyle(.tint)
                                         : AnyShapeStyle(.primary))
                        .monospacedDigit()
                    Text(reading.cardinal + (reading.gustKn.map { " · g\(Int($0.rounded()))" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var subtitle: String {
        var parts = ["Only on this phone"]
        if let metres = distanceMetres {
            parts.append(Format.distance(metres, unit: units.distance))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - On the map

/// The pin: the favorites star, so the map and the list agree about what
/// this thing is.
struct PrivateSpotPin: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(.tint, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}
