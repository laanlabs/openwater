import Foundation
import Testing
@testable import OpenWaterCore

/// The wave rules as a paddled foil has them — see `docs/WAVES.md` §7.
///
/// On a wing a ride must travel with the swell; on a SUP foil a ride is a
/// stretch on the foil at speed, whichever way it points, and two waves in
/// one flight are told apart by the pump between them.
@Suite("Paddled foil waves")
struct PaddledWaveTests {

    let builder = TrackBuilder(options: .forSport(.supFoil))

    private func analyse(_ legs: [SyntheticTrack.Leg]) -> (Track, [Flight]) {
        let track = builder.build(from: SyntheticTrack.generate(legs: legs))
        let flights = FoilDetector.forSport(.supFoil).detect(in: track)
        return (track, flights)
    }

    /// Paddle, a wave ridden across the swell, a pump back out the other
    /// way, a second wave, paddle in.
    private var linkedDay: [SyntheticTrack.Leg] {
        [
            .init(speed: 1.5, heading: 0, duration: 60),      // paddling
            .init(speed: 6.5, heading: 90, duration: 30),     // wave one, down the line
            .init(speed: 3.6, heading: 270, duration: 12),    // pumping back out, on the foil
            .init(speed: 6.5, heading: 100, duration: 30),    // wave two
            .init(speed: 1.5, heading: 0, duration: 60),      // paddling
        ]
    }

    @Test("Direction is not consulted: the same waves whatever the swell", arguments: [0.0, 90.0, 180.0, 270.0])
    func directionFree(swellFrom: Double) {
        let (track, flights) = analyse(linkedDay)
        let waves = WaveRideFinder.forSport(.supFoil).rides(in: track, flights: flights, swellFrom: swellFrom)
        #expect(waves.count == 2, "swell from \(Int(swellFrom))°: \(waves.count) rides")
    }

    @Test("Two waves in one flight are split at the pump, and the second is linked")
    func pumpSplits() {
        let (track, flights) = analyse(linkedDay)
        #expect(flights.count == 1, "one flight — the rider never touched down")
        let waves = WaveRideFinder.forSport(.supFoil).rides(in: track, flights: flights, swellFrom: 180)
        #expect(waves.count == 2)
        #expect(waves.linkedCount == 1)
        #expect(waves.rides.first?.linked == false)
        #expect(waves.rides.last?.linked == true)
        // Neither ride swallowed the pump.
        for ride in waves.rides { #expect(ride.duration < 36) }
    }

    @Test("A bottom turn is not a pump")
    func bottomTurnIsOneWave() {
        let (track, flights) = analyse([
            .init(speed: 1.5, heading: 0, duration: 60),
            .init(speed: 6.5, heading: 90, duration: 20),
            .init(speed: 4.0, heading: 200, duration: 2),      // scrubbed speed, reversed for two seconds
            .init(speed: 6.5, heading: 80, duration: 20),
            .init(speed: 1.5, heading: 0, duration: 60),
        ])
        let waves = WaveRideFinder.forSport(.supFoil).rides(in: track, flights: flights, swellFrom: 180)
        #expect(waves.count == 1, "\(waves.count) rides")
        #expect((waves.rides.first?.duration ?? 0) >= 40)
    }

    @Test("A wing still needs the swell", arguments: [0.0, 180.0])
    func wingStillUsesDirection(swellFrom: Double) {
        // The same track on a wing: rides across the swell are not waves for
        // it, and the count depends on the axis. This pins that the
        // paddled rules leaked nowhere.
        let track = TrackBuilder().build(from: SyntheticTrack.generate(legs: linkedDay))
        let across = WaveRideFinder.forSport(.wingfoil).rides(in: track, flights: [], swellFrom: 0)
        let along = WaveRideFinder.forSport(.wingfoil).rides(in: track, flights: [], swellFrom: 270)
        #expect(across.count != along.count || across.count == 0)
    }
}
