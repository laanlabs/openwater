import Foundation
import Testing
@testable import OpenWaterCore

/// The wave rules as a paddled foil has them — see `docs/WAVES.md` §7.
///
/// On a wing a ride must travel with the swell. On a SUP foil a ride is a
/// stretch on the foil at speed, along the face or straight down it, and
/// the direction has one job: a sustained stretch back *into* the swell is
/// the pump to the next wave, at any speed.
@Suite("Paddled foil waves")
struct PaddledWaveTests {

    let builder = TrackBuilder(options: .forSport(.supFoil))

    private func analyse(_ legs: [SyntheticTrack.Leg]) -> (Track, [Flight]) {
        let track = builder.build(from: SyntheticTrack.generate(legs: legs))
        let flights = FoilDetector.forSport(.supFoil).detect(in: track)
        return (track, flights)
    }

    /// Swell from the south: waves travel north. Paddle, a wave ridden down
    /// the line, a slow pump back out, a second wave, paddle in.
    private var slowLinkedDay: [SyntheticTrack.Leg] {
        [
            .init(speed: 1.5, heading: 0, duration: 60),      // paddling
            .init(speed: 6.5, heading: 80, duration: 30),     // wave one, down the line
            .init(speed: 3.6, heading: 180, duration: 12),    // pumping back out, slowly
            .init(speed: 6.5, heading: 100, duration: 30),    // wave two
            .init(speed: 1.5, heading: 0, duration: 60),      // paddling
        ]
    }

    /// The same day, but the pump back out is as fast as the ride — the
    /// first real SUP-foil recording — so only its heading gives it away.
    private var fastLinkedDay: [SyntheticTrack.Leg] {
        [
            .init(speed: 1.5, heading: 0, duration: 60),
            .init(speed: 6.5, heading: 20, duration: 30),
            .init(speed: 6.2, heading: 170, duration: 14),    // straight back into the swell, at speed
            .init(speed: 6.5, heading: 340, duration: 30),
            .init(speed: 1.5, heading: 0, duration: 60),
        ]
    }

    @Test("Riding down the line, eighty degrees off the swell, is still a wave")
    func downTheLineIsAWave() {
        let (track, flights) = analyse(slowLinkedDay)
        let waves = WaveRideFinder.forSport(.supFoil).rides(in: track, flights: flights, swellFrom: 180)
        #expect(waves.count == 2, "\(waves.count) rides")
        for ride in waves.rides { #expect(ride.offSwell > 60, "rode across the swell, \(Int(ride.offSwell))° off") }
    }

    @Test("A slow pump splits two waves, and the second is linked")
    func slowPumpSplits() {
        let (track, flights) = analyse(slowLinkedDay)
        #expect(flights.count == 1, "one flight — the rider never touched down")
        let waves = WaveRideFinder.forSport(.supFoil).rides(in: track, flights: flights, swellFrom: 180)
        #expect(waves.count == 2)
        #expect(waves.linkedCount == 1)
        #expect(waves.rides.last?.linked == true)
        for ride in waves.rides { #expect(ride.duration < 36) }
        #expect(waves.pumps.count == 1, "\(waves.pumps.count) pumps")
        #expect(waves.timePumping >= 8 && waves.timePumping <= 16, "\(waves.timePumping) s pumping")
    }

    @Test("A pump at full speed is told by its heading into the swell")
    func fastPumpSplits() {
        let (track, flights) = analyse(fastLinkedDay)
        #expect(flights.count == 1)
        let waves = WaveRideFinder.forSport(.supFoil).rides(in: track, flights: flights, swellFrom: 180)
        #expect(waves.count == 2, "\(waves.count) rides")
        #expect(waves.linkedCount == 1)
        #expect(waves.pumps.count == 1, "\(waves.pumps.count) pumps")
        #expect(waves.timePumping >= 10 && waves.timePumping <= 18, "\(waves.timePumping) s pumping")
        #expect(waves.distancePumping > 55 && waves.distancePumping < 110, "\(waves.distancePumping) m pumped")
    }

    @Test("A cutback through the swell's direction is not a pump")
    func cutbackIsOneWave() {
        let (track, flights) = analyse([
            .init(speed: 1.5, heading: 0, duration: 60),
            .init(speed: 6.5, heading: 40, duration: 20),
            .init(speed: 5.0, heading: 190, duration: 3),      // three seconds back through the swell
            .init(speed: 6.5, heading: 350, duration: 20),
            .init(speed: 1.5, heading: 0, duration: 60),
        ])
        let waves = WaveRideFinder.forSport(.supFoil).rides(in: track, flights: flights, swellFrom: 180)
        #expect(waves.count == 1, "\(waves.count) rides")
        #expect(waves.pumps.isEmpty)
        #expect((waves.rides.first?.duration ?? 0) >= 40)
    }

    @Test("The swell is read off the drop-ins, not the rides")
    func inferredFromCatches() {
        // Rides run east and west along a beach; every catch drops in
        // heading north. The swell is from the south, and a reading off
        // the whole rides would have said east-ish.
        let (track, flights) = analyse([
            .init(speed: 1.5, heading: 0, duration: 60),
            .init(speed: 6.5, heading: 0, duration: 4),
            .init(speed: 6.5, heading: 85, duration: 26),
            .init(speed: 1.5, heading: 180, duration: 60),
            .init(speed: 6.5, heading: 355, duration: 4),
            .init(speed: 6.5, heading: 80, duration: 26),
            .init(speed: 1.5, heading: 180, duration: 60),
        ])
        let from = WaveRideFinder.inferredSwell(in: track, flights: flights, thresholds: Sport.supFoil.thresholds)
        #expect(from != nil)
        if let from { #expect(Geo.angleSeparation(from, 180) < 30, "inferred from \(Int(from))°") }
    }

    @Test("A wing still needs the swell, and has no pumps")
    func wingStillUsesDirection() {
        let track = TrackBuilder().build(from: SyntheticTrack.generate(legs: slowLinkedDay))
        let across = WaveRideFinder.forSport(.wingfoil).rides(in: track, flights: [], swellFrom: 0)
        let along = WaveRideFinder.forSport(.wingfoil).rides(in: track, flights: [], swellFrom: 270)
        #expect(across.count != along.count || across.count == 0)
        let flights = FoilDetector.forSport(.wingfoil).detect(in: track)
        let waves = WaveRideFinder.forSport(.wingfoil).rides(in: track, flights: flights, swellFrom: 0)
        #expect(waves.pumps.isEmpty)
    }
}
