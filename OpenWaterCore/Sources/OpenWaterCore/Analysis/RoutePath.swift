import Foundation

/// A planned line over water: ordered waypoints and the geometry to walk
/// them.
///
/// The planned-route sibling of `TrackInterpolation`, which answers the
/// same questions about a *recorded* track. A track has timestamps and this
/// has none — position along a route is always someone's estimate, made by
/// `RouteProgress` below, and the honesty about that lives with the caller.
public struct RoutePath: Hashable, Sendable {

    /// Deduplicated: a zero-length leg (two taps on the same point) would
    /// make its bearing undefined and its share of the route meaningless.
    public let waypoints: [Geo.Coordinate]

    /// Metres from the start at each waypoint; always starts at 0.
    public let cumulativeDistance: [Double]

    public var totalDistance: Double { cumulativeDistance.last ?? 0 }

    public init(waypoints: [Geo.Coordinate]) {
        var kept: [Geo.Coordinate] = []
        var distances: [Double] = []
        for point in waypoints {
            if let last = kept.last {
                let leg = Geo.distance(last, point)
                guard leg > 1 else { continue }
                kept.append(point)
                distances.append((distances.last ?? 0) + leg)
            } else {
                kept.append(point)
                distances.append(0)
            }
        }
        self.waypoints = kept
        self.cumulativeDistance = distances
    }

    /// The point `metres` along the route, clamped to the ends — asking for
    /// a position before the start answers the start, past the finish the
    /// finish, which is exactly what an estimated rider does.
    public func coordinate(atDistance metres: Double) -> Geo.Coordinate? {
        guard let first = waypoints.first else { return nil }
        guard waypoints.count > 1 else { return first }
        if metres <= 0 { return first }
        if metres >= totalDistance { return waypoints.last }

        let leg = legIndex(atDistance: metres)
        let intoLeg = metres - cumulativeDistance[leg]
        return Geo.destination(
            from: waypoints[leg],
            bearing: Geo.bearing(from: waypoints[leg], to: waypoints[leg + 1]),
            distance: intoLeg
        )
    }

    /// The bearing of the leg containing `metres` — the way the route
    /// points there, which is what alignment against the wind wants.
    public func bearing(atDistance metres: Double) -> Double? {
        guard waypoints.count > 1 else { return nil }
        let leg = legIndex(atDistance: min(max(metres, 0), totalDistance))
        return Geo.bearing(from: waypoints[leg], to: waypoints[leg + 1])
    }

    /// Binary search for the leg whose span contains `metres`.
    private func legIndex(atDistance metres: Double) -> Int {
        var low = 0
        var high = cumulativeDistance.count - 2
        while low < high {
            let mid = (low + high + 1) / 2
            if cumulativeDistance[mid] <= metres { low = mid } else { high = mid - 1 }
        }
        return max(0, min(low, waypoints.count - 2))
    }

    // MARK: Sampling

    /// One evenly spaced point along the route, with where it stands and
    /// which way its leg points.
    public struct Sample: Hashable, Sendable {
        public let coordinate: Geo.Coordinate
        /// Metres from the start.
        public let distance: Double
        public let legBearing: Double

        public init(coordinate: Geo.Coordinate, distance: Double, legBearing: Double) {
            self.coordinate = coordinate
            self.distance = distance
            self.legBearing = legBearing
        }
    }

    /// Evenly spaced samples every ~`spacing` metres, capped at `maxPoints`,
    /// both endpoints always included. This is the shape the forecast APIs
    /// get asked with, so the cap is the API budget.
    public func sampled(every spacing: Double, maxPoints: Int) -> [Sample] {
        guard waypoints.count > 1, spacing > 0, maxPoints >= 2 else {
            return waypoints.prefix(1).map {
                Sample(coordinate: $0, distance: 0, legBearing: 0)
            }
        }
        // Enough points to honor the spacing, unless the cap says fewer —
        // then the spacing stretches so the ends still land exactly.
        let count = min(maxPoints, max(2, Int((totalDistance / spacing).rounded(.up)) + 1))
        let step = totalDistance / Double(count - 1)
        return (0..<count).compactMap { index in
            let metres = Double(index) * step
            guard let where_ = coordinate(atDistance: metres),
                  let bearing = bearing(atDistance: metres)
            else { return nil }
            return Sample(coordinate: where_, distance: metres, legBearing: bearing)
        }
    }
}

/// Where along a route somebody probably is at a moment — an estimate by
/// construction, and every rendering of it should say so.
public struct RouteProgress: Sendable {

    public var path: RoutePath
    public var departure: Date
    public var speed: RouteSpeedEstimate

    /// How the speed is known. One case today; the seam where per-rider
    /// history plugs in later without `distance(at:)` changing shape.
    public enum RouteSpeedEstimate: Sendable {
        case assumed(metresPerSecond: Double)

        var metresPerSecond: Double {
            switch self {
            case .assumed(let speed): max(0.01, speed)
            }
        }
    }

    public init(path: RoutePath, departure: Date, speed: RouteSpeedEstimate) {
        self.path = path
        self.departure = departure
        self.speed = speed
    }

    /// Metres covered by `time`, clamped to the route: at the start before
    /// departure, at the finish after arrival.
    public func distance(at time: Date) -> Double {
        let elapsed = time.timeIntervalSince(departure)
        guard elapsed > 0 else { return 0 }
        return min(path.totalDistance, elapsed * speed.metresPerSecond)
    }

    public func position(at time: Date) -> Geo.Coordinate? {
        path.coordinate(atDistance: distance(at: time))
    }

    public var eta: Date {
        departure.addingTimeInterval(path.totalDistance / speed.metresPerSecond)
    }
}
