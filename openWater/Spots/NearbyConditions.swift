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
        var gusts: [Double?] = []
        /// Degrees the wind comes from, aligned to `hours`.
        var directions: [Double?] = []
        /// A model that is already a blend of the others — NOAA's NBM
        /// contains GFS and HRRR and dozens more, statistically corrected
        /// against observations. Worth showing as its own line, wrong to
        /// average into a blend alongside its own ingredients: that counts
        /// the same physics twice and calls the double vote agreement.
        var isComposite: Bool = false
    }

    let hours: [Date]
    let models: [Model]
    var timeZone: TimeZone?
    /// Set when the network failed and this outlook is the cache's last
    /// good answer, this many seconds old. The card says so — a stale
    /// forecast posing as fresh is the one dishonesty worse than a blank.
    var staleAge: TimeInterval?

    /// The mean of just the models a rider has left switched on.
    ///
    /// Separate from `consensus`, which always averages everything: on the
    /// compare screen the whole point is that turning one off changes the
    /// blend, so you can see what the answer looks like without the model you
    /// distrust today.
    func blend(of enabled: Set<String>) -> [Double?] {
        let chosen = models.filter { enabled.contains($0.id) }
        guard !chosen.isEmpty else { return [] }
        return hours.indices.map { hour in
            let values = chosen.compactMap { $0.speeds[safe: hour] ?? nil }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
    }

    /// Gusts, blended the same way as the speeds.
    func blendGusts(of enabled: Set<String>) -> [Double?] {
        let chosen = models.filter { enabled.contains($0.id) }
        guard !chosen.isEmpty else { return [] }
        return hours.indices.map { hour in
            let values = chosen.compactMap { $0.gusts[safe: hour] ?? nil }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
    }

    /// Direction, averaged the only way a direction can be.
    ///
    /// A plain mean of 350° and 10° is 180° — due south, the exact opposite
    /// of the northerly both models actually forecast. Averaging the vectors
    /// and taking the angle back off avoids that, and also degrades
    /// sensibly: models pointing every which way produce a short resultant,
    /// which is honestly what disagreement about direction looks like.
    ///
    /// Each model's vote is weighted by its own speed: a model calling 20 kn
    /// from the west should out-vote one calling 3 kn from the south,
    /// because near calm a modelled direction is close to noise. This is the
    /// guide's rule of always working in components rather than averaging
    /// compass points as if they were all equally meant.
    func blendDirections(of enabled: Set<String>) -> [Double?] {
        let chosen = models.filter { enabled.contains($0.id) }
        guard !chosen.isEmpty else { return [] }
        return hours.indices.map { hour in
            var x = 0.0, y = 0.0
            for model in chosen {
                guard let direction = model.directions[safe: hour] ?? nil else { continue }
                // A model with a direction but no speed still votes, at the
                // weight of a light air — present, not dominant.
                let weight = max((model.speeds[safe: hour] ?? nil) ?? 1, 0.0)
                x += weight * cos(direction * .pi / 180)
                y += weight * sin(direction * .pi / 180)
            }
            guard x != 0 || y != 0 else { return nil }
            let mean = atan2(y, x) * 180 / .pi
            return mean < 0 ? mean + 360 : mean
        }
    }

    /// How far each model actually runs. They stop at different horizons —
    /// ICON at eight days, GEM at ten, GFS at sixteen — and a line that just
    /// ends is worth explaining rather than hiding.
    func horizon(of model: Model) -> Date? {
        guard let last = model.speeds.lastIndex(where: { $0 != nil }) else { return nil }
        return hours[safe: last]
    }

    /// The models that get a vote in the consensus and the spread — the
    /// independent ones. A composite would double-count its ingredients.
    private var independent: [Model] { models.filter { !$0.isComposite } }

    /// Mean across models at each hour — the consensus line.
    var consensus: [Double?] {
        hours.indices.map { hour in
            let values = independent.compactMap { $0.speeds[safe: hour] ?? nil }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
    }

    /// Gusts, averaged over the same voters — what the Foam caps draw.
    var consensusGusts: [Double?] {
        hours.indices.map { hour in
            let values = independent.compactMap { $0.gusts[safe: hour] ?? nil }
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
            let values = independent.compactMap { $0.speeds[safe: hour] ?? nil }
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

extension WindOutlook {
    /// The blend as core's vector series, m/s.
    ///
    /// Independent models only, so a composite cannot double-vote its own
    /// ingredients into whatever consumes this. Knots are this struct's
    /// display dialect; core speaks m/s, and the conversion happens here at
    /// the border rather than scattered through the consumers.
    var blendTimeline: WindTimeline {
        let ids = Set(models.filter { !$0.isComposite }.map(\.id))
        let speeds = blend(of: ids)
        let directions = blendDirections(of: ids)
        let gusts = blendGusts(of: ids)
        let toMS = 1 / 1.94384
        return WindTimeline(samples: hours.indices.compactMap { hour in
            guard let speed = speeds[safe: hour] ?? nil,
                  let direction = directions[safe: hour] ?? nil
            else { return nil }
            return WindTimeline.Sample(
                time: hours[hour],
                speed: speed * toMS,
                directionFrom: direction,
                gust: (gusts[safe: hour] ?? nil).map { $0 * toMS }
            )
        })
    }
}

// MARK: - The forecast, nudged by a real anemometer

/// The guide's 0–6 hour rule, wired to the sheet: when a station or buoy
/// nearby has just read the wind, the most useful thing that reading can do
/// is correct the models' next few hours — not sit in its own card being
/// merely true. `WindNowcast` in core does the arithmetic; this picks the
/// reading, runs it, and says the result in a sentence.
struct NowcastAdjustment {

    /// Who read the wind — a station name or a buoy's.
    let sourceName: String
    let ageMinutes: Int
    /// Observed minus blended at the reading's moment, knots. Positive
    /// means more wind on the water than in the models.
    let deltaKn: Double
    /// The blend with the innovation decayed through it, m/s.
    let corrected: WindTimeline

    /// Corrected knots this far ahead of now.
    func correctedKn(hoursAhead: Double, from now: Date = Date()) -> Double? {
        corrected.wind(at: now.addingTimeInterval(hoursAhead * 3600))
            .map { $0.speed * 1.94384 }
    }

    /// The whole thing as one sentence a rider can act on.
    var line: String {
        let age = ageMinutes <= 1 ? "just now" : "\(ageMinutes) min ago"
        guard abs(deltaKn) >= 1.5 else {
            return "\(sourceName) read the wind \(age) and agrees with the models."
        }
        let sense = deltaKn > 0 ? "above" : "below"
        var text = "\(sourceName) read \(Int(abs(deltaKn).rounded())) kn \(sense) the models \(age)."
        if let soon = correctedKn(hoursAhead: 1), let later = correctedKn(hoursAhead: 3) {
            text += " Next hours corrected to \(Int(soon.rounded())), then \(Int(later.rounded())) kn."
        }
        return text
    }

    /// Pick a reading, subtract the models, decay the difference.
    ///
    /// The nearest fresh reading wins rather than the freshest: inside the
    /// two-hour bar they are all current enough, and a mile of distance
    /// costs more representativeness than an hour of age. Stations correct
    /// as full vectors; a buoy reports no wind direction, so it borrows the
    /// model's own direction and corrects the strength alone — a smaller
    /// claim, honestly limited to what was measured.
    static func make(outlook: WindOutlook, stations: [FreeStation], buoys: [Buoy],
                     at now: Date = Date()) -> NowcastAdjustment? {
        let model = outlook.blendTimeline
        guard !model.isEmpty else { return nil }
        let toMS = 1 / 1.94384

        var candidates: [(metres: Double, name: String, sample: WindTimeline.Sample)] = []
        for station in stations {
            guard let observation = station.observation,
                  let kn = observation.windKn,
                  let read = observation.at, now.timeIntervalSince(read) < 2 * 3600,
                  let direction = observation.directionDeg ?? model.wind(at: read)?.directionFrom
            else { continue }
            candidates.append((station.metres, station.name, WindTimeline.Sample(
                time: read, speed: kn * toMS, directionFrom: direction,
                gust: observation.gustKn.map { $0 * toMS })))
        }
        for buoy in buoys {
            guard let reading = buoy.reading,
                  let kn = reading.windKn,
                  let read = reading.at, now.timeIntervalSince(read) < 2 * 3600,
                  let direction = model.wind(at: read)?.directionFrom
            else { continue }
            candidates.append((buoy.metres, buoy.name, WindTimeline.Sample(
                time: read, speed: kn * toMS, directionFrom: direction)))
        }

        guard let chosen = candidates.min(by: { $0.metres < $1.metres }),
              let modelled = model.wind(at: chosen.sample.time)
        else { return nil }
        return NowcastAdjustment(
            sourceName: chosen.name,
            ageMinutes: max(0, Int(now.timeIntervalSince(chosen.sample.time) / 60)),
            deltaKn: (chosen.sample.speed - modelled.speed) * 1.94384,
            corrected: WindNowcast().corrected(model, by: chosen.sample)
        )
    }
}

// MARK: - How the models have been landing here

/// Each model's recent record at one point: how far its call made days
/// ahead typically drifted from its own final hour.
///
/// Two flavours, and the struct says which it is. With a met buoy near the
/// spot, the reference is that buoy's own anemometer over the past two
/// weeks — real verification, the strongest sentence this screen can say.
/// Without one, the reference is each model's freshest run, which makes
/// this a *steadiness* measure: honest about being weaker, still worth
/// having, because a rider choosing which line to believe on Thursday for
/// Saturday wants to know that ICON has been rewriting its story here all
/// month while ECMWF has not. Both are free: Open-Meteo keeps every
/// model's previous runs, and NDBC's realtime files carry 45 days of
/// readings.
struct ModelSteadiness {

    struct Row: Identifiable {
        let id: String
        let label: String
        /// Mean absolute error, knots, by days of lead. `[1]` is the
        /// day-ahead call, `[3]` three days out. Against the buoy when
        /// verified, against the model's own final run when not — and in
        /// the verified case `[0]` exists too: how wrong the freshest run
        /// still is at this water.
        let revisionKn: [Int: Double]

        /// The headline number: two days out, the lead a rider actually
        /// plans a weekend around.
        var twoDaysOutKn: Double? { revisionKn[2] }
    }

    let rows: [Row]
    /// Set when the reference was a real anemometer: the buoy's name and
    /// how far it sits from the point being forecast.
    var verifiedAgainst: (name: String, metres: Double)? = nil
    var isEmpty: Bool { rows.isEmpty }

    /// The model that has moved its story least at two days.
    var steadiest: Row? {
        rows.filter { $0.twoDaysOutKn != nil }
            .min { ($0.twoDaysOutKn ?? .infinity) < ($1.twoDaysOutKn ?? .infinity) }
    }
}

// MARK: - The forecast as a distribution

/// One model run thirty-one times from nudged starting points.
///
/// The model compare screen shows disagreement between agencies, which is a
/// spread but not a distribution — four deterministic models make correlated
/// errors, and their agreement understates the real uncertainty. An ensemble
/// is the honest version: GEFS perturbs its own starting conditions and runs
/// again, and the fraction of members clearing a threshold *is* a
/// probability. "Seven in ten members say fifteen knots" is the sentence a
/// rider deciding whether to drive two hours actually needs.
struct EnsembleOutlook {

    let hours: [Date]
    /// Hourly wind in knots, one row per member, each aligned to `hours`.
    let members: [[Double?]]
    var timeZone: TimeZone?

    var isEmpty: Bool { members.isEmpty || hours.isEmpty }
    var memberCount: Int { members.count }

    /// The member opinions for one hour, sorted and stripped of gaps.
    private func opinions(at hour: Int) -> [Double] {
        members.compactMap { $0[safe: hour] ?? nil }.sorted()
    }

    /// A percentile of what the members say at one hour, interpolated.
    func percentile(_ p: Double, at hour: Int) -> Double? {
        let values = opinions(at: hour)
        guard !values.isEmpty else { return nil }
        let rank = max(0, min(1, p / 100)) * Double(values.count - 1)
        let low = Int(rank.rounded(.down))
        let high = Int(rank.rounded(.up))
        let t = rank - Double(low)
        return values[low] * (1 - t) + values[high] * t
    }

    /// The chance of at least this much wind at one hour, 0–1: the fraction
    /// of members that clear the bar. Crude and honest — no fitted curve,
    /// just a show of hands.
    func probabilityAtLeast(_ kn: Double, at hour: Int) -> Double? {
        let values = opinions(at: hour)
        guard !values.isEmpty else { return nil }
        return Double(values.filter { $0 >= kn }.count) / Double(values.count)
    }

    /// The row for a moment on some other chart's clock, since the ensemble
    /// runs a shorter horizon than the deterministic models beside it.
    func hourIndex(of date: Date) -> Int? {
        guard let index = hours.lastIndex(where: { $0 <= date }) else { return nil }
        // An hour from a 16-day outlook can be far past the ensemble's end;
        // only answer for moments the ensemble actually covers.
        return date.timeIntervalSince(hours[index]) < 3_600 ? index : nil
    }
}

// MARK: - The next few hours, every quarter hour

/// Wind at fifteen-minute grain, where a rapid-update model actually
/// provides it.
///
/// An hourly forecast can hide a sixty-minute session inside one bar, and a
/// front's arrival inside another. The rapid-update regionals — HRRR over
/// North America, ICON-D2 over central Europe, AROME over France — publish
/// native quarter-hour steps that can catch both. Deliberately absent
/// elsewhere: Open-Meteo will happily interpolate hourly data to fifteen
/// minutes anywhere on Earth, and a smooth curve pretending to be four
/// times the information is exactly the false precision this app is
/// against. No native model, no card.
struct NearTermWind {
    let times: [Date]
    /// Knots, aligned to `times` — this is a display struct and stays in
    /// the display dialect.
    let speedsKn: [Double?]
    let gustsKn: [Double?]
    /// Degrees the wind comes from.
    let directions: [Double?]
    var timeZone: TimeZone?

    var isEmpty: Bool { times.isEmpty || !speedsKn.contains { $0 != nil } }

    var peakGustKn: Double? { gustsKn.compactMap { $0 }.max() }
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
              let data = await ForecastCache.data(from: url, ttl: 1800),
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

    /// The four global models worth comparing, each run by a different
    /// meteorological agency on different physics, so where they agree is
    /// genuinely more trustworthy than any of them alone — plus NOAA's
    /// National Blend of Models, which is not independent physics at all
    /// but dozens of models statistically corrected against real stations.
    /// The NBM is the best single line there is over the US, a null grid
    /// everywhere else (it simply vanishes from the response), and marked
    /// composite so it never gets averaged in beside its own ingredients.
    private static let models: [(id: String, label: String, isComposite: Bool)] = [
        ("ecmwf_ifs025", "ECMWF", false),
        ("gfs_seamless", "GFS", false),
        ("icon_seamless", "ICON", false),
        ("gem_seamless", "GEM", false),
        ("ncep_nbm_conus", "NBM", true),
    ]

    static func outlook(at coordinate: Geo.Coordinate, days: Int = 1,
                        pastDays: Int = 0) async -> WindOutlook {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            .init(name: "models", value: models.map(\.id).joined(separator: ",")),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "forecast_days", value: String(days)),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ] + (pastDays > 0 ? [URLQueryItem(name: "past_days", value: String(pastDays))] : [])
        guard let url = components.url,
              let served = await ForecastCache.serve(from: url, ttl: 1800),
              let root = try? JSONSerialization.jsonObject(with: served.data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Double]
        else { return WindOutlook(hours: [], models: []) }

        // Each model comes back on its own suffixed key, and a model with no
        // data for this point is simply absent — so build from what arrived
        // rather than from what was asked for.
        func series(_ field: String, _ model: String) -> [Double?] {
            (hourly["\(field)_\(model)"] as? [Any])?.map { $0 as? Double } ?? []
        }
        let series = models.compactMap { model -> WindOutlook.Model? in
            let speeds = series("wind_speed_10m", model.id)
            guard speeds.contains(where: { $0 != nil }) else { return nil }
            return WindOutlook.Model(
                id: model.id, label: model.label, speeds: speeds,
                gusts: series("wind_gusts_10m", model.id),
                directions: series("wind_direction_10m", model.id),
                isComposite: model.isComposite
            )
        }
        return WindOutlook(
            hours: times.map { Date(timeIntervalSince1970: $0) },
            models: series,
            timeZone: (root["timezone"] as? String).flatMap(TimeZone.init(identifier:)),
            staleAge: served.staleAge
        )
    }

    /// The quarter-hour models, asked together — see `NearTermWind`.
    ///
    /// All three rapid-update regionals go in one request. A model that
    /// does not cover the point simply drops out of the response; when none
    /// covers it the API answers with an error and the card stays off,
    /// which is the design. When exactly one model has data its series
    /// arrives on bare keys; where domains overlap the keys are suffixed
    /// and the finer model is preferred.
    static func nearTerm(at coordinate: Geo.Coordinate, hoursAhead: Int = 6) async -> NearTermWind {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "minutely_15", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            .init(name: "models", value: "ncep_hrrr_conus,icon_d2,meteofrance_arome_france_hd"),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "forecast_minutely_15", value: String(hoursAhead * 4)),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        let empty = NearTermWind(times: [], speedsKn: [], gustsKn: [], directions: [])
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 900),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quarter = root["minutely_15"] as? [String: Any],
              let times = quarter["time"] as? [Double]
        else { return empty }

        // Finest grid first for the overlap regions; bare key when a single
        // model answered alone.
        func series(_ field: String) -> [Double?] {
            for suffix in ["_meteofrance_arome_france_hd", "_icon_d2", "_ncep_hrrr_conus", ""] {
                if let row = quarter[field + suffix] as? [Any] {
                    let values = row.map { $0 as? Double }
                    if values.contains(where: { $0 != nil }) { return values }
                }
            }
            return []
        }
        return NearTermWind(
            times: times.map { Date(timeIntervalSince1970: $0) },
            speedsKn: series("wind_speed_10m"),
            gustsKn: series("wind_gusts_10m"),
            directions: series("wind_direction_10m"),
            timeZone: (root["timezone"] as? String).flatMap(TimeZone.init(identifier:))
        )
    }

    /// The next few hours of wind at several points, in one request.
    ///
    /// Open-Meteo takes comma-joined coordinate lists and answers with one
    /// forecast per point, which is exactly the shape of a downwind route:
    /// launch, middle, takeout. One reading at the midpoint can call a run
    /// fair while the takeout sits in a headland's shadow — the whole point
    /// of asking three times is catching the route's disagreements with
    /// itself.
    static func windAlong(_ coordinates: [Geo.Coordinate],
                          hours: Int = 4) async -> [[WindForecastHour]] {
        guard !coordinates.isEmpty else { return [] }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude",
                  value: coordinates.map { String(format: "%.4f", $0.latitude) }.joined(separator: ",")),
            .init(name: "longitude",
                  value: coordinates.map { String(format: "%.4f", $0.longitude) }.joined(separator: ",")),
            .init(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "forecast_hours", value: String(hours)),
            .init(name: "timeformat", value: "unixtime"),
        ]
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 1800),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        // One point answers as an object, several as an array — normalise.
        let points = (root as? [[String: Any]]) ?? (root as? [String: Any]).map { [$0] } ?? []
        return points.map { point -> [WindForecastHour] in
            guard let hourly = point["hourly"] as? [String: Any],
                  let times = hourly["time"] as? [Double],
                  let speeds = (hourly["wind_speed_10m"] as? [Any])?.map({ $0 as? Double }),
                  let directions = (hourly["wind_direction_10m"] as? [Any])?.map({ $0 as? Double })
            else { return [] }
            let gusts = (hourly["wind_gusts_10m"] as? [Any])?.map { $0 as? Double }
            return times.indices.compactMap { hour in
                guard let speed = speeds[safe: hour] ?? nil,
                      let direction = directions[safe: hour] ?? nil
                else { return nil }
                return WindForecastHour(
                    date: Date(timeIntervalSince1970: times[hour]),
                    speedKn: speed,
                    gustKn: gusts?[safe: hour] ?? nil,
                    directionDeg: direction
                )
            }
        }
    }

    /// Every model's recent record near a point — verified against a buoy
    /// when one is close enough to speak for the water, self-consistency
    /// otherwise. See `ModelSteadiness` for what each flavour means.
    static func modelRecord(near coordinate: Geo.Coordinate) async -> ModelSteadiness {
        // Thirty kilometres, because past that a buoy's wind is a different
        // piece of weather, and a "verified" badge on the wrong water would
        // be worse than the humbler measure.
        if let buoy = await DataBuoyCenter.buoys(near: coordinate, limit: 1,
                                                radius: 30_000).first {
            let observations = await DataBuoyCenter.windHistory(for: buoy.id)
            // Two weeks of mostly-hourly readings; much less and the score
            // is an anecdote.
            if observations.count >= 150 {
                var verified = await steadiness(at: buoy.coordinate, against: observations)
                if !verified.isEmpty {
                    verified.verifiedAgainst = (buoy.name, buoy.metres)
                    return verified
                }
            }
        }
        return await steadiness(at: coordinate, against: nil)
    }

    /// Two weeks of every model's forecasts at one point, scored.
    ///
    /// The previous-runs endpoint serves, for any past hour, what each model
    /// said one to three days beforehand alongside its final call. With
    /// `reference` observations the score is each forecast's gap from what
    /// an anemometer then measured; without, its gap from the model's own
    /// final call. Cached six hours: the past does not move quickly.
    private static func steadiness(
        at coordinate: Geo.Coordinate,
        against reference: [(at: Date, windKn: Double)]?
    ) async -> ModelSteadiness {
        let leads = [0, 1, 2, 3]
        let independents = models.filter { !$0.isComposite }
        var components = URLComponents(string: "https://previous-runs-api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: leads.map { "wind_speed_10m_previous_day\($0)" }
                .joined(separator: ",")),
            .init(name: "models", value: independents.map(\.id).joined(separator: ",")),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "past_days", value: "14"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 21_600),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Double]
        else { return ModelSteadiness(rows: []) }

        // Only hours that have actually happened: the request's tail is
        // still forecast, where neither reference means anything yet.
        let now = Date().timeIntervalSince1970
        func series(_ lead: Int, _ model: String) -> [Double?] {
            (hourly["wind_speed_10m_previous_day\(lead)_\(model)"] as? [Any])?
                .map { $0 as? Double } ?? []
        }
        // Observations bucketed to the nearest hour mark, averaged when a
        // station reports more often — NDBC's standard rows land at :50,
        // which rounds to the hour they were nearly measuring.
        let observed: [Int: Double]? = reference.map { readings in
            var buckets: [Int: (total: Double, count: Int)] = [:]
            for reading in readings {
                let hour = Int((reading.at.timeIntervalSince1970 / 3600).rounded())
                let sum = buckets[hour] ?? (0, 0)
                buckets[hour] = (sum.total + reading.windKn, sum.count + 1)
            }
            return buckets.mapValues { $0.total / Double($0.count) }
        }

        let scoredLeads = observed == nil ? Array(leads.dropFirst()) : leads
        let rows = independents.compactMap { model -> ModelSteadiness.Row? in
            let final = series(0, model.id)
            guard final.contains(where: { $0 != nil }) else { return nil }
            var revisions: [Int: Double] = [:]
            for lead in scoredLeads {
                let forecast = lead == 0 ? final : series(lead, model.id)
                let gaps = times.indices.compactMap { hour -> Double? in
                    guard times[hour] <= now,
                          let was = forecast[safe: hour] ?? nil
                    else { return nil }
                    if let observed {
                        guard let truth = observed[Int((times[hour] / 3600).rounded())]
                        else { return nil }
                        return abs(was - truth)
                    }
                    guard let became = final[safe: hour] ?? nil else { return nil }
                    return abs(was - became)
                }
                // A couple of days of overlap is noise, not a record.
                if gaps.count >= 48 {
                    revisions[lead] = gaps.reduce(0, +) / Double(gaps.count)
                }
            }
            guard !revisions.isEmpty else { return nil }
            return ModelSteadiness.Row(id: model.id, label: model.label, revisionKn: revisions)
        }
        return ModelSteadiness(rows: rows)
    }

    /// GEFS, thirty-one times over — see `EnsembleOutlook`.
    ///
    /// A separate endpoint and a separate call because it is a different
    /// question: the outlook asks four agencies for their best guess, this
    /// asks one agency how sure it is. Seven days, since ensemble spread at
    /// day ten is an honest shrug not worth the bytes.
    static func ensemble(at coordinate: Geo.Coordinate, days: Int = 7) async -> EnsembleOutlook {
        var components = URLComponents(string: "https://ensemble-api.open-meteo.com/v1/ensemble")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "wind_speed_10m"),
            .init(name: "models", value: "ncep_gefs025"),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "forecast_days", value: String(days)),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 3600),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Double]
        else { return EnsembleOutlook(hours: [], members: []) }

        // The control run arrives on the bare key, the perturbed members on
        // `_memberNN` suffixes. All of them are equally valid opinions.
        let members = hourly.keys
            .filter { $0.hasPrefix("wind_speed_10m") }
            .sorted()
            .compactMap { key -> [Double?]? in
                let row = (hourly[key] as? [Any])?.map { $0 as? Double }
                return row?.contains(where: { $0 != nil }) == true ? row : nil
            }
        return EnsembleOutlook(
            hours: times.map { Date(timeIntervalSince1970: $0) },
            members: members,
            timeZone: (root["timezone"] as? String).flatMap(TimeZone.init(identifier:))
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
              let data = await ForecastCache.data(from: url, ttl: 3600)
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

    // MARK: - Looking a day up after the fact

    /// What the models say a past session's hours were doing.
    ///
    /// Any of it can be missing on its own: the marine grid has no cell for
    /// a river, the archive has not caught up to yesterday. What arrived is
    /// offered; what did not stays silent.
    struct Historical {
        var windDirectionFrom: Double?
        var windSpeedKn: Double?
        var windGustKn: Double?
        var swellMetres: Double?
        var swellDirectionFrom: Double?
        /// The hour-by-hour record the averages were taken from, worth
        /// keeping on the session rather than dying in a label here.
        var windTimeline: WindTimeline?

        var isEmpty: Bool { windDirectionFrom == nil && swellMetres == nil }
    }

    /// Wind and swell for a session that already happened, averaged over the
    /// hours it spanned.
    static func historical(at coordinate: Geo.Coordinate,
                           during window: DateInterval) async -> Historical {
        async let wind = historicalWind(at: coordinate, during: window)
        async let sea = historicalSwell(at: coordinate, during: window)
        let (w, s) = await (wind, sea)
        return Historical(windDirectionFrom: w?.directionFrom,
                          windSpeedKn: (w?.speed).map { $0 * 1.94384 },
                          windGustKn: (w?.gust).map { $0 * 1.94384 },
                          swellMetres: s?.metres, swellDirectionFrom: s?.direction,
                          windTimeline: w?.timeline)
    }

    private static func historicalWind(
        at coordinate: Geo.Coordinate, during window: DateInterval
    ) async -> (directionFrom: Double, speed: Double?, gust: Double?, timeline: WindTimeline)? {
        // Two endpoints hold the past and neither holds all of it: the
        // archive runs about five days behind the present, and the forecast
        // endpoint keeps a rolling window whose depth is its own business —
        // nominally ninety days, observed shallower. Not a date-arithmetic
        // problem: ask the likelier one first, and when it answers 200 with
        // a grid of nulls, ask the other.
        let recent = window.start.timeIntervalSinceNow > -30 * 86_400
        let endpoints = [
            "https://api.open-meteo.com/v1/forecast",
            "https://archive-api.open-meteo.com/v1/archive",
        ]
        for endpoint in recent ? endpoints : endpoints.reversed() {
            if let found = await wind(from: endpoint, at: coordinate, during: window) {
                return found
            }
        }
        return nil
    }

    private static func wind(
        from endpoint: String, at coordinate: Geo.Coordinate, during window: DateInterval
    ) async -> (directionFrom: Double, speed: Double?, gust: Double?, timeline: WindTimeline)? {
        var components = URLComponents(string: endpoint)!
        let (from, to) = utcDays(of: window)
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "wind_speed_10m,wind_direction_10m,wind_gusts_10m"),
            .init(name: "start_date", value: from),
            .init(name: "end_date", value: to),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "UTC"),
        ]

        struct Payload: Decodable {
            struct Hourly: Decodable {
                let time: [Double]
                let wind_speed_10m: [Double?]?
                let wind_direction_10m: [Double?]?
                let wind_gusts_10m: [Double?]?
            }
            let hourly: Hourly?
        }
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 21_600),
              let hourly = (try? JSONDecoder().decode(Payload.self, from: data))?.hourly
        else { return nil }

        // The archive speaks km/h by default; the timeline is m/s like
        // everything else in core, and knots happen at the display edge.
        let kmh = 1.0 / 3.6
        let samples = hours(in: hourly.time, of: window).compactMap { index -> WindTimeline.Sample? in
            guard let speed = hourly.wind_speed_10m?[safe: index] ?? nil,
                  let direction = hourly.wind_direction_10m?[safe: index] ?? nil
            else { return nil }
            return WindTimeline.Sample(
                time: Date(timeIntervalSince1970: hourly.time[index]),
                speed: speed * kmh,
                directionFrom: direction,
                gust: (hourly.wind_gusts_10m?[safe: index] ?? nil).map { $0 * kmh }
            )
        }
        let timeline = WindTimeline(samples: samples)

        // Direction off the mean vector, so the strong hours out-vote the
        // light ones about which way the day blew — the old unweighted
        // circular mean let a 2 kn zephyr count as hard as a 20 kn breeze.
        guard let averaged = timeline.averaged(over: window) else { return nil }
        return (averaged.directionFrom, averaged.speed, averaged.gust, timeline)
    }

    private static func historicalSwell(
        at coordinate: Geo.Coordinate, during window: DateInterval
    ) async -> (metres: Double, direction: Double?)? {
        var components = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        let (from, to) = utcDays(of: window)
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "swell_wave_height,swell_wave_direction,wave_height,wave_direction"),
            .init(name: "start_date", value: from),
            .init(name: "end_date", value: to),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "UTC"),
        ]

        struct Payload: Decodable {
            struct Hourly: Decodable {
                let time: [Double]
                let swell_wave_height: [Double?]?
                let swell_wave_direction: [Double?]?
                let wave_height: [Double?]?
                let wave_direction: [Double?]?
            }
            let hourly: Hourly?
        }
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 21_600),
              let hourly = (try? JSONDecoder().decode(Payload.self, from: data))?.hourly
        else { return nil }

        let picked = hours(in: hourly.time, of: window)
        // Swell proper first; total wave height only when the swell series is
        // a wind-chop-only blank, which close to shore it often is.
        var heights = picked.compactMap { hourly.swell_wave_height?[safe: $0] ?? nil }
        var directions = picked.compactMap { hourly.swell_wave_direction?[safe: $0] ?? nil }
        if heights.isEmpty {
            heights = picked.compactMap { hourly.wave_height?[safe: $0] ?? nil }
            directions = picked.compactMap { hourly.wave_direction?[safe: $0] ?? nil }
        }
        guard !heights.isEmpty else { return nil }
        return (heights.reduce(0, +) / Double(heights.count), circularMean(of: directions))
    }

    /// Indices of the hours inside the window, padded so a forty-minute
    /// session still catches the hour it sat in.
    private static func hours(in times: [Double], of window: DateInterval) -> [Int] {
        let from = window.start.timeIntervalSince1970 - 2_700
        let to = window.end.timeIntervalSince1970 + 2_700
        return times.indices.filter { times[$0] >= from && times[$0] <= to }
    }

    /// Mean of bearings the short way round — 350° and 10° average to 0°,
    /// not 180°.
    private static func circularMean(of degrees: [Double]) -> Double? {
        guard !degrees.isEmpty else { return nil }
        var x = 0.0, y = 0.0
        for d in degrees {
            x += sin(d * .pi / 180)
            y += cos(d * .pi / 180)
        }
        guard x != 0 || y != 0 else { return nil }
        return Geo.normalizeDegrees(atan2(x, y) * 180 / .pi)
    }

    private static func utcDays(of window: DateInterval) -> (String, String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return (formatter.string(from: window.start), formatter.string(from: window.end))
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
        // Predictions, not readings — the tide table was computed from the
        // moon, and caching it wrongs nobody.
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 21_600)
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
    /// Where it is moored. Kept rather than discarded after the distance
    /// sort, so a rider can be shown which piece of water it speaks for —
    /// "12 km away" says nothing about whether it is outside the bar or
    /// inside the bay, and those are different oceans.
    var coordinate: Geo.Coordinate
    var reading: BuoyReading?

    var url: URL {
        URL(string: "https://www.ndbc.noaa.gov/station_page.php?station=\(id)")!
    }
}

struct BuoyReading: Hashable {
    let waveHeightM: Double?
    let dominantPeriodS: Double?
    /// Mean wave direction, degrees the waves are coming *from*.
    ///
    /// The column a height leaves out. Two metres from the south-east and two
    /// metres from the south-west are different days at the same beach, and
    /// this is the one place on the screen where that is measured rather than
    /// modelled.
    var meanDirectionDeg: Double?
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
            .map { Buoy(id: $0.station.id, name: $0.station.name,
                        metres: $0.metres, coordinate: $0.station.coordinate) }
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
            meanDirectionDeg: value(11),
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

    /// Every wind reading in the station's realtime file — about 45 days,
    /// newest first, mostly hourly.
    ///
    /// The same file `latest` reads the first row of; the rest of it is the
    /// spot's recent truth, and it is what turns "the models have been
    /// steady here" into "the models have been *right* here". Goes through
    /// the forecast cache despite being observations — the exception that
    /// proves that rule, because nothing here is presented as a current
    /// reading: this feeds a two-week score, where an hour of staleness
    /// changes nothing and a 300 KB re-download per screen would.
    static func windHistory(for stationId: String) async -> [(at: Date, windKn: Double)] {
        guard let url = URL(string: "https://www.ndbc.noaa.gov/data/realtime2/\(stationId.uppercased()).txt"),
              let data = await ForecastCache.data(from: url, ttl: 3600),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        return text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { row -> (at: Date, windKn: Double)? in
                let columns = row.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard columns.count >= 7 else { return nil }
                func value(_ index: Int) -> Double? {
                    guard let raw = columns[safe: index], raw != "MM" else { return nil }
                    return Double(raw)
                }
                // YY MM DD hh mm WDIR WSPD — same columns as `latest`.
                guard let speed = value(6) else { return nil }
                var stamp = DateComponents()
                stamp.year = value(0).map(Int.init)
                stamp.month = value(1).map(Int.init)
                stamp.day = value(2).map(Int.init)
                stamp.hour = value(3).map(Int.init)
                stamp.minute = value(4).map(Int.init)
                guard let at = utc.date(from: stamp) else { return nil }
                return (at, speed * 3600 / 1852)
            }
    }
}

// MARK: - Surf

/// What the sea is doing, split the way surfers split it.
///
/// "Waves" is two different things stacked on top of each other: swell, which
/// travelled here from a storm days ago and arrives with long periods and
/// clean lines, and wind wave, which is being made right now by the wind on
/// your face and is just chop. A single significant-height number adds them
/// together and tells you neither. The free marine model separates them, and
/// carries a second swell train besides — which is exactly the breakdown the
/// surf apps show, because it is the one that decides whether it is worth
/// paddling out.
struct SurfConditions {

    struct Train {
        let heightM: Double
        let periodS: Double?
        let directionDeg: Double?

        var heightFt: Double { heightM * 3.28084 }
    }

    let at: Date
    /// Combined sea: swell and wind wave together, which is the number that
    /// matches "surf height" on a report.
    let waveHeightM: Double?
    let wavePeriodS: Double?
    let waveDirectionDeg: Double?

    let primarySwell: Train?
    let secondarySwell: Train?
    let windWave: Train?

    let seaTemperatureC: Double?
    /// Set and drift. The one thing here that also matters to the analysis:
    /// a knot of current is the difference between speed over ground and
    /// speed through water.
    let currentKn: Double?
    let currentDirectionDeg: Double?

    var hasAnything: Bool { waveHeightM != nil || primarySwell != nil }

    /// Surf height as a range, the way every report states it — a single
    /// number implies a precision the ocean does not have.
    var surfRangeFt: (low: Int, high: Int)? {
        guard let waveHeightM else { return nil }
        let feet = waveHeightM * 3.28084
        let low = max(0, Int((feet * 0.8).rounded(.down)))
        return (low, max(low + 1, Int((feet * 1.25).rounded(.up))))
    }

    /// The body-part scale, which is how surfers actually talk about size.
    var sizeDescription: String? {
        guard let range = surfRangeFt else { return nil }
        return switch range.high {
        case ...1: "Ankle to knee"
        case 2: "Knee to thigh"
        case 3: "Thigh to waist"
        case 4: "Waist to chest"
        case 5, 6: "Chest to head"
        case 7, 8: "Head to overhead"
        case 9...12: "Well overhead"
        default: "Double overhead and up"
        }
    }

    /// What to wear. A judgement, and stated as one — thresholds vary by
    /// person by a good few degrees, and nobody should take this over their
    /// own experience of being cold.
    var wetsuit: String? {
        guard let seaTemperatureC else { return nil }
        return switch seaTemperatureC {
        case 24...: "Boardshorts weather"
        case 21..<24: "Shorty or 2 mm"
        case 18..<21: "2 mm full"
        case 15..<18: "3/2 mm"
        case 12..<15: "4/3 mm, maybe boots"
        case 9..<12: "5/4 mm, boots and hood"
        default: "5/4 hooded, boots and gloves"
        }
    }
}

extension OpenMeteo {

    /// One call for the sea state, including the swell breakdown.
    static func surf(at coordinate: Geo.Coordinate) async -> SurfConditions? {
        var components = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "current", value: "wave_height,wave_direction,wave_period,wind_wave_height,wind_wave_direction,wind_wave_period,swell_wave_height,swell_wave_direction,swell_wave_period,secondary_swell_wave_height,secondary_swell_wave_direction,secondary_swell_wave_period,sea_surface_temperature,ocean_current_velocity,ocean_current_direction"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 1800),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any]
        else { return nil }

        func number(_ key: String) -> Double? { current[key] as? Double }

        func train(_ prefix: String) -> SurfConditions.Train? {
            guard let height = number("\(prefix)height"), height > 0.01 else { return nil }
            return SurfConditions.Train(heightM: height,
                                        periodS: number("\(prefix)period"),
                                        directionDeg: number("\(prefix)direction"))
        }

        let conditions = SurfConditions(
            at: (current["time"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date(),
            waveHeightM: number("wave_height"),
            wavePeriodS: number("wave_period"),
            waveDirectionDeg: number("wave_direction"),
            primarySwell: train("swell_wave_"),
            secondarySwell: train("secondary_swell_wave_"),
            windWave: train("wind_wave_"),
            seaTemperatureC: number("sea_surface_temperature"),
            // Reported in km/h; knots is what the rest of the app speaks.
            currentKn: number("ocean_current_velocity").map { $0 / 1.852 },
            currentDirectionDeg: number("ocean_current_direction")
        )
        // Inland points answer with a full set of nulls rather than an error.
        return conditions.hasAnything ? conditions : nil
    }
}

// MARK: - Tide

/// The tide curve at a point, and the turns derived from it.
///
/// NOAA's predictions are the authority where they exist, and they exist only
/// in the United States. Open-Meteo's marine model carries sea level
/// worldwide, which is a model rather than a harmonic prediction and is
/// therefore worse — and available at every spot in the guide, which makes it
/// the right thing to draw. The NOAA stations stay listed underneath for
/// anyone who wants the real numbers.
struct TideCurve {

    struct Point: Identifiable {
        let at: Date
        let metres: Double
        var id: Date { at }
    }

    struct Turn: Identifiable {
        let at: Date
        let metres: Double
        let isHigh: Bool
        var id: Date { at }
    }

    let points: [Point]
    var timeZone: TimeZone?

    var isEmpty: Bool { points.count < 3 }

    var low: Double { points.map(\.metres).min() ?? 0 }
    var high: Double { points.map(\.metres).max() ?? 1 }

    /// Where the water is now, interpolated between the surrounding hours.
    var now: Point? {
        let moment = Date()
        guard let after = points.firstIndex(where: { $0.at >= moment }) else { return points.last }
        guard after > 0 else { return points.first }
        let a = points[after - 1], b = points[after]
        let span = b.at.timeIntervalSince(a.at)
        guard span > 0 else { return a }
        let fraction = moment.timeIntervalSince(a.at) / span
        return Point(at: moment, metres: a.metres + (b.metres - a.metres) * fraction)
    }

    /// Rising or falling, which is the half of "1.1 m" that actually matters
    /// — a metre on the way up is a different beach from a metre on the way
    /// down, and it decides whether the sandbar is about to appear or go.
    var isRising: Bool? {
        let moment = Date()
        guard let after = points.firstIndex(where: { $0.at >= moment }), after > 0 else { return nil }
        return points[after].metres > points[after - 1].metres
    }

    /// Highs and lows, read off the curve as sign changes in the slope.
    ///
    /// Derived rather than fetched because the curve is global and the
    /// harmonic tables are not — and an hourly series resolves a turn to
    /// within about half an hour, which is the precision anybody plans to.
    var turns: [Turn] {
        guard points.count > 2 else { return [] }
        var found: [Turn] = []
        for index in 1..<(points.count - 1) {
            let before = points[index - 1].metres
            let here = points[index].metres
            let after = points[index + 1].metres
            if here >= before, here >= after, here > before || here > after {
                found.append(Turn(at: points[index].at, metres: here, isHigh: true))
            } else if here <= before, here <= after, here < before || here < after {
                found.append(Turn(at: points[index].at, metres: here, isHigh: false))
            }
        }
        return found
    }

    var nextTurn: Turn? { turns.first { $0.at > Date() } }
}

extension OpenMeteo {

    /// Two days of sea level, hourly. Global.
    static func tide(at coordinate: Geo.Coordinate) async -> TideCurve {
        var components = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "sea_level_height_msl"),
            // Three, not two. The API returns whole local days, so two of
            // them leaves only the rest of today plus tomorrow — measured at
            // 24 hours ahead, which is not enough to plan around a tide for
            // a session the day after next. Three guarantees at least 48.
            .init(name: "forecast_days", value: "3"),
            .init(name: "past_days", value: "1"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 21_600),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Double],
              let heights = hourly["sea_level_height_msl"] as? [Any]
        else { return TideCurve(points: []) }

        let points = times.indices.compactMap { index -> TideCurve.Point? in
            guard let metres = heights[safe: index] as? Double else { return nil }
            return TideCurve.Point(at: Date(timeIntervalSince1970: times[index]), metres: metres)
        }
        return TideCurve(
            points: points,
            timeZone: (root["timezone"] as? String).flatMap(TimeZone.init(identifier:))
        )
    }
}

// MARK: - Multi-day surf

/// The swell, day by day, in the parts of the day a rider plans around.
///
/// A single "wave height" is the least useful way to describe surf. What
/// decides a session is the combination — how big, how long the period, which
/// way it is coming from, and what the wind is doing to it — and how that
/// combination changes across a day. Hence bands rather than hours: nobody
/// plans a dawn patrol to the hour, and twenty-four rows a day is a table
/// nobody reads.
struct SurfOutlook {

    struct Band: Identifiable {
        let start: Date
        let label: String
        let primary: SurfConditions.Train?
        let secondary: SurfConditions.Train?
        let windKn: Double?
        let windFromDeg: Double?

        var id: Date { start }

        /// Wind relative to the swell it is blowing across.
        ///
        /// The single most important thing about a forecast day and the one
        /// a height alone cannot tell you: the same four feet is clean at
        /// dawn and unrideable by noon. Nil when either is unknown, because a
        /// guess here would be worse than a blank.
        var windEffect: WindEffect? {
            guard let windFromDeg, let swellFrom = primary?.directionDeg,
                  let windKn, windKn > 3
            else { return nil }
            let raw = abs((windFromDeg - swellFrom).truncatingRemainder(dividingBy: 360))
            let between = raw > 180 ? 360 - raw : raw
            // Wind from the same quarter as the swell is behind it, blowing
            // onshore with it. Opposite is offshore, holding the face up.
            switch between {
            case ..<60: return .onshore
            case ..<120: return .crossShore
            default: return .offshore
            }
        }
    }

    enum WindEffect: String {
        case offshore = "offshore"
        case crossShore = "cross-shore"
        case onshore = "onshore"

        /// Green is not "good surf", it is "the wind is not spoiling it".
        var isFavourable: Bool { self == .offshore }
    }

    struct Day: Identifiable {
        let date: Date
        let bands: [Band]
        var id: Date { date }

        var biggest: Double? { bands.compactMap { $0.primary?.heightM }.max() }
        var longestPeriod: Double? { bands.compactMap { $0.primary?.periodS }.max() }
    }

    var days: [Day] = []
    var timeZone: TimeZone?

    /// The hourly series behind the bands.
    ///
    /// Bands answer "when should I go"; the hours answer "what is it doing" —
    /// a swell filling in over six hours is a shape, and four rows a day
    /// cannot draw it. Kept alongside rather than instead, because the two
    /// screens want different things from the same fetch.
    var hours: [Date] = []
    var swellM: [Double?] = []
    var periodS: [Double?] = []
    var swellFromDeg: [Double?] = []
    var windKn: [Double?] = []
    var windFromDeg: [Double?] = []
    var tideM: [Double?] = []

    /// The hour nearest now, for the marker every surf chart carries.
    var nowIndex: Int? {
        let moment = Date()
        return hours.indices.min {
            abs(hours[$0].timeIntervalSince(moment)) < abs(hours[$1].timeIntervalSince(moment))
        }
    }

    /// Whether the wave model covers this water at all.
    ///
    /// Inland, the marine API answers with a full set of hours and a null in
    /// every column — so the days exist and every band is empty. Rendered
    /// naively that is five days of confident "flat" for a lake, which is a
    /// forecast rather than an absence. Flat is a real answer at a real
    /// coast; no model is a different thing and should say so.
    var hasModel = false

    var isEmpty: Bool { days.isEmpty || !hasModel }

}

extension OpenMeteo {

    /// Swell and wind, hourly, for the next several days.
    ///
    /// Two calls because they are two APIs — the wave model and the weather
    /// model — and the wind matters as much as the swell for deciding whether
    /// to go. Run together so the wait is one call long, not two.
    static func surfOutlook(at coordinate: Geo.Coordinate, days: Int = 5) async -> SurfOutlook {
        async let marine = hourlyMarine(at: coordinate, days: days)
        async let wind = hourlyWind(at: coordinate, days: days)
        let (sea, air) = await (marine, wind)

        guard !sea.times.isEmpty else { return SurfOutlook() }

        var calendar = Calendar.current
        if let zone = sea.zone { calendar.timeZone = zone }

        // Four bands a day, named the way somebody talks about going out.
        let bands: [(name: String, hours: Range<Int>)] = [
            ("Dawn", 5..<9), ("Morning", 9..<12),
            ("Afternoon", 12..<17), ("Evening", 17..<21),
        ]

        let grouped = Dictionary(grouping: sea.times.indices) {
            calendar.startOfDay(for: sea.times[$0])
        }

        var out: [SurfOutlook.Day] = []
        for day in grouped.keys.sorted() {
            guard let indices = grouped[day] else { continue }
            var built: [SurfOutlook.Band] = []

            for band in bands {
                let inBand = indices.filter {
                    band.hours.contains(calendar.component(.hour, from: sea.times[$0]))
                }
                guard let middle = inBand[safe: inBand.count / 2] else { continue }

                built.append(SurfOutlook.Band(
                    start: sea.times[middle],
                    label: band.name,
                    primary: sea.train(at: middle, prefix: "swell_wave_"),
                    secondary: sea.train(at: middle, prefix: "secondary_swell_wave_"),
                    windKn: air.speeds[safe: air.index(of: sea.times[middle])] ?? nil,
                    windFromDeg: air.directions[safe: air.index(of: sea.times[middle])] ?? nil
                ))
            }
            if !built.isEmpty {
                out.append(SurfOutlook.Day(date: day, bands: built))
            }
        }
        let covered = sea.columns["swell_wave_height"]?.contains { $0 != nil } ?? false

        // The wind series resampled onto the wave model's hours, so the two
        // can be drawn against one axis. They agree in practice; matching by
        // time rather than by index keeps that from being an assumption.
        let windSpeeds = sea.times.map { air.speeds[safe: air.index(of: $0)] ?? nil }
        let windAngles = sea.times.map { air.directions[safe: air.index(of: $0)] ?? nil }

        return SurfOutlook(
            days: out, timeZone: sea.zone,
            hours: sea.times,
            swellM: sea.columns["swell_wave_height"] ?? [],
            periodS: sea.columns["swell_wave_period"] ?? [],
            swellFromDeg: sea.columns["swell_wave_direction"] ?? [],
            windKn: windSpeeds,
            windFromDeg: windAngles,
            tideM: sea.columns["sea_level_height_msl"] ?? [],
            hasModel: covered
        )
    }

    /// The wave model's hourly fields, kept as raw columns so a band can pull
    /// any train out of them by name.
    private struct HourlyMarine {
        var times: [Date] = []
        var zone: TimeZone?
        var columns: [String: [Double?]] = [:]

        func train(at index: Int, prefix: String) -> SurfConditions.Train? {
            guard let height = columns["\(prefix)height"]?[safe: index] ?? nil,
                  height > 0.05 else { return nil }
            return SurfConditions.Train(
                heightM: height,
                periodS: columns["\(prefix)period"]?[safe: index] ?? nil,
                directionDeg: columns["\(prefix)direction"]?[safe: index] ?? nil
            )
        }
    }

    private struct HourlyWind {
        var times: [Date] = []
        var speeds: [Double?] = []
        var directions: [Double?] = []

        func index(of date: Date) -> Int {
            times.firstIndex { abs($0.timeIntervalSince(date)) < 1800 } ?? -1
        }
    }

    private static func hourlyMarine(at coordinate: Geo.Coordinate,
                                     days: Int) async -> HourlyMarine {
        // Tide rides along on the same call: it is the same API and the same
        // hours, so asking for it here means one fetch and one axis instead
        // of two series that have to be aligned afterwards.
        let fields = ["swell_wave_height", "swell_wave_period", "swell_wave_direction",
                      "secondary_swell_wave_height", "secondary_swell_wave_period",
                      "secondary_swell_wave_direction", "wave_height",
                      "sea_level_height_msl"]
        var components = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: fields.joined(separator: ",")),
            .init(name: "forecast_days", value: String(days)),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 10_800),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let stamps = hourly["time"] as? [Double]
        else { return HourlyMarine() }

        var out = HourlyMarine()
        out.times = stamps.map { Date(timeIntervalSince1970: $0) }
        if let identifier = root["timezone"] as? String {
            out.zone = TimeZone(identifier: identifier)
        }
        for field in fields {
            out.columns[field] = (hourly[field] as? [Any])?.map { $0 as? Double }
        }
        return out
    }

    private static func hourlyWind(at coordinate: Geo.Coordinate,
                                   days: Int) async -> HourlyWind {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "wind_speed_10m,wind_direction_10m"),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "forecast_days", value: String(days)),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 10_800),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let stamps = hourly["time"] as? [Double]
        else { return HourlyWind() }

        var out = HourlyWind()
        out.times = stamps.map { Date(timeIntervalSince1970: $0) }
        out.speeds = (hourly["wind_speed_10m"] as? [Any])?.map { $0 as? Double } ?? []
        out.directions = (hourly["wind_direction_10m"] as? [Any])?.map { $0 as? Double } ?? []
        return out
    }
}
