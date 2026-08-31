import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The wind over your patch of coast, with the hour on the D-pad.
///
/// This is the screen the big display earns. The wash is the phone's own —
/// `WindWashModel`, the same 7×9 field, the same palette, drawn as map polygons
/// because SwiftUI's `Map` still cannot take a geo-registered image — and on a
/// television it is finally the size the thing wants to be.
///
/// The map does not pan or zoom. There is no gesture for it on a remote worth
/// building, and more usefully there is no need: the frame is the box your own
/// spots sit in, which is the only part of the coast this app is about. That
/// frees all four arrow keys, and left and right go to the hour — which is free,
/// because the model holds three days of it and scrubbing is a re-render rather
/// than a fetch.
struct WindMapScreen: View {

    @Environment(SpotGuideStore.self) private var guide

    @State private var wash = WindWashModel()
    @State private var offsetHours = 0

    /// How far the clock will travel. The field carries seventy-two, but a
    /// television is not a planning tool — two days is the horizon somebody
    /// standing up decides a weekend on.
    private static let horizon = 48

    private var scrubbed: Date {
        Calendar.current.date(byAdding: .hour, value: offsetHours, to: .now) ?? .now
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            map
            clock
        }
        .ignoresSafeArea()
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left:  offsetHours = max(0, offsetHours - 1)
            case .right: offsetHours = min(Self.horizon, offsetHours + 1)
            default: break
            }
        }
        .task(id: offsetHours) {
            wash.scrub(to: offsetHours == 0 ? nil : scrubbed)
        }
        .task(id: region.map { "\($0.center.latitude),\($0.center.longitude)" } ?? "-") {
            guard let region else { return }
            wash.viewSettled(on: region, layer: .wind, widthPoints: 1920, displayScale: 2)
            // Both: `refreshWind` fills the pins for now, `refreshWindHours`
            // fills them for every other hour the clock can reach. This tab
            // can be the one the app opens on, so neither can be assumed.
            await guide.refreshWind(for: guide.favorites)
            await guide.refreshWindHours(for: guide.favorites)
        }
    }

    private var map: some View {
        // Read during body evaluation, not inside the content builder.
        // A read that happens inside `Map`'s builder registers no observation
        // dependency, so the pins would draw once — nameless and numberless —
        // and never update when the readings landed. The phone's map hoists
        // its readings for exactly this reason.
        let readings = pinReadings
        return Map(initialPosition: region.map { .region($0) } ?? .automatic,
                   interactionModes: []) {
            ForEach(wash.cells) { cell in
                MapPolygon(coordinates: cell.coordinates)
                    .foregroundStyle(cell.color)
            }
            ForEach(guide.favorites) { spot in
                Annotation(spot.name, coordinate: spot.clCoordinate) {
                    SpotBadge(name: spot.name, reading: readings[spot.spotId])
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
    }

    /// The clock, and the only thing the remote does here.
    private var clock: some View {
        HStack(spacing: 20) {
            Image(systemName: "chevron.left")
                .foregroundStyle(offsetHours == 0 ? .tertiary : .secondary)
            Text(offsetHours == 0 ? "Now" : scrubbed.formatted(.dateTime.weekday(.abbreviated).hour()))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 260)
            Image(systemName: "chevron.right")
                .foregroundStyle(offsetHours == Self.horizon ? .tertiary : .secondary)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 60)
    }

    /// Every pin's number for the hour the clock is on.
    private var pinReadings: [String: WindReading] {
        var out: [String: WindReading] = [:]
        for spot in guide.favorites {
            if let reading = guide.reading(for: spot.spotId,
                                           at: offsetHours == 0 ? nil : scrubbed) {
                out[spot.spotId] = reading
            }
        }
        return out
    }

    /// The box your own spots sit in, with room around it.
    ///
    /// Nil until the guide has loaded and something is starred — there is no
    /// sensible "here" on an Apple TV to fall back to, and guessing at one
    /// would put the map somewhere nobody sails.
    private var region: MKCoordinateRegion? {
        let spots = guide.favorites
        guard !spots.isEmpty else { return nil }
        let lats = spots.map(\.latitude), lons = spots.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max(0.5, (maxLat - minLat) * 1.6),
                        longitudeDelta: max(0.5, (maxLon - minLon) * 1.6)))
    }
}

/// A spot on the map, carrying its number.
private struct SpotBadge: View {

    let name: String
    let reading: WindReading?

    var body: some View {
        VStack(spacing: 4) {
            if let reading {
                HStack(spacing: 6) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 14))
                        .rotationEffect(.degrees(reading.directionDeg + 180))
                    Text("\(Int(reading.speedKn.rounded()))")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(reading.isFiring ? Color.accentColor : Color.black.opacity(0.75),
                            in: Capsule())
                .foregroundStyle(.white)
            }
            Text(name)
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

extension GuideSpot {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
