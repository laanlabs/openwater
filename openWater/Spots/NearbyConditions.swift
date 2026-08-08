import Foundation
import OpenWaterCore
import SwiftUI

// MARK: - The sky, not just the wind

/// What it is like out there right now, beyond how hard it is blowing.
///
/// The spot page has always led with wind, which is right — it is the number
/// that decides whether you drive. But wind alone does not tell you to bring a
/// jacket, and "18 knots" reads very differently at 8°C in rain than at 28°C
/// in sun. This is the rest of that sentence.
///
/// Open-Meteo, same free model the wind estimate already comes from, so it
/// costs one more field on a request the app was making anyway.
struct SpotWeather: Codable, Hashable {
    let temperatureC: Double
    let apparentC: Double?
    /// WMO present-weather code — the standard the model reports in.
    let code: Int
    let isDay: Bool
    let at: Date

    var symbol: String { Self.symbol(for: code, isDay: isDay) }
    var label: String { Self.label(for: code) }

    /// Hierarchical rendering in one deliberate colour rather than
    /// `.multicolor`: Apple's multicolour clouds are white, which is
    /// invisible on the white cards these sit on. One colour per family also
    /// makes the icon readable at 20pt, which is the size it is usually shown.
    var tint: Color {
        switch code {
        case 0, 1: isDay ? .orange : .indigo
        case 51...67, 80...82: .blue
        case 71...77, 85, 86: .teal
        case 95...99: .purple
        default: .secondary
        }
    }

    /// WMO 4677, collapsed to the distinctions a rider on a beach cares about.
    /// Drizzle and rain are separate; "moderate" and "dense" freezing drizzle
    /// are not.
    static func label(for code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mainly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61, 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81: "Showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorms"
        case 96, 99: "Thunderstorms, hail"
        default: "—"
        }
    }

    static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 67: "cloud.rain.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

// MARK: - Free public observation stations

/// A real anemometer somebody else pays for, near the spot.
///
/// The guide's own meters are mostly iKitesurf, which is the best network
/// there is for this sport and also the one that asks for a subscription.
/// NOAA runs hundreds of stations that anybody can read for nothing —
/// airfields, road-weather sensors, marine buoys — and near a lot of launches
/// one of them is close enough to be worth a look before paying for anything.
///
/// `api.weather.gov` is free, keyless, and United States only. Outside it this
/// simply finds nothing, and the sheet says so rather than pretending.
struct FreeStation: Identifiable, Hashable {
    let id: String
    let name: String
    let coordinate: Geo.Coordinate
    let metres: Double

    /// Filled in lazily — the list arrives first, readings trickle in after.
    var observation: StationObservation?

    var url: URL {
        URL(string: "https://www.weather.gov/wrh/timeseries?site=\(id)")!
    }
}

/// The latest reading from one of those stations.
struct StationObservation: Hashable {
    let windKn: Double?
    let gustKn: Double?
    let directionDeg: Double?
    let temperatureC: Double?
    let summary: String?
    let at: Date?

    var isStale: Bool {
        guard let at else { return true }
        return Date().timeIntervalSince(at) > 3 * 3600
    }
}

/// Reads NOAA's public observation network.
///
/// NWS asks every caller to identify itself in `User-Agent` and will refuse
/// anonymous traffic, so that header is not optional politeness.
enum NationalWeatherService {

    private static let agent = "openWater/1.0 (openwaterapp.com; support@openwaterapp.com)"

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    /// Stations near a coordinate, nearest first.
    ///
    /// The endpoint answers a 301 to the gridpoint that actually owns the
    /// list; `URLSession` follows it, which is why this reads as one call and
    /// the equivalent `curl` needs `-L`.
    static func stations(near coordinate: Geo.Coordinate, limit: Int = 8) async -> [FreeStation] {
        let path = String(format: "https://api.weather.gov/points/%.4f,%.4f/stations",
                          coordinate.latitude, coordinate.longitude)
        guard let url = URL(string: path), let data = await get(url) else { return [] }

        struct Payload: Decodable {
            struct Feature: Decodable {
                struct Geometry: Decodable { let coordinates: [Double] }
                struct Properties: Decodable {
                    let stationIdentifier: String?
                    let name: String?
                }
                let geometry: Geometry?
                let properties: Properties?
            }
            let features: [Feature]?
        }
        guard let features = (try? JSONDecoder().decode(Payload.self, from: data))?.features else {
            return []
        }

        return features
            .compactMap { feature -> FreeStation? in
                guard let id = feature.properties?.stationIdentifier,
                      let pair = feature.geometry?.coordinates, pair.count >= 2
                else { return nil }
                // GeoJSON is longitude first, which is the opposite of every
                // other coordinate in this app.
                let here = Geo.Coordinate(latitude: pair[1], longitude: pair[0])
                return FreeStation(
                    id: id,
                    name: feature.properties?.name ?? id,
                    coordinate: here,
                    metres: Geo.distance(coordinate, here)
                )
            }
            .sorted { $0.metres < $1.metres }
            .prefix(limit)
            .map { $0 }
    }

    /// The latest observation from one station, or nil when it has not
    /// reported — plenty of these sensors are seasonal or simply broken, which
    /// is worth showing as "no reading" rather than hiding.
    static func latest(for stationId: String) async -> StationObservation? {
        guard let url = URL(string: "https://api.weather.gov/stations/\(stationId)/observations/latest"),
              let data = await get(url)
        else { return nil }

        struct Payload: Decodable {
            struct Properties: Decodable {
                struct Quantity: Decodable {
                    let value: Double?
                    let unitCode: String?
                }
                let timestamp: String?
                let textDescription: String?
                let temperature: Quantity?
                let windSpeed: Quantity?
                let windGust: Quantity?
                let windDirection: Quantity?
            }
            let properties: Properties?
        }
        guard let p = (try? JSONDecoder().decode(Payload.self, from: data))?.properties else {
            return nil
        }

        // NWS reports wind in km/h and temperature in °C, but says so in every
        // payload rather than promising it — so convert from what it declares
        // rather than from what it usually sends.
        func knots(_ q: Payload.Properties.Quantity?) -> Double? {
            guard let value = q?.value else { return nil }
            return switch q?.unitCode {
            case "wmoUnit:km_h-1": value / 1.852
            case "wmoUnit:m_s-1": value * 3600 / 1852
            default: value / 1.852
            }
        }
        func celsius(_ q: Payload.Properties.Quantity?) -> Double? {
            guard let value = q?.value else { return nil }
            return q?.unitCode == "wmoUnit:degF" ? (value - 32) * 5 / 9 : value
        }

        let observed = p.timestamp.flatMap {
            ISO8601DateFormatter().date(from: $0)
                ?? ISO8601DateFormatter.withFractionalSeconds.date(from: $0)
        }
        let summary = p.textDescription?.isEmpty == false ? p.textDescription : nil
        // A station that reports nothing at all is not worth a row.
        guard knots(p.windSpeed) != nil || celsius(p.temperature) != nil || summary != nil else {
            return nil
        }
        return StationObservation(
            windKn: knots(p.windSpeed),
            gustKn: knots(p.windGust),
            directionDeg: p.windDirection?.value,
            temperatureC: celsius(p.temperature),
            summary: summary,
            at: observed
        )
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
