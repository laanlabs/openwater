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

    /// A plausible wing session: reaches back and forth across the wind with
    /// gybes between them, and a burst of speed on one run.
    ///
    /// With a northerly wind (wind *from* 0°), a broad reach on starboard is
    /// about 135° and on port about 225°.
    /// A plausible wing session, with the messiness that makes it useful.
    ///
    /// A constant-speed run is a bad fixture and a worse demo: if a rider holds
    /// exactly 13 m/s for 75 seconds then the best 2 s, 10 s, 100 m, 250 m and
    /// 500 m are all *identical*, which is arithmetically correct and tells you
    /// nothing about whether the analysis works. Real riders surge in the gusts
    /// and bleed speed in the lulls, so each run is built from several legs with
    /// varying speed, and the window metrics separate the way they should.
    public static func wingSession(
        windFrom: Double = 0,
        runs: Int = 8,
        runDuration: TimeInterval = 90,
        // Speeds chosen so the *peak* lands where a good wingfoiler's peak
        // actually lands. Base speeds are only half the story: a 13 m/s base
        // with ±2σ of 22 % gust reaches 20 m/s, which is 39 knots — windsurf
        // world-record territory, and it makes every number in the demo look
        // made up. The base and the gust have to be picked together.
        cruiseSpeed: Double = 8.5,      // ~16.5 kn
        burstSpeed: Double = 10.5,      // ~20 kn
        burstOnRun: Int = 3,
        gybeDuration: TimeInterval = 6,
        gybeSpeed: Double = 4,
        /// How much speed varies within a run, as a fraction of its base speed.
        gustiness: Double = 0.12,
        /// Fraction of gybes carried without touching down.
        dryGybeRate: Double = 0.5,
        seed: UInt64 = 0xB0A7
    ) -> [TrackPoint] {
        var rng = SplitMix64(seed: seed)
        var legs: [Leg] = []

        for i in 0..<runs {
            let downwindish = i.isMultiple(of: 2)
            // Alternate between a downwind reach and an upwind one, flipping
            // tack every pair, so the four-run cycle is SE, NE, SW, NW — which
            // sums to roughly zero and keeps the session inside a bay instead of
            // marching off in one direction.
            //
            // With the wind from `windFrom`, upwind is `windFrom ± 45` and
            // downwind is `windFrom ± 135`. Both are measured from the wind
            // direction itself; adding 180 to the upwind leg (as this did
            // originally) points it downwind too, which produced a track with
            // only two heading modes and no upwind component at all.
            let offset: Double = downwindish ? 135 : 45
            let sign: Double = (i / 2).isMultiple(of: 2) ? 1 : -1
            let heading = Geo.normalizeDegrees(windFrom + sign * offset)
            let base = i == burstOnRun ? burstSpeed : cruiseSpeed

            // Break the run into gust-length chunks so speed is never flat.
            let chunkCount = max(3, Int(runDuration / 12))
            let chunkDuration = runDuration / Double(chunkCount)
            for chunk in 0..<chunkCount {
                // Clamp the gust to ±2σ. An unclamped Gaussian occasionally
                // produces a 3σ outlier, and on a 13 m/s base that is a 25-knot
                // gust on top — which shows up as a world-record peak in a demo
                // session and makes every number look untrustworthy.
                let swing = max(-2, min(2, rng.nextGaussian())) * gustiness
                // The fastest chunk of the burst run is the session's peak.
                let bias = (i == burstOnRun && chunk == chunkCount / 2) ? 0.12 : 0
                let speed = max(2, base * (1 + swing + bias))
                legs.append(Leg(
                    speed: speed,
                    heading: heading + rng.nextGaussian() * 4,
                    duration: chunkDuration,
                    transition: chunk == 0 ? 4 : 3
                ))
            }

            guard i < runs - 1 else { continue }
            // A dry gybe carries speed through; a wet one drops to a crawl and
            // needs a restart.
            let dry = Double(i) / Double(max(1, runs - 1)) < dryGybeRate
            legs.append(Leg(
                speed: dry ? max(gybeSpeed, base * 0.72) : gybeSpeed * 0.4,
                heading: heading,
                duration: dry ? gybeDuration : gybeDuration * 2.5,
                transition: 2
            ))
        }
        return generate(legs: legs)
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
