import Foundation

/// Turns raw fixes into an analysis-ready `Track`.
///
/// The order of operations matters and is not arbitrary:
/// 1. sort and de-duplicate by time — imported files are not always ordered;
/// 2. reject structurally invalid fixes;
/// 3. reject accuracy outliers;
/// 4. reject teleports, which are the classic GPS failure on the water;
/// 5. build the distance and elapsed prefix arrays;
/// 6. resolve a speed channel, preferring Doppler;
/// 7. smooth it with a Kalman filter weighted by the receiver's own confidence;
/// 8. resolve a course channel;
/// 9. score the whole thing.
public struct TrackBuilder: Sendable {

    public struct Options: Sendable {
        /// Fixes worse than this in metres are dropped — *preferred*, not
        /// absolute. See `accuracyOutlierSigmas`, which can relax it.
        public var maxHorizontalAccuracy: Double

        /// How far past the recording's own spread a fix has to sit before the
        /// accuracy gate calls it an outlier, in robust standard deviations.
        ///
        /// This exists because of a real session: forty-eight minutes of
        /// parawinging came back as 189 points in 22 short bursts, separated by
        /// gaps of up to three minutes, four of the bursts being a single fix.
        /// The receiver had been running at 1 Hz throughout. What removed the
        /// rest was this filter — a flat 12-metre limit meeting a phone that
        /// spent the session with a body between it and the sky, where 15–40
        /// metres is simply what a receiver reports. Nine tenths of the session
        /// was deleted in silence, and because legs longer than
        /// `maxBridgedGap` contribute no distance, most of the distance went
        /// with it.
        ///
        /// The mistake was treating an accuracy limit as an absolute standard
        /// when its job is an outlier test: throw out the fixes that are bad
        /// *for this recording*. So the limit becomes the looser of the strict
        /// value and `median + sigmas × MAD` of the accuracies actually
        /// reported, capped by `accuracyCeiling`. Never tighter than the strict
        /// value — a clean recording is judged exactly as before, because its
        /// median and spread are both small.
        ///
        /// The median and MAD rather than mean and standard deviation
        /// specifically because the thing being detected — a minority of very
        /// bad fixes — is the thing that would corrupt a mean-based estimate
        /// into accepting itself.
        public var accuracyOutlierSigmas: Double

        /// The furthest the gate will ever be relaxed, in metres.
        ///
        /// Past this a fix is not merely soft, it is wrong: at foiling speeds a
        /// 1 Hz sample covers ~25 m, so a 60-metre fix cannot say which way the
        /// rider was going. Keeping the session honest stops here — beyond it
        /// the holes are the truthful answer.
        public var accuracyCeiling: Double
        /// Speeds above this in m/s are treated as receiver spikes.
        public var maxPlausibleSpeed: Double
        /// Reject a fix if reaching it from the previous one would require more
        /// than this speed, in m/s. Set generously — a legitimate 1 Hz gap after
        /// a dropout looks like a teleport otherwise, so this is only applied
        /// when the time gap is short.
        public var maxImpliedSpeed: Double
        /// Time gaps longer than this are treated as dropouts rather than as
        /// real travel, so the implied-speed check is skipped across them.
        public var dropoutGap: TimeInterval
        /// A leg longer than this contributes no distance.
        ///
        /// Across a real hole in the recording — a receiver dropout, or a
        /// stretch the rider cut out of the middle — the straight line between
        /// the two surviving fixes is not a path anybody took. Counting it adds
        /// distance that was never sailed and hands the speed windows a leg at
        /// a speed nobody did, which is worse than admitting the gap. Thirty
        /// seconds is far beyond any normal 1 Hz interruption, so ordinary
        /// tracks are unaffected.
        public var maxBridgedGap: TimeInterval
        /// Run the Kalman filter over the speed channel.
        public var smoothSpeed: Bool
        /// Speed accuracy worse than this in m/s means the sample cannot support
        /// a record claim; the value is still used, but flagged.
        public var maxSpeedAccuracyForRecords: Double

        public init(
            maxHorizontalAccuracy: Double = 12,
            accuracyOutlierSigmas: Double = 3,
            accuracyCeiling: Double = 60,
            maxPlausibleSpeed: Double = 35,
            maxImpliedSpeed: Double = 45,
            dropoutGap: TimeInterval = 5,
            maxBridgedGap: TimeInterval = 30,
            smoothSpeed: Bool = true,
            maxSpeedAccuracyForRecords: Double = 2.0
        ) {
            self.maxHorizontalAccuracy = maxHorizontalAccuracy
            self.accuracyOutlierSigmas = accuracyOutlierSigmas
            self.accuracyCeiling = accuracyCeiling
            self.maxPlausibleSpeed = maxPlausibleSpeed
            self.maxBridgedGap = maxBridgedGap
            self.maxImpliedSpeed = maxImpliedSpeed
            self.dropoutGap = dropoutGap
            self.smoothSpeed = smoothSpeed
            self.maxSpeedAccuracyForRecords = maxSpeedAccuracyForRecords
        }

        public static func forSport(_ sport: Sport) -> Options {
            let t = sport.thresholds
            return Options(
                maxHorizontalAccuracy: t.maxHorizontalAccuracy,
                maxPlausibleSpeed: t.maxPlausibleSpeed,
                maxImpliedSpeed: t.maxPlausibleSpeed * 1.5
            )
        }

        /// Permissive settings for imported third-party files, which often lack
        /// accuracy channels entirely.
        public static let lenient = Options(
            maxHorizontalAccuracy: 50,
            maxPlausibleSpeed: 40,
            maxImpliedSpeed: 60
        )
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Build

    public func build(from rawPoints: [TrackPoint]) -> Track {
        let offered = rawPoints.count
        var rejections: [Rejection] = []

        // 1. Order by time, dropping exact duplicates.
        var sorted = rawPoints.sorted { $0.timestamp < $1.timestamp }
        var deduped: [TrackPoint] = []
        deduped.reserveCapacity(sorted.count)
        for p in sorted {
            if let last = deduped.last, last.timestamp == p.timestamp {
                rejections.append(.init(timestamp: p.timestamp, reason: .duplicateTimestamp))
                continue
            }
            deduped.append(p)
        }
        sorted = deduped

        // 2 & 3. Structural validity and accuracy.
        let accuracyLimit = resolvedAccuracyLimit(for: sorted)
        var accepted: [TrackPoint] = []
        accepted.reserveCapacity(sorted.count)
        for p in sorted {
            guard p.hasValidPosition else {
                rejections.append(.init(timestamp: p.timestamp, reason: .invalidPosition))
                continue
            }
            // A receiver that reports no accuracy at all (imported GPX) is given
            // the benefit of the doubt rather than having its whole track binned.
            if p.horizontalAccuracy > accuracyLimit {
                rejections.append(.init(
                    timestamp: p.timestamp,
                    reason: .poorAccuracy,
                    value: p.horizontalAccuracy
                ))
                continue
            }
            if let s = p.speed, s > options.maxPlausibleSpeed {
                rejections.append(.init(
                    timestamp: p.timestamp,
                    reason: .impossibleSpeed,
                    value: s
                ))
                continue
            }
            accepted.append(p)
        }

        // 4. Teleport rejection, iterated because one bad fix can shadow the next.
        accepted = rejectTeleports(accepted, into: &rejections)

        guard accepted.count >= 2 else {
            return Track(
                points: accepted,
                elapsed: accepted.isEmpty ? [] : [0],
                cumulativeDistance: accepted.isEmpty ? [] : [0],
                speed: accepted.isEmpty ? [] : [0],
                course: accepted.isEmpty ? [] : [0],
                speedSource: .derived,
                quality: .unknown,
                rejections: rejections
            )
        }

        // 5. Prefix arrays.
        let t0 = accepted[0].timestamp
        var elapsed = [TimeInterval](repeating: 0, count: accepted.count)
        var cumulative = [Double](repeating: 0, count: accepted.count)
        for i in 1..<accepted.count {
            elapsed[i] = accepted[i].timestamp.timeIntervalSince(t0)
            let gap = accepted[i].timestamp.timeIntervalSince(accepted[i - 1].timestamp)
            let step = gap <= options.maxBridgedGap
                ? Geo.distance(accepted[i - 1].coordinate, accepted[i].coordinate)
                : 0
            cumulative[i] = cumulative[i - 1] + step
        }

        // 6 & 7. Speed channel.
        let (speed, source) = resolveSpeed(points: accepted, elapsed: elapsed, cumulative: cumulative)

        // 8. Course channel.
        let course = resolveCourse(points: accepted)

        // 9. Quality.
        let quality = scoreQuality(
            points: accepted,
            elapsed: elapsed,
            offered: offered,
            rejected: rejections.count,
            source: source,
            accuracyLimit: accuracyLimit
        )

        return Track(
            points: accepted,
            elapsed: elapsed,
            cumulativeDistance: cumulative,
            speed: speed,
            course: course,
            speedSource: source,
            quality: quality,
            rejections: rejections
        )
    }

    // MARK: - Teleports

    /// Drops fixes that would require an impossible speed to reach.
    ///
    /// Only applied across short gaps: after a genuine dropout the receiver
    /// legitimately reappears a long way away, and binning that point would
    /// discard the rest of the session.
    private func rejectTeleports(_ points: [TrackPoint], into rejections: inout [Rejection]) -> [TrackPoint] {
        guard points.count > 2 else { return points }
        var result: [TrackPoint] = [points[0]]
        result.reserveCapacity(points.count)

        for i in 1..<points.count {
            let prev = result[result.count - 1]
            let cur = points[i]
            let dt = cur.timestamp.timeIntervalSince(prev.timestamp)
            guard dt > 0, dt <= options.dropoutGap else {
                result.append(cur)
                continue
            }
            let d = Geo.distance(prev.coordinate, cur.coordinate)
            let implied = d / dt
            if implied > options.maxImpliedSpeed {
                rejections.append(.init(
                    timestamp: cur.timestamp,
                    reason: .impossibleSpeed,
                    value: implied
                ))
                continue
            }
            result.append(cur)
        }
        return result
    }

    // MARK: - Speed

    private func resolveSpeed(
        points: [TrackPoint],
        elapsed: [TimeInterval],
        cumulative: [Double]
    ) -> ([Double], SpeedSource) {
        let n = points.count
        var raw = [Double](repeating: 0, count: n)
        var accuracies = [Double?](repeating: nil, count: n)
        var dopplerCount = 0

        for i in 0..<n {
            if points[i].hasValidSpeed, let s = points[i].speed {
                raw[i] = s
                accuracies[i] = points[i].speedAccuracy
                dopplerCount += 1
            } else {
                // Central difference where possible — it is a full sample less
                // laggy than a backward difference, which matters at 1 Hz.
                let lo = max(0, i - 1)
                let hi = min(n - 1, i + 1)
                let dt = elapsed[hi] - elapsed[lo]
                raw[i] = dt > 0 ? (cumulative[hi] - cumulative[lo]) / dt : 0
                accuracies[i] = nil
            }
            raw[i] = min(max(0, raw[i]), options.maxPlausibleSpeed)
        }

        let source: SpeedSource =
            dopplerCount == n ? .doppler :
            dopplerCount == 0 ? .derived : .mixed

        guard options.smoothSpeed, n > 1 else { return (raw, source) }

        // Forward pass, then a backward pass and average the two. A single
        // forward Kalman lags by roughly one time constant; running it in both
        // directions and averaging cancels that lag, which keeps peak timings
        // aligned with the map.
        var forward = [Double](repeating: 0, count: n)
        var filter = KalmanSpeedFilter(
            // Position-derived speed is far noisier than Doppler, so trust the
            // model more and the measurement less in that case.
            defaultMeasurementNoise: source == .derived ? 2.0 : 0.5
        )
        for i in 0..<n {
            let dt = i == 0 ? 1 : elapsed[i] - elapsed[i - 1]
            forward[i] = filter.update(measurement: raw[i], accuracy: accuracies[i], dt: dt)
        }

        var backward = [Double](repeating: 0, count: n)
        filter.reset()
        for i in stride(from: n - 1, through: 0, by: -1) {
            let dt = i == n - 1 ? 1 : elapsed[i + 1] - elapsed[i]
            backward[i] = filter.update(measurement: raw[i], accuracy: accuracies[i], dt: dt)
        }

        var smoothed = [Double](repeating: 0, count: n)
        for i in 0..<n {
            smoothed[i] = min(max(0, (forward[i] + backward[i]) / 2), options.maxPlausibleSpeed)
        }
        return (smoothed, source)
    }

    // MARK: - Course

    private func resolveCourse(points: [TrackPoint]) -> [Double] {
        let n = points.count
        var course = [Double](repeating: 0, count: n)
        var lastKnown: Double = 0

        for i in 0..<n {
            if let c = points[i].course, c >= 0, c.isFinite {
                course[i] = Geo.normalizeDegrees(c)
                lastKnown = course[i]
            } else {
                // Derive over a two-sample baseline: at 1 Hz a single-sample
                // bearing is dominated by position noise.
                let lo = max(0, i - 1)
                let hi = min(n - 1, i + 1)
                if lo != hi,
                   Geo.distance(points[lo].coordinate, points[hi].coordinate) > 0.5 {
                    course[i] = Geo.bearing(from: points[lo].coordinate, to: points[hi].coordinate)
                    lastKnown = course[i]
                } else {
                    // Stationary: hold the last heading rather than emitting noise.
                    course[i] = lastKnown
                }
            }
        }
        return course
    }

    // MARK: - Accuracy gate

    /// The accuracy limit this particular recording will be held to.
    ///
    /// The preferred limit, or `median + sigmas × MAD` of the accuracies this
    /// recording actually reported if that is looser, capped at
    /// `accuracyCeiling`. Never tighter than the preferred limit: a clean
    /// recording is judged exactly as strictly as it was before.
    ///
    /// A short recording is left alone entirely. Ten fixes cannot establish
    /// what a receiver's normal spread is, and a session that merely starts
    /// badly should not talk the gate open for the rest of itself.
    func resolvedAccuracyLimit(for points: [TrackPoint]) -> Double {
        let strict = options.maxHorizontalAccuracy
        guard options.accuracyOutlierSigmas > 0,
              options.accuracyCeiling > strict else { return strict }

        // Only fixes that reported an accuracy have a say. A negative value is
        // the receiver saying the position itself is invalid, and those are
        // rejected on their own account a few lines below.
        let reported = points
            .filter { $0.hasValidPosition }
            .map(\.horizontalAccuracy)
            .sorted()
        guard reported.count >= 10 else { return strict }

        let median = reported[reported.count / 2]
        // Median absolute deviation, scaled to be comparable to a standard
        // deviation for normally distributed data.
        let deviations = reported.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2] * 1.4826

        return min(max(strict, median + options.accuracyOutlierSigmas * mad),
                   options.accuracyCeiling)
    }

    // MARK: - Quality

    private func scoreQuality(
        points: [TrackPoint],
        elapsed: [TimeInterval],
        offered: Int,
        rejected: Int,
        source: SpeedSource,
        accuracyLimit: Double
    ) -> TrackQuality {
        let n = points.count
        var accuracySum = 0.0
        var accuracyCount = 0
        var worst = 0.0
        var doppler = 0

        for p in points {
            if p.horizontalAccuracy >= 0 {
                accuracySum += p.horizontalAccuracy
                accuracyCount += 1
                worst = max(worst, p.horizontalAccuracy)
            }
            if p.hasValidSpeed { doppler += 1 }
        }

        let meanAccuracy = accuracyCount > 0 ? accuracySum / Double(accuracyCount) : 0
        let duration = elapsed.last ?? 0
        let fixRate = duration > 0 ? Double(n) / duration : 0

        // Dropouts: gaps beyond 3× the median interval.
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(max(0, n - 1))
        for i in 1..<max(1, n) { deltas.append(elapsed[i] - elapsed[i - 1]) }
        let median = deltas.isEmpty ? 1 : deltas.sorted()[deltas.count / 2]
        let gapThreshold = max(3 * median, 3.0)
        var dropoutCount = 0
        var dropoutDuration: TimeInterval = 0
        for d in deltas where d > gapThreshold {
            dropoutCount += 1
            dropoutDuration += d
        }

        let dopplerCoverage = n > 0 ? Double(doppler) / Double(n) : 0
        let rejectionRate = offered > 0 ? Double(rejected) / Double(offered) : 0

        // Weighted score. Doppler coverage is weighted heavily because without
        // it the peak-speed numbers are simply less defensible.
        let accuracyScore = accuracyCount == 0
            ? 55.0                                            // unknown, assume mediocre
            : max(0, min(1, (15 - meanAccuracy) / 12)) * 100
        let rateScore = max(0, min(1, fixRate / 1.0)) * 100
        let dropoutScore = duration > 0
            ? max(0, 1 - dropoutDuration / duration) * 100
            : 100
        let dopplerScore = dopplerCoverage * 100
        let rejectionScore = max(0, 1 - rejectionRate * 2) * 100

        let score =
            accuracyScore * 0.30 +
            dopplerScore * 0.30 +
            dropoutScore * 0.20 +
            rateScore * 0.10 +
            rejectionScore * 0.10

        return TrackQuality(
            score: min(100, max(0, score)),
            meanAccuracy: meanAccuracy,
            worstAccuracy: worst,
            fixRate: fixRate,
            dropoutCount: dropoutCount,
            dropoutDuration: dropoutDuration,
            dopplerCoverage: dopplerCoverage,
            rejectionRate: rejectionRate,
            accuracyLimitUsed: accuracyLimit
        )
    }
}
