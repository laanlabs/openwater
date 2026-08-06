import CoreLocation
import Foundation
import OpenWaterCore

/// Turns the ends of a run into "Viento → Hatchery".
///
/// Two sources, in order. The **spot guide** first, because it knows the names
/// riders actually say: a launch is "Viento", not "Viento State Recreation
/// Site", and certainly not "Interstate 84". Then **Apple's geocoder**, because
/// plenty of launches are not in the guide — a river bend, a beach with no
/// name on any list, somebody's local that nobody has submitted. The same
/// two-step already runs in `LocationPickerSheet.resolveName()`.
///
/// The hard part is not naming the ends. It is deciding whether to say anything
/// at all: a session that finished where it started has no route, and "Viento →
/// Viento" is worse than silence. So a route needs *both* ends far enough apart
/// to be different places *and* two names that differ — the second test catches
/// the case where a long lap session drifts a kilometre down the beach and both
/// ends geocode to the same park.
@MainActor
@Observable
final class RouteNamer {

    private let guide: SpotGuideStore

    /// Sessions looked up this launch, successful or not, so a failed geocode
    /// is not retried on every scroll. `CLGeocoder` answers a rate limit with
    /// an error, and hammering it turns one failure into permanent failure.
    private var attempted: Set<UUID> = []

    init(guide: SpotGuideStore) {
        self.guide = guide
    }

    /// How far apart the ends must be before this is a route rather than a
    /// session at one spot.
    static let minimumSeparation: Double = 1000

    /// Close enough to a known launch to borrow its name.
    static let spotRadius: Double = 1000

    /// Resolve and store the route for a session, if it has one and has not
    /// been looked up before.
    ///
    /// Safe to call from `.task` on any view: it is a no-op for a session that
    /// already has an answer, for one already tried this launch, and for one
    /// whose shape says there is no route to name.
    func resolve(for stored: StoredSession, session: Session) async {
        guard stored.routeResolvedAt == nil, !attempted.contains(stored.id) else { return }
        attempted.insert(stored.id)

        let name = await route(for: session)

        // Stamped whatever the outcome, so "no route here" is remembered as an
        // answer rather than as a question still to ask.
        stored.routeName = name
        stored.routeResolvedAt = .now
    }

    /// The route line for a session, or nil when it does not have one.
    func route(for session: Session) async -> String? {
        guard let summary = session.summary else { return nil }
        guard summary.shape.isPointToPoint else { return nil }

        guard let start = session.track.points.first?.coordinate,
              let end = session.track.points.last?.coordinate,
              Geo.distance(start, end) >= Self.minimumSeparation
        else { return nil }

        async let startName = name(for: start)
        async let endName = name(for: end)
        guard let from = await startName, let to = await endName else { return nil }

        // Both ends in the same place by name is a lap that wandered, not a
        // run. Compared case- and diacritic-insensitively because the guide
        // and the geocoder disagree about capitalisation more often than they
        // disagree about the place.
        guard from.compare(to, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        else { return nil }

        return "\(from) → \(to)"
    }

    /// A name a rider would recognise for one coordinate.
    private func name(for coordinate: Geo.Coordinate) async -> String? {
        await guide.load()
        if let spot = guide.nearestSpot(to: coordinate),
           Geo.distance(coordinate, .init(latitude: spot.latitude, longitude: spot.longitude)) < Self.spotRadius {
            return spot.name
        }

        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
        guard let placemark = placemarks?.first else { return nil }
        // `name` is often a street address, which is worse than useless for a
        // stretch of water — prefer the things that name an area.
        return placemark.subLocality
            ?? placemark.locality
            ?? placemark.inlandWater
            ?? placemark.ocean
            ?? placemark.subAdministrativeArea
            ?? placemark.name
    }
}
