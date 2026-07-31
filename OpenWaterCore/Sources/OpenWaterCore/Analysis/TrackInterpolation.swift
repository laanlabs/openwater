import Foundation

/// Continuous-domain access to a track.
///
/// A 1 Hz track is a set of samples, but the metrics we want are defined on
/// continuous intervals ("the fastest 500 m", "the best 10 seconds"). Snapping
/// those to sample boundaries costs real accuracy: at 20 knots a whole second of
/// slop is 10 m, which is 2 % of a 500 m run. So every window metric is computed
/// against these interpolated accessors instead.
///
/// Within a sample interval, speed is assumed constant — which makes distance
/// linear in time and time linear in distance, so the interpolation is exact
/// with respect to the recorded data rather than an approximation of it.
extension Track {

    /// Cumulative distance in metres at an arbitrary elapsed time, clamped to
    /// the recording.
    public func distance(atElapsed t: TimeInterval) -> Double {
        guard !isEmpty else { return 0 }
        if t <= elapsed[0] { return cumulativeDistance[0] }
        if t >= elapsed[count - 1] { return cumulativeDistance[count - 1] }

        let i = index(atElapsed: t) ?? 0
        guard i + 1 < count else { return cumulativeDistance[i] }
        let span = elapsed[i + 1] - elapsed[i]
        guard span > 0 else { return cumulativeDistance[i] }
        let f = (t - elapsed[i]) / span
        return cumulativeDistance[i] + f * (cumulativeDistance[i + 1] - cumulativeDistance[i])
    }

    /// The earliest elapsed time at which cumulative distance reaches `d`.
    ///
    /// "Earliest" matters when the rider was stopped: the distance is flat over
    /// an interval, and for the *end* of a run we want the moment the line was
    /// crossed, not the moment they finally moved again.
    public func earliestTime(atDistance d: Double) -> TimeInterval {
        guard !isEmpty else { return 0 }
        if d <= cumulativeDistance[0] { return elapsed[0] }
        if d >= cumulativeDistance[count - 1] { return elapsed[count - 1] }

        // First index whose cumulative distance is >= d.
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulativeDistance[mid] >= d { hi = mid } else { lo = mid + 1 }
        }
        guard lo > 0 else { return elapsed[0] }
        let span = cumulativeDistance[lo] - cumulativeDistance[lo - 1]
        guard span > 0 else { return elapsed[lo] }
        let f = (d - cumulativeDistance[lo - 1]) / span
        return elapsed[lo - 1] + f * (elapsed[lo] - elapsed[lo - 1])
    }

    /// The latest elapsed time at which cumulative distance is still `d`.
    ///
    /// The mirror image of `earliestTime`: for the *start* of a run we want the
    /// last moment before the rider left the line, so a preceding stop is not
    /// charged against the run.
    public func latestTime(atDistance d: Double) -> TimeInterval {
        guard !isEmpty else { return 0 }
        if d <= cumulativeDistance[0] {
            // Skip any leading stationary period.
            var i = 0
            while i + 1 < count && cumulativeDistance[i + 1] <= d { i += 1 }
            return elapsed[i]
        }
        if d >= cumulativeDistance[count - 1] { return elapsed[count - 1] }

        // Last index whose cumulative distance is <= d.
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulativeDistance[mid] <= d { lo = mid } else { hi = mid - 1 }
        }
        guard lo + 1 < count else { return elapsed[lo] }
        let span = cumulativeDistance[lo + 1] - cumulativeDistance[lo]
        guard span > 0 else { return elapsed[lo] }
        let f = (d - cumulativeDistance[lo]) / span
        return elapsed[lo] + f * (elapsed[lo + 1] - elapsed[lo])
    }

    /// Interpolated position at an arbitrary elapsed time.
    public func coordinate(atElapsed t: TimeInterval) -> Geo.Coordinate? {
        guard !isEmpty else { return nil }
        if t <= elapsed[0] { return points[0].coordinate }
        if t >= elapsed[count - 1] { return points[count - 1].coordinate }
        let i = index(atElapsed: t) ?? 0
        guard i + 1 < count else { return points[i].coordinate }
        let span = elapsed[i + 1] - elapsed[i]
        guard span > 0 else { return points[i].coordinate }
        let f = (t - elapsed[i]) / span
        let a = points[i], b = points[i + 1]
        // Linear in lat/lon: over a 1 s hop the great-circle correction is
        // sub-millimetre, so this is exact enough and far cheaper than slerp.
        return Geo.Coordinate(
            latitude: a.latitude + f * (b.latitude - a.latitude),
            longitude: a.longitude + f * (b.longitude - a.longitude)
        )
    }

    /// Interpolated instantaneous speed at an arbitrary elapsed time.
    public func speed(atElapsed t: TimeInterval) -> Double {
        guard !isEmpty else { return 0 }
        if t <= elapsed[0] { return speed[0] }
        if t >= elapsed[count - 1] { return speed[count - 1] }
        let i = index(atElapsed: t) ?? 0
        guard i + 1 < count else { return speed[i] }
        let span = elapsed[i + 1] - elapsed[i]
        guard span > 0 else { return speed[i] }
        let f = (t - elapsed[i]) / span
        return speed[i] + f * (speed[i + 1] - speed[i])
    }

    /// Coordinates covering an elapsed-time interval, with interpolated
    /// endpoints so a highlighted run starts and ends exactly where it should.
    public func coordinates(fromElapsed t0: TimeInterval, toElapsed t1: TimeInterval) -> [Geo.Coordinate] {
        guard !isEmpty, t1 >= t0 else { return [] }
        var result: [Geo.Coordinate] = []
        if let c = coordinate(atElapsed: t0) { result.append(c) }
        for i in 0..<count where elapsed[i] > t0 && elapsed[i] < t1 {
            result.append(points[i].coordinate)
        }
        if let c = coordinate(atElapsed: t1) { result.append(c) }
        return result
    }

    /// The worst (largest) speed accuracy reported inside a time interval, or
    /// `nil` if the receiver never reported one.
    ///
    /// Records are gated on this: a peak that only exists in a stretch where the
    /// receiver admitted ±10 m/s of doubt is not a peak.
    public func worstSpeedAccuracy(fromElapsed t0: TimeInterval, toElapsed t1: TimeInterval) -> Double? {
        var worst: Double?
        for i in 0..<count where elapsed[i] >= t0 && elapsed[i] <= t1 {
            guard let sa = points[i].speedAccuracy, sa >= 0 else { continue }
            worst = max(worst ?? 0, sa)
        }
        return worst
    }

    /// Longest gap between consecutive fixes inside a time interval.
    public func largestGap(fromElapsed t0: TimeInterval, toElapsed t1: TimeInterval) -> TimeInterval {
        var largest: TimeInterval = 0
        var previous: TimeInterval?
        for i in 0..<count where elapsed[i] >= t0 && elapsed[i] <= t1 {
            if let p = previous { largest = max(largest, elapsed[i] - p) }
            previous = elapsed[i]
        }
        return largest
    }
}
