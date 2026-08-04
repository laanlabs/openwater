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
                    "beat", "broadRun"] {
            object.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PolarAnalysis.self, from: stripped)
        #expect(decoded.beat == nil)
        #expect(decoded.bins.count == polar.bins.count)
    }
}
