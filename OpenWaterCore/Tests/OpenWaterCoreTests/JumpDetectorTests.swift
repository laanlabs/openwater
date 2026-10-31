import Foundation
import Testing
@testable import OpenWaterCore

/// What a jump is, what a swell is, and what a bad fix is.
///
/// Two reports shaped this. A rider sent back a parawing run — "one single
/// downwind run with no jumps" — and the app had found nine, one of them
/// claiming nineteen metres of air. Then a wingfoil rider sent back a session
/// with about fifteen real jumps in it and the app found **none**.
///
/// Both had the same cause. The detector read the accelerometer for a *collapse*
/// toward zero, on the theory that free fall is quiet. At the apex of a real
/// jump the measured session reads `verticalAccelSD` 8.5 and a peak of 12.6 —
/// the one-second window holds the takeoff, the air and the landing together,
/// so the signal spikes. Hunting for quiet found smooth water and missed every
/// jump, and only the landing-spike clause kept it from firing constantly.
///
/// Height is the signal now. These pin the ways that can go wrong.
@Suite("Jump detection")
struct JumpDetectorTests {

    let builder = TrackBuilder()

    /// A real flight, sampled the way the track samples one.
    ///
    /// Writing a profile by hand is how the first version of this suite went
    /// wrong: `[1.2, 2.4, 1.1]` reads like a tidy 2.4 m jump and is nothing of
    /// the sort — three samples a second apart is three seconds of air, which
    /// under gravity is an eleven-metre jump. A fixture has to obey `g·t²/8`
    /// or it is testing arithmetic against a shape that cannot occur.
    static func parabola(height: Double, interval: Double = 1) -> [Double] {
        let g = 9.80665
        let half = (8 * height / g).squareRoot() / 2
        var out: [Double] = []
        var tau = -(half / interval).rounded(.down) * interval
        while tau <= half {
            out.append(max(0, height - g / 2 * tau * tau))
            tau += interval
        }
        return out
    }

    /// A ride at a steady speed with a height profile written onto it.
    ///
    /// The profile is laid over the middle so the local baseline has real water
    /// either side of the event, which is the case it has to work in — a
    /// baseline taken from the edge of a track is not one.
    func ride(
        heights: [Double] = [],
        at offset: Int = 100,
        landingSpike: Double = 20,
        takeoffPop: Double = 0,
        stopsAfter: Bool = false,
        slowsAfter: Bool = false,
        noise: Double = 0.05,
        verticalAccuracy: Double = 1.5,
        baro: Bool = false
    ) -> Track {
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 240),
        ])
        for i in raw.indices {
            // Ordinary riding: a little height noise, a little chop, neither of
            // which is a jump.
            let wobble = i % 3 == 0 ? noise : (i % 3 == 1 ? -noise : 0)
            let height = wobble + (heights.indices.contains(i - offset) ? heights[i - offset] : 0)
            if baro {
                raw[i].absoluteAltitude = height
                raw[i].altitude = nil
            } else {
                raw[i].altitude = height
                raw[i].verticalAccuracy = verticalAccuracy
            }
            raw[i].verticalAccelSD = 1.4
            raw[i].verticalAccelPeak = 4
            // The landing lands where the profile comes back down; the pop,
            // when there is one, is the sample before the board left.
            if !heights.isEmpty, i == offset + heights.count - 1 {
                raw[i].verticalAccelPeak = landingSpike
            }
            if !heights.isEmpty, takeoffPop > 0, i == offset - 1 {
                raw[i].verticalAccelPeak = takeoffPop
            }
            // A wipeout: the rider comes down in the water and stops.
            if stopsAfter, !heights.isEmpty, (offset + heights.count..<offset + heights.count + 3).contains(i) {
                raw[i].speed = 0.8
            }
            // A landing that cost speed: half of it, for the three seconds
            // after the board came down, then back up to pace.
            if slowsAfter, !heights.isEmpty, (offset + heights.count..<offset + heights.count + 3).contains(i) {
                raw[i].speed = 4.5
            }
        }
        return builder.build(from: raw)
    }

    // MARK: What is not a jump

    @Test("Flat-water noise is not a jump")
    func flatWaterIsNotAJump() {
        #expect(JumpDetector.forSport(.wingfoil).detect(in: ride()).isEmpty)
    }

    @Test("A swell you climb is not a jump")
    func broadSwellIsNotAJump() {
        // Up over five seconds and down over four: the same height as a jump
        // and none of the rate, which is the only thing separating them — and
        // the reason a downwinder does not report thirty jumps a run.
        let track = ride(heights: [0.4, 0.9, 1.4, 1.8, 2.0, 1.8, 1.4, 0.9, 0.4])
        #expect(JumpDetector.forSport(.parawing).detect(in: track).isEmpty,
                "a swell climbed over five seconds is water, not air")
    }

    @Test("A rise with no landing is not a jump")
    func riseWithoutLandingIsNotAJump() {
        // The receiver wandering. Nothing hit the board, so nothing happened.
        let track = ride(heights: Self.parabola(height: 2.4), landingSpike: 3)
        #expect(JumpDetector.forSport(.wingfoil).detect(in: track).isEmpty)
    }

    @Test("A jump landed cleanly on the foil is still a jump")
    func softLandingWithATakeoffPopIsFound() {
        // The best-landed jumps are the softest. Requiring the slam had been
        // selecting against skill; the pop that put the board in the air is
        // the witness instead.
        let track = ride(heights: Self.parabola(height: 2.4), landingSpike: 4, takeoffPop: 12)
        #expect(JumpDetector.forSport(.wingfoil).detect(in: track).count == 1)
    }

    @Test("A jump that ends in the water is still a jump")
    func wipeoutIsFound() {
        // The biggest jump of the measured session: three seconds wide, no
        // slam because water is soft, and the rider stopping dead. A receiver
        // glitch does not stop the rider.
        // Not a clean parabola: the receiver's filter smears a big jump over
        // several samples, and that width is part of what says "not a
        // glitch". These are the measured session's own numbers at 13:30, in
        // metres — 4.2 ft at the apex, three seconds wide.
        let track = ride(heights: [0.30, 1.27, 0.94, 0.91], landingSpike: 4, stopsAfter: true)
        let jumps = JumpDetector.forSport(.wingfoil).detect(in: track)
        #expect(jumps.count == 1)
        #expect((jumps.first?.height ?? 0) > 2.0, "got \(jumps.first?.height ?? 0) m for the biggest jump of the day")
    }

    @Test("A one-sample rise with no witness at all is still a needle")
    func needleWithNoEvidenceIsRefused() {
        // No slam, no pop, and nobody stopped: the receiver wandered.
        let track = ride(heights: [1.6], landingSpike: 4)
        #expect(JumpDetector.forSport(.wingfoil).detect(in: track).isEmpty)
    }

    @Test("Heights the receiver does not trust are not evidence")
    func poorVerticalAccuracyIsIgnored() {
        let track = ride(heights: Self.parabola(height: 2.4), verticalAccuracy: 20)
        #expect(JumpDetector.forSport(.wingfoil).detect(in: track).isEmpty,
                "a fix reporting 20 m of vertical error cannot show a 2 m jump")
    }

    @Test("Without any height channel nothing is claimed")
    func noHeightNoJumps() {
        var raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 240)])
        for i in raw.indices { raw[i].altitude = nil; raw[i].baroAltitude = nil }
        #expect(JumpDetector.forSport(.wingfoil).detect(in: builder.build(from: raw)).isEmpty)
    }

    // MARK: What is

    @Test("A sharp rise ending in a landing is a jump")
    func realJumpIsFound() throws {
        let jumps = JumpDetector.forSport(.wingfoil).detect(in: ride(heights: Self.parabola(height: 2.4)))
        #expect(jumps.count == 1)
    }

    @Test("The height read back is the height jumped", arguments: [1.5, 2.4, 3.0])
    func heightSurvivesTheRoundTrip(_ height: Double) throws {
        // A real flight in, the same flight out. This is the measurement the
        // whole screen rests on, and reading it off the peak got it wrong by
        // two to three times — every jump on the reported session came back
        // shorter than a mast, which on a foil cannot happen.
        let track = ride(heights: Self.parabola(height: height))
        let jump = try #require(JumpDetector.forSport(.wingfoil).detect(in: track).first)

        #expect(abs(jump.height - height) < height * 0.3,
                "\(height) m jumped, \(jump.height) m reported")
        let detector = JumpDetector.forSport(.wingfoil)
        #expect(abs(jump.airtime - detector.airtime(forHeight: height)) < 0.4,
                "airtime \(jump.airtime) s for a \(height) m jump")
    }

    @Test("A wing carries you, so the same height lasts longer than on a prone foil")
    func liftLengthensAirtime() throws {
        // The rider's report: a best wing jump of two metres that lasted two
        // to three seconds, where free fall gives 1.3 s. Free fall is what a
        // prone foil gets, because nothing is holding it up.
        let track = ride(heights: Self.parabola(height: 2.0))
        let wing = try #require(JumpDetector.forSport(.wingfoil).detect(in: track).first)
        let prone = try #require(JumpDetector.forSport(.prone).detect(in: track).first)
        #expect(prone.airtime < 1.5, "free fall from 2 m is 1.3 s, got \(prone.airtime)")
        #expect(wing.airtime > 2.0 && wing.airtime < 3.0, "a wing carried 2 m should last 2–3 s, got \(wing.airtime)")
    }

    @Test("A jump is never shorter than the water it left")
    func heightsAreNotPhysicallyImpossible() throws {
        // The rider's own check, as a test. Reading the apex off a filtered,
        // once-a-second channel returned heights below a mast length; recovering
        // it from the area does not.
        let track = ride(heights: Self.parabola(height: 1.5))
        let jump = try #require(JumpDetector.forSport(.wingfoil).detect(in: track).first)
        #expect(jump.height > 0.8, "a foil jump under a mast length is not a jump")
    }

    @Test("One sample of air is still a jump when something landed")
    func oneSampleJumpIsFound() {
        // The case a height-only detector must discard as a needle. The landing
        // spike is what lets this one be kept — a receiver glitch does not come
        // with 20 m/s² through the board — and on the measured wingfoil session
        // it is the difference between six jumps and twenty-two.
        #expect(JumpDetector.forSport(.wingfoil).detect(in: ride(heights: [1.6])).count == 1)
    }

    @Test("The bar rises with the water")
    func barIsRelativeToTheSession() {
        let detector = JumpDetector.forSport(.parawing)
        let flat = ride(noise: 0.05)
        let swell = ride(noise: 0.45)

        #expect(detector.riseBar(for: flat, heights: flat.points.map(\.altitude))
                == detector.minimumRise, "flat water gets the floor")
        #expect(detector.riseBar(for: swell, heights: swell.points.map(\.altitude))
                > detector.minimumRise, "a metre of swell has to raise the bar with it")
    }

    @Test("On moving water the receiver is not read at all")
    func receiverIsRefusedOnASwell() {
        // The parawing report, in miniature. A rider dropping into a trough
        // climbs fast and lands hard, which satisfies every other clause here —
        // so on water rough enough to raise the bar off its floor, the
        // receiver's height is refused rather than believed. The rider's own
        // verdict on that session was "no jumps".
        let track = ride(heights: [1.4, 2.6, 1.0], noise: 0.45)
        #expect(JumpDetector.forSport(.parawing).detect(in: track).isEmpty)
    }

    @Test("A receiver that is merely noisy is still read")
    func noisyReceiverOnFlatWaterIsRead() {
        // The flat-water wing session: 0.18 m of second-to-second noise
        // from the wrist's receiver alone, ten jumps and no altimeter, and
        // the old rule — refuse the receiver the moment its noise clears
        // the floor — reported none of them. Noise is not swell.
        let track = ride(heights: [1.6], slowsAfter: true, noise: 0.2)
        let detector = JumpDetector.forSport(.wingfoil)
        let heights: [Double?] = track.points.map { $0.altitude }
        #expect(detector.riseBar(for: track, heights: heights) > detector.minimumRise,
                "the fixture has to be off the floor to test anything")
        #expect(detector.detect(in: track).count == 1)
    }

    @Test("On a noisy receiver the slam alone is not a landing")
    func noisyReceiverNeedsTheSpeedLossToo() {
        // Chop slams the board and keeps its speed. On the flat day, any one
        // witness let thirty-one noise rises through; the slam and the
        // speed it cost together let through the thirteen the rider counted.
        let track = ride(heights: [1.6], noise: 0.2)
        #expect(JumpDetector.forSport(.wingfoil).detect(in: track).isEmpty)
    }

    @Test("On a noisy receiver the speed loss alone is not a landing")
    func noisyReceiverNeedsTheSlamToo() {
        let track = ride(heights: [1.6], landingSpike: 4, slowsAfter: true, noise: 0.2)
        #expect(JumpDetector.forSport(.wingfoil).detect(in: track).isEmpty)
    }

    @Test("One landing is one jump")
    func aSecondRiseInsideTheLandingIsTheSameJump() {
        // The receiver smears a jump over its neighbours, and a rise two
        // samples after the apex with the same landing is not a second jump.
        let track = ride(heights: [1.6, 0.3, 1.6])
        #expect(JumpDetector.forSport(.wingfoil).detect(in: track).count == 1)
    }

    @Test("The altimeter is read in preference to the receiver")
    func altimeterIsPreferred() {
        // Both present: the altimeter wins, because it is the one that
        // delivered every second on a wrist and the receiver is filtered.
        var raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 240)])
        let profile = Self.parabola(height: 2.4)
        for i in raw.indices {
            raw[i].altitude = 0
            raw[i].absoluteAltitude = profile.indices.contains(i - 100) ? profile[i - 100] : 0
            raw[i].verticalAccuracy = 1.5
            raw[i].verticalAccelPeak = i == 100 + profile.count - 1 ? 20 : 4
        }
        let track = builder.build(from: raw)

        let reading = JumpDetector.forSport(.wingfoil).reading(for: track)
        #expect(reading.source == .barometer)
        #expect(!reading.barometerRefused)
        #expect(JumpDetector.forSport(.wingfoil).detect(in: track).count == 1)
    }

    /// A wrist on the water, as the first session to carry the altimeter
    /// recorded it: metres between one fix and the next, in no shape at all,
    /// over whatever the board was doing. Deterministic, so the fixture is
    /// the same every run.
    static func spray(_ i: Int) -> Double {
        let phase = Double((i * 7919) % 97) / 97
        return (phase - 0.5) * 6
    }

    @Test("An altimeter that cannot hold still is refused, and the receiver is read")
    func noisyAltimeterIsRefusedForTheReceiver() {
        // The reported session: 104 jumps of 15 to 177 ft on an afternoon
        // with none, every one of them the barometer under spray or wind. The
        // receiver's altitude on the same fixes was fine, so it is the one
        // that gets read — and the jump it holds is still found.
        var raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 240)])
        let profile = Self.parabola(height: 2.4)
        for i in raw.indices {
            let jump = profile.indices.contains(i - 100) ? profile[i - 100] : 0
            raw[i].altitude = jump
            raw[i].verticalAccuracy = 1.5
            raw[i].absoluteAltitude = jump + Self.spray(i)
            raw[i].verticalAccelPeak = i == 100 + profile.count - 1 ? 20 : 4
        }
        let track = builder.build(from: raw)
        let detector = JumpDetector.forSport(.wingfoil)
        let reading = detector.reading(for: track)

        #expect((reading.barometerSwing ?? 0) > detector.maximumBarometerSwing,
                "the fixture has to swing further than the bar to test anything")
        #expect(reading.barometerRefused)
        #expect(reading.source == .receiver)
        #expect(!reading.receiverRefused)
        #expect(detector.detect(in: track).count == 1, "the receiver still had the jump in it")
    }

    @Test("On a wrist the altimeter is not read, however still it holds")
    func wristAltimeterIsNotRead() {
        // The second watch session: an altimeter swinging only 2.3 m one
        // second in ten — over the bar by a hair — and 42 jumps on an
        // afternoon with none. A wrist is in the wind by physics, not by
        // luck, so it does not get to pass the bar on a drier day.
        var raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 240)])
        let profile = Self.parabola(height: 2.4)
        for i in raw.indices {
            let jump = profile.indices.contains(i - 100) ? profile[i - 100] : 0
            raw[i].altitude = jump
            raw[i].verticalAccuracy = 1.5
            raw[i].absoluteAltitude = jump
            raw[i].verticalAccelPeak = i == 100 + profile.count - 1 ? 20 : 4
        }
        let track = builder.build(from: raw)

        let desk = JumpDetector.forSport(.wingfoil).reading(for: track)
        #expect(desk.source == .barometer, "off a wrist a still altimeter is read")

        let wrist = JumpDetector.forSport(.wingfoil, altimeterOnWrist: true).reading(for: track)
        #expect(wrist.source == .receiver)
        #expect(wrist.barometerRefused)
        #expect(wrist.altimeterOnWrist)
        #expect(wrist.barometerSwing != nil, "the swing is still measured, for the screen")
        #expect(JumpDetector.forSport(.wingfoil, altimeterOnWrist: true).detect(in: track).count == 1,
                "the receiver still had the jump in it")
    }

    @Test("A receiver at a quarter metre of noise is refused")
    func receiverAtAQuarterMetreIsRefused() {
        // The Montauk wrist: 0.24 m of second-to-second noise, and the
        // strict rules — slam and speed loss together — still confirmed
        // two rises on an afternoon with no jumps. The flat day with
        // thirteen real ones was at 0.18, and the refusal sits between.
        let track = ride(heights: [1.6], slowsAfter: true, noise: 0.24)
        let detector = JumpDetector.forSport(.wingfoil)
        #expect(detector.reading(for: track).receiverRefused)
        #expect(detector.detect(in: track).isEmpty)
    }

    @Test("A refused altimeter on moving water claims nothing")
    func noisyAltimeterOnASwellClaimsNothing() {
        // The reported session exactly: the altimeter under spray, and the
        // receiver's height over the bar the sea sets for it. No channel is
        // left to read, and the rider's word was "no jumps" — so none.
        var raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 240)])
        let trough = [1.4, 2.6, 1.0]
        for i in raw.indices {
            let wobble = i % 3 == 0 ? 0.45 : (i % 3 == 1 ? -0.45 : 0)
            let height = trough.indices.contains(i - 100) ? trough[i - 100] : wobble
            raw[i].altitude = height
            raw[i].verticalAccuracy = 1.5
            raw[i].absoluteAltitude = height + Self.spray(i)
            raw[i].verticalAccelPeak = i == 102 ? 20 : 4
        }
        let track = builder.build(from: raw)
        let detector = JumpDetector.forSport(.parawing)
        let reading = detector.reading(for: track)

        #expect(reading.source == nil)
        #expect(reading.barometerRefused)
        #expect(reading.receiverRefused)
        #expect(detector.detect(in: track).isEmpty)
    }

    @Test("The altimeter is read on the water the receiver is refused on")
    func altimeterSurvivesASwell() {
        // The reason it is worth having: a trough and a jump are the same
        // shape to a filtered receiver, so on swell the receiver says nothing.
        // The altimeter measures the board and keeps going.
        let track = ride(heights: Self.parabola(height: 2.4), noise: 0.45, baro: true)
        #expect(!JumpDetector.forSport(.wingfoil).detect(in: track).isEmpty)
    }

    @Test("The relative barometer is carried but never read")
    func relativeBarometerIsNotASource() {
        // It lagged the arm by three seconds. It stays in the archive for
        // comparison and must not become a height channel by accident.
        var raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 240)])
        for i in raw.indices { raw[i].altitude = nil; raw[i].baroAltitude = 1.0; raw[i].absoluteAltitude = nil }
        #expect(JumpDetector.forSport(.wingfoil).reading(for: builder.build(from: raw)).source == nil)
    }

    @Test("The barometer survives the round trip to disk and back")
    func baroAltitudeSurvivesArchiving() throws {
        // The silent failure this exists to catch: a channel recorded on the
        // wrist, dropped in serialisation, and noticed only after somebody has
        // spent a session collecting it. Codable synthesises the key, but the
        // archive is a hand-written format in places and a new field is exactly
        // what such a format forgets.
        var raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 60)])
        for i in raw.indices {
            raw[i].baroAltitude = Double(i) * 0.1
            raw[i].absoluteAltitude = 100 + Double(i) * 0.1
            raw[i].verticalAccelSamples = (0..<10).map { Double(i * 10 + $0) * 0.01 }
        }
        let track = TrackBuilder().build(from: raw)
        var session = Session(sport: .wingfoil, startDate: .now, endDate: .now.addingTimeInterval(60),
                              track: track)
        session.recordingIssues = ["Health would not start collecting: test"]

        let data = try SessionArchive.encoder().encode(SessionArchive(session: session))
        let back = try SessionArchive.decode(data)

        let heights: [Double] = back.session.track.points.compactMap { $0.baroAltitude }
        #expect(heights.count == raw.count, "baroAltitude was dropped in the archive")
        let absolute: [Double] = back.session.track.points.compactMap { $0.absoluteAltitude }
        #expect(absolute.count == raw.count, "absoluteAltitude was dropped in the archive")
        let samples = back.session.track.points.compactMap(\.verticalAccelSamples)
        #expect(samples.count == raw.count, "verticalAccelSamples was dropped in the archive")
        #expect(samples.last?.last == Double((raw.count - 1) * 10 + 9) * 0.01)
        #expect(back.session.recordingIssues == ["Health would not start collecting: test"],
                "the watch's account of a fault was dropped in the archive")
        #expect(abs((heights.last ?? 0) - Double(raw.count - 1) * 0.1) < 0.001)
    }

}
