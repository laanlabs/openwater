import Foundation

/// One reach: a stretch ridden on a roughly constant heading.
///
/// A session is a list of runs separated by transitions, and almost everything a
/// wing or windsurf rider wants to know is phrased in those terms — "how fast
/// was my best run", "how many did I get", "is my port side slower". So runs are
/// a first-class object rather than something the UI derives on the fly.
public struct Run: Hashable, Sendable, Codable, Identifiable {

    public let index: Int

    /// Index range into the parent track, inclusive.
    public let startIndex: Int
    public let endIndex: Int

    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval

    public let distance: Double
    public let averageSpeed: Double
    public let maxSpeed: Double

    /// Circular mean of the heading, weighted by distance.
    public let meanHeading: Double

    /// How straight the run was, 0–1. 1 means a perfect line; a slalom weaves.
    public let straightness: Double

    public let startCoordinate: Geo.Coordinate
    public let endCoordinate: Geo.Coordinate

    /// Fraction of the run spent flying, 0–1. Zero for non-foiling sports.
    public var foilingFraction: Double

    /// True wind angle held on this run, once the wind is known.
    /// Signed as `Wind.trueWindAngle`: positive is port tack, negative starboard.
    public var trueWindAngle: Double?

    /// Velocity made good along the wind axis, m/s. Positive is upwind.
    public var vmg: Double?

    public var id: Int { index }

    public var duration: TimeInterval { endElapsed - startElapsed }

    /// Which side of the wind the run was ridden on.
    public var tack: Tack? {
        guard let twa = trueWindAngle else { return nil }
        return twa < 0 ? .starboard : .port
    }

    /// Whether the run was heading generally upwind or downwind.
    public var point: PointOfSail? {
        guard let twa = trueWindAngle else { return nil }
        return PointOfSail(trueWindAngle: twa)
    }

    public init(
        index: Int,
        startIndex: Int,
        endIndex: Int,
        startElapsed: TimeInterval,
        endElapsed: TimeInterval,
        distance: Double,
        averageSpeed: Double,
        maxSpeed: Double,
        meanHeading: Double,
        straightness: Double,
        startCoordinate: Geo.Coordinate,
        endCoordinate: Geo.Coordinate,
        foilingFraction: Double = 0,
        trueWindAngle: Double? = nil,
        vmg: Double? = nil
    ) {
        self.index = index
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.distance = distance
        self.averageSpeed = averageSpeed
        self.maxSpeed = maxSpeed
        self.meanHeading = meanHeading
        self.straightness = straightness
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.foilingFraction = foilingFraction
        self.trueWindAngle = trueWindAngle
        self.vmg = vmg
    }
}

/// Which side the wind is coming over.
public enum Tack: String, Sendable, Codable, CaseIterable {
    case port, starboard

    public var displayName: String { rawValue.capitalized }

    public var opposite: Tack { self == .port ? .starboard : .port }
}

/// Coarse point of sail, from the magnitude of the true wind angle.
public enum PointOfSail: String, Sendable, Codable, CaseIterable {
    case noGo          // 0–35°, pinching or head to wind
    case closeHauled   // 35–55°
    case reaching      // 55–120°
    case broadReach    // 120–160°
    case running       // 160–180°

    public init(trueWindAngle: Double) {
        switch abs(trueWindAngle) {
        case ..<35: self = .noGo
        case ..<55: self = .closeHauled
        case ..<120: self = .reaching
        case ..<160: self = .broadReach
        default: self = .running
        }
    }

    public var displayName: String {
        switch self {
        case .noGo: "No-go"
        case .closeHauled: "Close hauled"
        case .reaching: "Reaching"
        case .broadReach: "Broad reach"
        case .running: "Running"
        }
    }

    public var isUpwind: Bool { self == .noGo || self == .closeHauled }
    public var isDownwind: Bool { self == .broadReach || self == .running }
}

/// Splits a track into runs.
///
/// The naive rule — "start a new run whenever the heading changes by more than
/// X" — produces garbage on real data, because at 1 Hz the heading of a rider
/// bouncing through chop jitters by tens of degrees. Two things fix that:
///
/// 1. the comparison is against the *running mean heading of the current run*,
///    not against the previous sample, so noise averages out; and
/// 2. a deviation has to persist for `confirmationTime` before it splits the
///    run, so a single bad fix or a momentary wobble is absorbed.
///
/// Slow sections are also excluded: a rider sitting in the water drifting is not
/// a run, and their heading is meaningless.
public struct RunSegmenter: Sendable {

    /// Heading deviation from the run's mean that starts a candidate split.
    public var splitAngle: Double

    /// How long the deviation must hold before the split is committed.
    public var confirmationTime: TimeInterval

    /// Below this speed the rider is not considered to be riding.
    public var minimumSpeed: Double

    /// Runs shorter than this are discarded as noise.
    public var minimumDistance: Double
    public var minimumDuration: TimeInterval

    public init(
        splitAngle: Double = 45,
        confirmationTime: TimeInterval = 2.5,
        minimumSpeed: Double = 1.5,
        minimumDistance: Double = 40,
        minimumDuration: TimeInterval = 5
    ) {
        self.splitAngle = splitAngle
        self.confirmationTime = confirmationTime
        self.minimumSpeed = minimumSpeed
        self.minimumDistance = minimumDistance
        self.minimumDuration = minimumDuration
    }

    public static func forSport(_ sport: Sport) -> RunSegmenter {
        var s = RunSegmenter()
        s.minimumSpeed = max(1.0, sport.thresholds.movingSpeed)
        switch sport {
        case .sail:
            // Keelboats hold a heading for a long time and turn slowly.
            s.confirmationTime = 8
            s.minimumDistance = 150
            s.minimumDuration = 30
        case .sup, .kayak:
            s.splitAngle = 60
            s.minimumDistance = 25
        case .downwindSUP, .prone:
            // Bumps mean constant small course changes; only a real direction
            // change should count.
            s.splitAngle = 60
            s.confirmationTime = 5
            s.minimumDistance = 60
        default:
            break
        }
        return s
    }

    // MARK: - Segment

    public func segment(_ track: Track) -> [Run] {
        guard track.count >= 3 else { return [] }

        var runs: [Run] = []
        var runStart: Int?
        var headingAccumulator = CircularAccumulator()
        var deviationSince: TimeInterval?

        func closeRun(at endIndex: Int) {
            guard let start = runStart, endIndex > start else {
                runStart = nil
                headingAccumulator = CircularAccumulator()
                deviationSince = nil
                return
            }
            if let run = makeRun(index: runs.count, from: start, to: endIndex, in: track) {
                runs.append(run)
            }
            runStart = nil
            headingAccumulator = CircularAccumulator()
            deviationSince = nil
        }

        for i in 0..<track.count {
            let moving = track.speed[i] >= minimumSpeed

            guard moving else {
                closeRun(at: i - 1)
                continue
            }

            guard let start = runStart else {
                runStart = i
                headingAccumulator = CircularAccumulator()
                headingAccumulator.add(track.course[i], weight: 1)
                deviationSince = nil
                continue
            }

            let mean = headingAccumulator.mean ?? track.course[i]
            let deviation = Geo.angleSeparation(mean, track.course[i])

            if deviation > splitAngle {
                if let since = deviationSince {
                    if track.elapsed[i] - since >= confirmationTime {
                        // Commit the split at the point the deviation began, so
                        // the turn itself belongs to neither run.
                        let splitIndex = track.index(atElapsed: since) ?? (i - 1)
                        closeRun(at: max(start, splitIndex))
                        runStart = i
                        headingAccumulator = CircularAccumulator()
                        headingAccumulator.add(track.course[i], weight: 1)
                    }
                } else {
                    deviationSince = track.elapsed[i]
                }
            } else {
                deviationSince = nil
                // Weight by distance travelled so a fast straight section
                // dominates the mean over a slow wobbly one.
                let step = i > 0 ? track.cumulativeDistance[i] - track.cumulativeDistance[i - 1] : 1
                headingAccumulator.add(track.course[i], weight: max(0.1, step))
            }
        }
        closeRun(at: track.count - 1)

        return runs
    }

    // MARK: - Run construction

    private func makeRun(index: Int, from start: Int, to end: Int, in track: Track) -> Run? {
        guard end > start, start >= 0, end < track.count else { return nil }

        let distance = track.cumulativeDistance[end] - track.cumulativeDistance[start]
        let duration = track.elapsed[end] - track.elapsed[start]
        guard distance >= minimumDistance, duration >= minimumDuration else { return nil }

        var accumulator = CircularAccumulator()
        var maxSpeed = 0.0
        for i in start...end {
            maxSpeed = max(maxSpeed, track.speed[i])
            let step = i > start ? track.cumulativeDistance[i] - track.cumulativeDistance[i - 1] : 0
            accumulator.add(track.course[i], weight: max(0.1, step))
        }

        let a = track.points[start].coordinate
        let b = track.points[end].coordinate
        // Straightness: how much of the distance travelled turned into progress.
        let straightness = distance > 0 ? min(1, Geo.distance(a, b) / distance) : 0

        return Run(
            index: index,
            startIndex: start,
            endIndex: end,
            startElapsed: track.elapsed[start],
            endElapsed: track.elapsed[end],
            distance: distance,
            averageSpeed: duration > 0 ? distance / duration : 0,
            maxSpeed: maxSpeed,
            meanHeading: accumulator.mean ?? Geo.bearing(from: a, to: b),
            straightness: straightness,
            startCoordinate: a,
            endCoordinate: b
        )
    }
}

/// Running circular mean, so headings can be averaged incrementally without
/// keeping every sample and without the 359°/1° wraparound bug.
struct CircularAccumulator {
    private var x = 0.0
    private var y = 0.0
    private(set) var totalWeight = 0.0

    mutating func add(_ degrees: Double, weight: Double = 1) {
        let r = degrees * .pi / 180
        x += weight * cos(r)
        y += weight * sin(r)
        totalWeight += weight
    }

    var mean: Double? {
        guard totalWeight > 0, x != 0 || y != 0 else { return nil }
        return Geo.normalizeDegrees(atan2(y, x) * 180 / .pi)
    }

    /// Concentration of the headings, 0–1. Near 1 means they all agree.
    var concentration: Double {
        guard totalWeight > 0 else { return 0 }
        return min(1, sqrt(x * x + y * y) / totalWeight)
    }
}
