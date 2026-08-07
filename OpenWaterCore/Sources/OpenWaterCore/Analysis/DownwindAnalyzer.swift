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

    /// Every glide, in time order.
    ///
    /// Kept rather than reduced away, because a glide has a *place*: the map
    /// wants to draw where on the run the rider was catching bumps, and the
    /// aggregates cannot answer that. Flights and jumps are held on
    /// `SessionSummary` alongside their own aggregate structs; glides live
    /// here instead, because this is the analyzer's whole return value and
    /// splitting it would mean changing that for one array.
    /// Optional in storage so archives written before glides were kept still
    /// decode — see the note on `SessionSummary.shape`.
    private let storedGlides: [Glide]?

    public var glides: [Glide] { storedGlides ?? [] }

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
        glides: [Glide] = [],
        glideCount: Int, glideTime: TimeInterval, glideFraction: Double,
        distanceGliding: Double, longestGlide: Glide?, fastestGlide: Glide?,
        averageGlideDuration: TimeInterval, averageGlideSpeed: Double,
        connectionRate: Double, averagePumpsPerGlide: Double?, distancePerPump: Double?,
        bumpPeriod: TimeInterval?, poweredDistance: Double?, glidedDistance: Double?,
        usedMotionData: Bool, confidence: Double
    ) {
        self.storedGlides = glides
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
    ///
    /// Five seconds, from riders: under that it is a nudge off a bit of chop,
    /// not a glide. It was three, and on a choppy day that turned every small
    /// push into an entry in the count.
    public var minimumGlideDuration: TimeInterval

    /// Absolute floor — below this you are drifting, whatever else is true.
    ///
    /// Deliberately low, because it is only a backstop. The test that does the
    /// work is `glideSpeedFraction`, relative to the day.
    public var minimumGlideSpeed: Double

    /// A glide must reach this fraction of the rider's own typical downwind
    /// speed for the session.
    ///
    /// Three quarters, and the number matters more than it looks. The
    /// reference is a *median*, so a fraction near one splits the rider's
    /// riding in half by construction — half of every run is below its own
    /// median, and a continuous glide would be chopped wherever it dipped
    /// under. The floor's job is to exclude stretches where the rider was not
    /// being carried at all: slogging, a water start, drifting. Those sit far
    /// below the median, not just under it.
    ///
    /// Measured against a reported session: at 0.95 a four-kilometre downwind
    /// run came out as 2.8 km of glide, at 0.85 as 3.1 km, and at 0.75 the
    /// whole run. Below 0.75 nothing further changes, and the pump-and-glide
    /// of a SUP downwinder stays ten separate glides throughout, because
    /// pumping happens at about a third of glide speed rather than just under
    /// it.
    ///
    /// Replaces a fixed floor, which was wrong in both directions. Big swell
    /// in light wind gives real glides at speeds a fixed bar rejects; a windy
    /// day makes powered riding fast enough to clear it. What actually
    /// distinguishes a glide is that the water is doing the work — so the
    /// question is whether the rider is going at or above their own pace for
    /// the day, not whether they have passed some absolute number.
    public var glideSpeedFraction: Double

    /// A glide may lose speed at up to this rate and still be a glide; steeper
    /// than that and the bump has passed under you.
    public var maximumDeceleration: Double   // m/s²

    /// How long an interruption a glide can survive, seconds.
    ///
    /// Sample-by-sample tests fragment a continuous ride. One fix dipping under
    /// the speed floor, or one gust-driven deceleration, ends a glide and
    /// starts another — a rider looked at a long unbroken downwind run drawn as
    /// a dozen separate dashes and said, correctly, that it was one glide.
    ///
    /// Bridging is deliberately conservative about *what* it will cross: never
    /// a touchdown, never a stretch where the accelerometer says the rider was
    /// working, and never a stretch sailed back up toward the wind. Those are
    /// the three things that genuinely end a glide, and each is checked before
    /// a gap is closed.
    public var glideGapTolerance: TimeInterval

    /// How much faster a glide has to get, as a fraction of the speed it
    /// started at.
    ///
    /// The test that separates gliding from riding along. Everything else —
    /// fast enough, downwind, not decelerating — a rider holding one speed on
    /// a powered wing passes just as well as a rider being carried. What only
    /// the bump does is *give* you speed: you pump up to it, it picks you up,
    /// and you accelerate. Without a rise there is nothing to say the water
    /// did anything.
    ///
    /// It matters most where the app is otherwise blind. With motion data the
    /// pump-energy test already separates working from gliding; without it,
    /// this is the only thing that does.
    public var minimumSpeedGain: Double

    public init(
        thresholds: SportThresholds = SportThresholds.forSport(.downwindSUP),
        pumpEnergyThreshold: Double = 0.9,
        minimumGlideDuration: TimeInterval? = nil,
        minimumGlideSpeed: Double = 3.0,
        glideSpeedFraction: Double? = nil,
        maximumDeceleration: Double = 0.35,
        minimumSpeedGain: Double? = nil,
        glideGapTolerance: TimeInterval = 20
    ) {
        self.thresholds = thresholds
        self.pumpEnergyThreshold = pumpEnergyThreshold
        self.minimumGlideDuration = minimumGlideDuration ?? thresholds.glideMinimumDuration
        self.minimumGlideSpeed = minimumGlideSpeed
        self.glideSpeedFraction = glideSpeedFraction ?? thresholds.glideSpeedFraction
        self.maximumDeceleration = maximumDeceleration
        self.minimumSpeedGain = minimumSpeedGain ?? thresholds.glideMinimumGain
        self.glideGapTolerance = glideGapTolerance
    }

    /// The analyzer for a sport, honouring the rider's own thresholds.
    ///
    /// See the note on `JumpDetector.forSport`: the glide settings did nothing
    /// for a day because this took the sport's defaults and the caller's
    /// overrides never arrived.
    public static func forSport(_ sport: Sport, thresholds: SportThresholds? = nil) -> DownwindAnalyzer {
        var a = DownwindAnalyzer(thresholds: thresholds ?? sport.thresholds)
        switch sport {
        case .downwindSUP, .prone:
            a.minimumGlideSpeed = 2.5
        case .wingfoil, .parawing:
            // A wing used to need a fixed 6 m/s, then a stricter fraction than
            // other sports, both on the reasoning that a powered rider is fast
            // anyway. Neither survived contact with real sessions: the fixed
            // bar missed glides in big swell and light wind, and the stricter
            // fraction cut a continuous run into pieces. Measuring the rider
            // against their own downwind pace already answers what those were
            // reaching for, so there is nothing to override here.
            break
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
        let glides = detectGlides(in: track, flights: flights, wind: wind, hasMotion: hasMotion)

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
            glides: glides,
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

    /// Close short interruptions so one continuous ride reads as one glide.
    ///
    /// A gap is crossed only when nothing in it says the glide really ended:
    /// the rider stayed on the foil, the accelerometer stayed quiet, and the
    /// track stayed pointed downwind. Where there is no motion data the second
    /// test cannot be applied and is skipped — which is the honest position,
    /// and the reason a session recorded with a watch is worth more here than
    /// an imported file.
    func bridgeInterruptions(
        in isGliding: inout [Bool],
        track: Track,
        wind: Wind?,
        flying: [Bool],
        requiresFlight: Bool,
        hasMotion: Bool
    ) {
        guard glideGapTolerance > 0, track.count > 2 else { return }

        var index = 0
        while index < track.count {
            guard isGliding[index] else { index += 1; continue }
            var end = index
            while end + 1 < track.count, isGliding[end + 1] { end += 1 }

            // Find where gliding resumes.
            var next = end + 1
            while next < track.count, !isGliding[next] { next += 1 }
            guard next < track.count else { break }

            if track.elapsed[next] - track.elapsed[end] <= glideGapTolerance,
               canBridge(from: end, to: next, track: track, wind: wind,
                         flying: flying, requiresFlight: requiresFlight, hasMotion: hasMotion) {
                for k in (end + 1)..<next { isGliding[k] = true }
                // Carry on from the same segment, which is now longer.
            } else {
                index = next
            }
        }
    }

    private func canBridge(
        from end: Int, to next: Int,
        track: Track, wind: Wind?,
        flying: [Bool], requiresFlight: Bool, hasMotion: Bool
    ) -> Bool {
        for k in (end + 1)..<next {
            if requiresFlight, !flying[k] { return false }
            if hasMotion, let energy = track.points[k].verticalAccelSD,
               energy > pumpEnergyThreshold { return false }
            if let wind {
                let heading = track.course[k]
                if Geo.angleSeparation(heading, wind.directionFrom) <= downwindHalfAngle {
                    return false
                }
            }
        }
        return true
    }

    /// The slowest the rider was in the seconds before a glide began.
    ///
    /// Measured against the trough rather than against the glide's own first
    /// sample, which was the first attempt and does not work: a segment only
    /// starts once speed is already above the floor, so entry and peak are
    /// nearly the same number and the "rise" is whatever noise happened to be
    /// left. Comparing to the lull before it asks the question that was
    /// actually meant — you were going *this*, then the bump took you to
    /// *that*.
    func troughBefore(_ index: Int, in track: Track) -> Double {
        let start = track.elapsed[index] - Self.riseWindow
        var trough = track.speed[index]
        var k = index
        while k > 0, track.elapsed[k] >= start {
            trough = min(trough, track.speed[k])
            k -= 1
        }
        return max(trough, 0.1)
    }

    /// How far back to look for the lull before a glide, seconds.
    public static let riseWindow: TimeInterval = 8

    /// The rider's own pace for the session, measured *going downwind*.
    ///
    /// Median rather than mean, because a session is mostly not riding — water
    /// starts, drifting, sitting — and a mean drags the reference toward those.
    ///
    /// Downwind-only, because GPS reports speed over ground and a river does
    /// not care which way you are pointing. A rider reported a long downwind
    /// run against a strong current, and the numbers bore it out: reciprocal
    /// headings differed by about a knot, their median speed *downwind* was
    /// 9.6 knots and *upwind* 11.1, and the whole-session median that set the
    /// glide floor came out at 10.2 — above their typical downwind pace. More
    /// than half of the riding a glide could possibly happen in was below the
    /// bar it had to clear.
    ///
    /// Comparing downwind speed against a downwind reference absorbs that,
    /// and the same correction handles the ordinary case of a rider simply
    /// being quicker on one point of sail than another.
    func typicalRidingSpeed(in track: Track, wind: Wind? = nil) -> Double {
        var downwind: [Double] = []
        var all: [Double] = []
        for i in 0..<track.count where track.speed[i] >= thresholds.movingSpeed {
            all.append(track.speed[i])
            if let wind,
               Geo.angleSeparation(track.course[i], wind.directionFrom) > downwindHalfAngle {
                downwind.append(track.speed[i])
            }
        }
        // Enough downwind riding to describe a pace; otherwise fall back to the
        // whole session rather than to a handful of samples.
        let sample = downwind.count >= 60 ? downwind : all
        guard !sample.isEmpty else { return 0 }
        return sample.sorted()[sample.count / 2]
    }

    /// Whether a candidate glide was actually sailed downwind.
    ///
    /// The detector's other tests — flying, fast enough, not decelerating —
    /// describe a good stretch of riding, not a glide. On a session of
    /// upwind-downwind laps a close reach passes all three, and a real Gorge
    /// session came back with thirty-four "glides" of which the first was
    /// sailed forty-six degrees off the wind. That is a beat, and calling it a
    /// glide put upwind legs on a screen about riding swell.
    ///
    /// The bump can only push you the way it is going, so a glide has to be
    /// well abaft the beam. Riders put the line a little deeper than 90° —
    /// a beam reach and a shade below it is still riding across, not being
    /// carried — so the bar is `downwindHalfAngle`. Without wind there is
    /// nothing to check against and the candidate stands; the confidence
    /// already says the call is weaker then.
    func isDownwind(from start: Int, to end: Int, in track: Track, wind: Wind?) -> Bool {
        guard let wind else { return true }
        let heading = Geo.bearing(from: track.points[start].coordinate,
                                  to: track.points[end].coordinate)
        return Geo.angleSeparation(heading, wind.directionFrom) > downwindHalfAngle
    }

    /// How far off the wind a glide has to be sailed, degrees. Comes from the
    /// sport's thresholds so a rider can move it.
    public var downwindHalfAngle: Double { thresholds.glideDownwindAngle }

    // MARK: - Glide segmentation

    func detectGlides(in track: Track, flights: [Flight], wind: Wind?, hasMotion: Bool) -> [Glide] {
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

        // What "fast" means on this day, rather than in general.
        let floor = max(minimumGlideSpeed, glideSpeedFraction * typicalRidingSpeed(in: track, wind: wind))

        var isGliding = [Bool](repeating: false, count: track.count)
        for i in 0..<track.count {
            guard track.speed[i] >= floor else { continue }
            guard !requiresFlight || flyingMask[i] else { continue }
            guard acceleration[i] >= -maximumDeceleration else { continue }
            if hasMotion, let energy = track.points[i].verticalAccelSD {
                guard energy <= pumpEnergyThreshold else { continue }
            }
            isGliding[i] = true
        }

        bridgeInterruptions(in: &isGliding, track: track, wind: wind,
                            flying: flyingMask, requiresFlight: requiresFlight,
                            hasMotion: hasMotion)

        // Extract runs.
        var glides: [Glide] = []
        var i = 0
        var previousEndIndex: Int?

        while i < track.count {
            guard isGliding[i] else { i += 1; continue }
            var j = i
            while j + 1 < track.count, isGliding[j + 1] { j += 1 }

            let duration = track.elapsed[j] - track.elapsed[i]
            var peak = 0.0
            for k in i...j { peak = max(peak, track.speed[k]) }
            let rose = peak >= troughBefore(i, in: track) * (1 + minimumSpeedGain)

            if duration >= minimumGlideDuration, j > i, rose,
               isDownwind(from: i, to: j, in: track, wind: wind) {
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
