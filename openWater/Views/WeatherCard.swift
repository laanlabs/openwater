import CoreLocation
import OpenWaterCore
import os
import SwiftUI
import WeatherKit

/// Current conditions where the rider is standing.
///
/// Wind is the reason to go or not go, and it is the one number a rider checks
/// before every session. Showing it on the record screen also feeds the rest of
/// the app: an observed direction is a far better input for the polar and the
/// angle metrics than the estimate derived from track shape, and it is offered
/// as the session's wind when a recording starts.
///
/// **Requires the WeatherKit capability.** It is an Apple service that needs the
/// entitlement enabled on the App ID, and it will simply report unavailable
/// without it. That is deliberate — this is the only network dependency in the
/// app, and everything else has to keep working when it is absent.
@MainActor
@Observable
final class WeatherLookup {

    enum State: Equatable {
        case idle
        case loading
        case unavailable(String)
        case loaded(Conditions)
    }

    struct Conditions: Equatable {
        var windSpeed: Double        // m/s
        var windGust: Double?        // m/s
        var windDirection: Double    // degrees the wind is coming from
        var temperature: Double      // °C
        var symbolName: String
        var condition: String
        var retrievedAt: Date
    }

    /// Failures here are deliberately invisible on screen — see `WeatherCard`.
    /// That is right for a rider and wrong for anyone trying to work out why
    /// there is no wind reading, since the entitlement, the App ID capability
    /// and the network can each fail with nothing to show for it. The reason
    /// goes to the log, where `log stream --predicate 'subsystem ==
    /// "com.laan.labs.openWater"'` will find it.
    private static let log = Logger(subsystem: "com.laan.labs.openWater", category: "weather")

    private(set) var state: State = .idle

    /// Apple's legal attribution page, which must be reachable from anywhere
    /// WeatherKit data is displayed. Fetched alongside the first reading.
    private(set) var attributionURL: URL?

    private var lastRequestedCoordinate: Geo.Coordinate?

    /// The wind that was actually blowing while a session was recorded.
    ///
    /// Not the same job as `load(for:)`, which answers "should I go out?".
    /// This answers "what was it doing an hour ago", and it is the difference
    /// between a polar measured against a real wind direction and one measured
    /// against a direction guessed from the shape of the track. WeatherKit
    /// serves historical hourly data, so it works for sessions recorded before
    /// the app ever asked — and for GPX files imported from another device,
    /// where there was never any chance of capturing conditions live.
    ///
    /// The hours are averaged as vectors and weighted by how much of the
    /// session each covers. Averaging bearings arithmetically is the classic
    /// error: 350° and 10° average to 180°, the exact opposite of the truth,
    /// and a rider would see every angle in the session inverted.
    ///
    /// It is a model, not an anemometer on the beach. In a gorge, a bay, or
    /// anywhere the geography bends the wind, the local truth can be a long way
    /// from a 2 km grid cell — which is why this is offered for the rider to
    /// accept rather than applied to their session unasked.
    static func recordedWind(
        at coordinate: Geo.Coordinate,
        from start: Date,
        to end: Date
    ) async throws -> OpenWaterCore.Wind {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Widened by an hour at each end: WeatherKit returns whole hours, and a
        // twenty-minute session sitting inside one of them would otherwise
        // match nothing at all.
        let forecast = try await WeatherService.shared.weather(
            for: location,
            including: .hourly(startDate: start.addingTimeInterval(-3600),
                               endDate: end.addingTimeInterval(3600))
        )

        var eastward = 0.0      // vector components of the direction
        var northward = 0.0
        var speedSum = 0.0
        var weightSum = 0.0

        for hour in forecast.forecast {
            // How much of the session this hour actually covers.
            let hourEnd = hour.date.addingTimeInterval(3600)
            let overlap = min(end, hourEnd).timeIntervalSince(max(start, hour.date))
            let weight = max(0, overlap)
            guard weight > 0 else { continue }

            let radians = hour.wind.direction.converted(to: .degrees).value * .pi / 180
            eastward += sin(radians) * weight
            northward += cos(radians) * weight
            speedSum += hour.wind.speed.converted(to: .metersPerSecond).value * weight
            weightSum += weight
        }

        guard weightSum > 0 else { throw WeatherError.noHistoricalData }

        let direction = atan2(eastward / weightSum, northward / weightSum) * 180 / .pi
        return OpenWaterCore.Wind(
            directionFrom: Geo.normalizeDegrees(direction),
            speed: speedSum / weightSum,
            source: .external,
            confidence: 1
        )
    }

    enum WeatherError: LocalizedError {
        case noHistoricalData

        var errorDescription: String? {
            switch self {
            case .noHistoricalData:
                "No recorded conditions for that time and place."
            }
        }
    }

    /// Fetch conditions, at most once per meaningful move.
    ///
    /// Re-requesting on every GPS fix would hammer the service for no benefit —
    /// the weather does not change over fifty metres.
    func load(for coordinate: Geo.Coordinate?) async {
        // Whether there was a position, never where it was — this app does not
        // put a rider's location in the system log.
        Self.log.debug("conditions lookup: position \(coordinate == nil ? "not yet" : "available", privacy: .public)")
        guard let coordinate else { return }
        if let last = lastRequestedCoordinate,
           Geo.distance(last, coordinate) < 2000,
           case .loaded = state {
            return
        }
        if case .loading = state { return }

        lastRequestedCoordinate = coordinate
        state = .loading

        do {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let weather = try await WeatherService.shared.weather(for: location, including: .current)
            state = .loaded(Conditions(
                windSpeed: weather.wind.speed.converted(to: .metersPerSecond).value,
                windGust: weather.wind.gust?.converted(to: .metersPerSecond).value,
                windDirection: weather.wind.direction.converted(to: .degrees).value,
                temperature: weather.temperature.converted(to: .celsius).value,
                symbolName: weather.symbolName,
                condition: weather.condition.description,
                retrievedAt: weather.date
            ))
            if attributionURL == nil {
                attributionURL = try? await WeatherService.shared.attribution.legalPageURL
            }
        } catch {
            // Not fatal and not worth a dialog: the app's entire purpose works
            // without it. Say plainly that conditions are unavailable.
            Self.log.error("Conditions lookup failed: \(error.localizedDescription, privacy: .public) — \(String(describing: error), privacy: .public)")
            state = .unavailable(error.localizedDescription)
        }
    }
}

/// Compact conditions readout for the record screen.
///
/// The lookup is owned by the caller rather than by this view, and that is not
/// a style choice. Until a reading arrives this view renders `EmptyView`, and
/// SwiftUI does not run `task`/`onAppear` on a view that resolves to
/// `EmptyView` — it has no representation in the tree to attach them to. With
/// the lookup and its `task` in here, the strip could never appear: idle drew
/// nothing, drawing nothing meant the task never ran, and the task never
/// running meant it stayed idle. Whatever kicks this off has to live on a view
/// that is always there.
struct WeatherCard: View {

    let lookup: WeatherLookup
    let units: UnitPreferences

    var body: some View {
        Group {
            switch lookup.state {
            case .loaded(let conditions):
                loaded(conditions)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking conditions…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .idle, .unavailable:
                // Nothing rather than an error strip. A rider who cannot get
                // weather does not need to be told about it every time they open
                // the tab, and the app does not depend on it.
                EmptyView()
            }
        }
    }

    /// Re-runs the lookup when the position changes meaningfully, not on every
    /// fix. The caller attaches this to `task(id:)`, which compares it, so it
    /// is rounded — about a kilometre, well inside the 2 km grid the data comes
    /// on.
    static func coordinateKey(_ coordinate: Geo.Coordinate?) -> String {
        guard let coordinate else { return "none" }
        return String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    private func loaded(_ conditions: WeatherLookup.Conditions) -> some View {
        HStack(spacing: 14) {
            Image(systemName: conditions.symbolName)
                .font(.title2)
                .symbolRenderingMode(.multicolor)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(conditions.windDirection))
                    Text(Format.speed(conditions.windSpeed, unit: units.speed))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    if let gust = conditions.windGust, gust > conditions.windSpeed * 1.1 {
                        Text("gusts \(Format.speed(gust, unit: units.speed, decimals: 0))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(Format.cardinal(conditions.windDirection)) · \(Int(conditions.temperature.rounded()))°C")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // Attribution and retrieval time. Both required by WeatherKit's
            // terms — the mark *and* a link to Apple's legal page, which is the
            // half that was missing and is the kind of thing App Review
            // rejects for — and both things a rider should see anyway: a wind
            // reading with no timestamp is not much use.
            VStack(alignment: .trailing, spacing: 1) {
                if let legal = lookup.attributionURL {
                    Link(" Weather", destination: legal)
                        .font(.system(size: 9))
                } else {
                    Text(" Weather")
                        .font(.system(size: 9))
                }
                Text(conditions.retrievedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
