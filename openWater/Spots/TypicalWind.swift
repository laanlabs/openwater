import Foundation
import OpenWaterCore
import OpenWaterSpots

// MARK: - What the wind normally does here this week

/// The wind normals for the week ahead, from the reanalysis archive.
///
/// Apple's statistics API has no wind — temperature and rain only — which is
/// unfortunate, because in this sport wind *is* the question and the rest is
/// what you wear while answering it. So this half of the card comes from
/// somewhere else: ERA5, the reanalysis behind `OpenMeteo.historical`, served
/// free and worldwide back to 1940.
///
/// A single year's value for one date is noise — one August Tuesday tells you
/// nothing about August Tuesdays. So each day here is built from every archive
/// day within three days of that date, across ten years: about seventy
/// observations, which is enough to say what the middle looks like and where
/// the edges are.
///
/// The middle half is what gets drawn, not the mean. "Normally 15 knots" is a
/// number no day ever actually is; "normally somewhere between 10 and 19, and
/// this week's forecast sits under all of it" is the sentence a rider deciding
/// whether to book a trip is actually asking for.
struct TypicalWind {

    /// One date's normals.
    struct Day: Identifiable, Equatable {
        let date: Date
        /// The middle half of what this date's peak wind has done — the 25th
        /// and 75th percentiles, in knots.
        let lowKn: Double
        let highKn: Double
        /// The middle of it.
        let medianKn: Double
        /// Degrees the wind normally comes from, vector-averaged.
        let directionDeg: Double?
        /// How many archive days went into it.
        let samples: Int

        var id: Date { date }
    }

    var days: [Day] = []
    /// The span the averages are built from, for the provenance line.
    var firstYear: Int?
    var lastYear: Int?

    var isEmpty: Bool { days.isEmpty }

    /// The week's own middle, for the header figure.
    var medianKn: Double? {
        let values = days.map(\.medianKn).sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    /// The week's prevailing direction.
    var directionDeg: Double? {
        TypicalWind.circularMean(of: days.compactMap(\.directionDeg))
    }

    /// This week's forecast peaks against the normal middles, in knots.
    ///
    /// Split from the fetch and the view so a fixture can exercise it. Matched
    /// by calendar day rather than by index, for the same reason the
    /// temperature half is: the two sources start their weeks from their own
    /// idea of today.
    func comparison(to forecast: [WeatherDetail.Day],
                    calendar: Calendar = .current) -> Double? {
        var deltas: [Double] = []
        for normal in days {
            guard let day = forecast.first(where: {
                calendar.isDate($0.date, inSameDayAs: normal.date)
            }), let peak = day.windMaxKn else { continue }
            deltas.append(peak - normal.medianKn)
        }
        guard !deltas.isEmpty else { return nil }
        return deltas.reduce(0, +) / Double(deltas.count)
    }

    /// Mean of bearings the short way round — 350° and 10° average to 0°, not
    /// 180°, and a card that inverted a prevailing wind would be worse than
    /// one that never mentioned it.
    static func circularMean(of degrees: [Double]) -> Double? {
        guard !degrees.isEmpty else { return nil }
        var x = 0.0, y = 0.0
        for degree in degrees {
            x += sin(degree * .pi / 180)
            y += cos(degree * .pi / 180)
        }
        guard x != 0 || y != 0 else { return nil }
        return Geo.normalizeDegrees(atan2(x, y) * 180 / .pi)
    }
}

// MARK: - Fetching it

extension OpenMeteo {

    /// Ten years of daily peak wind, folded into normals for the week ahead.
    ///
    /// One request for the whole span rather than one a year. It is about
    /// seventy kilobytes, which is a lot for a card — but the answer is a
    /// decade of finished weather and cannot change, so it is asked for once a
    /// month and read from disk every other time.
    static func typicalWind(at coordinate: Geo.Coordinate, days: Int = 7,
                            from today: Date = Date(), timeZone: TimeZone? = nil,
                            years: Int = 10) async -> TypicalWind {
        var calendar = Calendar.current
        if let timeZone { calendar.timeZone = timeZone }
        let start = calendar.startOfDay(for: today)
        let targets = (0..<days).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
        guard !targets.isEmpty else { return TypicalWind() }

        // ERA5 lands about five days behind real time, so this year is only
        // partly there and the current month would be missing from its own
        // average. The span ends at the last new year's eve that is certainly
        // complete, which keeps every year in it weighted the same.
        let lastYear = calendar.component(.year, from: today) - 1
        let firstYear = lastYear - years + 1

        var components = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "start_date", value: "\(firstYear)-01-01"),
            .init(name: "end_date", value: "\(lastYear)-12-31"),
            .init(name: "daily", value: "wind_speed_10m_max,wind_direction_10m_dominant"),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = components.url,
              // A month. The only thing that can change this answer is a new
              // year finishing, and the fallback path's three-hour staleness
              // window is meaningless for a decade of settled weather.
              let data = await ForecastCache.data(from: url, ttl: 30 * 86_400)
        else { return TypicalWind() }

        var wind = parseTypicalWind(data, for: targets, calendar: calendar)
        wind.firstYear = firstYear
        wind.lastYear = lastYear
        return wind
    }

    /// Fold the archive's daily rows into one set of normals per target date.
    ///
    /// Split from the fetch so a fixture can exercise it. The date handling is
    /// the part worth pinning: Open-Meteo's own caveat is that with
    /// `timeformat=unixtime` a *daily* stamp is local midnight written as
    /// though it were GMT. That is a nuisance when you want an instant and a
    /// gift when you want a calendar date — reading the stamp back in GMT
    /// hands over exactly the local day it stands for, with no offset applied
    /// and none needed.
    static func parseTypicalWind(_ data: Data, for targets: [Date],
                                 calendar: Calendar,
                                 windowDays: Int = 3) -> TypicalWind {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = root["daily"] as? [String: Any],
              let times = daily["time"] as? [Double]
        else { return TypicalWind() }

        let speeds = (daily["wind_speed_10m_max"] as? [Any])?.map { $0 as? Double } ?? []
        let directions = (daily["wind_direction_10m_dominant"] as? [Any])?.map { $0 as? Double } ?? []

        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = TimeZone(secondsFromGMT: 0)!

        // Every archive day, filed under the slot in the year it belongs to.
        var speedsByDay: [Int: [Double]] = [:]
        var directionsByDay: [Int: [Double]] = [:]
        for index in times.indices {
            guard let speed = speeds[safe: index] ?? nil else { continue }
            let date = Date(timeIntervalSince1970: times[index])
            let parts = gmt.dateComponents([.month, .day], from: date)
            guard let month = parts.month, let day = parts.day,
                  let slot = Self.daySlot(month: month, day: day)
            else { continue }
            speedsByDay[slot, default: []].append(speed)
            if let direction = directions[safe: index] ?? nil {
                directionsByDay[slot, default: []].append(direction)
            }
        }
        guard !speedsByDay.isEmpty else { return TypicalWind() }

        let rows = targets.compactMap { target -> TypicalWind.Day? in
            let parts = calendar.dateComponents([.month, .day], from: target)
            guard let month = parts.month, let day = parts.day,
                  let slot = Self.daySlot(month: month, day: day)
            else { return nil }

            // Every slot within `windowDays` of this one, the long way round
            // the new year included — a window on December 30th reaches into
            // January, and a card that went quiet for a week each winter
            // because the arithmetic ran off the end would be a poor trade for
            // the three lines this costs.
            var sample: [Double] = []
            var bearings: [Double] = []
            for offset in -windowDays...windowDays {
                let neighbour = ((slot + offset) % 365 + 365) % 365
                sample += speedsByDay[neighbour] ?? []
                bearings += directionsByDay[neighbour] ?? []
            }
            guard sample.count >= 5 else { return nil }

            let sorted = sample.sorted()
            return TypicalWind.Day(
                date: target,
                lowKn: Self.percentile(sorted, 0.25),
                highKn: Self.percentile(sorted, 0.75),
                medianKn: Self.percentile(sorted, 0.5),
                directionDeg: TypicalWind.circularMean(of: bearings),
                samples: sample.count
            )
        }
        return TypicalWind(days: rows)
    }

    /// Which of 365 slots a date falls in, so dates from different years
    /// compare directly.
    ///
    /// February 29th folds onto the 28th. It is one day in four, and the
    /// alternative — a 366th slot that three years in four are empty — puts a
    /// hole in the window every leap year for no gain.
    static func daySlot(month: Int, day: Int) -> Int? {
        let before = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        guard (1...12).contains(month), day >= 1 else { return nil }
        let lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return before[month - 1] + min(day, lengths[month - 1]) - 1
    }

    /// Nearest-rank percentile of an already-sorted array.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count - 1)).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
