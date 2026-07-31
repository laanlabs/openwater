import Foundation

/// One glide: a stretch riding the energy of a bump rather than making it.
public struct Glide: Hashable, Sendable, Codable, Identifiable {

    public let id: Int

    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval
    public let startIndex: Int
    public let endIndex: Int

    public let distance: Double
    public let entrySpeed: Double
    public let peakSpeed: Double
    public let exitSpeed: Double
    public let averageSpeed: Double

    /// Pump strokes counted in the effort that set this glide up.
    public let pumpsToEnter: Int?

    /// Whether the rider reached this glide straight from the previous one
    /// without dropping off the foil — the thing you are actually trying to do.
    public let connected: Bool

    public let confidence: Double

    public var duration: TimeInterval { endElapsed - startElapsed }

    /// Speed gained across the glide, m/s. Positive means the bump gave you more
    /// than it took.
    public var speedGain: Double { exitSpeed - entrySpeed }

    public init(
        id: Int, startElapsed: TimeInterval, endElapsed: TimeInterval,
        startIndex: Int, endIndex: Int, distance: Double,
        entrySpeed: Double, peakSpeed: Double, exitSpeed: Double, averageSpeed: Double,
        pumpsToEnter: Int?, connected: Bool, confidence: Double
    ) {
        self.id = id
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.distance = distance
        self.entrySpeed = entrySpeed
        self.peakSpeed = peakSpeed
        self.exitSpeed = exitSpeed
        self.averageSpeed = averageSpeed
        self.pumpsToEnter = pumpsToEnter
        self.connected = connected
        self.confidence = confidence
    }
}

/// What happened on a downwinder.
///
/// Max speed is almost beside the point on a downwind run. The question is how
/// much of it you got for free: how many bumps you caught, how long you rode
/// each, and how often you linked one to the next without dropping.
public struct DownwindSummary: Hashable, Sendable, Codable {

    public let glideCount: Int

    /// Total seconds gliding.
    public let glideTime: TimeInterval

    /// Glide time as a fraction of moving time, 0–1. **The headline number.**
    public let glideFraction: Double

    public let distanceGliding: Double

    public let longestGlide: Glide?
    public let fastestGlide: Glide?

    public let averageGlideDuration: TimeInterval
    public let averageGlideSpeed: Double

    /// Glides entered without an intervening touchdown, as a fraction.
    /// This is your linking rate, and it is the skill ceiling of the sport.
    public let connectionRate: Double

    /// Mean pumps needed to get onto a glide. Lower is better.
    public let averagePumpsPerGlide: Double?

    /// Metres travelled per pump stroke across the session.
    public let distancePerPump: Double?

    /// The dominant swell interval the rider was working, seconds, from the
    /// autocorrelation of the speed trace. Tells you what the ocean was doing.
    public let bumpPeriod: TimeInterval?

    /// Distance ridden with the wing powered up versus riding the swell.
    /// Parawing-relevant, and always an estimate.
    public let poweredDistance: Double?
    public let glidedDistance: Double?

    public let usedMotionData: Bool
    public let confidence: Double

    public init(
        glideCount: Int, glideTime: TimeInterval, glideFraction: Double,
        distanceGliding: Double, longestGlide: Glide?, fastestGlide: Glide?,
        averageGlideDuration: TimeInterval, averageGlideSpeed: Double,
        connectionRate: Double, averagePumpsPerGlide: Double?, distancePerPump: Double?,
        bumpPeriod: TimeInterval?, poweredDistance: Double?, glidedDistance: Double?,
        usedMotionData: Bool, confidence: Double
    ) {
        self.glideCount = glideCount
        self.glideTime = glideTime
        self.glideFraction = glideFraction
        self.distanceGliding = distanceGliding
        self.longestGlide = longestGlide
        self.fastestGlide = fastestGlide
        self.averageGlideDuration = averageGlideDuration
        self.averageGlideSpeed = averageGlideSpeed
        self.connectionRate = connectionRate
        self.averagePumpsPerGlide = averagePumpsPerGlide
        self.distancePerPump = distancePerPump
        self.bumpPeriod = bumpPeriod
        self.poweredDistance = poweredDistance
        self.glidedDistance = glidedDistance
        self.usedMotionData = usedMotionData
        self.confidence = confidence
    }

    public static let none = DownwindSummary(
        glideCount: 0, glideTime: 0, glideFraction: 0, distanceGliding: 0,
        longestGlide: nil, fastestGlide: nil, averageGlideDuration: 0,
        averageGlideSpeed: 0, connectionRate: 0, averagePumpsPerGlide: nil,
        distancePerPump: nil, bumpPeriod: nil, poweredDistance: nil,
        glidedDistance: nil, usedMotionData: false, confidence: 0
    )
}

/// Segments a downwind run into pumping and gliding.
///
/// The cycle has a clear signature. Pumping is *work*: a strong rhythmic
/// component in the accelerometer around 0.5–2 Hz, with speed flat or falling
/// because you are converting effort into just enough lift to stay up. A glide
/// is the opposite: the accelerometer goes quiet and the speed holds or builds
/// as the bump does the work.
///
/// So the discriminator is the pair (pump energy, speed trend), and a glide is
/// a stretch where the rider is flying, not pumping, and not decelerating hard.
///
/// Without motion data the pump term is unavailable and the segmentation falls
/// back to speed alone. That still finds the big glides, but it cannot tell a
/// quiet glide from an efficient pump, so the confidence is reported much lower
/// rather than the result being presented as equivalent.
public struct DownwindAnalyzer: Sendable {

    public var thresholds: SportThresholds

    /// Vertical-acceleration SD above which the rider is considered to be
    /// working, m/s². Below the foil-smoothness threshold but above the noise
    /// floor of a quiet glide.
    public var pumpEnergyThreshold: Double

    /// Minimum duration for a stretch to count as a glide.
    public var minimumGlideDuration: TimeInterval

    /// Speed below which nothing counts.
    public var minimumGlideSpeed: Double

    /// A glide may lose speed at up to this rate and still be a glide; steeper
    /// than that and the bump has passed under you.
    public var maximumDeceleration: Double   // m/s²

    public init(
        thresholds: SportThresholds = SportThresholds.forSport(.downwindSUP),
        pumpEnergyThreshold: Double = 0.9,
        minimumGlideDuration: TimeInterval = 3,
        minimumGlideSpeed: Double = 4.0,
        maximumDeceleration: Double = 0.35
    ) {
        self.thresholds = thresholds
        self.pumpEnergyThreshold = pumpEnergyThreshold
        self.minimumGlideDuration = minimumGlideDuration
        self.minimumGlideSpeed = minimumGlideSpeed
        self.maximumDeceleration = maximumDeceleration
    }

    public static func forSport(_ sport: Sport) -> DownwindAnalyzer {
        var a = DownwindAnalyzer(thresholds: sport.thresholds)
        switch sport {
        case .downwindSUP, .prone:
            a.minimumGlideSpeed = 3.5
        case .wingfoil, .parawing:
            // On a wing the rider is powered, so a "glide" means the wing is
            // depowered and the swell is doing the work. That needs a higher bar.
            a.minimumGlideSpeed = 6.0
            a.minimumGlideDuration = 4
        default:
            break
        }
        return a
    }

    // MARK: - Analyse

    public func analyse(
        track: Track,
        flights: [Flight],
        wind: Wind?,
        movingTime: TimeInterval
    ) -> DownwindSummary {
        guard track.count >= 10 else { return .none }

        let hasMotion = track.points.contains { $0.verticalAccelSD != nil }
        let glides = detectGlides(in: track, flights: flights, hasMotion: hasMotion)

        guard !glides.isEmpty else {
            return DownwindSummary(
                glideCount: 0, glideTime: 0, glideFraction: 0, distanceGliding: 0,
                longestGlide: nil, fastestGlide: nil, averageGlideDuration: 0,
                averageGlideSpeed: 0, connectionRate: 0, averagePumpsPerGlide: nil,
                distancePerPump: nil, bumpPeriod: bumpPeriod(of: track),
                poweredDistance: nil, glidedDistance: nil,
                usedMotionData: hasMotion, confidence: hasMotion ? 0.6 : 0.3
            )
        }

        let glideTime = glides.reduce(0) { $0 + $1.duration }
        let glideDistance = glides.reduce(0) { $0 + $1.distance }
        let connected = glides.filter(\.connected).count

        let pumpCounts = glides.compactMap(\.pumpsToEnter)
        let totalPumps = pumpCounts.reduce(0, +)

        let (powered, glided) = poweredSplit(track: track, wind: wind, glides: glides)

        return DownwindSummary(
            glideCount: glides.count,
            glideTime: glideTime,
            glideFraction: movingTime > 0 ? min(1, glideTime / movingTime) : 0,
            distanceGliding: glideDistance,
            longestGlide: glides.max { $0.duration < $1.duration },
            fastestGlide: glides.max { $0.peakSpeed < $1.peakSpeed },
            averageGlideDuration: glideTime / Double(glides.count),
            averageGlideSpeed: glideTime > 0 ? glideDistance / glideTime : 0,
            // The first glide had nothing to connect from, so it is excluded
            // from the denominator rather than counted as a failure.
            connectionRate: glides.count > 1
                ? Double(connected) / Double(glides.count - 1)
                : 0,
            averagePumpsPerGlide: pumpCounts.isEmpty
                ? nil
                : Double(totalPumps) / Double(pumpCounts.count),
            distancePerPump: totalPumps > 0 ? track.totalDistance / Double(totalPumps) : nil,
            bumpPeriod: bumpPeriod(of: track),
            poweredDistance: powered,
            glidedDistance: glided,
            usedMotionData: hasMotion,
            confidence: hasMotion ? 0.8 : 0.4
        )
    }

    // MARK: - Glide segmentation

    func detectGlides(in track: Track, flights: [Flight], hasMotion: Bool) -> [Glide] {
        let flyingMask = FoilDetector(thresholds: thresholds)
            .flyingMask(flights: flights, count: track.count)
        let requiresFlight = !flights.isEmpty

        // Smoothed acceleration along the track, for the deceleration test.
        var acceleration = [Double](repeating: 0, count: track.count)
        for i in 1..<track.count {
            let dt = track.elapsed[i] - track.elapsed[i - 1]
            acceleration[i] = dt > 0 ? (track.speed[i] - track.speed[i - 1]) / dt : 0
        }
        acceleration = smooth(acceleration, window: 3)

        var isGliding = [Bool](repeating: false, count: track.count)
        for i in 0..<track.count {
            guard track.speed[i] >= minimumGlideSpeed else { continue }
            guard !requiresFlight || flyingMask[i] else { continue }
            guard acceleration[i] >= -maximumDeceleration else { continue }
            if hasMotion, let energy = track.points[i].verticalAccelSD {
                guard energy <= pumpEnergyThreshold else { continue }
            }
            isGliding[i] = true
        }

        // Extract runs.
        var glides: [Glide] = []
        var i = 0
        var previousEndIndex: Int?

        while i < track.count {
            guard isGliding[i] else { i += 1; continue }
            var j = i
            while j + 1 < track.count, isGliding[j + 1] { j += 1 }

            let duration = track.elapsed[j] - track.elapsed[i]
            if duration >= minimumGlideDuration, j > i {
                var peak = 0.0
                for k in i...j { peak = max(peak, track.speed[k]) }
                let distance = track.cumulativeDistance[j] - track.cumulativeDistance[i]

                // Connected if the rider never left the foil since the last glide.
                let connected: Bool = {
                    guard let previous = previousEndIndex, previous < i else { return false }
                    guard requiresFlight else { return true }
                    return (previous...i).allSatisfy { flyingMask[$0] }
                }()

                glides.append(Glide(
                    id: glides.count,
                    startElapsed: track.elapsed[i],
                    endElapsed: track.elapsed[j],
                    startIndex: i,
                    endIndex: j,
                    distance: distance,
                    entrySpeed: track.speed[i],
                    peakSpeed: peak,
                    exitSpeed: track.speed[j],
                    averageSpeed: duration > 0 ? distance / duration : 0,
                    pumpsToEnter: hasMotion
                        ? countPumps(in: track, before: i, since: previousEndIndex)
                        : nil,
                    connected: connected,
                    confidence: hasMotion ? 0.8 : 0.45
                ))
                previousEndIndex = j
            }
            i = j + 1
        }

        return glides
    }

    /// Counts pump strokes in the run-up to a glide.
    ///
    /// A pump is one cycle of the vertical acceleration crossing above and back
    /// below the working threshold, which is a robust proxy for one stroke
    /// without needing a full spectral estimate on a watch.
    private func countPumps(in track: Track, before index: Int, since previous: Int?) -> Int? {
        let start = previous.map { $0 + 1 } ?? max(0, index - 30)
        guard start < index else { return 0 }

        var count = 0
        var above = false
        for i in start..<index {
            guard let energy = track.points[i].verticalAccelSD else { continue }
            if !above, energy > pumpEnergyThreshold {
                above = true
                count += 1
            } else if above, energy < pumpEnergyThreshold * 0.7 {
                above = false
            }
        }
        return count
    }

    // MARK: - Bump period

    /// Dominant period in the speed trace, from its autocorrelation.
    ///
    /// Riding swell modulates speed at the swell's encounter period, so the lag
    /// of the strongest autocorrelation peak in a plausible band is a direct
    /// read of what you were riding.
    func bumpPeriod(of track: Track, band: ClosedRange<TimeInterval> = 3...25) -> TimeInterval? {
        guard track.count >= 60 else { return nil }
        let dt = track.sampleInterval
        guard dt > 0, dt < 5 else { return nil }

        // Detrend so a general slowdown does not swamp the oscillation.
        let mean = track.speed.reduce(0, +) / Double(track.count)
        let signal = track.speed.map { $0 - mean }
        let energy = signal.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }

        let minLag = max(1, Int((band.lowerBound / dt).rounded()))
        let maxLag = min(track.count / 2, Int((band.upperBound / dt).rounded()))
        guard maxLag > minLag else { return nil }

        var bestLag = 0
        var bestValue = 0.0
        for lag in minLag...maxLag {
            var sum = 0.0
            for i in 0..<(signal.count - lag) {
                sum += signal[i] * signal[i + lag]
            }
            let normalised = sum / energy
            if normalised > bestValue {
                bestValue = normalised
                bestLag = lag
            }
        }

        // A weak peak means there was no coherent swell to speak of.
        guard bestValue > 0.15, bestLag > 0 else { return nil }
        return Double(bestLag) * dt
    }

    // MARK: - Powered vs glided

    /// Splits distance into "under power" and "riding the swell".
    ///
    /// A powered rider can hold an angle across or up the wind; a rider purely
    /// riding bumps cannot — they go where the swell goes, which is downwind.
    /// So distance sailed with a true wind angle shallower than a broad reach is
    /// attributed to power, and deep-downwind distance inside a detected glide
    /// is attributed to the swell.
    ///
    /// This is an inference from geometry, not a measurement of the wing, and it
    /// is labelled as such wherever it is shown.
    private func poweredSplit(track: Track, wind: Wind?, glides: [Glide]) -> (Double?, Double?) {
        guard let wind, wind.confidence > 0.3 else { return (nil, nil) }

        var glidingMask = [Bool](repeating: false, count: track.count)
        for g in glides {
            guard g.startIndex >= 0, g.endIndex < track.count else { continue }
            for i in g.startIndex...g.endIndex { glidingMask[i] = true }
        }

        var powered = 0.0
        var glided = 0.0
        for i in 1..<track.count {
            let step = track.cumulativeDistance[i] - track.cumulativeDistance[i - 1]
            guard step > 0 else { continue }
            let twa = abs(wind.trueWindAngle(heading: track.course[i]))
            if twa < 140 {
                powered += step        // holding an angle takes power
            } else if glidingMask[i] {
                glided += step         // deep and free
            } else {
                powered += step
            }
        }
        return (powered, glided)
    }

    // MARK: - Helpers

    private func smooth(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > window else { return values }
        var result = values
        let half = window / 2
        for i in 0..<values.count {
            let lo = max(0, i - half)
            let hi = min(values.count - 1, i + half)
            var sum = 0.0
            for k in lo...hi { sum += values[k] }
            result[i] = sum / Double(hi - lo + 1)
        }
        return result
    }
}
