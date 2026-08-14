import CoreLocation
import OpenWaterCore
import WeatherKit

/// Looks up the wind that was blowing while a session was recorded.
///
/// **Requires the WeatherKit capability.** It is an Apple service that needs the
/// entitlement enabled on the App ID, and it will simply throw without it. That
/// is deliberate — everything else has to keep working when it is absent, and
/// `RecordedWindRow` turns the failure into words a rider can act on.
enum WeatherLookup {

    /// The wind that was actually blowing while a session was recorded.
    ///
    /// Not the same job as the launch forecast on the record screen, which
    /// answers "should I go out?". This answers "what was it doing an hour
    /// ago", and it is the difference between a polar measured against a real
    /// wind direction and one measured against a direction guessed from the
    /// shape of the track. WeatherKit serves historical hourly data, so it
    /// works for sessions recorded before the app ever asked — and for GPX
    /// files imported from another device, where there was never any chance of
    /// capturing conditions live.
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
}
