import Foundation

/// What the rider achieved at each angle to the wind.
///
/// This is the picture nobody else draws well, and for wing and parawing it is
/// the whole game: the sport is not "how fast", it is "how fast at what angle,
/// and can you do it on both tacks".
public struct PolarAnalysis: Hashable, Sendable, Codable {

    public let wind: Wind

    /// One entry per true-wind-angle bin, both tacks folded together for the
    /// classic polar shape.
    public let bins: [Bin]

    /// Bins kept separate by tack, which is where the interesting asymmetry
    /// lives — almost everyone is measurably worse on one side.
    public let portBins: [Bin]
    public let starboardBins: [Bin]

    /// Best velocity made good upwind, m/s, and the angle it was achieved at.
    public let bestUpwindVMG: VMGResult?

    /// Best velocity made good downwind, m/s, and the angle.
    public let bestDownwindVMG: VMGResult?

    /// Angle between the mean port and starboard *upwind* headings — how tight
    /// a zig-zag you can hold going up.
    public let tackingAngle: Double?

    /// The same downwind.
    public let gybingAngle: Double?

    /// Closest angle to the wind sustained for a meaningful stretch.
    public let bestUpwindAngle: Double?

    /// Deepest angle sustained downwind.
    public let deepestDownwindAngle: Double?

    /// 0–1. 1 means the two tacks performed identically.
    public let symmetry: Double

    /// Which tack was faster, and by how much as a fraction.
    public let weakerTack: Tack?
    public let tackSpeedDelta: Double

    /// Distance sailed on each point of sail.
    public let distanceByPoint: [PointOfSail: Double]

    /// Mean course held upwind on each tack, degrees true. These are the two
    /// legs of the zig-zag; `tackingAngle` is the separation between them.
    /// Optional twice over: a session may never go upwind on a tack, and
    /// summaries stored before these fields existed decode without them.
    public var portUpwindHeading: Double?
    public var starboardUpwindHeading: Double?
    public var portDownwindHeading: Double?
    public var starboardDownwindHeading: Double?

    /// The realistic VMG: best net progress dead upwind over a full beat.
    ///
    /// The per-bin VMG above answers "what could this gear do at its best
    /// angle" — one tack, best bin, no tacking cost. This answers the question
    /// riders actually argue about: over your best kilometre of working to
    /// windward, gybes and wobbles included, how fast did you actually climb
    /// the course? It is measured as net displacement along the wind axis per
    /// unit time, over the best stretch of at least a kilometre of sailing in
    /// which *both* tacks carry real distance — a one-tack reach with a lucky
    /// wind shift cannot win it.
    public var beat: BothTacksVMG?

    /// The same measured dead downwind.
    public var broadRun: BothTacksVMG?

    public struct BothTacksVMG: Hashable, Sendable, Codable {
        /// Net speed made good along the wind axis, m/s.
        public let vmg: Double
        /// Where the stretch sits in the session.
        public let startElapsed: TimeInterval
        public let endElapsed: TimeInterval
        /// Sailed path length, metres — at least the required minimum.
        public let distance: Double
        /// Fraction of that distance on port tack.
        public let portShare: Double

        public init(vmg: Double, startElapsed: TimeInterval, endElapsed: TimeInterval,
                    distance: Double, portShare: Double) {
            self.vmg = vmg
            self.startElapsed = startElapsed
            self.endElapsed = endElapsed
            self.distance = distance
            self.portShare = portShare
        }
    }

    /// The mean angle off the wind held upwind on a tack, degrees.
    public func upwindAngle(_ tack: Tack) -> Double? {
        let heading = tack == .port ? portUpwindHeading : starboardUpwindHeading
        return heading.map { abs(Geo.angleDelta(from: wind.directionFrom, to: $0)) }
    }

    /// The mean angle short of dead downwind held on a tack, degrees from the
    /// wind direction (so 180 is a dead run).
    public func downwindAngle(_ tack: Tack) -> Double? {
        let heading = tack == .port ? portDownwindHeading : starboardDownwindHeading
        return heading.map { abs(Geo.angleDelta(from: wind.directionFrom, to: $0)) }
    }

    public struct Bin: Hashable, Sendable, Codable, Identifiable {
        /// Centre of the bin in degrees. For the folded polar this is `0...180`;
        /// for the per-tack polars it is signed.
        public let angle: Double
        /// Best speed achieved in this bin, m/s.
        public let maxSpeed: Double
        /// 90th percentile — a more honest "what you can actually hold" than the
        /// single best sample, which is often a GPS artefact.
        public let p90Speed: Double
        public let medianSpeed: Double
        /// Distance sailed in this bin, metres. Thin bins are unreliable.
        public let distance: Double
        public let duration: TimeInterval

        public var id: Double { angle }

        /// Whether enough was sailed here to draw a line through it.
        public var isSubstantial: Bool { distance >= 100 }

        public init(
            angle: Double, maxSpeed: Double, p90Speed: Double, medianSpeed: Double,
            distance: Double, duration: TimeInterval
        ) {
            self.angle = angle
            self.maxSpeed = maxSpeed
            self.p90Speed = p90Speed
            self.medianSpeed = medianSpeed
            self.distance = distance
            self.duration = duration
        }
    }

    public struct VMGResult: Hashable, Sendable, Codable {
        /// Velocity made good, m/s, always positive.
        public let vmg: Double
        /// The true wind angle it was achieved at.
        public let angle: Double
        /// Boat speed at that angle.
        public let speed: Double
        public let tack: Tack

        public init(vmg: Double, angle: Double, speed: Double, tack: Tack) {
            self.vmg = vmg
            self.angle = angle
            self.speed = speed
            self.tack = tack
        }
    }
}

/// Builds a `PolarAnalysis` from a track and a known wind.
public struct PolarBuilder: Sendable {

    /// Bin width in degrees.
    public var binWidth: Double

    /// Samples slower than this are excluded — a stopped rider has an angle but
    /// it means nothing.
    public var minimumSpeed: Double

    /// A bin needs at least this much distance before it contributes to VMG and
    /// angle conclusions, so one lucky sample cannot define your best angle.
    public var minimumBinDistance: Double

    public init(binWidth: Double = 5, minimumSpeed: Double = 2.0, minimumBinDistance: Double = 60) {
        self.binWidth = binWidth
        self.minimumSpeed = minimumSpeed
        self.minimumBinDistance = minimumBinDistance
    }

    public func build(track: Track, wind: Wind) -> PolarAnalysis {
        // Collect per-sample observations bucketed by signed TWA.
        var signedBuckets: [Int: Bucket] = [:]
        var foldedBuckets: [Int: Bucket] = [:]
        var distanceByPoint: [PointOfSail: Double] = [:]

        var portUpwind = CircularAccumulator()
        var starboardUpwind = CircularAccumulator()
        var portDownwind = CircularAccumulator()
        var starboardDownwind = CircularAccumulator()

        var bestUpwind: PolarAnalysis.VMGResult?
        var bestDownwind: PolarAnalysis.VMGResult?
        var bestUpwindAngle: Double?
        var deepestDownwindAngle: Double?

        var portDistance = 0.0, portSpeedDistance = 0.0
        var starboardDistance = 0.0, starboardSpeedDistance = 0.0

        for i in 1..<max(1, track.count) {
            let step = track.cumulativeDistance[i] - track.cumulativeDistance[i - 1]
            let dt = track.elapsed[i] - track.elapsed[i - 1]
            let speed = track.speed[i]
            guard step > 0, speed >= minimumSpeed else { continue }

            let heading = track.course[i]
            let twa = wind.trueWindAngle(heading: heading)
            let tack: Tack = twa < 0 ? .starboard : .port
            let point = PointOfSail(trueWindAngle: twa)

            distanceByPoint[point, default: 0] += step

            let signedBin = Int((twa / binWidth).rounded())
            signedBuckets[signedBin, default: Bucket()].add(speed: speed, distance: step, duration: dt)

            let foldedBin = Int((abs(twa) / binWidth).rounded())
            foldedBuckets[foldedBin, default: Bucket()].add(speed: speed, distance: step, duration: dt)

            switch tack {
            case .port:
                portDistance += step
                portSpeedDistance += speed * step
                if point.isUpwind { portUpwind.add(heading, weight: step) }
                if point.isDownwind { portDownwind.add(heading, weight: step) }
            case .starboard:
                starboardDistance += step
                starboardSpeedDistance += speed * step
                if point.isUpwind { starboardUpwind.add(heading, weight: step) }
                if point.isDownwind { starboardDownwind.add(heading, weight: step) }
            }
        }

        // Per-bin statistics.
        let folded = foldedBuckets
            .map { PolarAnalysis.Bin(bucket: $1, angle: Double($0) * binWidth) }
            .sorted { $0.angle < $1.angle }
        let portBins = signedBuckets
            .filter { $0.key > 0 }
            .map { PolarAnalysis.Bin(bucket: $1, angle: Double($0) * binWidth) }
            .sorted { $0.angle < $1.angle }
        let starboardBins = signedBuckets
            .filter { $0.key < 0 }
            .map { PolarAnalysis.Bin(bucket: $1, angle: Double($0) * binWidth) }
            .sorted { $0.angle < $1.angle }

        // VMG and extreme angles, using the p90 of each substantial bin rather
        // than its single best sample.
        for (bin, bucket) in signedBuckets {
            guard bucket.distance >= minimumBinDistance else { continue }
            let angle = Double(bin) * binWidth
            let speed = bucket.percentile(0.9)
            let tack: Tack = angle < 0 ? .starboard : .port
            let vmg = speed * cos(angle * .pi / 180)

            if vmg > 0 {
                if bestUpwind == nil || vmg > bestUpwind!.vmg {
                    bestUpwind = .init(vmg: vmg, angle: angle, speed: speed, tack: tack)
                }
                if bestUpwindAngle == nil || abs(angle) < abs(bestUpwindAngle!) {
                    bestUpwindAngle = angle
                }
            } else {
                if bestDownwind == nil || -vmg > bestDownwind!.vmg {
                    bestDownwind = .init(vmg: -vmg, angle: angle, speed: speed, tack: tack)
                }
                if deepestDownwindAngle == nil || abs(angle) > abs(deepestDownwindAngle!) {
                    deepestDownwindAngle = angle
                }
            }
        }

        // Tacking and gybing angles — the separation between the mean headings
        // held on the two tacks.
        let tackingAngle: Double? = {
            guard let p = portUpwind.mean, let s = starboardUpwind.mean,
                  portUpwind.totalWeight > minimumBinDistance,
                  starboardUpwind.totalWeight > minimumBinDistance else { return nil }
            return Geo.angleSeparation(p, s)
        }()
        let gybingAngle: Double? = {
            guard let p = portDownwind.mean, let s = starboardDownwind.mean,
                  portDownwind.totalWeight > minimumBinDistance,
                  starboardDownwind.totalWeight > minimumBinDistance else { return nil }
            return Geo.angleSeparation(p, s)
        }()

        // Tack symmetry: compare mean speed on each tack, and how evenly the
        // distance was shared. Someone who only ever goes one way is not
        // symmetric, they are avoiding their bad side.
        let portMean = portDistance > 0 ? portSpeedDistance / portDistance : 0
        let starboardMean = starboardDistance > 0 ? starboardSpeedDistance / starboardDistance : 0
        let speedSymmetry: Double = {
            let hi = max(portMean, starboardMean)
            guard hi > 0 else { return 1 }
            return min(portMean, starboardMean) / hi
        }()
        let distanceSymmetry: Double = {
            let total = portDistance + starboardDistance
            guard total > 0 else { return 1 }
            return 1 - abs(portDistance - starboardDistance) / total
        }()
        let symmetry = 0.7 * speedSymmetry + 0.3 * distanceSymmetry

        let weaker: Tack? = {
            guard portDistance > 0, starboardDistance > 0,
                  abs(portMean - starboardMean) > 0.05 else { return nil }
            return portMean < starboardMean ? .port : .starboard
        }()

        var analysis = PolarAnalysis(
            wind: wind,
            bins: folded,
            portBins: portBins,
            starboardBins: starboardBins,
            bestUpwindVMG: bestUpwind,
            bestDownwindVMG: bestDownwind,
            tackingAngle: tackingAngle,
            gybingAngle: gybingAngle,
            bestUpwindAngle: bestUpwindAngle,
            deepestDownwindAngle: deepestDownwindAngle,
            symmetry: max(0, min(1, symmetry)),
            weakerTack: weaker,
            tackSpeedDelta: max(portMean, starboardMean) > 0
                ? abs(portMean - starboardMean) / max(portMean, starboardMean)
                : 0,
            distanceByPoint: distanceByPoint
        )
        analysis.portUpwindHeading = portUpwind.totalWeight > minimumBinDistance ? portUpwind.mean : nil
        analysis.starboardUpwindHeading = starboardUpwind.totalWeight > minimumBinDistance ? starboardUpwind.mean : nil
        analysis.portDownwindHeading = portDownwind.totalWeight > minimumBinDistance ? portDownwind.mean : nil
        analysis.starboardDownwindHeading = starboardDownwind.totalWeight > minimumBinDistance ? starboardDownwind.mean : nil

        let both = BothTacksVMGFinder().find(track: track, wind: wind)
        analysis.beat = both.beat
        analysis.broadRun = both.run
        return analysis
    }
}

/// Finds the best genuine beat and run — net progress along the wind axis
/// with both tacks carrying weight.
///
/// The idea comes straight from riders comparing parawing upwind numbers: a
/// "best VMG" built from each tack's best moment separately is fiction when
/// the wind shifts mid-session, because both tacks look brilliant against a
/// wind neither was sailed in. Requiring one continuous stretch with real
/// distance on both tacks makes the number survivable in an argument: it is
/// what the rider's position actually did, tack cost and all.
struct BothTacksVMGFinder {

    /// Sailed path a stretch must cover before it counts.
    var minimumDistance: Double = 1000

    /// Least share of that path either tack may carry. Half-and-half is the
    /// ideal beat; a quarter keeps asymmetric-but-real zig-zags eligible
    /// while still excluding the one-gybe reach.
    var minimumTackShare: Double = 0.25

    func find(track: Track, wind: Wind) -> (beat: PolarAnalysis.BothTacksVMG?, run: PolarAnalysis.BothTacksVMG?) {
        let n = track.count
        guard n >= 3 else { return (nil, nil) }

        // Per-step: sailed distance, distance on port, and displacement along
        // the wind axis (positive toward where the wind comes from), all as
        // prefix sums so any window is O(1).
        let toWind = wind.directionFrom * Double.pi / 180
        let axisEast = sin(toWind), axisNorth = cos(toWind)
        let metresPerDegree = 111_320.0

        var sailed = [0.0], port = [0.0], upAxis = [0.0]
        sailed.reserveCapacity(n); port.reserveCapacity(n); upAxis.reserveCapacity(n)
        for i in 1..<n {
            let step = track.cumulativeDistance[i] - track.cumulativeDistance[i - 1]
            let a = track.points[i - 1], b = track.points[i]
            let dE = (b.longitude - a.longitude) * metresPerDegree * cos(a.latitude * .pi / 180)
            let dN = (b.latitude - a.latitude) * metresPerDegree
            let twa = wind.trueWindAngle(heading: track.course[i])
            sailed.append(sailed[i - 1] + step)
            port.append(port[i - 1] + (twa >= 0 ? step : 0))
            upAxis.append(upAxis[i - 1] + dE * axisEast + dN * axisNorth)
        }

        var beat: PolarAnalysis.BothTacksVMG?
        var run: PolarAnalysis.BothTacksVMG?

        // For each start, the shortest window that satisfies the distance —
        // the two-pointer never retreats, so the whole scan is O(n).
        var j = 0
        for i in 0..<(n - 1) {
            if j <= i { j = i + 1 }
            while j < n, sailed[j] - sailed[i] < minimumDistance { j += 1 }
            guard j < n else { break }

            let path = sailed[j] - sailed[i]
            let dt = track.elapsed[j] - track.elapsed[i]
            guard dt > 0, path > 0 else { continue }

            let portShare = (port[j] - port[i]) / path
            guard portShare >= minimumTackShare, portShare <= 1 - minimumTackShare else { continue }

            let vmg = (upAxis[j] - upAxis[i]) / dt
            let candidate = PolarAnalysis.BothTacksVMG(
                vmg: abs(vmg),
                startElapsed: track.elapsed[i],
                endElapsed: track.elapsed[j],
                distance: path,
                portShare: portShare
            )
            if vmg > 0 {
                if candidate.vmg > (beat?.vmg ?? 0) { beat = candidate }
            } else if vmg < 0 {
                if candidate.vmg > (run?.vmg ?? 0) { run = candidate }
            }
        }
        return (beat, run)
    }
}

/// Distance-weighted speed samples for one angular bin.
struct Bucket {
    private(set) var samples: [(speed: Double, weight: Double)] = []
    private(set) var distance: Double = 0
    private(set) var duration: TimeInterval = 0
    private(set) var maxSpeed: Double = 0

    mutating func add(speed: Double, distance d: Double, duration dt: TimeInterval) {
        samples.append((speed, d))
        distance += d
        duration += dt
        maxSpeed = max(maxSpeed, speed)
    }

    /// Distance-weighted percentile. Weighting by distance rather than by sample
    /// count matters: at a fixed sample rate, fast sections contribute fewer
    /// samples per metre, so an unweighted percentile is biased slow.
    func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty, distance > 0 else { return 0 }
        let sorted = samples.sorted { $0.speed < $1.speed }
        let target = distance * p
        var accumulated = 0.0
        for s in sorted {
            accumulated += s.weight
            if accumulated >= target { return s.speed }
        }
        return sorted.last?.speed ?? 0
    }
}

extension PolarAnalysis.Bin {
    init(bucket: Bucket, angle: Double) {
        self.init(
            angle: angle,
            maxSpeed: bucket.maxSpeed,
            p90Speed: bucket.percentile(0.9),
            medianSpeed: bucket.percentile(0.5),
            distance: bucket.distance,
            duration: bucket.duration
        )
    }
}
