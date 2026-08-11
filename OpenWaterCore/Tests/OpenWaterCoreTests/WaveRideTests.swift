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
}
