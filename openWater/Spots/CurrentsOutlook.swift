import Foundation
import OpenWaterCore
import SwiftUI

// MARK: - Currents

/// The water's own motion at a point: how fast it runs, which way it sets,
/// and when it turns.
///
/// One convention, stated here because it is the single place the app's wind
/// habit becomes a bug: **currents point TOWARD** — the set, the direction the
/// water carries you — where wind is stated FROM. Open-Meteo's
/// `ocean_current_direction` and NOAA's `meanFloodDir`/`meanEbbDir` both speak
/// "toward", so arrows drawn from this type rotate as-is. No +180.
struct CurrentsOutlook {

    struct Hour: Identifiable {
        let at: Date
        /// Magnitude in knots; nil where the source has no answer this hour.
        let speedKn: Double?
        /// Set — degrees true, toward.
        let directionDeg: Double?
        var id: Date { at }
    }

    /// A turn of the water: the peaks and the pauses. Station predictions
    /// name these outright; the model curve never carries them.
    struct Event: Identifiable {
        enum Kind { case maxFlood, maxEbb, slack }
        let at: Date
        let kind: Kind
        /// Peak speed in knots, magnitude. Slack has none worth printing.
        let speedKn: Double?
        var id: Date { at }
    }

    /// Which authority produced these numbers. The two are never mixed:
    /// a station inside `Currents.stationRadius` replaces the model
    /// wholesale, exactly as NOAA tide predictions replace the modelled
    /// sea-level curve — different physics, different datums, one owner
    /// per screen.
    enum Source {
        /// Open-Meteo's ocean model. Worldwide, hourly, and a model —
        /// every rendering of it says so (CC-BY 4.0 attribution required).
        case model
        /// NOAA CO-OPS harmonic predictions at a named station. Predicted
        /// from harmonics, not measured — still not an observation.
        case station(CurrentStation)
    }

    var hours: [Hour]
    /// Station sources only. A subordinate station publishes *only* these —
    /// its `hours` stay empty rather than being faked from four events.
    var events: [Event] = []
    let source: Source
    var timeZone: TimeZone?
    /// The offline-fallback age, seconds, when that is what this is.
    var staleAge: TimeInterval?

    /// No usable answer at all — distinct from a failed fetch upstream:
    /// an inland point gets a well-formed reply whose every value is null,
    /// and the tab should say "no marine cell here", not "network error".
    var isEmpty: Bool {
        !hours.contains { $0.speedKn != nil } && events.isEmpty
    }

    /// The water right now, interpolated between the surrounding hours.
    /// Directions cross the flood/ebb flip between two hours, so the nearer
    /// hour's set is used whole rather than averaging 50° with 230° into a
    /// direction the water never ran.
    var now: Hour? {
        let moment = Date()
        guard let after = hours.firstIndex(where: { $0.at >= moment }) else { return hours.last }
        guard after > 0 else { return hours.first }
        let a = hours[after - 1], b = hours[after]
        guard let av = a.speedKn, let bv = b.speedKn else { return a.speedKn != nil ? a : b }
        let span = b.at.timeIntervalSince(a.at)
        guard span > 0 else { return a }
        let fraction = moment.timeIntervalSince(a.at) / span
        return Hour(at: moment,
                    speedKn: av + (bv - av) * fraction,
                    directionDeg: fraction < 0.5 ? a.directionDeg : b.directionDeg)
    }

    var nextEvent: Event? { events.first { $0.at > Date() } }

    /// The station's top-of-hour rows laid onto another axis — the flow
    /// screen's scrubber walks the field's hour slots, and the station's
    /// rows land in them by timestamp. A slot the station does not speak
    /// for stays nil rather than borrowing the model's: wholesale, never
    /// mixed, down to the single slot.
    static func aligned(_ hours: [Hour], to axis: [Date]) -> [Hour] {
        let byTime = Dictionary(hours.map { ($0.at, $0) }) { first, _ in first }
        return axis.map { byTime[$0] ?? Hour(at: $0, speedKn: nil, directionDeg: nil) }
    }
}

/// A NOAA current-prediction station, at its shallowest published bin.
///
/// Many stations predict at several depths; the shallowest bin is the water
/// a rider's board sits in, so that is the one the index keeps.
struct CurrentStation: Identifiable, Hashable {
    let id: String
    /// The depth bin the predictions are for — passed to the API separately,
    /// shown to nobody.
    let bin: Int
    let name: String
    let metres: Double
    /// Where it stands — kept for the map, because "8 km away" does not say
    /// which side of the channel, and an ebb runs differently across one.
    let coordinate: Geo.Coordinate
    /// Harmonic stations publish a real hourly series; subordinate stations
    /// publish only the turns (max flood, max ebb, slack), whatever interval
    /// is asked for.
    let isHarmonic: Bool

    var url: URL {
        URL(string: "https://tidesandcurrents.noaa.gov/noaacurrents/predictions?id=\(id)_\(bin)")!
    }
}

/// The currents chart's colours — the reference apps' shared grammar,
/// which riders already read: the water's pauses in cool pales and blues,
/// its runs warming through yellow and amber to orange as it picks up.
/// Half a knot matters here the way three knots matter for wind, so the
/// bands sit close together at the bottom of the scale.
nonisolated enum CurrentPalette {
    static func color(for kn: Double) -> Color {
        switch kn {
        case ..<0.2: Color(red: 0.80, green: 0.86, blue: 0.92)
        case ..<0.5: Color(red: 0.55, green: 0.73, blue: 0.88)
        case ..<0.8: Color(red: 0.49, green: 0.78, blue: 0.76)
        case ..<1.2: Color(red: 0.95, green: 0.83, blue: 0.40)
        case ..<1.6: Color(red: 0.96, green: 0.68, blue: 0.28)
        case ..<2.2: Color(red: 0.95, green: 0.52, blue: 0.20)
        default: Color(red: 0.90, green: 0.33, blue: 0.16)
        }
    }

    /// The flow map's wash wears blue, the reference marine maps' own
    /// habit — slack water near white so the chart shows through, the
    /// stream deepening toward indigo — while the bars keep the warm ramp.
    /// Two palettes for one quantity on one screen is deliberate: it is
    /// exactly how the reference draws it, and the arrows carry the read
    /// between them.
    static func washColour(for kn: Double) -> UIColor {
        switch kn {
        case ..<0.1: UIColor(red: 0.97, green: 0.98, blue: 1.00, alpha: 1)
        case ..<0.3: UIColor(red: 0.85, green: 0.91, blue: 0.97, alpha: 1)
        case ..<0.6: UIColor(red: 0.69, green: 0.82, blue: 0.94, alpha: 1)
        case ..<0.9: UIColor(red: 0.52, green: 0.72, blue: 0.91, alpha: 1)
        case ..<1.3: UIColor(red: 0.36, green: 0.60, blue: 0.86, alpha: 1)
        case ..<1.8: UIColor(red: 0.24, green: 0.47, blue: 0.79, alpha: 1)
        case ..<2.4: UIColor(red: 0.17, green: 0.34, blue: 0.68, alpha: 1)
        default: UIColor(red: 0.14, green: 0.22, blue: 0.55, alpha: 1)
        }
    }
}

// MARK: - Open-Meteo ocean model

extension OpenMeteo {

    /// Hourly ocean current at a point. Global, and a model.
    ///
    /// Same shape as `tide(at:)` on purpose — same three-day window, same
    /// axis — so the currents chart and the tide curve scrub together.
    static func currents(at coordinate: Geo.Coordinate) async -> CurrentsOutlook {
        var components = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "ocean_current_velocity,ocean_current_direction"),
            .init(name: "forecast_days", value: "3"),
            .init(name: "past_days", value: "1"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = components.url,
              let served = await ForecastCache.serve(from: url, ttl: 3600)
        else { return CurrentsOutlook(hours: [], source: .model) }

        var outlook = parseModelCurrents(served.data)
        outlook.staleAge = served.staleAge
        return outlook
    }

    /// Split from the fetch so a fixture can exercise it.
    static func parseModelCurrents(_ data: Data) -> CurrentsOutlook {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Double],
              let velocities = hourly["ocean_current_velocity"] as? [Any],
              let directions = hourly["ocean_current_direction"] as? [Any]
        else { return CurrentsOutlook(hours: [], source: .model) }

        let hours = times.indices.map { index -> CurrentsOutlook.Hour in
            // km/h off the wire, knots on every screen — the same division
            // the surf card does, in the same place: at the parse.
            let kn = (velocities[safe: index] as? Double).map { $0 / 1.852 }
            return CurrentsOutlook.Hour(
                at: Date(timeIntervalSince1970: times[index]),
                speedKn: kn,
                directionDeg: directions[safe: index] as? Double
            )
        }
        return CurrentsOutlook(
            hours: hours,
            source: .model,
            timeZone: (root["timezone"] as? String).flatMap(TimeZone.init(identifier:))
        )
    }
}

extension OpenMeteo {

    /// Currents and sea state along a line of points, one request — the
    /// marine sibling of `windAlong`: same comma-joined coordinates, same
    /// object-vs-array normalisation, same inland-nulls-become-empty rule.
    /// Route sampling stays on the model on purpose: a route crossing
    /// between CO-OPS station domains would stitch two authorities
    /// mid-line, and the point tabs already carry the stations.
    static func marineAlong(_ coordinates: [Geo.Coordinate], hours: Int = 24,
                            pastHours: Int = 0)
        async -> [(currents: [CurrentsOutlook.Hour], waves: [WaveHour])] {
        guard !coordinates.isEmpty else { return [] }
        var components = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        components.queryItems = [
            .init(name: "latitude",
                  value: coordinates.map { String(format: "%.4f", $0.latitude) }.joined(separator: ",")),
            .init(name: "longitude",
                  value: coordinates.map { String(format: "%.4f", $0.longitude) }.joined(separator: ",")),
            .init(name: "hourly", value: "ocean_current_velocity,ocean_current_direction,wave_height,wave_period"),
            .init(name: "forecast_hours", value: String(hours)),
            .init(name: "timeformat", value: "unixtime"),
        ]
        // The Spots map's time slider reaches behind now; the wind
        // fetcher's own `pastHours`, for the water.
        if pastHours > 0 {
            components.queryItems?.append(.init(name: "past_hours", value: String(pastHours)))
        }
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 1800),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        let points = (root as? [[String: Any]]) ?? (root as? [String: Any]).map { [$0] } ?? []
        return points.map { point in
            guard let hourly = point["hourly"] as? [String: Any],
                  let times = hourly["time"] as? [Double]
            else { return (currents: [], waves: []) }
            func series(_ key: String) -> [Double?] {
                (hourly[key] as? [Any])?.map { $0 as? Double } ?? []
            }
            let velocity = series("ocean_current_velocity")
            let set = series("ocean_current_direction")
            let heights = series("wave_height")
            let periods = series("wave_period")

            let currents = times.indices.map { hour in
                CurrentsOutlook.Hour(
                    at: Date(timeIntervalSince1970: times[hour]),
                    speedKn: (velocity[safe: hour] ?? nil).map { $0 / 1.852 },
                    directionDeg: set[safe: hour] ?? nil
                )
            }
            let waves = times.indices.map { hour in
                WaveHour(at: Date(timeIntervalSince1970: times[hour]),
                         heightM: heights[safe: hour] ?? nil,
                         periodS: periods[safe: hour] ?? nil,
                         swellM: nil)
            }
            return (
                currents: currents.contains(where: { $0.speedKn != nil }) ? currents : [],
                waves: waves.contains(where: { $0.heightM != nil }) ? waves : []
            )
        }
    }
}

// MARK: - NOAA CO-OPS current predictions

extension TidesAndCurrents {

    /// The currents station index, boiled down and kept on disk like the
    /// tide index — a separate file, because the two lists answer different
    /// questions and refresh independently.
    private static var cachedCurrents: [DistilledCurrent] = []

    private static var currentsCacheURL: URL {
        URL.cachesDirectory.appending(path: "noaa-current-stations.json")
    }

    struct DistilledCurrent: Codable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let bin: Int
        let depth: Double?
        let isHarmonic: Bool
    }

    static func currentStations(near coordinate: Geo.Coordinate, limit: Int = 3) async -> [CurrentStation] {
        let index = await loadCurrentsIndex()
        return index
            .map { (row: $0, metres: Geo.distance(coordinate, Geo.Coordinate(latitude: $0.latitude, longitude: $0.longitude))) }
            .sorted { $0.metres < $1.metres }
            .prefix(limit)
            .map {
                CurrentStation(id: $0.row.id, bin: $0.row.bin, name: $0.row.name,
                               metres: $0.metres,
                               coordinate: Geo.Coordinate(latitude: $0.row.latitude, longitude: $0.row.longitude),
                               isHarmonic: $0.row.isHarmonic)
            }
    }

    private static func loadCurrentsIndex() async -> [DistilledCurrent] {
        if !cachedCurrents.isEmpty { return cachedCurrents }

        if let data = try? Data(contentsOf: currentsCacheURL),
           let rows = try? JSONDecoder().decode([DistilledCurrent].self, from: data), !rows.isEmpty {
            cachedCurrents = rows
            return rows
        }

        guard let url = URL(string: "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=currentpredictions"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else {
            // The bundle's snapshot: same distilled rows, refreshed by
            // scripts/refresh-station-snapshots.sh, so a signal-less first
            // launch still knows its current stations.
            if let bundled = Bundle.main.url(forResource: "noaa-current-stations", withExtension: "json"),
               let data = try? Data(contentsOf: bundled),
               let rows = try? JSONDecoder().decode([DistilledCurrent].self, from: data) {
                cachedCurrents = rows
                return rows
            }
            return []
        }

        let rows = distillCurrentsIndex(data)
        if let encoded = try? JSONEncoder().encode(rows) {
            try? encoded.write(to: currentsCacheURL, options: .atomic)
        }
        cachedCurrents = rows
        return rows
    }

    /// The 4,400-row index, reduced to one row per instrument.
    ///
    /// - "W" stations — weak and variable — are dropped: their whole
    ///   prediction is "don't bother".
    /// - A station that publishes several depth bins keeps only its
    ///   shallowest: the bin the board floats in.
    static func distillCurrentsIndex(_ data: Data) -> [DistilledCurrent] {
        struct Payload: Decodable {
            struct Station: Decodable {
                let id: String?
                let name: String?
                let lat: Double?
                let lng: Double?
                let currbin: Int?
                let depth: Double?
                let type: String?
            }
            let stations: [Station]?
        }
        let stations = (try? JSONDecoder().decode(Payload.self, from: data))?.stations ?? []

        var bestById: [String: DistilledCurrent] = [:]
        for station in stations {
            guard let id = station.id, let name = station.name,
                  let lat = station.lat, let lng = station.lng,
                  let bin = station.currbin,
                  let type = station.type, type != "W" else { continue }
            let row = DistilledCurrent(id: id, name: name, latitude: lat, longitude: lng,
                                       bin: bin, depth: station.depth,
                                       isHarmonic: type == "H")
            if let existing = bestById[id] {
                // Shallower wins; a bin with no stated depth (subordinates)
                // is treated as surface.
                if (row.depth ?? 0) < (existing.depth ?? 0) { bestById[id] = row }
            } else {
                bestById[id] = row
            }
        }
        return bestById.values.sorted { $0.id < $1.id }
    }

    /// Predictions for one station: an hourly series where the station is
    /// harmonic, and the turns either way.
    ///
    /// Predictions, not readings — computed from harmonics, and caching
    /// them wrongs nobody (the tide fetcher's words, same endpoint).
    static func currentPredictions(for station: CurrentStation) async -> CurrentsOutlook {
        // Yesterday through two days out, station-local — the same window
        // the model curve covers, so the swap changes authority, not axis.
        let calendar = Calendar.current
        let begin = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd"
        stamp.timeZone = .current

        func request(interval: String) -> URL? {
            var components = URLComponents(
                string: "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter")!
            components.queryItems = [
                .init(name: "product", value: "currents_predictions"),
                .init(name: "station", value: station.id),
                .init(name: "bin", value: String(station.bin)),
                .init(name: "begin_date", value: stamp.string(from: begin)),
                .init(name: "range", value: "96"),
                .init(name: "interval", value: interval),
                // English units so speeds arrive in knots — the unit every
                // other number in the Spots layer already speaks.
                .init(name: "units", value: "english"),
                .init(name: "time_zone", value: "lst_ldt"),
                .init(name: "format", value: "json"),
            ]
            return components.url
        }

        var hours: [CurrentsOutlook.Hour] = []
        if station.isHarmonic, let url = request(interval: "60"),
           let data = await ForecastCache.data(from: url, ttl: 21_600) {
            hours = parseHourlyPredictions(data)
        }
        var events: [CurrentsOutlook.Event] = []
        if let url = request(interval: "MAX_SLACK"),
           let data = await ForecastCache.data(from: url, ttl: 21_600) {
            events = parseEventPredictions(data)
        }
        return CurrentsOutlook(hours: hours, events: events,
                               source: .station(station), timeZone: .current)
    }

    /// `interval=60` rows, in the two dialects the stations actually speak.
    /// Some answer `{"Speed": "0.949", "Direction": 50}` — a string
    /// magnitude and the set, stored as-is. Others answer a signed
    /// `Velocity_Major` with `meanFloodDir`/`meanEbbDir`, the MAX_SLACK
    /// vocabulary at hourly cadence: positive floods, negative ebbs, and
    /// the sign picks which mean direction the water is running. A row
    /// carrying `Type` is an *event* that answered where hours were asked
    /// — the subordinate-station trap — and is dropped, so a station that
    /// cannot do hours yields honestly empty hours instead of a blank
    /// chart with a working scrubber.
    static func parseHourlyPredictions(_ data: Data) -> [CurrentsOutlook.Hour] {
        struct Payload: Decodable {
            struct Root: Decodable { let cp: [Row]? }
            struct Row: Decodable {
                let Time: String
                let Speed: String?
                let Direction: Double?
                let Velocity_Major: Double?
                let meanFloodDir: Double?
                let meanEbbDir: Double?
                let kind: String?
                enum CodingKeys: String, CodingKey {
                    case Time, Speed, Direction, Velocity_Major, meanFloodDir, meanEbbDir
                    case kind = "Type"
                }
            }
            let current_predictions: Root?
        }
        let parser = stationTimeParser
        return ((try? JSONDecoder().decode(Payload.self, from: data))?.current_predictions?.cp ?? [])
            .compactMap { row in
                guard row.kind == nil, let at = parser.date(from: row.Time) else { return nil }
                if let speed = row.Speed.flatMap(Double.init) {
                    return CurrentsOutlook.Hour(at: at, speedKn: speed,
                                                directionDeg: row.Direction)
                }
                if let major = row.Velocity_Major {
                    return CurrentsOutlook.Hour(
                        at: at,
                        speedKn: abs(major),
                        directionDeg: major >= 0 ? row.meanFloodDir : row.meanEbbDir)
                }
                return nil
            }
    }

    /// `interval=MAX_SLACK` rows carry a signed `Velocity_Major`: positive
    /// is flood, negative is ebb, zero-ish with `Type: "slack"` is the pause.
    static func parseEventPredictions(_ data: Data) -> [CurrentsOutlook.Event] {
        struct Payload: Decodable {
            struct Root: Decodable { let cp: [Row]? }
            struct Row: Decodable {
                let Time: String
                let kind: String?
                let Velocity_Major: Double?
                enum CodingKeys: String, CodingKey {
                    case Time, Velocity_Major
                    case kind = "Type"
                }
            }
            let current_predictions: Root?
        }
        let parser = stationTimeParser
        return ((try? JSONDecoder().decode(Payload.self, from: data))?.current_predictions?.cp ?? [])
            .compactMap { row in
                guard let at = parser.date(from: row.Time) else { return nil }
                switch row.kind?.lowercased() {
                case "flood":
                    return CurrentsOutlook.Event(at: at, kind: .maxFlood,
                                                 speedKn: row.Velocity_Major.map(abs))
                case "ebb":
                    return CurrentsOutlook.Event(at: at, kind: .maxEbb,
                                                 speedKn: row.Velocity_Major.map(abs))
                case "slack":
                    return CurrentsOutlook.Event(at: at, kind: .slack, speedKn: nil)
                default:
                    return nil
                }
            }
    }

    /// Station times arrive as `lst_ldt` — the station's own local clock,
    /// which for a rider standing on that shore is also theirs. The same
    /// approximation the tide parser makes, for the same reason.
    private static var stationTimeParser: DateFormatter {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd HH:mm"
        parser.timeZone = .current
        return parser
    }
}

// MARK: - The one door

/// Who speaks for the water at a point: a NOAA station when one is close
/// enough to mean something, the ocean model everywhere else. Wholesale,
/// never blended — the tide screen's doctrine, applied to its sibling.
enum Currents {

    /// How close a station must stand to replace the model — the same 15 km
    /// SURF.md grants a water-level station, and a named constant because
    /// the number is a policy, not a tuning.
    static let stationRadius: Double = 15_000

    /// The station half of the door alone: the nearest station's word when
    /// one stands close enough to speak for this point, nil where none does
    /// — or where the nearest answered with nothing, because a failed fetch
    /// is not an authority. The flow screen calls this rather than
    /// `outlook(at:)` since the model already sits under it as the field.
    static func station(at coordinate: Geo.Coordinate) async -> CurrentsOutlook? {
        guard let station = await TidesAndCurrents.currentStations(near: coordinate, limit: 1).first,
              station.metres <= stationRadius else { return nil }
        let predicted = await TidesAndCurrents.currentPredictions(for: station)
        return predicted.isEmpty ? nil : predicted
    }

    static func outlook(at coordinate: Geo.Coordinate) async -> CurrentsOutlook {
        if let predicted = await station(at: coordinate) { return predicted }
        return await OpenMeteo.currents(at: coordinate)
    }
}
