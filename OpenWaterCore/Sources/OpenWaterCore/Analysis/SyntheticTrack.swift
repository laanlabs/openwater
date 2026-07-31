import Foundation

/// Builds tracks with known-by-construction properties.
///
/// This exists in the shipping target rather than the test target on purpose:
/// it also powers the demo mode and the simulator's fake recorder, so the UI can
/// be developed and screenshotted without anybody getting wet.
public enum SyntheticTrack {

    /// One leg of a ride: hold a speed on a heading for a duration.
    public struct Leg: Sendable {
        public var speed: Double          // m/s
        public var heading: Double        // degrees
        public var duration: TimeInterval
        /// Seconds spent easing into this leg's speed and heading from the last.
        public var transition: TimeInterval

        public init(speed: Double, heading: Double, duration: TimeInterval, transition: TimeInterval = 0) {
            self.speed = speed
            self.heading = heading
            self.duration = duration
            self.transition = transition
        }
    }

    /// Generate fixes by dead-reckoning through a list of legs.
    ///
    /// - Parameters:
    ///   - legs: the ride.
    ///   - start: where it begins.
    ///   - startDate: when it begins.
    ///   - sampleRate: fixes per second.
    ///   - horizontalAccuracy: reported accuracy for every fix.
    ///   - speedAccuracy: reported speed accuracy, or `nil` to omit Doppler
    ///     entirely so the derived-speed path gets exercised.
    ///   - noise: metres of Gaussian position jitter (deterministic — seeded).
    /// Open water in San Francisco Bay, between Treasure Island and Berkeley.
    ///
    /// Picked so a generated session of a couple of kilometres stays on water in
    /// every direction. The obvious-looking coordinates near the city are all on
    /// land or too close to it, and a demo track drawn across somebody's street
    /// grid undermines the thing it is demonstrating.
    public static let defaultStart = Geo.Coordinate(latitude: 37.8450, longitude: -122.3400)

    public static func generate(
        legs: [Leg],
        start: Geo.Coordinate = SyntheticTrack.defaultStart,
        startDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        sampleRate: Double = 1,
        horizontalAccuracy: Double = 4,
        speedAccuracy: Double? = 0.4,
        noise: Double = 0,
        seed: UInt64 = 0x5EED
    ) -> [TrackPoint] {
        guard sampleRate > 0 else { return [] }
        let dt = 1 / sampleRate
        var rng = SplitMix64(seed: seed)

        var points: [TrackPoint] = []
        var position = start
        var elapsed: TimeInterval = 0
        var previousSpeed = legs.first?.speed ?? 0
        var previousHeading = legs.first?.heading ?? 0

        for leg in legs {
            let total = leg.duration
            var legTime: TimeInterval = 0
            while legTime < total - 1e-9 {
                // Ease speed and heading across the transition so detectors see
                // a realistic turn rather than an instantaneous jump.
                let f = leg.transition > 0 ? min(1, legTime / leg.transition) : 1
                let eased = f * f * (3 - 2 * f)   // smoothstep
                let speed = previousSpeed + (leg.speed - previousSpeed) * eased
                let heading = Geo.normalizeDegrees(
                    previousHeading + Geo.angleDelta(from: previousHeading, to: leg.heading) * eased
                )

                var reported = position
                if noise > 0 {
                    let dn = rng.nextGaussian() * noise
                    let de = rng.nextGaussian() * noise
                    reported = Geo.destination(from: position, bearing: 0, distance: dn)
                    reported = Geo.destination(from: reported, bearing: 90, distance: de)
                }

                points.append(TrackPoint(
                    timestamp: startDate.addingTimeInterval(elapsed),
                    latitude: reported.latitude,
                    longitude: reported.longitude,
                    altitude: 0,
                    speed: speedAccuracy == nil ? nil : speed,
                    course: heading,
                    horizontalAccuracy: horizontalAccuracy,
                    verticalAccuracy: horizontalAccuracy * 1.5,
                    speedAccuracy: speedAccuracy,
                    verticalAccelSD: speed > 4.5 ? 0.4 : 2.2,
                    verticalAccelPeak: speed > 4.5 ? 2.0 : 9.0
                ))

                // Advance the true position using the speed for this step.
                position = Geo.destination(from: position, bearing: heading, distance: speed * dt)
                elapsed += dt
                legTime += dt
            }
            previousSpeed = leg.speed
            previousHeading = leg.heading
        }

        return points
    }

    /// A straight run at a constant speed — the simplest thing that has a
    /// checkable answer for every window metric.
    public static func constantSpeed(
        _ speed: Double,
        duration: TimeInterval,
        heading: Double = 90,
        sampleRate: Double = 1
    ) -> [TrackPoint] {
        generate(
            legs: [Leg(speed: speed, heading: heading, duration: duration)],
            sampleRate: sampleRate
        )
    }

    /// A plausible wing or parawing session.
    ///
    /// The shape matters as much as the numbers. A real session launches from
    /// one point on the shore and works the same patch of water over and over:
    /// out on a reach, a rounded gybe at the far end, back on the other tack to
    /// somewhere near where it started. Repeated twenty or thirty times, that
    /// draws a bundle of long thin loops fanning out from the launch — which is
    /// exactly the overlapping tangle the map legibility work exists to solve.
    ///
    /// The return leg is **aimed at the launch point** rather than held at a
    /// fixed wind angle. That distinction is the whole thing: two fixed
    /// reciprocal-ish headings never quite cancel, so the session creeps a
    /// little further downwind every lap and after twenty of them has marched
    /// clean across the bay. Riders do not do that, because they are steering
    /// back to where their car is.
    ///
    /// Speeds vary within and between laps too: a constant-speed run makes the
    /// best 2 s, 10 s, 100 m and 500 m all identical, which is arithmetically
    /// correct and tells you nothing about whether the analysis works.
    public static func wingSessionLegs(
        windFrom: Double = 20,
        runs: Int = 26,
        runDuration: TimeInterval = 52,
        cruiseSpeed: Double = 8.5,
        burstSpeed: Double = 10.5,
        burstOnRun: Int = 7,
        gybeDuration: TimeInterval = 6,
        gybeSpeed: Double = 4,
        /// How much speed varies within a run, as a fraction of its base speed.
        gustiness: Double = 0.12,
        /// Fraction of gybes carried without touching down.
        dryGybeRate: Double = 0.7,
        /// How far the laps fan out from each other, degrees.
        fanSpread: Double = 34,
        seed: UInt64 = 0xB0A7
    ) -> [Leg] {
        var rng = SplitMix64(seed: seed)
        var legs: [Leg] = []

        // Dead-reckon alongside the legs so the return can be steered home.
        let launch = Geo.Coordinate(latitude: 0, longitude: 0)
        var position = launch

        /// Emit one leg and advance the simulated position with it.
        func sail(heading: Double, distance: Double, base: Double, easeIn: Bool) {
            let chunkCount = max(3, Int(distance / 110))
            let chunkDistance = distance / Double(chunkCount)
            for chunk in 0..<chunkCount {
                // Clamp the gust to ±2σ: an unclamped Gaussian occasionally
                // throws a 3σ outlier, which on a 10 m/s base reads as a
                // world-record peak and makes every number look invented.
                let swing = max(-2, min(2, rng.nextGaussian())) * gustiness
                let speed = max(2.5, base * (1 + swing))
                let legHeading = heading + rng.nextGaussian() * 2.5
                legs.append(Leg(
                    speed: speed,
                    heading: legHeading,
                    duration: chunkDistance / speed,
                    transition: (easeIn && chunk == 0) ? 5 : 3
                ))
                position = Geo.destination(from: position, bearing: legHeading, distance: chunkDistance)
            }
        }

        func turn(at heading: Double, base: Double, dry: Bool) {
            legs.append(Leg(
                speed: dry ? max(gybeSpeed, base * 0.72) : gybeSpeed * 0.4,
                heading: heading,
                duration: dry ? gybeDuration : gybeDuration * 2.5,
                transition: 2
            ))
        }

        for lap in 0..<runs {
            // The wind is not steady for an hour. Some laps are done in a lull
            // and barely on the foil, some in a gust — and that spread is what
            // makes a speed-coloured track readable. Without it every run lands
            // in the middle of the ramp and the whole map comes out one shade of
            // green, which looks tidy and shows nothing.
            let windPhase = sin(Double(lap) * 0.9) * 0.5 + cos(Double(lap) * 0.37) * 0.28
            let conditions = 1 + windPhase * 0.42
            let base = max(4.2, (lap == burstOnRun ? burstSpeed : cruiseSpeed) * conditions)
            let dry = Double((lap * 3) % 10) / 10 < dryGybeRate

            // Fan the outbound legs across a spread of reaching angles so the
            // loops splay from the launch instead of lying on top of each other.
            let fan = (Double(lap) / Double(max(1, runs - 1)) - 0.5) * fanSpread
            let outbound = Geo.normalizeDegrees(windFrom + 145 + fan + rng.nextGaussian() * 3)

            // A few laps push much further out, as they do when the wind fills
            // in or somebody chases a gust across the bay.
            let reach = runDuration * cruiseSpeed * (lap % 7 == 3 ? 1.8 : 0.85 + Double(lap % 3) * 0.14)

            sail(heading: outbound, distance: reach, base: base, easeIn: true)
            turn(at: outbound, base: base, dry: dry)

            // Home. Aimed at the launch, offset a little so the return does not
            // retrace the outbound exactly — real tracks never do.
            let home = Geo.bearing(from: position, to: launch) + rng.nextGaussian() * 6
            let distanceHome = Geo.distance(position, launch)
            sail(heading: home, distance: distanceHome * 0.94, base: base, easeIn: true)

            if lap < runs - 1 {
                turn(at: home, base: base, dry: dry)
            }
        }
        return legs
    }

    /// The same session as ready-to-use fixes.
    public static func wingSession(
        windFrom: Double = 20,
        runs: Int = 26,
        runDuration: TimeInterval = 52,
        cruiseSpeed: Double = 8.5,
        burstSpeed: Double = 10.5,
        burstOnRun: Int = 7,
        gybeDuration: TimeInterval = 6,
        gybeSpeed: Double = 4,
        gustiness: Double = 0.12,
        dryGybeRate: Double = 0.7,
        fanSpread: Double = 34,
        seed: UInt64 = 0xB0A7
    ) -> [TrackPoint] {
        generate(legs: wingSessionLegs(
            windFrom: windFrom, runs: runs, runDuration: runDuration,
            cruiseSpeed: cruiseSpeed, burstSpeed: burstSpeed, burstOnRun: burstOnRun,
            gybeDuration: gybeDuration, gybeSpeed: gybeSpeed, gustiness: gustiness,
            dryGybeRate: dryGybeRate, fanSpread: fanSpread, seed: seed
        ))
    }

    /// An alpha loop: out, turn, and back to within a few metres of the start.
    public static func alphaLoop(
        speed: Double = 10,
        legDistance: Double = 260,
        separation: Double = 20
    ) -> [TrackPoint] {
        let legDuration = legDistance / speed
        return generate(legs: [
            Leg(speed: speed, heading: 90, duration: legDuration),
            Leg(speed: speed, heading: 270, duration: legDuration, transition: 3),
        ].map { $0 }, start: SyntheticTrack.defaultStart)
            .adjustingReturnLeg(separation: separation)
    }
}

private extension Array where Element == TrackPoint {
    /// Nudge the second half sideways so the loop does not retrace itself
    /// exactly — real gybes leave a gap.
    func adjustingReturnLeg(separation: Double) -> [TrackPoint] {
        guard count > 2 else { return self }
        let half = count / 2
        return enumerated().map { index, point in
            guard index >= half else { return point }
            var p = point
            let shifted = Geo.destination(from: point.coordinate, bearing: 0, distance: separation)
            p.latitude = shifted.latitude
            p.longitude = shifted.longitude
            return p
        }
    }
}

/// A tiny deterministic PRNG so synthetic tracks are reproducible across runs
/// and platforms — a test that fails only sometimes is worse than no test.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Box–Muller, unit variance.
    mutating func nextGaussian() -> Double {
        let u1 = max(Double.leastNormalMagnitude, Double(next() >> 11) * 0x1p-53)
        let u2 = Double(next() >> 11) * 0x1p-53
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
