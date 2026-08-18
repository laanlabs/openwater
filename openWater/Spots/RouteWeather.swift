import Foundation
import OpenWaterCore
import SwiftUI

/// The forecast along a route: a small grid of sample points × hours,
/// fetched once per route and read from memory forever after — scrubbing
/// the timeline, changing the departure or the speed never touches the
/// network.
struct RouteForecastGrid {

    /// Cheap identity for view keying — a new fetch is a new stamp, so
    /// map overlays rebuilt from the grid can key off it instead of
    /// diffing arrays.
    let stamp = UUID()

    let samples: [RoutePath.Sample]
    /// The shared hourly axis, from the wind response.
    let hours: [Date]
    /// `wind[sample][hour]`, aligned to `samples` and `hours`.
    let wind: [[WindForecastHour]]
    /// Water along the route arrives in the next phase; the grid already
    /// has the shape for it.
    var currents: [[CurrentsOutlook.Hour]] = []
    var waves: [[WaveHour]] = []

    var isEmpty: Bool { hours.isEmpty || wind.allSatisfy(\.isEmpty) }

    /// Wind at a distance along the route at an instant — bilinear over
    /// the grid. Speeds lerp linearly; directions lerp the only way angles
    /// can, via `Geo.angleDelta`, so 350° and 10° meet at due north and
    /// never at due south.
    func wind(atDistance metres: Double, time: Date) -> (speedKn: Double, gustKn: Double?, directionDeg: Double)? {
        guard !isEmpty, samples.count == wind.count else { return nil }

        // Bracket by distance.
        let after = samples.firstIndex { $0.distance >= metres } ?? samples.count - 1
        let before = max(0, after - 1)
        let span = samples[after].distance - samples[before].distance
        let alongFraction = span > 0 ? (metres - samples[before].distance) / span : 0

        guard let a = wind(atSample: before, time: time),
              let b = wind(atSample: after, time: time)
        else { return nil }

        let f = min(1, max(0, alongFraction))
        return (
            speedKn: a.speedKn + (b.speedKn - a.speedKn) * f,
            gustKn: zip2(a.gustKn, b.gustKn).map { $0 + ($1 - $0) * f } ?? a.gustKn ?? b.gustKn,
            directionDeg: lerpAngle(a.directionDeg, b.directionDeg, f)
        )
    }

    /// One sample's wind at an instant, lerped between its two bracketing
    /// hours.
    private func wind(atSample index: Int, time: Date) -> (speedKn: Double, gustKn: Double?, directionDeg: Double)? {
        let series = wind[index]
        guard !series.isEmpty else { return nil }
        guard let after = series.firstIndex(where: { $0.date >= time }) else {
            let last = series[series.count - 1]
            return (last.speedKn, last.gustKn, last.directionDeg)
        }
        guard after > 0 else {
            let first = series[0]
            return (first.speedKn, first.gustKn, first.directionDeg)
        }
        let a = series[after - 1], b = series[after]
        let span = b.date.timeIntervalSince(a.date)
        let f = span > 0 ? min(1, max(0, time.timeIntervalSince(a.date) / span)) : 0
        return (
            speedKn: a.speedKn + (b.speedKn - a.speedKn) * f,
            gustKn: zip2(a.gustKn, b.gustKn).map { $0 + ($1 - $0) * f } ?? a.gustKn ?? b.gustKn,
            directionDeg: lerpAngle(a.directionDeg, b.directionDeg, f)
        )
    }

    /// Current at a distance along the route at an instant — the same
    /// bilinear walk as the wind, over the marine grid. Nil where the
    /// route has no marine cell (rivers, lakes) — the row simply hides.
    func current(atDistance metres: Double, time: Date) -> (speedKn: Double, setDeg: Double)? {
        guard samples.count == currents.count, !currents.isEmpty else { return nil }
        let after = samples.firstIndex { $0.distance >= metres } ?? samples.count - 1
        let before = max(0, after - 1)
        let span = samples[after].distance - samples[before].distance
        let f = span > 0 ? min(1, max(0, (metres - samples[before].distance) / span)) : 0
        guard let a = current(atSample: before, time: time),
              let b = current(atSample: after, time: time)
        else { return current(atSample: before, time: time) ?? current(atSample: after, time: time) }
        return (speedKn: a.speedKn + (b.speedKn - a.speedKn) * f,
                setDeg: lerpAngle(a.setDeg, b.setDeg, f))
    }

    private func current(atSample index: Int, time: Date) -> (speedKn: Double, setDeg: Double)? {
        let series = currents[index]
        guard !series.isEmpty else { return nil }
        let nearest = series.min {
            abs($0.at.timeIntervalSince(time)) < abs($1.at.timeIntervalSince(time))
        }
        guard let nearest, let speed = nearest.speedKn, let set = nearest.directionDeg
        else { return nil }
        return (speed, set)
    }

    /// Wave height at a distance and instant, nearest sample and hour —
    /// waves change slowly enough that bilinear would be false precision.
    func waveHeight(atDistance metres: Double, time: Date) -> Double? {
        guard samples.count == waves.count, !waves.isEmpty else { return nil }
        let nearest = samples.indices.min {
            abs(samples[$0].distance - metres) < abs(samples[$1].distance - metres)
        } ?? 0
        return waves[nearest]
            .min { abs($0.at.timeIntervalSince(time)) < abs($1.at.timeIntervalSince(time)) }?
            .heightM
    }

    private func lerpAngle(_ a: Double, _ b: Double, _ f: Double) -> Double {
        let mixed = a + Geo.angleDelta(from: a, to: b) * f
        return (mixed.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
    }

    private func zip2(_ a: Double?, _ b: Double?) -> (Double, Double)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}

/// Everything the inspected route's weather needs in one observable spot,
/// shared by the panel (scrubber, readout) and the map (marker, colored
/// segments) so neither invents its own copy of the estimate.
@MainActor
@Observable
final class RouteWeatherModel {

    private(set) var grid: RouteForecastGrid?
    private(set) var isLoading = false

    /// The shared cursor; nil is "now".
    var scrub: Date?
    var departure: Date = RouteWeatherModel.nextWholeHour()
    /// Knots; seeded from the route on load, adjustable in the panel.
    var speedKn: Double = 14

    /// Sampling: one point every ~2 km, never more than 12 — one forecast
    /// request per route activation, whatever its length.
    static let sampleSpacing: Double = 2000
    static let maxSamples = 12

    private var loadedKey: String?

    func load(for route: PlannedRoute) async {
        let key = "\(route.id)|\(route.waypoints.hashValue)"
        if loadedKey != key {
            speedKn = route.speedKn
            departure = Self.nextWholeHour()
            scrub = nil
        }
        // Same line, same fetch — the grid survives panel round-trips and
        // ForecastCache already deduplicates identical URLs on disk.
        guard loadedKey != key || grid == nil else { return }
        loadedKey = key
        isLoading = true
        let samples = route.path.sampled(every: Self.sampleSpacing, maxPoints: Self.maxSamples)
        // Exactly two requests per activation, whatever the route's length:
        // the forecast grid and the marine grid, fetched together.
        async let windTask = OpenMeteo.windAlong(samples.map(\.coordinate), hours: 24)
        async let marineTask = OpenMeteo.marineAlong(samples.map(\.coordinate), hours: 24)
        let (winds, marine) = await (windTask, marineTask)
        var built = RouteForecastGrid(
            samples: samples,
            hours: winds.first(where: { !$0.isEmpty })?.map(\.date) ?? [],
            wind: winds
        )
        built.currents = marine.map(\.currents)
        built.waves = marine.map(\.waves)
        grid = built
        isLoading = false
    }

    func progress(for route: PlannedRoute) -> RouteProgress {
        RouteProgress(path: route.path, departure: departure,
                      speed: .assumed(metresPerSecond: speedKn * 0.5144))
    }

    /// The instant every reading is about: the scrubbed hour, else now.
    var instant: Date { scrub ?? Date() }

    static func nextWholeHour(after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: date)?.end ?? date
        return hour
    }
}
