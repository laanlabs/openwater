import Foundation

/// Evaluates `SpeedCategory` rules against a track.
///
/// Every algorithm here is exact with respect to the recorded data rather than
/// a sampled approximation. The trick that makes that affordable is that
/// cumulative distance is piecewise linear in time, so the sliding-window
/// average is piecewise linear too, and a piecewise-linear function attains its
/// extremes at its breakpoints. Evaluating only at breakpoints gives the true
/// continuous maximum in O(n) instead of scanning a fine time grid.
public struct SpeedAnalyzer: Sendable {

    /// Speed accuracy beyond this, in m/s, drags a result's confidence down.
    public var speedAccuracyLimit: Double

    /// A fix gap this long inside a window makes the result untrustworthy.
    public var maxGapInWindow: TimeInterval

    /// How far a window's average may exceed the fastest speed the receiver
    /// reported inside it before it is treated as position noise.
    ///
    /// Every figure here is measured across the ground, from positions. That is
    /// right for a distance — a metre is a metre however noisy the fix — and
    /// wrong for a speed, because a position that jumps invents one. A session
    /// recorded in two apps made the case: forty-four metres between two fixes
    /// one second apart, while the receiver's own Doppler said 2.4 knots at
    /// both ends. The two-second best came out at 46 knots on a wingfoil
    /// session whose fastest instant was 15.
    ///
    /// So the receiver gets the final word on speed. A window cannot average
    /// faster than the quickest moment inside it, plus a margin for the
    /// smoothing and for a genuine peak falling between two fixes. Distance is
    /// left alone: capping that would put us under every other app on the same
    /// track, and a metre really is a metre.
    public var dopplerTolerance: Double

    public init(
        speedAccuracyLimit: Double = 2.0,
        maxGapInWindow: TimeInterval = 5,
        dopplerTolerance: Double = 1.15
    ) {
        self.speedAccuracyLimit = speedAccuracyLimit
        self.maxGapInWindow = maxGapInWindow
        self.dopplerTolerance = dopplerTolerance
    }

    // MARK: - The receiver's veto

    /// Fastest reported speed in any range of a track, in constant time.
    ///
    /// Built once per category and queried once per candidate window. The
    /// obvious version — scan the range each time — is O(n) per candidate and
    /// there are 2n candidates, which turned a three-hour track from a second
    /// into a minute. A sparse table costs one O(n log n) build and answers
    /// every query with two lookups.
    struct ReportedSpeedIndex {
        private let elapsed: [TimeInterval]
        /// `levels[k][i]` is the maximum over `2^k` samples starting at `i`.
        private let levels: [[Double]]
        let isUsable: Bool

        init(track: Track) {
            elapsed = track.elapsed
            var reported = [Double](repeating: -1, count: track.count)
            var any = false
            for i in 0..<track.count where track.points[i].hasValidSpeed {
                if let v = track.points[i].speed, v >= 0 {
                    reported[i] = v
                    any = true
                }
            }
            // A track with no Doppler channel has nothing independent to check
            // positions against — most imported GPX. Deriving a ceiling from
            // the same positions would be circular, so the veto stands down.
            isUsable = any && track.speedSource != .derived

            guard !reported.isEmpty else { levels = []; return }
            var built = [reported]
            var width = 1
            while width * 2 <= reported.count {
                let previous = built[built.count - 1]
                let span = reported.count - width * 2 + 1
                var next = [Double](repeating: -1, count: max(0, span))
                for i in 0..<max(0, span) {
                    next[i] = max(previous[i], previous[i + width])
                }
                built.append(next)
                width *= 2
            }
            levels = built
        }

        /// Fastest reported speed at or between two elapsed times, or nil when
        /// no fix in the range carried one.
        func peak(from t0: TimeInterval, to t1: TimeInterval) -> Double? {
            guard isUsable, !levels.isEmpty else { return nil }
            let lower = lowerBound(t0)
            let upper = upperBound(t1)
            guard lower <= upper, lower >= 0, upper < elapsed.count else { return nil }
            let length = upper - lower + 1
            let k = 63 - UInt64(length).leadingZeroBitCount        // floor(log2)
            guard k < levels.count else { return nil }
            let level = levels[k]
            let secondStart = upper - (1 << k) + 1
            guard lower < level.count, secondStart >= 0, secondStart < level.count else { return nil }
            let best = max(level[lower], level[secondStart])
            return best >= 0 ? best : nil
        }

        private func lowerBound(_ t: TimeInterval) -> Int {
            var lo = 0, hi = elapsed.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if elapsed[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        private func upperBound(_ t: TimeInterval) -> Int {
            var lo = 0, hi = elapsed.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if elapsed[mid] <= t { lo = mid + 1 } else { hi = mid }
            }
            return lo - 1
        }
    }

    /// The most a window may claim, given what the receiver measured in it.
    ///
    /// `.infinity` when there is nothing to check against, which leaves the
    /// figure exactly as the positions gave it.
    func speedCeiling(_ index: ReportedSpeedIndex, from t0: TimeInterval, to t1: TimeInterval) -> Double {
        guard let peak = index.peak(from: t0, to: t1), peak > 0 else { return .infinity }
        return peak * dopplerTolerance
    }

    // MARK: - Entry point

    public func evaluate(_ category: SpeedCategory, on track: Track) -> SpeedResult {
        switch category {
        case .time(let seconds):
            bestTimeWindow(seconds: seconds, on: track, category: category)
        case .multiTime(let count, let seconds):
            bestNonOverlappingWindows(count: count, seconds: seconds, on: track, category: category)
        case .distance(let metres):
            bestDistanceWindow(metres: metres, on: track, category: category)
        case .alpha(let metres, let proximity):
            bestAlpha(metres: metres, proximity: proximity, on: track, category: category)
        }
    }

    public func evaluate(_ categories: [SpeedCategory], on track: Track) -> [SpeedResult] {
        categories.map { evaluate($0, on: track) }
    }

    // MARK: - Best average over a fixed duration

    /// Maximises `(distance(t) − distance(t − D)) / D` over all `t`.
    ///
    /// Breakpoints of that function are the sample times and the sample times
    /// shifted forward by `D`, so both families are tested.
    func bestTimeWindow(seconds: TimeInterval, on track: Track, category: SpeedCategory) -> SpeedResult {
        guard track.count >= 2 else {
            return .unavailable(category, reason: .trackTooShort)
        }
        guard track.duration >= seconds, seconds > 0 else {
            return .unavailable(category, reason: .notEnoughDuration)
        }

        let reported = ReportedSpeedIndex(track: track)
        var bestDistance = -1.0
        var bestSpeed = -1.0
        var bestEnd: TimeInterval = 0

        func consider(end: TimeInterval) {
            let start = end - seconds
            guard start >= track.elapsed[0], end <= track.duration else { return }
            let d = track.distance(atElapsed: end) - track.distance(atElapsed: start)
            // Compared on the capped speed rather than raw distance, so the
            // window that wins is the genuinely fastest one and not merely the
            // one containing the worst fix.
            let capped = min(d / seconds, speedCeiling(reported, from: start, to: end))
            if capped > bestSpeed {
                bestSpeed = capped
                bestDistance = d
                bestEnd = end
            }
        }

        for t in track.elapsed {
            consider(end: t)              // window ending on a sample
            consider(end: t + seconds)    // window starting on a sample
        }

        guard bestDistance >= 0 else {
            return .unavailable(category, reason: .notEnoughDuration)
        }

        let start = bestEnd - seconds
        let speed = min(bestDistance / seconds, speedCeiling(reported, from: start, to: bestEnd))
        let segment = SpeedResult.Segment(
            startElapsed: start, endElapsed: bestEnd,
            distance: bestDistance, speed: speed
        )
        return SpeedResult(
            category: category,
            speed: speed,
            startElapsed: start,
            endElapsed: bestEnd,
            distance: bestDistance,
            segments: [segment],
            isValid: true,
            confidence: confidence(for: track, from: start, to: bestEnd)
        )
    }

    // MARK: - Average of the n best non-overlapping windows

    /// The `5 × 10 s` rule.
    ///
    /// A greedy "take the fastest window, then the fastest that does not
    /// overlap it" is the obvious approach and it is *not* optimal — a slightly
    /// slower first pick can leave room for two much faster ones. Since this is
    /// the metric people are ranked on, it is worth doing properly: candidates
    /// are sorted by end time and solved with weighted interval scheduling, which
    /// gives the true maximum-sum set of `count` non-overlapping windows.
    func bestNonOverlappingWindows(
        count: Int,
        seconds: TimeInterval,
        on track: Track,
        category: SpeedCategory
    ) -> SpeedResult {
        guard count > 0, seconds > 0 else {
            return .unavailable(category, reason: .notEnoughSegments)
        }
        guard track.count >= 2 else {
            return .unavailable(category, reason: .trackTooShort)
        }
        guard track.duration >= seconds * Double(count) else {
            return .unavailable(category, reason: .notEnoughDuration)
        }

        let reported = ReportedSpeedIndex(track: track)
        // Candidate windows at every breakpoint, as (start, end, distance).
        var candidates: [(start: TimeInterval, end: TimeInterval, distance: Double)] = []
        candidates.reserveCapacity(track.count * 2)
        var seen = Set<Int64>()

        func add(end: TimeInterval) {
            let start = end - seconds
            guard start >= track.elapsed[0], end <= track.duration else { return }
            // De-duplicate to the millisecond; the two breakpoint families
            // overlap heavily on a uniform 1 Hz track.
            let key = Int64((end * 1000).rounded())
            guard seen.insert(key).inserted else { return }
            let raw = track.distance(atElapsed: end) - track.distance(atElapsed: start)
            // Capped here rather than at the end: the scheduler maximises total
            // distance, so an uncapped noisy window would be *chosen* and then
            // corrected, displacing a window that was genuinely faster.
            let ceiling = speedCeiling(reported, from: start, to: end)
            let d = ceiling.isFinite ? min(raw, ceiling * seconds) : raw
            candidates.append((start, end, d))
        }

        for t in track.elapsed {
            add(end: t)
            add(end: t + seconds)
        }
        guard candidates.count >= count else {
            return .unavailable(category, reason: .notEnoughSegments)
        }

        candidates.sort { $0.end < $1.end }
        let n = candidates.count

        // p[i] = index one past the last candidate that ends at or before
        // candidate i starts. Monotonic, so a single sweep finds them all.
        var p = [Int](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            while j < n && candidates[j].end <= candidates[i].start + 1e-9 { j += 1 }
            // j may have overshot for this i; walk back is unnecessary because
            // candidates[i].start is non-decreasing in i.
            p[i] = j
        }

        // dp[k][i] = best total distance using at most k windows from the first i.
        // Rolling over k keeps this to two rows.
        var previous = [Double](repeating: 0, count: n + 1)
        var choice = [[Int]](repeating: [Int](repeating: -1, count: n + 1), count: count + 1)

        for k in 1...count {
            var current = [Double](repeating: 0, count: n + 1)
            for i in 1...n {
                let skip = current[i - 1]
                let take = candidates[i - 1].distance + previous[p[i - 1]]
                if take > skip {
                    current[i] = take
                    choice[k][i] = i - 1
                } else {
                    current[i] = skip
                    choice[k][i] = choice[k][i - 1]
                }
            }
            previous = current
        }

        // Reconstruct.
        var chosen: [Int] = []
        var k = count
        var i = n
        while k > 0, i > 0 {
            let pick = choice[k][i]
            guard pick >= 0 else { break }
            chosen.append(pick)
            i = p[pick]
            k -= 1
        }
        guard chosen.count == count else {
            return .unavailable(category, reason: .notEnoughSegments)
        }
        chosen.reverse()

        let segments = chosen.map { idx -> SpeedResult.Segment in
            let c = candidates[idx]
            return SpeedResult.Segment(
                startElapsed: c.start,
                endElapsed: c.end,
                distance: c.distance,
                speed: c.distance / seconds
            )
        }
        let meanSpeed = segments.reduce(0) { $0 + $1.speed } / Double(segments.count)
        let start = segments.first?.startElapsed ?? 0
        let end = segments.last?.endElapsed ?? 0

        // Confidence is the weakest link across the segments, not the average —
        // one garbage window invalidates the set.
        let conf = segments
            .map { confidence(for: track, from: $0.startElapsed, to: $0.endElapsed) }
            .min() ?? 0

        return SpeedResult(
            category: category,
            speed: meanSpeed,
            startElapsed: start,
            endElapsed: end,
            distance: segments.reduce(0) { $0 + $1.distance },
            segments: segments,
            isValid: true,
            confidence: conf
        )
    }

    // MARK: - Best average over a fixed distance

    /// Minimises the time taken to cover `metres`, flying start.
    ///
    /// Time-as-a-function-of-distance is piecewise linear, so again only the
    /// breakpoints matter: each sample considered as the run's start, and each
    /// sample considered as its finish.
    func bestDistanceWindow(metres: Double, on track: Track, category: SpeedCategory) -> SpeedResult {
        guard track.count >= 2 else {
            return .unavailable(category, reason: .trackTooShort)
        }
        guard metres > 0, track.totalDistance >= metres else {
            return .unavailable(category, reason: .notEnoughDistance)
        }

        let reported = ReportedSpeedIndex(track: track)
        var bestSpeed = -1.0
        var bestDuration = Double.infinity
        var bestStart: TimeInterval = 0
        var bestEnd: TimeInterval = 0

        // Compared on capped speed, not on the shortest clock. Picking the
        // quickest run first and capping it afterwards chooses whichever
        // stretch had the worst fix — the one whose distance is most inflated —
        // and then answers with the slow Doppler from inside it. That reported
        // 4.7 knots for a hundred metres on a session averaging eight.
        func consider(start: TimeInterval, end: TimeInterval) {
            guard end > start else { return }
            let duration = end - start
            let capped = min(metres / duration, speedCeiling(reported, from: start, to: end))
            guard capped > bestSpeed else { return }
            bestSpeed = capped
            bestDuration = duration
            bestStart = start
            bestEnd = end
        }

        for d in track.cumulativeDistance {
            // This sample as the start of the run.
            if d + metres <= track.totalDistance {
                consider(
                    start: track.latestTime(atDistance: d),
                    end: track.earliestTime(atDistance: d + metres)
                )
            }
            // This sample as the finish of the run.
            if d - metres >= 0 {
                consider(
                    start: track.latestTime(atDistance: d - metres),
                    end: track.earliestTime(atDistance: d)
                )
            }
        }

        guard bestDuration.isFinite, bestDuration > 0 else {
            return .unavailable(category, reason: .notEnoughDistance)
        }

        let speed = bestSpeed
        let segment = SpeedResult.Segment(
            startElapsed: bestStart, endElapsed: bestEnd,
            distance: metres, speed: speed
        )
        return SpeedResult(
            category: category,
            speed: speed,
            startElapsed: bestStart,
            endElapsed: bestEnd,
            distance: metres,
            segments: [segment],
            isValid: true,
            confidence: confidence(for: track, from: bestStart, to: bestEnd)
        )
    }

    // MARK: - Alpha

    /// Alpha racing: cover `metres` while turning, and finish within
    /// `proximity` metres of where the run began.
    ///
    /// The naive form is O(n²) because every start has to be checked against
    /// every finish. It collapses to O(n) once you notice the finish is
    /// determined by the start: the run is exactly `metres` long, so a single
    /// forward pointer tracks it.
    func bestAlpha(
        metres: Double,
        proximity: Double,
        on track: Track,
        category: SpeedCategory
    ) -> SpeedResult {
        guard track.count >= 3 else {
            return .unavailable(category, reason: .trackTooShort)
        }
        guard track.totalDistance >= metres else {
            return .unavailable(category, reason: .notEnoughDistance)
        }

        let reported = ReportedSpeedIndex(track: track)
        var bestSpeed = -1.0
        var bestDuration = Double.infinity
        var bestStart: TimeInterval = 0
        var bestEnd: TimeInterval = 0
        var sawATurn = false
        var sawAReturn = false

        func consider(startDistance: Double) {
            let endDistance = startDistance + metres
            guard startDistance >= 0, endDistance <= track.totalDistance else { return }

            let startTime = track.latestTime(atDistance: startDistance)
            let endTime = track.earliestTime(atDistance: endDistance)
            let duration = endTime - startTime
            guard duration > 0 else { return }

            // Cheap rejections first — proximity kills most candidates and
            // costs one haversine, while the turn test costs a scan.
            guard let startCoord = track.coordinate(atElapsed: startTime),
                  let endCoord = track.coordinate(atElapsed: endTime) else { return }
            guard Geo.distance(startCoord, endCoord) <= proximity else { return }
            sawAReturn = true

            // Ranked on the speed that survives the veto, not on the raw clock.
            // Picking the quickest lap and capping it afterwards hands the prize
            // to whichever lap had the worst position noise and then answers
            // with the honest Doppler from inside it — a slow lap wearing a fast
            // lap's start and finish.
            let capped = min(metres / duration, speedCeiling(reported, from: startTime, to: endTime))
            guard capped > bestSpeed else { return }
            guard containsTurn(track: track, fromElapsed: startTime, toElapsed: endTime) else { return }
            sawATurn = true

            bestSpeed = capped
            bestDuration = duration
            bestStart = startTime
            bestEnd = endTime
        }

        for d in track.cumulativeDistance {
            consider(startDistance: d)            // this sample as the start
            consider(startDistance: d - metres)   // this sample as the finish
        }

        guard bestDuration.isFinite else {
            let reason: SpeedResult.InvalidReason =
                !sawAReturn ? .didNotReturnToStart :
                !sawATurn ? .noQualifyingTurn : .notEnoughDistance
            return .unavailable(category, reason: reason)
        }

        let speed = bestSpeed
        let segment = SpeedResult.Segment(
            startElapsed: bestStart, endElapsed: bestEnd,
            distance: metres, speed: speed
        )
        return SpeedResult(
            category: category,
            speed: speed,
            startElapsed: bestStart,
            endElapsed: bestEnd,
            distance: metres,
            segments: [segment],
            isValid: true,
            confidence: confidence(for: track, from: bestStart, to: bestEnd)
        )
    }

    /// Whether the heading reverses by at least 90° somewhere in the interval.
    ///
    /// Uses the extremes of the *cumulative* heading change rather than the raw
    /// spread of headings, so an S-bend that wanders 60° each way does not
    /// masquerade as a gybe.
    private func containsTurn(
        track: Track,
        fromElapsed t0: TimeInterval,
        toElapsed t1: TimeInterval,
        minimumChange: Double = 90
    ) -> Bool {
        var cumulative = 0.0
        var minimum = 0.0
        var maximum = 0.0
        var previous: Double?

        for i in 0..<track.count where track.elapsed[i] >= t0 && track.elapsed[i] <= t1 {
            let c = track.course[i]
            if let p = previous {
                cumulative += Geo.angleDelta(from: p, to: c)
                minimum = min(minimum, cumulative)
                maximum = max(maximum, cumulative)
                if maximum - minimum >= minimumChange { return true }
            }
            previous = c
        }
        return false
    }

    // MARK: - Confidence

    /// How much to trust a window: the receiver's own doubt about the speed,
    /// the presence of dropouts, and whether the speed channel is Doppler at all.
    func confidence(for track: Track, from t0: TimeInterval, to t1: TimeInterval) -> Double {
        var score = 1.0

        switch track.speedSource {
        case .doppler: break
        case .mixed: score *= 0.85
        case .derived: score *= 0.7
        }

        if let worst = track.worstSpeedAccuracy(fromElapsed: t0, toElapsed: t1) {
            // Full marks up to the limit, tailing off to zero at 3× the limit.
            let over = max(0, worst - speedAccuracyLimit)
            score *= max(0, 1 - over / (speedAccuracyLimit * 2))
        }

        let gap = track.largestGap(fromElapsed: t0, toElapsed: t1)
        if gap > maxGapInWindow {
            score *= max(0, 1 - (gap - maxGapInWindow) / maxGapInWindow)
        }

        score *= 0.5 + 0.5 * min(1, track.quality.score / 80)

        return max(0, min(1, score))
    }
}
