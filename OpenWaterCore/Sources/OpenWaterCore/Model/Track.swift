import Foundation

/// A cleaned, analysis-ready track.
///
/// The whole analysis layer works on the parallel arrays in here rather than on
/// `[TrackPoint]` directly. That is deliberate: every metric in the app is some
/// form of window over time or distance, and having `elapsed` and
/// `cumulativeDistance` precomputed as monotonically increasing arrays turns
/// almost all of those queries into O(n) two-pointer sweeps instead of O(n²).
///
/// Build one with `TrackBuilder`, never by hand.
public struct Track: Sendable, Codable {

    /// The points that survived validation, in ascending time order.
    public let points: [TrackPoint]

    /// Seconds since `startDate`, one per point. Strictly increasing.
    public let elapsed: [TimeInterval]

    /// Metres travelled from the first point, one per point. Non-decreasing.
    public let cumulativeDistance: [Double]

    /// Best available speed in m/s, one per point: Doppler where trustworthy,
    /// smoothed position-derived speed otherwise.
    public let speed: [Double]

    /// Course over ground in degrees, one per point. Reported course where
    /// available, otherwise derived from consecutive positions and smoothed.
    public let course: [Double]

    /// How the speed channel was obtained, for honesty in the UI.
    public let speedSource: SpeedSource

    /// GPS quality assessment for the session as a whole.
    public let quality: TrackQuality

    /// Points that were rejected during ingest, and why.
    public let rejections: [Rejection]

    public init(
        points: [TrackPoint],
        elapsed: [TimeInterval],
        cumulativeDistance: [Double],
        speed: [Double],
        course: [Double],
        speedSource: SpeedSource,
        quality: TrackQuality,
        rejections: [Rejection] = []
    ) {
        self.points = points
        self.elapsed = elapsed
        self.cumulativeDistance = cumulativeDistance
        self.speed = speed
        self.course = course
        self.speedSource = speedSource
        self.quality = quality
        self.rejections = rejections
    }

    // MARK: - Basics

    public var count: Int { points.count }
    public var isEmpty: Bool { points.isEmpty }

    public var startDate: Date? { points.first?.timestamp }
    public var endDate: Date? { points.last?.timestamp }

    /// Wall-clock length of the recording.
    public var duration: TimeInterval { elapsed.last ?? 0 }

    /// Total distance over the ground, metres.
    public var totalDistance: Double { cumulativeDistance.last ?? 0 }

    /// Median interval between fixes, seconds. 1 Hz on most watches.
    public var sampleInterval: TimeInterval {
        guard count > 1 else { return 1 }
        var deltas = [TimeInterval]()
        deltas.reserveCapacity(count - 1)
        for i in 1..<count { deltas.append(elapsed[i] - elapsed[i - 1]) }
        deltas.sort()
        return deltas[deltas.count / 2]
    }

    public subscript(index: Int) -> TrackPoint { points[index] }

    public func coordinate(at index: Int) -> Geo.Coordinate { points[index].coordinate }

    /// Bounding box of the track, or `nil` if empty.
    public var boundingBox: (min: Geo.Coordinate, max: Geo.Coordinate)? {
        guard let first = points.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in points.dropFirst() {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        return (Geo.Coordinate(latitude: minLat, longitude: minLon),
                Geo.Coordinate(latitude: maxLat, longitude: maxLon))
    }

    // MARK: - Lookup

    /// Index of the last sample at or before `time` seconds elapsed.
    ///
    /// Binary search — the map scrubber calls this on every frame.
    public func index(atElapsed time: TimeInterval) -> Int? {
        guard !elapsed.isEmpty else { return nil }
        if time < elapsed[0] { return nil }
        var lo = 0, hi = elapsed.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if elapsed[mid] <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Index of the last sample at or before `metres` of cumulative distance.
    public func index(atDistance metres: Double) -> Int? {
        guard !cumulativeDistance.isEmpty else { return nil }
        if metres < cumulativeDistance[0] { return nil }
        var lo = 0, hi = cumulativeDistance.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulativeDistance[mid] <= metres { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Mean speed over an index range, weighted by time rather than by sample
    /// count so a dropout does not distort the answer.
    public func meanSpeed(from i: Int, to j: Int) -> Double {
        guard i < j, i >= 0, j < count else { return 0 }
        let dt = elapsed[j] - elapsed[i]
        guard dt > 0 else { return 0 }
        return (cumulativeDistance[j] - cumulativeDistance[i]) / dt
    }

    /// The slice of coordinates covering an index range, for drawing.
    public func coordinates(from i: Int, to j: Int) -> [Geo.Coordinate] {
        guard i <= j, i >= 0, j < count else { return [] }
        return points[i...j].map(\.coordinate)
    }
}

/// Where the speed channel came from.
public enum SpeedSource: String, Sendable, Codable {
    /// Receiver-supplied Doppler speed. The trustworthy case.
    case doppler
    /// Derived by differentiating positions. Noisier; peaks are less reliable.
    case derived
    /// A mix — Doppler where present, derived to fill gaps.
    case mixed

    public var isTrustworthyForRecords: Bool { self != .derived }

    public var displayName: String {
        switch self {
        case .doppler: "Doppler"
        case .derived: "Position-derived"
        case .mixed: "Mixed"
        }
    }
}

/// A point that did not make it into the track.
public struct Rejection: Hashable, Sendable, Codable {
    public enum Reason: String, Sendable, Codable {
        case invalidPosition
        case poorAccuracy
        case impossibleSpeed
        case nonMonotonicTime
        case duplicateTimestamp

        public var displayName: String {
            switch self {
            case .invalidPosition: "Invalid position"
            case .poorAccuracy: "Accuracy too low"
            case .impossibleSpeed: "Implausible jump"
            case .nonMonotonicTime: "Out-of-order timestamp"
            case .duplicateTimestamp: "Duplicate timestamp"
            }
        }
    }

    public let timestamp: Date
    public let reason: Reason
    /// The offending value, for the diagnostics screen.
    public let value: Double?

    public init(timestamp: Date, reason: Reason, value: Double? = nil) {
        self.timestamp = timestamp
        self.reason = reason
        self.value = value
    }
}

/// How much the numbers from this track can be trusted.
public struct TrackQuality: Hashable, Sendable, Codable {

    /// 0–100. Above 80 is a clean recording; below 50 treat records as indicative.
    public let score: Double

    /// Mean horizontal accuracy in metres across accepted points.
    public let meanAccuracy: Double

    /// Worst accepted horizontal accuracy, metres.
    public let worstAccuracy: Double

    /// Fixes per second actually achieved.
    public let fixRate: Double

    /// Number of gaps longer than 3× the nominal sample interval.
    public let dropoutCount: Int

    /// Total seconds lost to those gaps.
    public let dropoutDuration: TimeInterval

    /// Fraction of points that carried a usable Doppler speed, 0–1.
    public let dopplerCoverage: Double

    /// Points thrown away as a fraction of points offered, 0–1.
    public let rejectionRate: Double

    public init(
        score: Double,
        meanAccuracy: Double,
        worstAccuracy: Double,
        fixRate: Double,
        dropoutCount: Int,
        dropoutDuration: TimeInterval,
        dopplerCoverage: Double,
        rejectionRate: Double
    ) {
        self.score = score
        self.meanAccuracy = meanAccuracy
        self.worstAccuracy = worstAccuracy
        self.fixRate = fixRate
        self.dropoutCount = dropoutCount
        self.dropoutDuration = dropoutDuration
        self.dopplerCoverage = dopplerCoverage
        self.rejectionRate = rejectionRate
    }

    public static let unknown = TrackQuality(
        score: 0, meanAccuracy: 0, worstAccuracy: 0, fixRate: 0,
        dropoutCount: 0, dropoutDuration: 0, dopplerCoverage: 0, rejectionRate: 0
    )

    public enum Grade: String, Sendable, Codable {
        case excellent, good, fair, poor

        public var displayName: String { rawValue.capitalized }
    }

    public var grade: Grade {
        switch score {
        case 85...: .excellent
        case 65..<85: .good
        case 40..<65: .fair
        default: .poor
        }
    }
}
