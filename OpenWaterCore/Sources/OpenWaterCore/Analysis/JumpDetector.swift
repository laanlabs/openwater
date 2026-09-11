import Foundation

/// A detected jump.
public struct Jump: Hashable, Sendable, Codable, Identifiable {

    public let id: Int

    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval
    public let startIndex: Int
    public let endIndex: Int

    /// Seconds in the air.
    public let airtime: TimeInterval

    /// Estimated height in metres, from hangtime under gravity.
    public let height: Double

    /// Speed going in — the thing that made the jump possible.
    public let takeoffSpeed: Double

    /// Speed on landing. Keeping it is what separates a jump from a crash.
    public let landingSpeed: Double

    /// Distance covered while airborne.
    public let distance: Double

    /// 0–1. Named honestly: this is a detection, not a measurement.
    public let confidence: Double

    public init(
        id: Int, startElapsed: TimeInterval, endElapsed: TimeInterval,
        startIndex: Int, endIndex: Int, airtime: TimeInterval, height: Double,
        takeoffSpeed: Double, landingSpeed: Double, distance: Double, confidence: Double
    ) {
        self.id = id
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.airtime = airtime
        self.height = height
        self.takeoffSpeed = takeoffSpeed
        self.landingSpeed = landingSpeed
        self.distance = distance
        self.confidence = confidence
    }

    /// Fraction of takeoff speed kept through the landing.
    public var landingRetention: Double {
        takeoffSpeed > 0 ? min(2, landingSpeed / takeoffSpeed) : 0
    }
}

public struct JumpSummary: Hashable, Sendable, Codable {
    public let count: Int
    public let bestAirtime: TimeInterval
    public let bestHeight: Double
    public let totalAirtime: TimeInterval
    public let highest: Jump?
    public let longest: Jump?

    public init(
        count: Int, bestAirtime: TimeInterval, bestHeight: Double,
        totalAirtime: TimeInterval, highest: Jump?, longest: Jump?
    ) {
        self.count = count
        self.bestAirtime = bestAirtime
        self.bestHeight = bestHeight
        self.totalAirtime = totalAirtime
        self.highest = highest
        self.longest = longest
    }

    public static let none = JumpSummary(
        count: 0, bestAirtime: 0, bestHeight: 0, totalAirtime: 0,
        highest: nil, longest: nil
    )

    public init(jumps: [Jump]) {
        guard !jumps.isEmpty else { self = .none; return }
        self.init(
            count: jumps.count,
            bestAirtime: jumps.map(\.airtime).max() ?? 0,
            bestHeight: jumps.map(\.height).max() ?? 0,
            totalAirtime: jumps.reduce(0) { $0 + $1.airtime },
            highest: jumps.max { $0.height < $1.height },
            longest: jumps.max { $0.airtime < $1.airtime }
        )
    }
}

/// Detects jumps from the height channel, confirmed by the landing.
///
/// **This used to read the accelerometer and it was looking for the wrong
/// thing.** The premise was that user acceleration collapses toward zero in
/// the air, so a quiet window ending in a spike was a jump. Measured against a
/// wingfoil session whose rider counted about fifteen jumps, the apex of a real
/// jump reads `verticalAccelSD` **8.5** and a peak of **12.6** — the signal
/// does not collapse, it spikes, because a one-second window at the apex
/// contains the takeoff impulse, the air, and the landing all at once. The old
/// rule could therefore only ever fire on smooth water followed by a chop hit,
/// which is exactly the false positive that once reported nineteen metres of
/// air on a downwinder, and it found nothing at all on a session full of real
/// jumps.
///
/// So height is the signal and the accelerometer is the witness:
///
/// 1. **A rise above the local baseline.** The baseline is a median of the half
///    minute around the sample, so a rider who is climbing a swell is measured
///    against the swell rather than against the sea.
/// 2. **That is not swell.** A wave lifts you over four or five seconds; a jump
///    leaves the water in one or two. The rise *rate* separates them, and it is
///    the only thing that does — on a downwinder the heights are the same.
/// 3. **A landing.** A hard spike in vertical acceleration within a few seconds
///    of the apex. This is what a receiver glitch never has, and it is why this
///    can accept a rise one sample wide where a height-only detector must throw
///    it away as a needle.
///
/// Height is the rise itself. That is honest with a barometer and an
/// underestimate without one — see `TrackPoint.baroAltitude`, which is why the
/// barometer is recorded at all.
public struct JumpDetector: Sendable {

    /// Smallest rise above the local baseline worth calling a jump, metres.
    public var minimumRise: Double

    /// How many times the session's own height noise a rise must clear.
    ///
    /// The same idea as the old free-fall bar, and the only thing that keeps
    /// flat water and a downwinder on one scale: a rider on a metre of swell
    /// has a metre of height happening to them constantly, and calling that a
    /// jump would report thirty of them a run. Measured second-to-second height
    /// change while planing was 0.10 m on a harbour session and 0.32 m on a
    /// parawing downwinder — so the bar has to move with the water.
    public var riseNoiseFactor: Double

    /// Metres per second of climb, below which this is swell and not a jump.
    public var minimumRiseRate: Double

    /// The landing spike that confirms it, m/s².
    public var landingThreshold: Double

    /// Longest plausible airtime — anything more is a sensor fault, not a boost.
    public var maximumAirtime: TimeInterval

    /// Shortest airtime worth reporting. Derived from height rather than
    /// timed, so this is a height floor wearing seconds — which is the unit
    /// riders think in.
    public var minimumAirtime: TimeInterval = 0.6

    /// You cannot jump from a standstill.
    public var minimumTakeoffSpeed: Double

    /// Height fixes worse than this are not evidence of anything.
    public var maximumVerticalAccuracy: Double

    public init(
        minimumRise: Double = 0.5,
        riseNoiseFactor: Double = 4,
        minimumRiseRate: Double = 0.4,
        landingThreshold: Double = 8,
        maximumAirtime: TimeInterval = 8,
        minimumTakeoffSpeed: Double = 3.0,
        maximumVerticalAccuracy: Double = 5
    ) {
        self.minimumRise = minimumRise
        self.riseNoiseFactor = riseNoiseFactor
        self.minimumRiseRate = minimumRiseRate
        self.landingThreshold = landingThreshold
        self.maximumAirtime = maximumAirtime
        self.minimumTakeoffSpeed = minimumTakeoffSpeed
        self.maximumVerticalAccuracy = maximumVerticalAccuracy
    }

    /// The detector for a sport, honouring the rider's own thresholds.
    public static func forSport(_ sport: Sport, thresholds: SportThresholds? = nil) -> JumpDetector {
        let t = thresholds ?? sport.thresholds
        var d = JumpDetector(
            minimumRise: t.jumpMinimumRise,
            landingThreshold: t.jumpLandingSpike,
            minimumTakeoffSpeed: t.jumpMinimumTakeoffSpeed
        )
        d.minimumAirtime = t.jumpMinimumAirtime
        switch sport {
        case .kitesurf, .kitefoil:
            d.maximumAirtime = 12
        case .windsurf:
            d.maximumAirtime = 6
        case .wingfoil, .parawing:
            d.maximumAirtime = 5
        default:
            break
        }
        return d
    }

    /// Which height channel this track is read from.
    ///
    /// The absolute altimeter when it is there; the receiver otherwise.
    ///
    /// Two barometer APIs were recorded side by side on a wrist, over the same
    /// arm raises, before either was trusted. The relative one handed over a
    /// new value every 2.4 s and lagged the arm by three or four — it smears a
    /// one-second event into a creep and cannot see a jump. The absolute one
    /// delivered every 1.1 s, tracked each raise as a clean 0.65–0.97 m step,
    /// and sat within ±5 cm standing still. That is a sensor that can time a
    /// jump, and it is the only one on the wrist that can. So it is read, and
    /// `TrackPoint.baroAltitude` — the relative channel — stays recorded for
    /// comparison and nothing more.
    ///
    /// Why it beats the receiver: it is not filtered across seconds, it does
    /// not care whether the sky is visible, and it keeps working on swell —
    /// where the receiver's height is refused outright because a trough and a
    /// jump look the same to it. Peak rather than area, because the recorder
    /// holds the highest reading between fixes, so the apex is in the data
    /// rather than something to be recovered from under the curve.
    ///
    /// One thing it can do that the receiver cannot: re-anchor. It is fused
    /// with the receiver for its absolute frame, and a fix improving mid-run
    /// can step the whole baseline. The witnesses below are the guard — a
    /// re-anchor has no takeoff pop, no landing, and does not stop the rider.
    public enum Source: Sendable { case barometer, receiver }

    /// The one line to flip back if a session on the water says otherwise.
    static let trustsBarometer = true

    public static func source(for track: Track) -> Source? {
        if trustsBarometer {
            let baro = track.points.reduce(into: 0) { $0 += $1.absoluteAltitude == nil ? 0 : 1 }
            if baro > track.count / 2 { return .barometer }
        }
        return track.points.contains(where: { $0.altitude != nil }) ? .receiver : nil
    }

    /// Height recovered from the area under the excursion.
    ///
    /// Self-consistent, because the window and the answer define each other: a
    /// taller jump is a longer one, so integrating over a fixed window either
    /// clips a big jump or sweeps baseline wander into a small one. Measured on
    /// the reported session, a fixed ten-second window put a 2.4 ft peak above
    /// a 3.3 ft one purely on how far its neighbouring drift happened to run.
    ///
    /// So: integrate, read a height, take the airtime that height implies,
    /// integrate again over *that*. It settles in two or three passes, and the
    /// window is then bounded by the physics rather than by wherever the
    /// baseline noise crossed zero.
    static func heightFromArea(
        apex: Int, heights: [Double?], baseline: [Double?],
        elapsed: [TimeInterval], maximumAirtime: TimeInterval
    ) -> Double {
        /// A = ⅔·h·√(8h/g) = K·h^1.5
        let k = (2.0 / 3.0) * (8.0 / 9.80665).squareRoot()

        func area(halfWidth: Double) -> Double {
            let span = Int(halfWidth.rounded(.up))
            var total = 0.0
            for i in max(0, apex - span)...min(heights.count - 1, apex + span) {
                guard let h = heights[i], let b = baseline[i] else { continue }
                let above = h - b
                if above > 0 { total += above }
            }
            return total
        }

        var halfWidth = 1.0
        var height = 0.0
        for _ in 0..<6 {
            let a = area(halfWidth: halfWidth)
            height = a > 0 ? pow(a / k, 2.0 / 3.0) : 0
            let airtime = min(maximumAirtime, (8 * height / 9.80665).squareRoot())
            let next = max(0.5, airtime / 2)
            if abs(next - halfWidth) < 0.05 { break }
            halfWidth = next
        }
        return height
    }

    /// The bar a rise has to clear on this track: the floor, or the session's
    /// own height noise, whichever is higher.
    func riseBar(for track: Track, heights: [Double?]) -> Double {
        var steps: [Double] = []
        for i in 1..<max(1, track.count) {
            guard let a = heights[i], let b = heights[i - 1],
                  track.speed[i] >= minimumTakeoffSpeed else { continue }
            steps.append(abs(a - b))
        }
        guard steps.count >= 30 else { return minimumRise }
        steps.sort()
        return max(minimumRise, steps[steps.count / 2] * riseNoiseFactor)
    }

    public func detect(in track: Track) -> [Jump] {
        guard track.count >= 60, let source = Self.source(for: track) else { return [] }

        let heights: [Double?] = track.points.map {
            switch source {
            case .barometer: return $0.absoluteAltitude
            case .receiver:
                // A receiver that admits it does not know the height is not
                // evidence of a jump. The barometer has no such caveat.
                guard ($0.verticalAccuracy ?? .infinity) <= maximumVerticalAccuracy else { return nil }
                return $0.altitude
            }
        }

        let bar = riseBar(for: track, heights: heights)

        // **The receiver only gets to speak about flat water.**
        //
        // Its height is a filtered guess, and on a downwinder the guess and a
        // jump are the same shape: a rider dropping into a two-metre trough
        // climbs a metre in a second and lands hard at the bottom, which is
        // every clause below satisfied by the sea. Measured on the parawing
        // session whose rider said "one single downwind run with no jumps",
        // this found fourteen of them.
        //
        // So when the session's own height noise forces the bar up off its
        // floor, the water is moving too much for the receiver to be read, and
        // the honest answer is the one this always gave: nothing. A barometer
        // has no such limit — it measures the board rather than inferring it,
        // which is the whole reason it is recorded.
        if source == .receiver, bar > minimumRise { return [] }

        let window = 15

        // The local baseline: the water this rider is on, not sea level.
        var baseline = [Double?](repeating: nil, count: track.count)
        for i in window..<max(window, track.count - window) {
            let around = (i - window...i + window).compactMap { heights[$0] }
            guard around.count >= window else { continue }
            baseline[i] = around.sorted()[around.count / 2]
        }

        func rise(_ i: Int) -> Double? {
            guard let h = heights[i], let b = baseline[i] else { return nil }
            return h - b
        }

        func isUp(_ i: Int) -> Bool {
            guard let r = rise(i), r >= bar else { return false }
            return track.speed[i] >= minimumTakeoffSpeed
        }

        var jumps: [Jump] = []
        var i = window
        while i < track.count - window {
            guard isUp(i) else { i += 1; continue }

            var j = i
            while j + 1 < track.count - window, isUp(j + 1) { j += 1 }

            let apex = (i...j).max { (rise($0) ?? 0) < (rise($1) ?? 0) } ?? i
            let height = rise(apex) ?? 0

            // How long the climb took. Walked back to where the rider was still
            // essentially on the water, so a jump off the top of a swell is
            // measured from the swell.
            var start = i
            while start > window, let r = rise(start - 1), r > height * 0.25 { start -= 1 }
            let climb = track.elapsed[apex] - track.elapsed[max(0, start - 1)]
            let rate = climb > 0 ? height / climb : .infinity

            // **Something has to have happened to the board** — but a slam on
            // landing is only one of the things that does.
            //
            // The landing spike was the sole confirmation, and it threw away
            // the biggest jump of the measured session: 4.2 ft at the apex,
            // three seconds wide, the rider's speed collapsing from 15 kn to
            // under 2 — and an accelerometer that stayed quiet, because they
            // came down in the water rather than on the board. A slam only
            // marks the jumps that were landed *badly*. A clean foil landing
            // is soft by definition, and a wipeout is soft because water is.
            // Gating on the slam alone selects against exactly the two ways a
            // big jump ends.
            //
            // So three witnesses, any one of which will do:
            //
            // 1. **The landing** — the slam, as before.
            // 2. **The takeoff** — the pop that put the board in the air. Every
            //    one of the sixteen jumps the slam had already accepted also
            //    carried one, at two-thirds the landing's bar or above; it is
            //    the signature the slam was standing in for.
            // 3. **The wipeout** — an excursion at least two samples wide, and
            //    the rider stopping. A receiver glitch does not stop the rider.
            //
            // A one-sample rise with none of them is still refused. That is
            // the needle, and this is still what tells it from a jump.
            let landingWindow = apex...min(track.count - 1, apex + 3)
            let spike = landingWindow.compactMap { track.points[$0].verticalAccelPeak }.max() ?? 0

            let takeoffWindow = max(0, apex - 3)...apex
            let pop = takeoffWindow.compactMap { track.points[$0].verticalAccelPeak }.max() ?? 0
            let popThreshold = landingThreshold * 2 / 3

            let slowest = landingWindow.map { track.speed[$0] }.min() ?? track.speed[apex]
            let stopped = track.speed[apex] > 0 && slowest / track.speed[apex] <= 0.5
            let width = j - i + 1

            let confirmed = spike >= landingThreshold
                || pop >= popThreshold
                || (stopped && width >= 2)

            // **What the jump was, not what the receiver managed to catch.**
            //
            // The apex is only the answer when the sensor can be believed at
            // it. The barometer can: it samples throughout and the recorder
            // keeps the peak between fixes, so the top of the jump is in the
            // data. The receiver's altitude cannot — it is filtered, and it is
            // read once a second, so a jump lasting about a second is caught
            // part-way up as often as at the top. Both losses shrink the peak
            // and neither shrinks the *area*: a linear filter moves a pulse
            // around but conserves what is under it.
            //
            // A parabolic flight of height h lasts √(8h/g) and encloses
            // ⅔·h·√(8h/g), so the area gives the height back whatever the
            // filter did to its shape.
            //
            // The rider's own check is what proved this was needed. On a foil
            // the mast has to clear the water before you are airborne at all,
            // so the smallest jump that can physically exist is about a mast
            // length — and every one of the sixteen this found on the measured
            // session read *under* that. They were not conservative, they were
            // impossible. Read from area, the same session's smallest lands at
            // 0.92 m, which is a mast, and nothing was told to put it there.
            let measured = source == .barometer
                ? height
                : Self.heightFromArea(apex: apex, heights: heights, baseline: baseline,
                                      elapsed: track.elapsed, maximumAirtime: maximumAirtime)
            let airtime = min(maximumAirtime, (8 * measured / 9.80665).squareRoot())

            if rate >= minimumRiseRate, confirmed,
               airtime >= minimumAirtime, airtime <= maximumAirtime {
                let witness = max(spike / landingThreshold, pop / popThreshold,
                                  stopped && width >= 2 ? 1 : 0)
                var confidence = min(1, height / (bar * 2)) * 0.5
                    + min(1, witness / 2) * 0.5
                confidence *= 0.6 + 0.4 * min(1, track.quality.score / 80)
                if source == .receiver { confidence *= 0.75 }

                jumps.append(Jump(
                    id: jumps.count,
                    startElapsed: track.elapsed[max(0, start - 1)],
                    endElapsed: track.elapsed[min(track.count - 1, j + 1)],
                    startIndex: max(0, start - 1),
                    endIndex: min(track.count - 1, j + 1),
                    airtime: airtime,
                    height: measured,
                    takeoffSpeed: track.speed[max(0, start - 1)],
                    landingSpeed: track.speed[min(track.count - 1, j + 1)],
                    distance: track.cumulativeDistance[min(track.count - 1, j + 1)]
                        - track.cumulativeDistance[max(0, start - 1)],
                    confidence: max(0, min(1, confidence))
                ))
            }
            i = j + 1
        }

        return jumps
    }
}
