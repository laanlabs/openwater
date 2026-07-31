import CoreLocation
import OpenWaterCore
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

    private(set) var state: State = .idle
    private var lastRequestedCoordinate: Geo.Coordinate?

    /// Fetch conditions, at most once per meaningful move.
    ///
    /// Re-requesting on every GPS fix would hammer the service for no benefit —
    /// the weather does not change over fifty metres.
    func load(for coordinate: Geo.Coordinate?) async {
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
        } catch {
            // Not fatal and not worth a dialog: the app's entire purpose works
            // without it. Say plainly that conditions are unavailable.
            state = .unavailable(error.localizedDescription)
        }
    }
}

/// Compact conditions readout for the record screen.
struct WeatherCard: View {

    let coordinate: Geo.Coordinate?
    let units: UnitPreferences

    @State private var lookup = WeatherLookup()

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
        .task(id: coordinateKey) {
            await lookup.load(for: coordinate)
        }
    }

    /// Re-runs the lookup when the position changes meaningfully, not on every
    /// fix — `task(id:)` compares this, so it is rounded.
    private var coordinateKey: String {
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

            // Provider attribution and retrieval time, both required by
            // WeatherKit's terms and both things a rider should see anyway —
            // a wind reading with no timestamp is not much use.
            VStack(alignment: .trailing, spacing: 1) {
                Text(" Weather")
                    .font(.system(size: 9))
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
