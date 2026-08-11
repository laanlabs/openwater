import Foundation

/// The wind for a session.
///
/// Direction is always the meteorological convention: the direction the wind is
/// coming *from*. A northerly is 0°.
public struct Wind: Hashable, Sendable, Codable {

    /// Degrees the wind is coming from, 0–360.
    public var directionFrom: Double

    /// Wind speed in m/s, if the user supplied it. Never inferred — a track
    /// cannot tell you wind strength without a boat polar, and pretending
    /// otherwise would be a lie dressed up as a feature.
    public var speed: Double?

    /// Gust in m/s, when a source supplied one. Same contract as `speed`:
    /// a forecast or a station can say it, a track never can. The difference
    /// between steady 18 and 10–30 cycling is the difference between a
    /// session and a swim, and it deserves better than living only in the
    /// forecast screens.
    public var gust: Double?

    /// How the direction was arrived at.
    public var source: Source

    /// 0–1 for an estimate; always 1 for a manual entry.
    public var confidence: Double

    /// Whether a usable wind strength is known.
    ///
    /// A session very often has a direction and no speed: the direction can be
    /// estimated from the track's own shape, and the strength never can. Every
    /// screen that wants to say so was writing its own `speed == nil || speed
    /// == 0` check, and a zero is the same absence as a nil here — nobody rides
    /// in no wind and then records it.
    public var hasSpeed: Bool {
        guard let speed else { return false }
        return speed > 0.1
    }

    public enum Source: String, Sendable, Codable {
        /// Inferred from an upwind/downwind track structure. The good case.
        case estimatedBidirectional
        /// Inferred from a one-way run assumed to be downwind. Weaker.
        case estimatedDownwindOnly
        /// The rider typed it in.
        case manual
        /// Supplied by an external observation or forecast.
        case external

        public var displayName: String {
            switch self {
            case .estimatedBidirectional: "Estimated from track"
            case .estimatedDownwindOnly: "Estimated (downwind run)"
            case .manual: "Entered manually"
            case .external: "Observed"
            }
        }

        public var isEstimate: Bool {
            self == .estimatedBidirectional || self == .estimatedDownwindOnly
        }
    }

    public init(directionFrom: Double, speed: Double? = nil, gust: Double? = nil,
                source: Source, confidence: Double) {
        self.directionFrom = Geo.normalizeDegrees(directionFrom)
        self.speed = speed
        self.gust = gust
        self.source = source
        self.confidence = max(0, min(1, confidence))
    }

    /// True wind angle for a heading, in `-180...180`.
    ///
    /// `0` is pointing straight into the wind, `±180` is dead downwind.
    /// **Positive is port tack** (wind over the port side), negative starboard.
    public func trueWindAngle(heading: Double) -> Double {
        Geo.angleDelta(from: directionFrom, to: heading)
    }

    /// Velocity made good: the component of speed along the wind axis.
    /// Positive is progress upwind, negative is progress downwind.
    public func vmg(speed: Double, heading: Double) -> Double {
        speed * cos(trueWindAngle(heading: heading) * .pi / 180)
    }

    /// VMG treated as a magnitude toward whichever end of the course the rider
    /// is working — what you actually want to maximise on a given leg.
    public func vmgMagnitude(speed: Double, heading: Double) -> Double {
        abs(vmg(speed: speed, heading: heading))
    }
}

/// Infers the wind direction from the shape of the track.
///
/// The insight is that a wind-powered rider's heading distribution is not
/// arbitrary — it is *shaped by* the wind:
///
/// - there is a no-go sector straight upwind that essentially no distance is
///   sailed in, and
/// - the rest of the distribution is close to symmetric about the wind axis,
///   because tacking and gybing produce mirrored pairs of headings.
///
/// So we score every candidate wind direction on those two properties and take
/// the best. This needs no weather API, works offline, works retroactively on an
/// imported file from years ago, and is honest about its own confidence.
///
/// A pure downwind run has no such structure — everything is on one heading. That
/// case is detected separately and handled by assuming the obvious.
public struct WindEstimator: Sendable {

    /// Bin width for the heading histogram, degrees.
    public var binWidth: Double

    /// Half-width of the no-go sector used in scoring, degrees.
    public var noGoHalfAngle: Double

    /// Ignore samples slower than this — a drifting rider's heading says
    /// nothing about the wind.
    public var minimumSpeed: Double

    /// Above this heading concentration the track is treated as one-directional.
    public var unimodalThreshold: Double

    public init(
        binWidth: Double = 5,
        noGoHalfAngle: Double = 32,
        minimumSpeed: Double = 2.0,
        unimodalThreshold: Double = 0.82
    ) {
        self.binWidth = binWidth
        self.noGoHalfAngle = noGoHalfAngle
        self.minimumSpeed = minimumSpeed
        self.unimodalThreshold = unimodalThreshold
    }

    // MARK: - Estimate

    public func estimate(from track: Track) -> Wind? {
        guard track.count >= 10 else { return nil }

        let binCount = Int((360 / binWidth).rounded())
        var histogram = [Double](repeating: 0, count: binCount)
        var accumulator = CircularAccumulator()
        var totalDistance = 0.0

        for i in 1..<track.count {
            let step = track.cumulativeDistance[i] - track.cumulativeDistance[i - 1]
            guard step > 0, track.speed[i] >= minimumSpeed else { continue }
            let bin = Int(Geo.normalizeDegrees(track.course[i]) / binWidth) % binCount
            histogram[bin] += step
            accumulator.add(track.course[i], weight: step)
            totalDistance += step
        }
        guard totalDistance > 100 else { return nil }

        // One-directional? Then there is no upwind structure to exploit.
        if accumulator.concentration >= unimodalThreshold, let mean = accumulator.mean {
            // A rider going one way for a whole session is going downwind. The
            // wind is therefore behind them, i.e. coming from where they started.
            return Wind(
                directionFrom: Geo.normalizeDegrees(mean + 180),
                source: .estimatedDownwindOnly,
                // Deliberately capped: this is an assumption, not a measurement.
                confidence: min(0.6, accumulator.concentration * 0.65)
            )
        }

        // Score every candidate direction at bin resolution, then refine.
        var bestScore = -Double.infinity
        var bestDirection = 0.0
        for bin in 0..<binCount {
            let direction = Double(bin) * binWidth
            let s = score(direction: direction, histogram: histogram, total: totalDistance, binCount: binCount)
            if s > bestScore {
                bestScore = s
                bestDirection = direction
            }
        }

        // Refine to 1° around the winning bin.
        var refined = bestDirection
        var refinedScore = bestScore
        var offset = -binWidth
        while offset <= binWidth {
            let direction = Geo.normalizeDegrees(bestDirection + offset)
            let s = score(direction: direction, histogram: histogram, total: totalDistance, binCount: binCount)
            if s > refinedScore {
                refinedScore = s
                refined = direction
            }
            offset += 1
        }

        // A score near 1 means a clean no-go sector and a well-mirrored
        // distribution. Below about 0.35 the track simply is not telling us.
        //
        // Capped below 1 on purpose. A perfect score means the *track* is
        // unambiguous, not that the wind is known — a rider sailing tidy
        // reciprocals in a thirty-degree shift produces a beautiful
        // distribution around a direction that was never true for more than
        // a few minutes. Certainty belongs to a number somebody typed in, and
        // the warning logic reads this value to decide how loudly to hedge.
        let confidence = max(0, min(0.9, (refinedScore - 0.2) / 0.65))
        guard confidence > 0.12 else { return nil }

        return Wind(
            directionFrom: refined,
            source: .estimatedBidirectional,
            confidence: confidence
        )
    }

    // MARK: - Scoring

    /// How well a candidate wind direction explains the heading distribution.
    ///
    /// Two terms, both in 0–1:
    /// - **emptiness** of the no-go sector, and
    /// - **mirror symmetry** of the remaining distribution about the wind axis.
    ///
    /// Symmetry alone is not enough: it is maximised by *any* axis of a
    /// symmetric distribution, including the one 90° away. The no-go term is
    /// what breaks that tie, because only the true wind direction has a hole
    /// in it.
    func score(direction: Double, histogram: [Double], total: Double, binCount: Int) -> Double {
        var noGoDistance = 0.0
        var asymmetry = 0.0
        var mirrored = 0.0

        for bin in 0..<binCount {
            let heading = Double(bin) * binWidth + binWidth / 2
            let twa = Geo.angleDelta(from: direction, to: heading)
            if abs(twa) <= noGoHalfAngle {
                noGoDistance += histogram[bin]
            }

            // Compare this bin against its mirror image across the wind axis.
            let mirrorHeading = Geo.normalizeDegrees(direction - twa)
            let mirrorBin = Int(mirrorHeading / binWidth) % binCount
            let a = histogram[bin]
            let b = histogram[mirrorBin]
            asymmetry += abs(a - b)
            mirrored += a + b
        }

        let emptiness = 1 - min(1, noGoDistance / total)
        let symmetry = mirrored > 0 ? 1 - min(1, asymmetry / mirrored) : 0

        // Weighted toward emptiness: a hole straight upwind is the single most
        // reliable fingerprint of the wind axis, and it is the term that is
        // robust when a session is lopsided (more downwind than upwind sailed).
        return 0.62 * emptiness + 0.38 * symmetry
    }
}
