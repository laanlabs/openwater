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

// MARK: - Forecast, and whether to believe it

/// The next day's wind according to several models at once.
///
/// One forecast line is a number with no error bar, and riders treat it as
/// one. Open-Meteo will serve the major global models side by side for
/// nothing, which turns that number into something far more useful: when GFS,
/// ECMWF, ICON and GEM all say fourteen knots at four, that is a plan. When
/// they say eight, fourteen, nine and nineteen, the honest answer is nobody
/// knows yet, and a rider deciding whether to drive two hours deserves to be
/// told which of those they are looking at.
struct WindOutlook {

    struct Model: Identifiable, Hashable {
        let id: String
        let label: String
        /// Hourly wind in knots, aligned to `hours`.
        let speeds: [Double?]
    }

    let hours: [Date]
    let models: [Model]

    /// Mean across models at each hour — the consensus line.
    var consensus: [Double?] {
        hours.indices.map { hour in
            let values = models.compactMap { $0.speeds[safe: hour] ?? nil }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
    }

    /// The widest disagreement between models over the useful window, in knots.
    ///
    /// Measured over the next twelve hours rather than the whole run, because
    /// models always diverge eventually and it is today's session in question.
    var spreadKn: Double {
        let window = min(12, hours.count)
        return (0..<window).compactMap { hour -> Double? in
            let values = models.compactMap { $0.speeds[safe: hour] ?? nil }
            guard values.count > 1, let low = values.min(), let high = values.max() else { return nil }
            return high - low
        }
        .max() ?? 0
    }

    /// What the spread means, in words a rider can act on.
    var agreement: (label: String, detail: String) {
        switch spreadKn {
        case ..<4:
            ("Models agree",
             "Within \(Int(spreadKn.rounded())) kn of each other for the next twelve hours. As settled as a forecast gets.")
        case ..<8:
            ("Models roughly agree",
             "Up to \(Int(spreadKn.rounded())) kn apart. The shape is probably right, the strength is a guess.")
        default:
            ("Models disagree",
             "As much as \(Int(spreadKn.rounded())) kn apart. Nobody knows yet — check a real station before driving.")
        }
    }

    var isEmpty: Bool { models.isEmpty || hours.isEmpty }
}

// MARK: - The full picture

/// Everything the free model will say about one point, in one request.
///
/// The cards on the conditions sheet are deliberately a glance — a number and
/// a shape. This is what sits behind them when a rider wants the workings:
/// humidity and dew point, pressure, cloud, UV, visibility, the hour-by-hour
/// run and the next five days.
struct WeatherDetail {

    struct Now {
        let at: Date
        let temperatureC: Double?
        let apparentC: Double?
        let humidity: Double?
        let dewPointC: Double?
        let pressureHPa: Double?
        let cloudCover: Double?
        let precipitationMm: Double?
        let visibilityM: Double?
        let uvIndex: Double?
        let windKn: Double?
        let gustKn: Double?
        let directionDeg: Double?
        let code: Int
        let isDay: Bool
    }

    struct Hour: Identifiable {
        let at: Date
        let temperatureC: Double?
        let dewPointC: Double?
        let windKn: Double?
        let gustKn: Double?
        let directionDeg: Double?
        let precipitationChance: Double?
        let visibilityM: Double?
        let uvIndex: Double?
        let code: Int
        var id: Date { at }
    }

    struct Day: Identifiable {
        let date: Date
        let code: Int
        let highC: Double?
        let lowC: Double?
        let sunrise: Date?
        let sunset: Date?
        let uvMax: Double?
        let precipitationChance: Double?
        let windMaxKn: Double?
        let gustMaxKn: Double?
        let directionDeg: Double?
        var id: Date { date }
    }

    var now: Now?
    var hours: [Hour] = []
    var days: [Day] = []

    /// The spot's own timezone, not the phone's.
    ///
    /// Sunset at a launch in Maui is a fact about Maui. Formatted in the
    /// timezone of a rider sitting in Maine it reads three hours wrong, which
    /// is exactly the kind of quiet error that gets someone off the water
    /// late. Every time on the detail screens is rendered in this.
    var timeZone: TimeZone?

    var isEmpty: Bool { now == nil && hours.isEmpty }
}

extension OpenMeteo {

    /// One request for the lot. Splitting current, hourly and daily into three
    /// calls would triple the round trips for data the API is happy to return
    /// together.
    static func detail(at coordinate: Geo.Coordinate) async -> WeatherDetail {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m"),
            .init(name: "hourly", value: "temperature_2m,dew_point_2m,precipitation_probability,wind_speed_10m,wind_gusts_10m,wind_direction_10m,weather_code,visibility,uv_index"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant"),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "forecast_days", value: "5"),
            .init(name: "timeformat", value: "unixtime"),
            // Without this the model answers in GMT and a rider in California
            // sees yesterday's date on today's row.
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return WeatherDetail() }

        var detail = WeatherDetail()

        // Open-Meteo's own caveat: with `unixtime`, hourly stamps are true
        // instants but *daily* ones are local midnight written as though it
        // were GMT. Subtracting the offset turns them back into the instant
        // they mean, which is what makes "Today" say Today.
        let offset = (root["utc_offset_seconds"] as? Double) ?? 0
        detail.timeZone = (root["timezone"] as? String).flatMap(TimeZone.init(identifier:))
            ?? TimeZone(secondsFromGMT: Int(offset))

        if let current = root["current"] as? [String: Any],
           let time = current["time"] as? Double {
            func number(_ key: String) -> Double? { current[key] as? Double }
            detail.now = WeatherDetail.Now(
                at: Date(timeIntervalSince1970: time),
                temperatureC: number("temperature_2m"),
                apparentC: number("apparent_temperature"),
                humidity: number("relative_humidity_2m"),
                dewPointC: nil,           // hourly only; filled in below
                pressureHPa: number("pressure_msl"),
                cloudCover: number("cloud_cover"),
                precipitationMm: number("precipitation"),
                visibilityM: nil,         // hourly only
                uvIndex: nil,             // hourly only
                windKn: number("wind_speed_10m"),
                gustKn: number("wind_gusts_10m"),
                directionDeg: number("wind_direction_10m"),
                code: Int(number("weather_code") ?? 0),
                isDay: (number("is_day") ?? 1) == 1
            )
        }

        if let hourly = root["hourly"] as? [String: Any],
           let times = hourly["time"] as? [Double] {
            func series(_ key: String) -> [Double?] {
                (hourly[key] as? [Any])?.map { $0 as? Double } ?? []
            }
            let temperature = series("temperature_2m")
            let dew = series("dew_point_2m")
            let wind = series("wind_speed_10m")
            let gust = series("wind_gusts_10m")
            let direction = series("wind_direction_10m")
            let chance = series("precipitation_probability")
            let visibility = series("visibility")
            let uv = series("uv_index")
            let codes = series("weather_code")

            detail.hours = times.indices.map { index in
                WeatherDetail.Hour(
                    at: Date(timeIntervalSince1970: times[index]),
                    temperatureC: temperature[safe: index] ?? nil,
                    dewPointC: dew[safe: index] ?? nil,
                    windKn: wind[safe: index] ?? nil,
                    gustKn: gust[safe: index] ?? nil,
                    directionDeg: direction[safe: index] ?? nil,
                    precipitationChance: chance[safe: index] ?? nil,
                    visibilityM: visibility[safe: index] ?? nil,
                    uvIndex: uv[safe: index] ?? nil,
                    code: Int((codes[safe: index] ?? nil) ?? 0)
                )
            }

            // The three fields the `current` block does not carry, taken from
            // whichever hour we are actually in.
            if let now = detail.now,
               let hour = detail.hours.last(where: { $0.at <= now.at }) {
                detail.now = WeatherDetail.Now(
                    at: now.at, temperatureC: now.temperatureC, apparentC: now.apparentC,
                    humidity: now.humidity, dewPointC: hour.dewPointC,
                    pressureHPa: now.pressureHPa, cloudCover: now.cloudCover,
                    precipitationMm: now.precipitationMm, visibilityM: hour.visibilityM,
                    uvIndex: hour.uvIndex, windKn: now.windKn, gustKn: now.gustKn,
                    directionDeg: now.directionDeg, code: now.code, isDay: now.isDay
                )
            }
        }

        if let daily = root["daily"] as? [String: Any],
           let times = daily["time"] as? [Double] {
            func series(_ key: String) -> [Double?] {
                (daily[key] as? [Any])?.map { $0 as? Double } ?? []
            }
            let codes = series("weather_code")
            let high = series("temperature_2m_max")
            let low = series("temperature_2m_min")
            let sunrise = series("sunrise")
            let sunset = series("sunset")
            let uv = series("uv_index_max")
            let chance = series("precipitation_probability_max")
            let wind = series("wind_speed_10m_max")
            let gust = series("wind_gusts_10m_max")
            let direction = series("wind_direction_10m_dominant")

            detail.days = times.indices.map { index in
                WeatherDetail.Day(
                    date: Date(timeIntervalSince1970: times[index] - offset),
                    code: Int((codes[safe: index] ?? nil) ?? 0),
                    highC: high[safe: index] ?? nil,
                    lowC: low[safe: index] ?? nil,
                    sunrise: (sunrise[safe: index] ?? nil).map { Date(timeIntervalSince1970: $0) },
                    sunset: (sunset[safe: index] ?? nil).map { Date(timeIntervalSince1970: $0) },
                    uvMax: uv[safe: index] ?? nil,
                    precipitationChance: chance[safe: index] ?? nil,
                    windMaxKn: wind[safe: index] ?? nil,
                    gustMaxKn: gust[safe: index] ?? nil,
                    directionDeg: direction[safe: index] ?? nil
                )
            }
        }

        return detail
    }
}

/// One hour of the sea-state forecast.
struct WaveHour: Identifiable, Hashable {
    let at: Date
    let heightM: Double?
    let periodS: Double?
    let swellM: Double?
    var id: Date { at }
}

/// Open-Meteo, which is the same free model behind the wind estimate — it
/// simply has far more to give than the app was asking of it.
enum OpenMeteo {

    /// The four global models worth comparing. Each is run by a different
    /// meteorological agency on different physics, so where they agree is
    /// genuinely more trustworthy than any of them alone.
    private static let models: [(id: String, label: String)] = [
        ("ecmwf_ifs025", "ECMWF"),
        ("gfs_seamless", "GFS"),
        ("icon_seamless", "ICON"),
        ("gem_seamless", "GEM"),
    ]

    static func outlook(at coordinate: Geo.Coordinate, hours: Int = 24) async -> WindOutlook {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "wind_speed_10m"),
            .init(name: "models", value: models.map(\.id).joined(separator: ",")),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "forecast_hours", value: String(hours)),
            .init(name: "timeformat", value: "unixtime"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Double]
        else { return WindOutlook(hours: [], models: []) }

        // Each model comes back on its own suffixed key, and a model with no
        // data for this point is simply absent — so build from what arrived
        // rather than from what was asked for.
        let series = models.compactMap { model -> WindOutlook.Model? in
            guard let raw = hourly["wind_speed_10m_\(model.id)"] as? [Any] else { return nil }
            let speeds = raw.map { $0 as? Double }
            guard speeds.contains(where: { $0 != nil }) else { return nil }
            return WindOutlook.Model(id: model.id, label: model.label, speeds: speeds)
        }
        return WindOutlook(
            hours: times.map { Date(timeIntervalSince1970: $0) },
            models: series
        )
    }

    /// Wave height, period and swell. Global, and empty inland — the marine
    /// grid simply has no cell for a lake in Nevada.
    static func waves(at coordinate: Geo.Coordinate, hours: Int = 24) async -> [WaveHour] {
        var components = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "wave_height,wave_period,swell_wave_height"),
            .init(name: "forecast_hours", value: String(hours)),
            .init(name: "timeformat", value: "unixtime"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }

        struct Payload: Decodable {
            struct Hourly: Decodable {
                let time: [Double]
                let wave_height: [Double?]?
                let wave_period: [Double?]?
                let swell_wave_height: [Double?]?
            }
            let hourly: Hourly?
        }
        guard let hourly = (try? JSONDecoder().decode(Payload.self, from: data))?.hourly else {
            return []
        }
        let rows = hourly.time.indices.map { index in
            WaveHour(
                at: Date(timeIntervalSince1970: hourly.time[index]),
                heightM: hourly.wave_height?[safe: index] ?? nil,
                periodS: hourly.wave_period?[safe: index] ?? nil,
                swellM: hourly.swell_wave_height?[safe: index] ?? nil
            )
        }
        // Inland points come back as a full grid of nulls rather than an
        // error, which would otherwise render as an empty chart with axes.
        return rows.contains(where: { $0.heightM != nil }) ? rows : []
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

// MARK: - Warnings

/// An active National Weather Service alert covering this point.
///
/// This is also the honest answer to "can we show lightning strikes". There
/// is no free, redistributable, real-time strike feed: Blitzortung's network
/// restricts commercial reuse, NOAA's GOES lightning mapper ships as NetCDF
/// on S3 rather than as tiles, and every provider with a clean strike API
/// charges for it. What is free is the warning a human forecaster issues when
/// the storm is worth caring about — which is the actionable half anyway. A
/// rider deciding whether to go out is served better by "Severe Thunderstorm
/// Warning until 4pm" than by a dot on a map.
///
/// Small Craft Advisories and Rip Current Statements come through the same
/// feed, and for this sport those are the ones that matter most.
struct WeatherAlert: Identifiable, Hashable {
    let id: String
    let event: String
    let headline: String?
    let severity: String
    let ends: Date?

    /// The ones that change whether you launch, floated to the top.
    var isOnTheWater: Bool {
        let e = event.lowercased()
        return e.contains("marine") || e.contains("small craft") || e.contains("rip current")
            || e.contains("thunderstorm") || e.contains("gale") || e.contains("storm")
            || e.contains("hurricane") || e.contains("tsunami") || e.contains("wind")
    }

    var isSevere: Bool {
        ["Extreme", "Severe"].contains(severity) || isOnTheWater
    }
}

extension NationalWeatherService {

    /// Alerts in force at a point. Keyless, and US only like the rest of NWS.
    static func alerts(at coordinate: Geo.Coordinate) async -> [WeatherAlert] {
        let path = String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f",
                          coordinate.latitude, coordinate.longitude)
        guard let url = URL(string: path), let data = await get(url) else { return [] }

        struct Payload: Decodable {
            struct Feature: Decodable {
                struct Properties: Decodable {
                    let id: String?
                    let event: String?
                    let headline: String?
                    let severity: String?
                    let ends: String?
                }
                let properties: Properties?
            }
            let features: [Feature]?
        }
        guard let features = (try? JSONDecoder().decode(Payload.self, from: data))?.features else {
            return []
        }
        return features
            .compactMap { feature -> WeatherAlert? in
                guard let p = feature.properties, let event = p.event else { return nil }
                return WeatherAlert(
                    id: p.id ?? event,
                    event: event,
                    headline: p.headline,
                    severity: p.severity ?? "Unknown",
                    ends: p.ends.flatMap { ISO8601DateFormatter().date(from: $0) }
                )
            }
            .sorted { ($0.isOnTheWater ? 0 : 1) < ($1.isOnTheWater ? 0 : 1) }
    }
}

// MARK: - Tides

/// A NOAA tide station and today's turns.
struct TideStation: Identifiable, Hashable {
    let id: String
    let name: String
    let metres: Double
    var events: [TideEvent] = []

    var url: URL {
        URL(string: "https://tidesandcurrents.noaa.gov/noaatidepredictions.html?id=\(id)")!
    }

    /// The next turn from now — the one number a rider actually wants.
    var next: TideEvent? { events.first { $0.at > Date() } }
}

struct TideEvent: Hashable {
    let at: Date
    let metres: Double
    let isHigh: Bool
}

/// NOAA CO-OPS: tide predictions for 3,499 US stations, free and keyless.
enum TidesAndCurrents {

    /// The station index is a 2 MB document and changes about never, so it is
    /// fetched once, boiled down to what we use, and kept on disk.
    private static var cached: [(id: String, name: String, coordinate: Geo.Coordinate)] = []

    private static var cacheURL: URL {
        URL.cachesDirectory.appending(path: "noaa-tide-stations.json")
    }

    private struct Distilled: Codable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
    }

    static func stations(near coordinate: Geo.Coordinate, limit: Int = 3) async -> [TideStation] {
        let index = await loadIndex()
        return index
            .map { (station: $0, metres: Geo.distance(coordinate, $0.coordinate)) }
            .sorted { $0.metres < $1.metres }
            .prefix(limit)
            .map { TideStation(id: $0.station.id, name: $0.station.name, metres: $0.metres) }
    }

    private static func loadIndex() async -> [(id: String, name: String, coordinate: Geo.Coordinate)] {
        if !cached.isEmpty { return cached }

        if let data = try? Data(contentsOf: cacheURL),
           let rows = try? JSONDecoder().decode([Distilled].self, from: data), !rows.isEmpty {
            cached = rows.map {
                ($0.id, $0.name, Geo.Coordinate(latitude: $0.latitude, longitude: $0.longitude))
            }
            return cached
        }

        guard let url = URL(string: "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=tidepredictions"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }

        struct Payload: Decodable {
            struct Station: Decodable {
                let id: String?
                let name: String?
                let lat: Double?
                let lng: Double?
            }
            let stations: [Station]?
        }
        let rows = ((try? JSONDecoder().decode(Payload.self, from: data))?.stations ?? [])
            .compactMap { station -> Distilled? in
                guard let id = station.id, let name = station.name,
                      let lat = station.lat, let lng = station.lng else { return nil }
                return Distilled(id: id, name: name, latitude: lat, longitude: lng)
            }
        if let encoded = try? JSONEncoder().encode(rows) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        cached = rows.map {
            ($0.id, $0.name, Geo.Coordinate(latitude: $0.latitude, longitude: $0.longitude))
        }
        return cached
    }

    /// Today's high and low waters for one station, in metres above MLLW.
    static func today(for stationId: String) async -> [TideEvent] {
        var components = URLComponents(
            string: "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter")!
        components.queryItems = [
            .init(name: "product", value: "predictions"),
            .init(name: "interval", value: "hilo"),
            .init(name: "station", value: stationId),
            .init(name: "date", value: "today"),
            .init(name: "datum", value: "MLLW"),
            .init(name: "units", value: "metric"),
            .init(name: "time_zone", value: "lst_ldt"),
            .init(name: "format", value: "json"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }

        struct Payload: Decodable {
            struct Prediction: Decodable { let t: String; let v: String; let type: String }
            let predictions: [Prediction]?
        }
        // The station's own local time, which is what the reading means and
        // also — usefully — the timezone the rider is standing in.
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd HH:mm"
        parser.timeZone = .current

        return ((try? JSONDecoder().decode(Payload.self, from: data))?.predictions ?? [])
            .compactMap { row in
                guard let at = parser.date(from: row.t), let metres = Double(row.v) else { return nil }
                return TideEvent(at: at, metres: metres, isHigh: row.type == "H")
            }
    }
}

// MARK: - Buoys

/// An offshore buoy: the only free source of what the water is actually doing.
///
/// Wave height, period and water temperature are measured, not modelled, and
/// no forecast grid substitutes for them. Water temperature in particular
/// decides what a rider wears, which is a safety question in a lot of the
/// places this app is used.
struct Buoy: Identifiable, Hashable {
    let id: String
    let name: String
    let metres: Double
    var reading: BuoyReading?

    var url: URL {
        URL(string: "https://www.ndbc.noaa.gov/station_page.php?station=\(id)")!
    }
}

struct BuoyReading: Hashable {
    let waveHeightM: Double?
    let dominantPeriodS: Double?
    let waterTempC: Double?
    let windKn: Double?
    let at: Date?
}

/// NOAA's National Data Buoy Center. Free, keyless, fixed-width text.
enum DataBuoyCenter {

    private static var cached: [(id: String, name: String, coordinate: Geo.Coordinate)] = []

    static func buoys(near coordinate: Geo.Coordinate, limit: Int = 3,
                      radius: Double = 150_000) async -> [Buoy] {
        let index = await loadIndex()
        return index
            .map { (station: $0, metres: Geo.distance(coordinate, $0.coordinate)) }
            .filter { $0.metres < radius }
            .sorted { $0.metres < $1.metres }
            .prefix(limit)
            .map { Buoy(id: $0.station.id, name: $0.station.name, metres: $0.metres) }
    }

    /// The index is XML with everything on the attributes of one tag, so each
    /// `<station …/>` is matched whole and its attributes read by name —
    /// robust to the order they come in, which does vary.
    ///
    /// Only stations flagged `met="y"` are kept. The file lists 1,351 of them
    /// and a good share are water-quality or current platforms with no
    /// meteorological feed at all; taking the nearest three regardless meant
    /// three 404s and an empty list that then claimed there were no buoys.
    private static func loadIndex() async -> [(id: String, name: String, coordinate: Geo.Coordinate)] {
        if !cached.isEmpty { return cached }
        guard let url = URL(string: "https://www.ndbc.noaa.gov/activestations.xml"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"<station\b[^>]*>"#)
        else { return [] }

        let text = xml as NSString
        cached = regex
            .matches(in: xml, range: NSRange(location: 0, length: text.length))
            .compactMap { match -> (String, String, Geo.Coordinate)? in
                let tag = text.substring(with: match.range)
                guard attribute("met", in: tag) == "y",
                      let id = attribute("id", in: tag),
                      let name = attribute("name", in: tag),
                      let lat = attribute("lat", in: tag).flatMap(Double.init),
                      let lon = attribute("lon", in: tag).flatMap(Double.init)
                else { return nil }
                return (id, name, Geo.Coordinate(latitude: lat, longitude: lon))
            }
        return cached
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let opening = tag.range(of: "\(name)=\"") else { return nil }
        let rest = tag[opening.upperBound...]
        guard let closing = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<closing])
    }

    /// The latest row of a station's realtime file.
    ///
    /// Fixed-width columns after two `#` header lines, with `MM` for a sensor
    /// that is not reporting — which is common, so every field is optional.
    static func latest(for stationId: String) async -> BuoyReading? {
        // Uppercase, always. The index lists shore stations in lower case
        // ("pxoc1") and the data files are upper ("PXOC1.txt"); numeric buoy
        // ids are unaffected, which is why this only showed up once the
        // nearest station was a pier rather than a buoy.
        guard let url = URL(string: "https://www.ndbc.noaa.gov/data/realtime2/\(stationId.uppercased()).txt"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        guard let first = rows.first else { return nil }
        let columns = first.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard columns.count >= 15 else { return nil }

        func value(_ index: Int) -> Double? {
            guard let raw = columns[safe: index], raw != "MM" else { return nil }
            return Double(raw)
        }
        // YY MM DD hh mm WDIR WSPD GST WVHT DPD APD MWD PRES ATMP WTMP
        //  0  1  2  3  4    5    6   7    8   9  10  11   12   13   14
        var stamp = DateComponents()
        stamp.year = value(0).map(Int.init)
        stamp.month = value(1).map(Int.init)
        stamp.day = value(2).map(Int.init)
        stamp.hour = value(3).map(Int.init)
        stamp.minute = value(4).map(Int.init)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let reading = BuoyReading(
            waveHeightM: value(8),
            dominantPeriodS: value(9),
            waterTempC: value(14),
            windKn: value(6).map { $0 * 3600 / 1852 },
            at: utc.date(from: stamp)
        )
        // Sea state or nothing. Plenty of these stations are piers reporting
        // only wind and air temperature — real data, but the wind tab already
        // answers that, and a "Buoys" list whose rows carry no wave height or
        // water temperature is just a second copy of it.
        guard reading.waveHeightM != nil || reading.waterTempC != nil else { return nil }
        return reading
    }
}
