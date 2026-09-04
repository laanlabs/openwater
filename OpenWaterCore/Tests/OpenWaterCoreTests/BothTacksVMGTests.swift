import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Both-tacks VMG and per-tack angles")
struct BothTacksVMGTests {

    let wind = Wind(directionFrom: 0, speed: 8, source: .manual, confidence: 1)

    /// A clean beat: 45° off the wind on each tack, four legs upwind.
    /// Geometry says VMG = speed · cos 45° ≈ 0.707 · speed.
    func beatTrack(speed: Double = 8) -> Track {
        let points = SyntheticTrack.generate(legs: [
            .init(speed: speed, heading: 315, duration: 60, transition: 2),
            .init(speed: speed, heading: 45, duration: 60, transition: 2),
            .init(speed: speed, heading: 315, duration: 60, transition: 2),
            .init(speed: speed, heading: 45, duration: 60, transition: 2),
        ])
        return TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
    }

    @Test("A real beat produces a VMG near geometry's answer")
    func beatVMG() throws {
        let polar = PolarBuilder().build(track: beatTrack(), wind: wind)
        let beat = try #require(polar.beat)
        let expected = 8 * cos(Double.pi / 4)
        // Transitions between legs cost a little; the number must land close
        // below the geometric ceiling, never above it.
        #expect(beat.vmg > expected * 0.85, "beat VMG \(beat.vmg) vs ceiling \(expected)")
        #expect(beat.vmg <= expected * 1.02)
        #expect(beat.distance >= 1000)
        #expect(beat.portShare > 0.3 && beat.portShare < 0.7,
                "shares should be near even on a symmetric beat: \(beat.portShare)")
    }

    @Test("A one-tack reach cannot win the beat")
    func reachIsExcluded() {
        // Fast, and pointing 45° off the wind — but never changing tack, so
        // the axis progress is a wind shift's illusion, not a beat.
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 45, duration: 240),
        ])
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let polar = PolarBuilder().build(track: track, wind: wind)
        #expect(polar.beat == nil, "one tack produced a 'beat' at \(polar.beat?.vmg ?? 0) m/s")
    }

    @Test("A downwind zig-zag produces a run, not a beat")
    func runVMG() throws {
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 8, heading: 135, duration: 60, transition: 2),
            .init(speed: 8, heading: 225, duration: 60, transition: 2),
            .init(speed: 8, heading: 135, duration: 60, transition: 2),
            .init(speed: 8, heading: 225, duration: 60, transition: 2),
        ])
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let polar = PolarBuilder().build(track: track, wind: wind)
        let run = try #require(polar.broadRun)
        let expected = 8 * cos(Double.pi / 4)
        #expect(run.vmg > expected * 0.85)
        #expect(polar.beat == nil)
    }

    @Test("Per-tack angles read the geometry back")
    func perTackAngles() throws {
        let polar = PolarBuilder().build(track: beatTrack(), wind: wind)
        let port = try #require(polar.upwindAngle(.port))
        let starboard = try #require(polar.upwindAngle(.starboard))
        #expect(abs(port - 45) < 6, "port upwind angle \(port)")
        #expect(abs(starboard - 45) < 6, "starboard upwind angle \(starboard)")
        // And the tacking angle is their sum, near 90.
        let tacking = try #require(polar.tackingAngle)
        #expect(abs(tacking - 90) < 10, "tacking angle \(tacking)")
    }

    @Test("Old summaries without the new keys still decode")
    func decodeCompatibility() throws {
        let polar = PolarBuilder().build(track: beatTrack(), wind: wind)
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(polar)) as! [String: Any]
        // Strip every new key, as a version-1 archive would lack them.
        for key in ["portUpwindHeading", "starboardUpwindHeading",
                    "portDownwindHeading", "starboardDownwindHeading",
                    "beat", "broadRun", "courseDirection"] {
            object.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PolarAnalysis.self, from: stripped)
        #expect(decoded.beat == nil)
        #expect(decoded.bins.count == polar.bins.count)
    }

    // MARK: - Made good toward a course

    /// The river case. A symmetric beat makes its net progress dead upwind;
    /// measured toward a course 20° off the wind, the same displacement
    /// projects to cos 20° of it. Nothing else about the polar moves: the
    /// tacks, the angles and the shares are all still the wind's.
    @Test("A course off the wind measures the beat along it")
    func beatAlongACourse() throws {
        let track = beatTrack()
        let toWind = try #require(PolarBuilder().build(track: track, wind: wind).beat)
        let polar = PolarBuilder().build(track: track, wind: wind, courseDirection: 20)
        let toCourse = try #require(polar.beat)

        #expect(polar.courseDirection == 20)
        #expect(polar.madeGoodAxis == 20)
        let expected = toWind.vmg * cos(20 * Double.pi / 180)
        #expect(abs(toCourse.vmg - expected) < 0.15,
                "along the course \(toCourse.vmg), expected \(expected) from \(toWind.vmg) upwind")
        #expect(toCourse.vmg < toWind.vmg)
        #expect(abs(toCourse.portShare - toWind.portShare) < 0.05)
        // The working angle is still off the *wind*.
        let angle = try #require(toCourse.meanAngle)
        #expect(abs(angle - 45) < 6, "mean angle \(angle)")
        #expect(PolarBuilder().build(track: track, wind: wind).courseDirection == nil)
    }

    @Test("A course at right angles to the wind finds no beat")
    func courseAcrossTheWindIsNotABeat() {
        // Progress along a 90° course from a 315°/45° zig-zag nets to
        // nothing much either way — no stretch clears the others.
        let polar = PolarBuilder().build(track: beatTrack(), wind: wind, courseDirection: 90)
        let along = polar.beat?.vmg ?? 0
        #expect(along < 1.5, "a beam-on course produced a beat of \(along) m/s")
    }

    /// A rider choosing "legs 1 to 4" should get the same number the finder
    /// would have found for that stretch — the same sums, the same rules.
    @Test("A chosen span measures the way the best beat does")
    func measuredSpan() throws {
        let track = beatTrack()
        let polar = PolarBuilder().build(track: track, wind: wind)
        let beat = try #require(polar.beat)
        let whole = try #require(PolarAnalysis.BothTacksVMG.measured(
            track: track, wind: wind, from: 0, to: track.count - 1))
        #expect(whole.legs == 4, "legs \(whole.legs ?? -1)")
        #expect(whole.portShare > 0.4 && whole.portShare < 0.6)
        #expect(abs(whole.distance - track.totalDistance) < 1)
        // The whole track includes the ease-in from a standing start, so it
        // can only be a touch slower than the best window inside it.
        #expect(whole.vmg <= beat.vmg * 1.001)
        #expect(whole.vmg > beat.vmg * 0.9, "whole \(whole.vmg) vs beat \(beat.vmg)")

        // Half the track, one tack: still measured, still honest about it.
        let half = try #require(PolarAnalysis.BothTacksVMG.measured(
            track: track, wind: wind, from: 0, to: track.count / 4))
        #expect(half.legs == 1)
        #expect(half.portShare > 0.95 || half.portShare < 0.05)

        // Nonsense spans measure nothing.
        #expect(PolarAnalysis.BothTacksVMG.measured(track: track, wind: wind, from: 10, to: 10) == nil)
        #expect(PolarAnalysis.BothTacksVMG.measured(track: track, wind: wind, from: 20, to: 10) == nil)
    }

    @Test("A span sailed away from the course still reads as a speed")
    func spanAwayFromCourse() throws {
        // Measured toward 180 — dead downwind — a beat is progress *away*,
        // and comes back as its magnitude, not zero.
        let track = beatTrack()
        let away = try #require(PolarAnalysis.BothTacksVMG.measured(
            track: track, wind: wind, toward: 180, from: 0, to: track.count - 1))
        let toward = try #require(PolarAnalysis.BothTacksVMG.measured(
            track: track, wind: wind, from: 0, to: track.count - 1))
        #expect(abs(away.vmg - toward.vmg) < 0.001)
    }

    /// The legs measure made-good along the same axis the beat does, and
    /// the axis changes nothing about which samples are a leg.
    @Test("Upwind legs measure made-good along the course")
    func legsAlongACourse() throws {
        let track = beatTrack()
        let toWind = UpwindLegFinder.legs(track: track, wind: wind)
        // Point the course straight down the 45° legs: those make good at
        // nearly their full length, and the 315° legs, at right angles to
        // it, make good nothing.
        let toCourse = UpwindLegFinder.legs(track: track, wind: wind, madeGoodToward: 45)
        #expect(toWind.count == 4)
        #expect(toCourse.count == toWind.count)
        for (a, b) in zip(toWind, toCourse) {
            #expect(a.startIndex == b.startIndex && a.endIndex == b.endIndex)
            #expect(a.tack == b.tack)
            #expect(abs(a.meanAngle - b.meanAngle) < 0.01)
            #expect(a.distance == b.distance)
        }
        let along = try #require(toCourse.first { abs(Geo.angleDelta(from: 45, to: 45)) < 1 && $0.tack == .port })
        #expect(along.madeGood > along.distance * 0.9, "made good \(along.madeGood) of \(along.distance)")
        let across = try #require(toCourse.first { $0.tack == .starboard })
        #expect(across.madeGood < across.distance * 0.15, "made good \(across.madeGood) of \(across.distance)")
    }
}
