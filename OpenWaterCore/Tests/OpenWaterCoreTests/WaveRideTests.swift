import Foundation
import Testing
@testable import OpenWaterCore

/// Wave rides are measured against the swell the rider set, not the wind —
/// see `WaveRideFinder`. These stay synthetic: the shape being tested is
/// "accelerating with the swell counts, the same speed across it does not".
@Suite("Wave rides")
struct WaveRideTests {

    let builder = TrackBuilder()

    /// Swell from the south: waves travel north, 0°.
    let swellFrom: Double = 180

    /// Cruise at 6, catch a wave to 9 heading north, settle back — twice —
    /// with cross-swell riding between. Legs switch abruptly on purpose: an
    /// eased transition smears the wave's acceleration into the reach before
    /// it, and then the *reach* passes the rise test on any axis.
    private func waveDay() -> Track {
        builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),                // reach across
            .init(speed: 9, heading: 0, duration: 20),                 // wave one
            .init(speed: 6, heading: 90, duration: 40),
            .init(speed: 9, heading: 20, duration: 15),                // wave two, angled
            .init(speed: 6, heading: 270, duration: 60),
        ]))
    }

    @Test("Finds the waves and only the waves")
    func findsWaves() {
        let track = waveDay()
        let summary = WaveRideFinder().rides(in: track, flights: [], swellFrom: swellFrom)

        #expect(summary.count == 2)
        // Both rides point with the swell, not across it.
        for ride in summary.rides {
            #expect(ride.offSwell < WaveRideFinder.halfAngle)
            #expect(ride.peakSpeed > 8)
        }
    }

    @Test("A fast reach across the swell is not a wave")
    func reachIsNotAWave() {
        // Same speeds, same accelerations — sailed at right angles to the
        // swell's travel the whole way.
        let track = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),
            .init(speed: 9, heading: 90, duration: 20, transition: 3),
            .init(speed: 6, heading: 90, duration: 40, transition: 3),
        ]))
        let summary = WaveRideFinder().rides(in: track, flights: [], swellFrom: swellFrom)
        #expect(summary.count == 0)
    }

    @Test("Holding one speed with the swell is not a wave")
    func steadySpeedIsNotAWave() {
        // Pointed dead with the swell throughout, but nothing ever *gave*
        // speed — a powered rider on a course for the beach.
        let track = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 8, heading: 0, duration: 180),
        ]))
        let summary = WaveRideFinder().rides(in: track, flights: [], swellFrom: swellFrom)
        #expect(summary.count == 0)
    }

    @Test("The same day against the wind axis reads differently")
    func swellAxisIsNotWindAxis() {
        // The point of the whole feature: wind from the west, swell from the
        // south. The wave rides head north — across the wind — and still
        // count, because the swell arrow is the anchor.
        let track = waveDay()
        let summary = WaveRideFinder().rides(in: track, flights: [], swellFrom: swellFrom)
        #expect(summary.count == 2)

        // Anchored on where the wind comes from instead, the northbound
        // rides sit at right angles to the axis and vanish.
        let windAnchored = WaveRideFinder().rides(in: track, flights: [], swellFrom: 270)
        #expect(windAnchored.count == 0)
    }

    // MARK: The rules have to move the answer

    /// The rides under one changed rule, everything else left alone.
    private func rides(
        _ track: Track,
        flights: [Flight] = [],
        _ change: (inout SportThresholds) -> Void = { _ in }
    ) -> WaveRideSummary {
        var rules = SportThresholds.forSport(.wingfoil)
        change(&rules)
        return WaveRideFinder(thresholds: rules)
            .rides(in: track, flights: flights, swellFrom: swellFrom)
    }

    /// Widening the cone cannot leave a rider on fewer seconds of wave.
    ///
    /// Seconds rather than the count, deliberately: a wider cone can *merge*
    /// two rides into one by taking in the water between them, so the count
    /// is genuinely not monotonic and asserting that it is would pin a
    /// falsehood. Time on waves is the quantity that has to behave.
    @Test("A wider cone never finds less riding")
    func coneWidensMonotonically() {
        let track = waveDay()
        let narrow = rides(track) { $0.waveConeAngle = 10 }
        let middle = rides(track) { $0.waveConeAngle = 45 }
        let wide = rides(track) { $0.waveConeAngle = 90 }

        #expect(narrow.timeOnWaves <= middle.timeOnWaves)
        #expect(middle.timeOnWaves <= wide.timeOnWaves)
        #expect(narrow.timeOnWaves > 0, "a ten-degree cone should still hold the wave ridden straight")
    }

    @Test("Asking the wave for more never finds more riding")
    func gainTightensMonotonically() {
        let track = waveDay()
        let generous = rides(track) { $0.waveMinimumGain = 0 }
        let asShipped = rides(track)
        let strict = rides(track) { $0.waveMinimumGain = 0.8 }

        #expect(asShipped.timeOnWaves <= generous.timeOnWaves)
        #expect(strict.timeOnWaves <= asShipped.timeOnWaves)
        #expect(strict.count == 0, "a wave has to add eighty per cent — nothing here did")
    }

    /// The promise the rules sheet makes in as many words: "anything shorter
    /// is still counted in the riding time — it is simply not given a number
    /// of its own."
    @Test("The shortest-ride rule names fewer rides without losing riding time")
    func shortestRideOnlyNames() {
        let track = waveDay()
        let everything = rides(track) { $0.waveMinimumDuration = 3 }
        let named = rides(track) { $0.waveMinimumDuration = 18 }

        #expect(named.count < everything.count)
        #expect(abs(named.timeOnWaves - everything.timeOnWaves) < 0.001)
        #expect(abs(named.distance - everything.distance) < 0.001)
    }

    /// Distance and time have to describe the same water, because the card
    /// prints them side by side and a rider divides one by the other.
    @Test("Distance and riding time count the same rides")
    func distanceAndTimeAgree() {
        let track = waveDay()
        let all = rides(track) { $0.waveMinimumDuration = 3 }
        let some = rides(track) { $0.waveMinimumDuration = 18 }

        // The named rides are a subset, so their distance cannot exceed the
        // total — and the total is unchanged by which of them got a number.
        let namedDistance = some.rides.reduce(0) { $0 + $1.distance }
        #expect(namedDistance <= some.distance + 0.001)
        #expect(abs(all.distance - some.distance) < 0.001)
        #expect(some.distance > 0)
    }

    // MARK: Carving

    /// A turn up the face points out of the cone for a beat and comes back.
    /// That is one ride, and it is two only if the rider says a carve ends one.
    @Test("A carve out of the cone and back is one ride")
    func carveIsBridged() {
        let track = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),
            .init(speed: 9, heading: 0, duration: 8),
            .init(speed: 9, heading: 80, duration: 3),      // up the face
            .init(speed: 9, heading: 0, duration: 8),
            .init(speed: 6, heading: 90, duration: 60),
        ]))

        let bridged = rides(track)
        #expect(bridged.count == 1)
        #expect(bridged.rides[0].duration > 15, "the ride should run through the carve")

        // With no carve tolerance the ride ends at the turn, and the water
        // after it is a second ride — caught straight off the back of the
        // first, so measured against the lull the first rose out of rather
        // than against the first wave's own speed. It used to vanish here,
        // which was the back-to-back loss in miniature. See docs/WAVES.md.
        let split = rides(track) { $0.waveBridgeSeconds = 0 }
        #expect(split.count == 2)
        #expect(split.rides[0].duration < bridged.rides[0].duration - 5)
        #expect(!split.rides[0].linked)
        #expect(split.rides[1].linked, "the second half was caught off the first")
        #expect(split.timeOnWaves < bridged.timeOnWaves)
        #expect(bridged.linkedCount == 0)
    }

    // MARK: Back to back

    /// The good day. Kick out of one wave, lose half a knot in the turn, and
    /// the next face is under you inside the rise window. Measured against
    /// the seconds just before it, the second wave shows an eight per cent
    /// rise against a twelve per cent bar and was not a wave at all.
    @Test("A wave caught straight after another is found")
    func linkedWaves() {
        let track = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),
            .init(speed: 9, heading: 0, duration: 15),                 // wave one
            .init(speed: 8.8, heading: 150, duration: 3),              // kick out, turn back
            .init(speed: 9.5, heading: 10, duration: 15),              // wave two
            .init(speed: 6, heading: 90, duration: 60),
        ]))
        let summary = rides(track)
        #expect(summary.count == 2, "found \(summary.count): \(summary.rides.map(\.duration))")
        #expect(summary.rides.first?.linked == false)
        #expect(summary.rides.last?.linked == true)
        #expect(summary.linkedCount == 1)

        // And a third, off the back of the second: the lull carries down
        // the chain, because none of them gave the speed back.
        let three = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),
            .init(speed: 9, heading: 0, duration: 15),
            .init(speed: 8.8, heading: 150, duration: 3),
            .init(speed: 9.5, heading: 10, duration: 15),
            .init(speed: 9.2, heading: 150, duration: 3),
            .init(speed: 9.8, heading: 0, duration: 15),
            .init(speed: 6, heading: 90, duration: 60),
        ]))
        #expect(rides(three).count == 3)
        #expect(rides(three).linkedCount == 2)
    }

    /// The chain has a length. Ten seconds of turning back at the same speed
    /// is past the rise window, and what is under the board then is not the
    /// last wave's gift — it is a powered rider holding pace.
    @Test("A wave is linked only inside the rise window")
    func linkHasALimit() {
        let track = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),
            .init(speed: 9, heading: 0, duration: 15),
            .init(speed: 8.8, heading: 150, duration: 12),             // too long
            .init(speed: 9.5, heading: 10, duration: 15),
            .init(speed: 6, heading: 90, duration: 60),
        ]))
        let summary = rides(track)
        #expect(summary.count == 1, "the second stretch never rose out of a lull of its own")
        #expect(summary.linkedCount == 0)
    }

    /// A short hole in the fixes is still a hole. Seven seconds is inside
    /// the rise window, and the chain must not carry across it — what
    /// happened in there is not known.
    @Test("A wave is not linked across a hole in the recording")
    func noLinkAcrossADropout() {
        var points = SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),
            .init(speed: 9, heading: 0, duration: 40),
            .init(speed: 6, heading: 90, duration: 60),
        ])
        points.removeSubrange(75..<82)
        let track = builder.build(from: points)
        let summary = rides(track)
        #expect(summary.count == 1, "found \(summary.rides.map(\.duration))")
        #expect(summary.linkedCount == 0)
    }

    // MARK: Noise

    /// The reason the rise bar is firmer than the glide detector's, tested
    /// at last: a long steady run with the swell, on a receiver reporting
    /// position only, has its speed derived from jittery fixes — and jitter
    /// is not a wave. Before the catch rule, every one of these read as a
    /// single three-hundred-second wave: the lowest of eight noisy samples
    /// before it against the highest of three hundred inside it.
    ///
    /// Half a metre to a metre of jitter is the realistic band — it makes
    /// the same sample-to-sample speed steps as the bumpiest real Doppler
    /// recording — and nothing may be found there. Two and three metres of
    /// white jitter every second is worse than any receiver, and one seed
    /// in eight still slips a wave through; the number is pinned so that a
    /// change which makes it worse is noticed.
    @Test("GPS jitter on a steady run with the swell is not a wave")
    func jitterIsNotAWave() {
        let seeds: [UInt64] = [1, 7, 42, 1234, 2, 3, 99, 31337]
        func falseWaves(noise: Double) -> Int {
            seeds.reduce(0) { found, seed in
                let track = builder.build(from: SyntheticTrack.generate(
                    legs: [.init(speed: 8, heading: 0, duration: 300)],
                    speedAccuracy: nil, noise: noise, seed: seed))
                return found + rides(track).count
            }
        }
        #expect(falseWaves(noise: 0.5) == 0)
        #expect(falseWaves(noise: 1.0) == 0)
        #expect(falseWaves(noise: 2.0) <= 1)
        #expect(falseWaves(noise: 3.0) <= 1)
    }

    /// The other half of the catch rule: a rider cruising in the cone at a
    /// powered pace and *then* getting a wave. The cruise was riding by the
    /// per-sample rule; it was not the wave. The ride begins where the wave
    /// did, and the cruise is not in it.
    @Test("A ride begins at the catch, not at the cruise before it")
    func rideBeginsAtTheCatch() {
        let track = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),
            .init(speed: 6.5, heading: 10, duration: 30),              // cruising in the cone
            .init(speed: 9, heading: 0, duration: 20),                 // the wave
            .init(speed: 6, heading: 90, duration: 60),
        ]))
        let summary = rides(track)
        #expect(summary.count == 1)
        let ride = try! #require(summary.rides.first)
        // Within a couple of samples of the step: the catch is found where
        // the window ahead is already lifted, which is a sample or two
        // before the first fast fix.
        #expect(ride.startElapsed >= 86 && ride.startElapsed <= 92,
                "the ride should begin where the wave did, not at \(ride.startElapsed)")
        #expect(ride.duration < 25)
    }

    // MARK: What the receiver did not see

    /// A dropout is not a wave.
    ///
    /// Two samples either side of a hole are adjacent in the array and a
    /// minute apart on the water. Nothing else in the finder notices: both
    /// ends clear the floor, and an acceleration divided by a sixty-second
    /// step rounds to nothing. What came out was one ride spanning the gap,
    /// its duration counting a minute the distance did not.
    @Test("A ride never spans a gap in the fixes")
    func dropoutEndsTheRide() {
        var points = SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 40),
            .init(speed: 9, heading: 0, duration: 100),
            .init(speed: 6, heading: 90, duration: 40),
        ])
        // Sixty seconds out of the middle of the wave, as a receiver under a
        // wetsuit sleeve loses them.
        points.removeSubrange(60..<120)
        let track = builder.build(from: points)

        let summary = rides(track)
        #expect(summary.rides.allSatisfy { $0.duration < 30 },
                "a ride is spanning the dropout: \(summary.rides.map(\.duration))")
        // The stretch after the hole has no lull behind it to have risen out
        // of — the samples that would have shown one are gone — so it is not
        // claimed as a second ride. Saying nothing is the honest answer.
        #expect(summary.count == 1)
    }

    // MARK: On the foil, and off it

    @Test("With flights recorded, only the flying stretches can be rides")
    func flightsGateTheRides() {
        let track = waveDay()
        // The first wave was flown; the second was not.
        let flight = Flight(
            id: 0, startElapsed: 60, endElapsed: 79,
            startIndex: 60, endIndex: 79,
            distance: 171, averageSpeed: 9, maxSpeed: 9,
            takeoffSpeed: 9, landingSpeed: 9, confidence: 0.8
        )
        #expect(rides(track, flights: [flight]).count == 1)
        // A sport with no flight phase records none, and the gate does not
        // apply — the same track keeps both waves.
        #expect(rides(track).count == 2)
    }

    // MARK: The board rattling

    /// The rule the wave sheet was built to let a rider switch off, tested
    /// for the first time: a deck being worked ends a ride, and the rider can
    /// say it should not.
    @Test("A rattling deck ends a ride, unless the rider says otherwise")
    func quietDeckGate() {
        var points = SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),
            .init(speed: 9, heading: 0, duration: 20),
            .init(speed: 6, heading: 90, duration: 40),
            .init(speed: 9, heading: 20, duration: 15),
            .init(speed: 6, heading: 270, duration: 60),
        ])
        // Short chop under the first wave, and nothing else changed.
        for i in 60..<80 { points[i].verticalAccelSD = 9 }
        let track = builder.build(from: points)

        #expect(rides(track).count == 1, "the rattling wave should have been cut")
        #expect(rides(track) { $0.waveQuietFraction = SportThresholds.waveChopIgnored }.count == 2,
                "turned all the way off, the accelerometer stops deciding")
    }

    // MARK: Sports ridden slowly

    /// A prone surfer's whole ride happens under a wing rider's floor.
    ///
    /// The floor was a flat 3 m/s for every sport, so a paddle-in session
    /// came back empty and the pace slider — the control the screen tells
    /// the rider to reach for — could not rescue it, because the floor is the
    /// greater of the two.
    @Test("A slow wave day counts for the sports ridden slowly")
    func floorFollowsTheSport() {
        let track = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 2.0, heading: 90, duration: 60),
            .init(speed: 2.8, heading: 0, duration: 40),
            .init(speed: 2.0, heading: 90, duration: 60),
            .init(speed: 2.8, heading: 0, duration: 40),
            .init(speed: 2.0, heading: 270, duration: 60),
        ]))

        let wing = WaveRideFinder.forSport(.wingfoil)
            .rides(in: track, flights: [], swellFrom: swellFrom)
        #expect(wing.count == 0)
        #expect(wing.speedFloor == 3.0)

        let prone = WaveRideFinder.forSport(.prone)
            .rides(in: track, flights: [], swellFrom: swellFrom)
        #expect(prone.count == 2, "two waves at 2.8 m/s, both under the wing floor")
        #expect(prone.speedFloor == 2.5)
    }

    // MARK: What the reading rests on

    @Test("A recording with no motion channel says so")
    func motionDataIsReported() {
        var points = SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 60),
            .init(speed: 9, heading: 0, duration: 20),
            .init(speed: 6, heading: 90, duration: 40),
        ])
        #expect(rides(builder.build(from: points)).usedMotionData)

        for i in points.indices { points[i].verticalAccelSD = nil }
        #expect(!rides(builder.build(from: points)).usedMotionData,
                "an imported file has no accelerometer and the screen has to say so")
    }
}
