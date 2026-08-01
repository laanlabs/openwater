import Foundation

/// Metrics as they stand right now, for a live display.
public struct LiveMetrics: Hashable, Sendable, Codable {

    public var currentSpeed: Double = 0
    public var maxSpeed: Double = 0
    public var averageSpeed: Double = 0
    public var averageMovingSpeed: Double = 0

    public var distance: Double = 0
    public var duration: TimeInterval = 0
    public var movingTime: TimeInterval = 0

    /// Rolling average over the last 10 seconds — what you are doing *now*,
    /// smoothed enough to be readable at speed.
    public var current10s: Double = 0

    /// Bests so far this session, keyed by category.
    public var bests: [SpeedCategory: Double] = [:]

    /// The five best non-overlapping 10 s windows, averaged.
    public var fiveByTen: Double = 0

    public var runCount: Int = 0
    public var maneuverCount: Int = 0

    /// Currently flying, per the live foil heuristic.
    public var isFoiling: Bool = false
    /// Duration of the flight in progress.
    public var currentFlightDuration: TimeInterval = 0
    public var longestFlight: TimeInterval = 0
    public var timeOnFoil: TimeInterval = 0

    public var heading: Double = 0
    public var trueWindAngle: Double?
    public var vmg: Double?

    public var heartRate: Double?

    /// Live GPS accuracy in metres, so a rider can see when a number is soft.
    public var horizontalAccuracy: Double = -1

    /// Seconds between the last two fixes the live screens accepted.
    ///
    /// Worth surfacing because "the GPS feels slow" is otherwise unfalsifiable:
    /// a rider cannot tell a receiver that is genuinely delivering once every
    /// four seconds from one delivering every second whose fixes are being
    /// thrown away upstream. One number on screen distinguishes them.
    public var fixInterval: TimeInterval?

    public var isMoving: Bool = false

    public init() {}

    public func best(_ category: SpeedCategory) -> Double { bests[category] ?? 0 }
}

/// A new personal best, the moment it happens.
public struct LiveRecord: Hashable, Sendable {
    public let category: SpeedCategory
    public let speed: Double
    /// The value it beat — the session best, or the all-time best if one was set.
    public let previous: Double
    public let isAllTime: Bool

    public init(category: SpeedCategory, speed: Double, previous: Double, isAllTime: Bool) {
        self.category = category
        self.speed = speed
        self.previous = previous
        self.isAllTime = isAllTime
    }
}

/// Computes live metrics incrementally as fixes arrive.
///
/// The post-session `SessionAnalyzer` rebuilds and re-filters the whole track
/// every time, which is right for accuracy and wrong for a watch battery. This
/// does the same job in O(log n) per fix by keeping the prefix arrays up to date
/// as it goes and answering each window query with a binary search rather than a
/// rescan.
///
/// The one deliberate difference from the post-session pass is smoothing: this
/// runs a forward-only Kalman, because a two-pass filter needs the future. That
/// makes live peaks fractionally laggier than the final numbers, so the final
/// figures can differ very slightly — always in the direction of the reviewed
/// track being the more accurate one.
public final class LiveAnalyzer: @unchecked Sendable {

    public private(set) var metrics = LiveMetrics()

    /// Categories tracked live. Kept short on purpose.
    public let categories: [SpeedCategory]

    /// All-time bests to compare against, so a genuine PB can be announced on
    /// the wrist the instant it happens.
    public var allTimeBests: [SpeedCategory: Double]

    private let thresholds: SportThresholds
    private let sport: Sport

    // Growing prefix arrays.
    private var elapsed: [TimeInterval] = []
    private var cumulative: [Double] = []
    private var speeds: [Double] = []
    private var courses: [Double] = []

    private var startDate: Date?
    private var lastCoordinate: Geo.Coordinate?
    private var filter = KalmanSpeedFilter()

    // Candidate 10 s windows, kept sorted-ish for the 5 × 10 s selection.
    private var tenSecondCandidates: [(end: TimeInterval, speed: Double)] = []

    // Live foil state.
    private var flightStart: TimeInterval?
    private var accumulatedFoilTime: TimeInterval = 0

    // Live run state.
    private var runHeading = CircularAccumulator()
    private var inRun = false
    private var deviationSince: TimeInterval?

    public init(
        sport: Sport,
        categories: [SpeedCategory] = SpeedCategory.live,
        allTimeBests: [SpeedCategory: Double] = [:]
    ) {
        self.sport = sport
        self.categories = categories
        self.allTimeBests = allTimeBests
        self.thresholds = sport.thresholds
    }

    // MARK: - Ingest

    /// Feed one fix. Returns any personal bests it just produced.
    @discardableResult
    public func add(_ point: TrackPoint) -> [LiveRecord] {
        guard point.hasValidPosition,
              point.horizontalAccuracy <= thresholds.liveAccuracyLimit else {
            metrics.horizontalAccuracy = point.horizontalAccuracy
            return []
        }

        if startDate == nil { startDate = point.timestamp }
        guard let startDate else { return [] }

        let t = point.timestamp.timeIntervalSince(startDate)
        // Reject out-of-order and duplicate fixes rather than corrupting the
        // monotonic arrays everything downstream depends on.
        if let last = elapsed.last, t <= last { return [] }

        let step: Double = {
            guard let previous = lastCoordinate else { return 0 }
            return Geo.distance(previous, point.coordinate)
        }()

        // Teleport guard, same rule as the post-session builder.
        if let last = elapsed.last, t - last <= 5, step / (t - last) > thresholds.maxPlausibleSpeed * 1.5 {
            return []
        }

        let dt = elapsed.last.map { t - $0 } ?? 1
        let raw: Double = point.hasValidSpeed
            ? (point.speed ?? 0)
            : (dt > 0 ? step / dt : 0)
        let smoothed = min(
            filter.update(measurement: raw, accuracy: point.speedAccuracy, dt: dt),
            thresholds.maxPlausibleSpeed
        )

        elapsed.append(t)
        cumulative.append((cumulative.last ?? 0) + step)
        speeds.append(smoothed)
        // Course, derived from movement when the receiver does not supply it.
        //
        // `TrackBuilder` already does this for the post-session pass, but the
        // live path did not — so on any device or import without a course
        // channel the live heading sat at 000° forever, and the angles screen
        // showed a compass permanently pointing north while the rider reached
        // back and forth.
        let derivedCourse: Double? = {
            if let course = point.course, course >= 0, course.isFinite {
                return Geo.normalizeDegrees(course)
            }
            // A short hop is dominated by position noise, so hold the previous
            // heading rather than emitting a random one.
            guard let previous = lastCoordinate, step > 1.5 else { return nil }
            return Geo.bearing(from: previous, to: point.coordinate)
        }()
        courses.append(derivedCourse ?? courses.last ?? 0)
        lastCoordinate = point.coordinate

        return update(with: point, at: t, dt: dt, smoothed: smoothed)
    }

    // MARK: - Update

    private func update(
        with point: TrackPoint,
        at t: TimeInterval,
        dt: TimeInterval,
        smoothed: Double
    ) -> [LiveRecord] {
        metrics.currentSpeed = smoothed
        metrics.maxSpeed = max(metrics.maxSpeed, smoothed)
        metrics.distance = cumulative.last ?? 0
        metrics.duration = t
        metrics.heading = courses.last ?? 0
        metrics.heartRate = point.heartRate ?? metrics.heartRate
        metrics.horizontalAccuracy = point.horizontalAccuracy
        metrics.fixInterval = elapsed.count > 1 ? dt : nil
        metrics.isMoving = smoothed >= thresholds.movingSpeed

        if metrics.isMoving, dt > 0, dt < 30 { metrics.movingTime += dt }
        metrics.averageSpeed = t > 0 ? metrics.distance / t : 0
        metrics.averageMovingSpeed = metrics.movingTime > 0
            ? metrics.distance / metrics.movingTime
            : 0

        metrics.current10s = meanSpeed(endingAt: t, duration: 10)

        updateFoilState(point: point, at: t, dt: dt, speed: smoothed)
        updateRunState(at: t, speed: smoothed)

        return updateBests(at: t)
    }

    private func updateBests(at t: TimeInterval) -> [LiveRecord] {
        var records: [LiveRecord] = []

        for category in categories {
            let value: Double
            switch category {
            case .time(let seconds):
                value = meanSpeed(endingAt: t, duration: seconds)
            case .distance(let metres):
                value = meanSpeed(endingAt: t, distance: metres)
            case .multiTime:
                continue   // handled below, since it is not a simple window
            case .alpha:
                continue   // too expensive per-sample; refreshed on demand
            }

            guard value > 0 else { continue }
            let previous = metrics.bests[category] ?? 0
            guard value > previous + 1e-6 else { continue }
            metrics.bests[category] = value

            // Only announce something worth announcing: a session best that is
            // also an all-time best, or a session best once it is meaningful.
            let allTime = allTimeBests[category] ?? 0
            if value > allTime, allTime > 0 {
                records.append(LiveRecord(
                    category: category, speed: value,
                    previous: allTime, isAllTime: true
                ))
            }
        }

        // 5 × 10 s: maintain a candidate list and re-select greedily. Greedy
        // rather than the optimal DP here purely for battery — the final,
        // reviewed number uses the exact solver.
        let tenSecond = meanSpeed(endingAt: t, duration: 10)
        if tenSecond > 0 {
            tenSecondCandidates.append((t, tenSecond))
            // Keep only the strongest candidates; anything outside the top few
            // dozen can never make a best-five.
            if tenSecondCandidates.count > 400 {
                tenSecondCandidates.sort { $0.speed > $1.speed }
                tenSecondCandidates.removeLast(tenSecondCandidates.count - 200)
                tenSecondCandidates.sort { $0.end < $1.end }
            }
            let five = greedyFiveByTen()
            if five > metrics.fiveByTen {
                let category = SpeedCategory.multiTime(count: 5, seconds: 10)
                let allTime = allTimeBests[category] ?? 0
                metrics.fiveByTen = five
                metrics.bests[category] = five
                if five > allTime, allTime > 0 {
                    records.append(LiveRecord(
                        category: category, speed: five,
                        previous: allTime, isAllTime: true
                    ))
                }
            }
        }

        return records
    }

    private func greedyFiveByTen(count: Int = 5, seconds: TimeInterval = 10) -> Double {
        guard tenSecondCandidates.count >= count else { return 0 }
        let sorted = tenSecondCandidates.sorted { $0.speed > $1.speed }
        var taken: [(end: TimeInterval, speed: Double)] = []
        for c in sorted {
            guard taken.count < count else { break }
            let overlaps = taken.contains { abs($0.end - c.end) < seconds }
            if !overlaps { taken.append(c) }
        }
        guard taken.count == count else { return 0 }
        return taken.reduce(0) { $0 + $1.speed } / Double(count)
    }

    // MARK: - Foil

    private func updateFoilState(
        point: TrackPoint,
        at t: TimeInterval,
        dt: TimeInterval,
        speed: Double
    ) {
        guard sport.isFoiling, thresholds.foilTakeoffSpeed.isFinite else { return }

        let smoothEnough = point.verticalAccelSD.map { $0 <= thresholds.foilSmoothnessSD } ?? true
        let fast = speed >= thresholds.foilTakeoffSpeed * (metrics.isFoiling ? 0.88 : 1.0)
        let flying = fast && smoothEnough

        if flying {
            if flightStart == nil { flightStart = t }
            if dt > 0, dt < 30 { accumulatedFoilTime += dt }
        } else if let start = flightStart {
            let duration = t - start
            if duration >= thresholds.minFlightDuration {
                metrics.longestFlight = max(metrics.longestFlight, duration)
            }
            flightStart = nil
        }

        metrics.isFoiling = flying
        metrics.currentFlightDuration = flightStart.map { t - $0 } ?? 0
        metrics.longestFlight = max(metrics.longestFlight, metrics.currentFlightDuration)
        metrics.timeOnFoil = accumulatedFoilTime
    }

    // MARK: - Runs

    /// A cut-down version of `RunSegmenter` that only needs to count, not to
    /// produce run objects — the full segmentation happens after the session.
    private func updateRunState(at t: TimeInterval, speed: Double) {
        let moving = speed >= max(1.5, thresholds.movingSpeed)
        let heading = courses.last ?? 0

        guard moving else {
            inRun = false
            runHeading = CircularAccumulator()
            deviationSince = nil
            return
        }

        guard inRun else {
            inRun = true
            runHeading = CircularAccumulator()
            runHeading.add(heading)
            metrics.runCount += 1
            return
        }

        let mean = runHeading.mean ?? heading
        if Geo.angleSeparation(mean, heading) > 45 {
            if let since = deviationSince {
                if t - since >= 2.5 {
                    metrics.runCount += 1
                    metrics.maneuverCount += 1
                    runHeading = CircularAccumulator()
                    runHeading.add(heading)
                    deviationSince = nil
                }
            } else {
                deviationSince = t
            }
        } else {
            deviationSince = nil
            runHeading.add(heading)
        }
    }

    // MARK: - Wind

    /// Attach a wind so the live angle screen can show TWA and VMG.
    public func setWind(_ wind: Wind?) {
        guard let wind else {
            metrics.trueWindAngle = nil
            metrics.vmg = nil
            return
        }
        metrics.trueWindAngle = wind.trueWindAngle(heading: metrics.heading)
        metrics.vmg = wind.vmg(speed: metrics.currentSpeed, heading: metrics.heading)
    }

    // MARK: - Window queries

    /// Mean speed over the window of `duration` ending at `t`.
    private func meanSpeed(endingAt t: TimeInterval, duration: TimeInterval) -> Double {
        let start = t - duration
        guard let first = elapsed.first, start >= first else { return 0 }
        let d = distance(atElapsed: t) - distance(atElapsed: start)
        return d / duration
    }

    /// Mean speed over the last `metres` of track ending at `t`.
    private func meanSpeed(endingAt t: TimeInterval, distance metres: Double) -> Double {
        let endDistance = cumulative.last ?? 0
        guard endDistance >= metres else { return 0 }
        let startTime = time(atDistance: endDistance - metres)
        let duration = t - startTime
        guard duration > 0 else { return 0 }
        return metres / duration
    }

    private func distance(atElapsed t: TimeInterval) -> Double {
        guard !elapsed.isEmpty else { return 0 }
        if t <= elapsed[0] { return cumulative[0] }
        if t >= elapsed[elapsed.count - 1] { return cumulative[cumulative.count - 1] }
        var lo = 0, hi = elapsed.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if elapsed[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        guard lo + 1 < elapsed.count else { return cumulative[lo] }
        let span = elapsed[lo + 1] - elapsed[lo]
        guard span > 0 else { return cumulative[lo] }
        let f = (t - elapsed[lo]) / span
        return cumulative[lo] + f * (cumulative[lo + 1] - cumulative[lo])
    }

    private func time(atDistance d: Double) -> TimeInterval {
        guard !cumulative.isEmpty else { return 0 }
        if d <= cumulative[0] { return elapsed[0] }
        if d >= cumulative[cumulative.count - 1] { return elapsed[elapsed.count - 1] }
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] >= d { hi = mid } else { lo = mid + 1 }
        }
        guard lo > 0 else { return elapsed[0] }
        let span = cumulative[lo] - cumulative[lo - 1]
        guard span > 0 else { return elapsed[lo] }
        let f = (d - cumulative[lo - 1]) / span
        return elapsed[lo - 1] + f * (elapsed[lo] - elapsed[lo - 1])
    }

    // MARK: - Reset

    public func reset() {
        metrics = LiveMetrics()
        elapsed.removeAll()
        cumulative.removeAll()
        speeds.removeAll()
        courses.removeAll()
        tenSecondCandidates.removeAll()
        startDate = nil
        lastCoordinate = nil
        filter.reset()
        flightStart = nil
        accumulatedFoilTime = 0
        inRun = false
        runHeading = CircularAccumulator()
        deviationSince = nil
    }
}
