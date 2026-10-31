import Foundation

/// A detected jump.
public struct Jump: Hashable, Sendable, Codable, Identifiable {

    public let id: Int

    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval
    public let startIndex: Int
    public let endIndex: Int

    /// Seconds in the air — worked back from the height under the sport's
    /// lift (`SportThresholds.jumpLiftFraction`), not timed.
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

    /// How much of the rider a wing or kite carries in the air, 0–1. See
    /// `SportThresholds.jumpLiftFraction`; this is what turns a height into
    /// an airtime, and free fall is the special case of zero.
    public var liftFraction: Double = 0

    /// Seconds a jump of `height` lasts under this sport's lift.
    public func airtime(forHeight height: Double) -> TimeInterval {
        let effectiveGravity = 9.80665 * (1 - min(0.95, max(0, liftFraction)))
        return (8 * height / effectiveGravity).squareRoot()
    }

    /// Second-to-second height change, metres, above which the receiver is
    /// refused outright: the water is moving and its height cannot tell a
    /// trough from a jump. See `detect(in:)` for the four sessions this sits
    /// between.
    public var maximumReceiverNoise: Double = 0.21

    /// The altimeter is on a wrist, and a wrist is in the wind.
    ///
    /// A barometer reads pressure, and moving air is pressure: at twenty
    /// knots of apparent wind the ram pressure on the sensor's port is about
    /// 65 Pa, which the altimeter reports as five metres of height, and a
    /// hand on a wing turns into and out of that wind with every stroke.
    /// Add spray. Two wingfoil sessions on a watch, both with the rider's
    /// word "no jumps": the first swung −132…+114 m and read 104 jumps, the
    /// second −33…+47 m and read 42, and the second's swing — 2.3 m one
    /// second in ten — cleared `maximumBarometerSwing` by so little that a
    /// slightly drier day would not have. The swing bar is a guard against
    /// a faulty sensor; a wrist is not faulty, it is in the wind, every
    /// time, by physics. So on a wrist the altimeter is recorded and never
    /// read, and the receiver is asked instead.
    ///
    /// A phone in a vest pocket is out of the wind and rides the same jump
    /// the board does. That is what the altimeter path is for, once a
    /// session on the water has measured it.
    public var altimeterOnWrist = false

    /// How far the altimeter may move between one fix and the next, one
    /// second in ten while at speed, metres, before it is refused and the
    /// receiver asked instead.
    ///
    /// The first session on the water to carry the channel said the desk
    /// test had not. A wingfoil afternoon in fifteen knots, the rider's own
    /// count "no jumps": the absolute altimeter on the wrist swung between
    /// −132 m and +114 m, moved a median 1.1 m between fixes while planing
    /// and over 6.5 m one second in ten, and was already doing it on the
    /// wade out. The receiver's altitude on the same fixes stayed within
    /// eight metres all afternoon. Read as it stood, the altimeter produced
    /// 104 jumps of 15 to 177 ft, and the rise bar — four times the
    /// session's own noise — could not help, because the fault is not in
    /// the middle of the distribution but in its tail: the rise above the
    /// local water was over 31 m one second in a hundred.
    ///
    /// Which is why this is a tail and not the median the receiver is held
    /// to. The altimeter is worth having because it measures the board on
    /// the sea the receiver filters away, and on a sea the board really
    /// does move half a metre a second — a median bar at the receiver's
    /// quarter metre would refuse exactly the water the altimeter exists
    /// for. But no sea lifts a board two metres in a second, and no session
    /// jumps every tenth second: a channel doing that is reading pressure,
    /// not height.
    ///
    /// The desk test that earned the altimeter the first read — ±5 cm
    /// standing, a clean step for an arm raise — was dry and out of the
    /// wind. A wrist on a wing is neither, and a barometer under spray or
    /// in a gust is a barometer. A phone in a vest pocket may do better;
    /// nothing on the water has said so yet.
    public var maximumBarometerSwing: Double = 2.0

    /// On a receiver whose noise is off the floor, the fraction of their
    /// speed a rider has to lose over the landing before a rise is believed.
    /// Two-thirds: a jump costs a third of your speed, chop does not.
    public var landingSpeedRetention: Double = 0.65

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
    public static func forSport(
        _ sport: Sport, thresholds: SportThresholds? = nil, altimeterOnWrist: Bool = false
    ) -> JumpDetector {
        let t = thresholds ?? sport.thresholds
        var d = JumpDetector(
            minimumRise: t.jumpMinimumRise,
            landingThreshold: t.jumpLandingSpike,
            minimumTakeoffSpeed: t.jumpMinimumTakeoffSpeed
        )
        d.minimumAirtime = t.jumpMinimumAirtime
        d.liftFraction = t.jumpLiftFraction
        d.altimeterOnWrist = altimeterOnWrist
        switch sport {
        case .kitesurf, .kitefoil:
            d.maximumAirtime = 12
        case .windsurf:
            d.maximumAirtime = 6
        case .wingfoil, .wingfoilSurf, .parawing:
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
    ///
    /// And one thing it does that the desk never showed: on a wrist on the
    /// water it does not read height at all. See `altimeterOnWrist` and
    /// `maximumBarometerSwing` — the altimeter is preferred where it is out
    /// of the wind and holds still, and the receiver is asked otherwise.
    public enum Source: Sendable { case barometer, receiver }

    /// The channel `detect` reads on a track, and what it found each one to
    /// be. The answer is the detector's, not the recording's: a screen that
    /// says where height came from has to ask here rather than look at which
    /// fields are filled, because a filled channel can still be refused.
    public struct Reading: Sendable, Equatable {

        /// What is read. Nil when the track carries no height, or when every
        /// channel it carries was refused.
        public let source: Source?

        /// Each channel's typical second-to-second change while at speed,
        /// metres — nil when the track does not carry the channel, zero when
        /// it does but there was too little riding to measure it on. This is
        /// the rise bar's input, and the receiver's refusal.
        public let barometerNoise: Double?
        public let receiverNoise: Double?

        /// The altimeter's second-to-second change one second in ten, metres
        /// — the altimeter's refusal, see `maximumBarometerSwing`.
        public let barometerSwing: Double?

        /// The altimeter was on a wrist, which is reason enough not to read
        /// it — see `altimeterOnWrist`. The swing is still measured, so a
        /// screen can say what the wind did to it.
        public let altimeterOnWrist: Bool

        /// The altimeter is there and is not read: on a wrist, or swinging
        /// further than a board can move.
        public var barometerRefused: Bool {
            barometerSwing != nil && source != .barometer
        }

        /// The receiver is there and is not read: the water is moving.
        /// Only asked when the altimeter is not read either.
        public var receiverRefused: Bool {
            receiverNoise != nil && source == nil
        }
    }

    /// What this track carries, before anyone asks whether it can be read.
    ///
    /// The altimeter counts only when it reached most of the fixes: a
    /// channel that came and went is the silent-hour fault
    /// `BarometerProvider` describes, not a height record.
    static func recorded(in track: Track) -> (barometer: Bool, receiver: Bool) {
        let baro = track.points.reduce(into: 0) { $0 += $1.absoluteAltitude == nil ? 0 : 1 }
        return (baro > track.count / 2, track.points.contains(where: { $0.altitude != nil }))
    }

    /// One channel's heights. A receiver that admits it does not know the
    /// height is not evidence of a jump, so its poor fixes are left out; the
    /// barometer has no such caveat.
    func heights(from source: Source, in track: Track) -> [Double?] {
        track.points.map {
            switch source {
            case .barometer: return $0.absoluteAltitude
            case .receiver:
                guard ($0.verticalAccuracy ?? .infinity) <= maximumVerticalAccuracy else { return nil }
                return $0.altitude
            }
        }
    }

    public func reading(for track: Track) -> Reading {
        let recorded = Self.recorded(in: track)
        var barometerNoise: Double?
        var barometerSwing: Double?
        if recorded.barometer {
            let steps = steps(for: track, heights: heights(from: .barometer, in: track))
            barometerNoise = steps.map { $0[$0.count / 2] } ?? 0
            barometerSwing = steps.map { $0[$0.count * 9 / 10] } ?? 0
        }
        let receiverNoise: Double? = recorded.receiver
            ? heightNoise(for: track, heights: heights(from: .receiver, in: track)) ?? 0
            : nil

        let source: Source?
        if !altimeterOnWrist, let swing = barometerSwing, swing <= maximumBarometerSwing {
            source = .barometer
        } else if let noise = receiverNoise, noise <= maximumReceiverNoise {
            source = .receiver
        } else {
            source = nil
        }
        return Reading(source: source, barometerNoise: barometerNoise, receiverNoise: receiverNoise,
                       barometerSwing: barometerSwing, altimeterOnWrist: altimeterOnWrist)
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

    /// Every second-to-second height change while at speed, metres, sorted.
    /// Nil when there is too little at speed to say anything from.
    func steps(for track: Track, heights: [Double?]) -> [Double]? {
        var steps: [Double] = []
        for i in 1..<max(1, track.count) {
            guard let a = heights[i], let b = heights[i - 1],
                  track.speed[i] >= minimumTakeoffSpeed else { continue }
            steps.append(abs(a - b))
        }
        guard steps.count >= 30 else { return nil }
        return steps.sorted()
    }

    /// The session's own height noise: the median second-to-second change
    /// while at speed, metres. Nil when there is too little at speed to say.
    func heightNoise(for track: Track, heights: [Double?]) -> Double? {
        steps(for: track, heights: heights).map { $0[$0.count / 2] }
    }

    /// The bar a rise has to clear on this track: the floor, or the session's
    /// own height noise, whichever is higher.
    func riseBar(for track: Track, heights: [Double?]) -> Double {
        guard let noise = heightNoise(for: track, heights: heights) else { return minimumRise }
        return max(minimumRise, noise * riseNoiseFactor)
    }

    public func detect(in track: Track) -> [Jump] {
        guard track.count >= 60 else { return [] }

        // **The receiver only gets to speak about flat water, and the
        // altimeter only when it holds still.**
        //
        // The receiver's height is a filtered guess, and on a downwinder the
        // guess and a jump are the same shape: a rider dropping into a
        // two-metre trough climbs a metre in a second and lands hard at the
        // bottom, which is every clause below satisfied by the sea. Measured
        // on the parawing session whose rider said "one single downwind run
        // with no jumps", this found fourteen of them.
        //
        // So when the water is moving too much for the receiver to be read,
        // the honest answer is the one this always gave: nothing. A barometer
        // has no such limit — it measures the board rather than inferring it,
        // which is the whole reason it is recorded. What it has instead is
        // wind and spray, which move it by metres a second on a wrist — see
        // `altimeterOnWrist` and `maximumBarometerSwing` — and an altimeter
        // in either is not read, with the receiver asked in its place.
        //
        // "Too much" used to mean any noise at all above the floor, and that
        // threw away a whole session. A wingfoil session on flat water in
        // fifteen knots, whose rider counted ten or more jumps and whose
        // altimeter had recorded nothing, measured 0.18 m of second-to-second
        // height noise while planing — not the sea, just this wrist's receiver
        // on this day — and was refused with all its jumps in it. The
        // receiver sessions measured so far: a harbour at 0.10 m, that flat
        // day at 0.18 m, a wrist in Montauk at 0.24 m on which the strict
        // rules below still confirmed two rises on an afternoon with no
        // jumps, and the parawing downwinder at 0.32 m. The refusal sits
        // between the flat day and the Montauk one.
        let reading = reading(for: track)
        guard let source = reading.source else { return [] }

        let heights = heights(from: source, in: track)
        let noise = (source == .barometer ? reading.barometerNoise : reading.receiverNoise) ?? 0
        let bar = max(minimumRise, noise * riseNoiseFactor)

        // Between the floor and the refusal the receiver is read, but not on
        // one witness. On the flat day, noise alone put some sixty rises over
        // the bar, and any-one-of-three accepted thirty-one of them. A jump
        // has a whole landing: the slam, and the speed it cost — the rider
        // came off the foil's drive for a second and put it back in the
        // water. Asking for both found thirteen, which is the count the rider
        // gave. Chop has the slam and keeps its speed; a glitch has neither.
        let strict = source == .receiver && bar > minimumRise

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

            // The whole landing, for the noisy receiver: a slam either side of
            // the apex — the receiver's height lags the board by a second or
            // two, so the slam is as often before the apex as after it — and
            // the speed it cost, from the fastest the rider was going into
            // the jump to the slowest they came out of it.
            let fastest = (max(0, start - 3)...apex).map { track.speed[$0] }.max() ?? track.speed[apex]
            let lostSpeed = fastest > 0 && slowest / fastest <= landingSpeedRetention

            let confirmed = strict
                ? max(spike, pop) >= landingThreshold && lostSpeed
                : spike >= landingThreshold
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
            //
            // Unless the receiver is noisy. The area recovers what a filter
            // took off a clean pulse; on the flat day the samples either side
            // of every jump were a quarter metre of noise and a second of lag
            // smear, and the area read them as air — thirteen jumps in
            // fifteen knots came out at six to thirteen feet. There the peak
            // is the smaller lie, as it is for the barometer.
            let measured = source == .barometer || strict
                ? height
                : Self.heightFromArea(apex: apex, heights: heights, baseline: baseline,
                                      elapsed: track.elapsed, maximumAirtime: maximumAirtime)
            let airtime = min(maximumAirtime, self.airtime(forHeight: measured))

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
                // One landing, one jump. The receiver smears a jump across
                // the samples either side of it, and a second rise inside the
                // landing window is that same jump read again — on the flat
                // day three of them came out as pairs three seconds apart.
                i = max(j + 1, apex + 4)
                continue
            }
            i = j + 1
        }

        return jumps
    }
}
