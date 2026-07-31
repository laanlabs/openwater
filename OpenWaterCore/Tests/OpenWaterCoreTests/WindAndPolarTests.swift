import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Wind estimation")
struct WindEstimatorTests {

    let builder = TrackBuilder()

    /// A session that reaches back and forth across a known wind, going up and
    /// then back down, which is what a real wing session looks like.
    func session(windFrom: Double) -> Track {
        var legs: [SyntheticTrack.Leg] = []
        // Two upwind reaches at ±50° and two downwind at ±140°, repeated.
        let angles: [Double] = [50, -50, 140, -140, 50, -50, 140, -140]
        for twa in angles {
            let heading = Geo.normalizeDegrees(windFrom + twa)
            legs.append(.init(speed: 9, heading: heading, duration: 60, transition: 4))
        }
        return builder.build(from: SyntheticTrack.generate(legs: legs))
    }

    @Test("Recovers the wind direction from a bidirectional session",
          arguments: [0.0, 45, 90, 180, 270, 315])
    func recoversWindDirection(windFrom: Double) {
        let t = session(windFrom: windFrom)
        let wind = try! #require(WindEstimator().estimate(from: t))

        #expect(wind.source == .estimatedBidirectional)
        let error = Geo.angleSeparation(wind.directionFrom, windFrom)
        #expect(error < 15, "wind \(windFrom)° estimated as \(wind.directionFrom)° (error \(error)°)")
        #expect(wind.confidence > 0.4)
    }

    @Test("A one-way run is reported as a downwind assumption, not a measurement")
    func oneWayRunIsFlaggedAsAssumption() {
        // Straight downwind for ten minutes, as on a point-to-point downwinder.
        let t = builder.build(from: SyntheticTrack.constantSpeed(11, duration: 600, heading: 200))
        let wind = try! #require(WindEstimator().estimate(from: t))

        #expect(wind.source == .estimatedDownwindOnly)
        // Riding 200° means the wind is behind, from 020°.
        #expect(Geo.angleSeparation(wind.directionFrom, 20) < 15)
        // And it must not claim to be confident about it.
        #expect(wind.confidence <= 0.6)
    }

    @Test("A rider's own wind entry always wins over the estimate")
    func manualWindWins() {
        let t = session(windFrom: 90)
        let manual = Wind(directionFrom: 200, source: .manual, confidence: 1)
        let summary = SessionAnalyzer(
            configuration: .init(sport: .wingfoil, wind: manual)
        ).analyse(t)
        #expect(summary.wind?.directionFrom == 200)
        #expect(summary.wind?.source == .manual)
    }
}

@Suite("Polar analysis")
struct PolarTests {

    let builder = TrackBuilder()

    @Test("True wind angles and tacks come out on the right sides")
    func twaConventions() {
        let wind = Wind(directionFrom: 0, source: .manual, confidence: 1)

        // Wind from the north. Heading north-east means the wind is on the port
        // bow, so this is port tack.
        #expect(wind.trueWindAngle(heading: 45) == 45)
        #expect(Run.probe(twa: 45).tack == .port)

        // Heading north-west puts the wind on the starboard bow.
        #expect(wind.trueWindAngle(heading: 315) == -45)
        #expect(Run.probe(twa: -45).tack == .starboard)

        // Straight into it, and straight away from it.
        #expect(PointOfSail(trueWindAngle: 0) == .noGo)
        #expect(PointOfSail(trueWindAngle: 180) == .running)
        #expect(PointOfSail(trueWindAngle: -45) == .closeHauled)
    }

    @Test("VMG is positive upwind and negative downwind")
    func vmgSign() {
        let wind = Wind(directionFrom: 0, source: .manual, confidence: 1)
        #expect(wind.vmg(speed: 10, heading: 0) > 0)       // straight upwind
        #expect(wind.vmg(speed: 10, heading: 180) < 0)     // straight downwind
        #expect(abs(wind.vmg(speed: 10, heading: 90)) < 1e-9)  // beam reach
        // 45° upwind: VMG is speed × cos 45.
        #expect(abs(wind.vmg(speed: 10, heading: 45) - 10 * cos(.pi / 4)) < 1e-9)
    }

    @Test("Tacking and gybing angles match the sailed geometry")
    func tackingAndGybingAngles() {
        let windFrom = 0.0
        let wind = Wind(directionFrom: windFrom, source: .manual, confidence: 1)

        // Upwind at ±45° (a 90° tacking angle) and downwind at ±145°
        // (a 70° gybing angle between the two downwind headings).
        var legs: [SyntheticTrack.Leg] = []
        for twa in [45.0, -45, 145, -145, 45, -45, 145, -145] {
            legs.append(.init(
                speed: 9,
                heading: Geo.normalizeDegrees(windFrom + twa),
                duration: 60, transition: 4
            ))
        }
        let t = builder.build(from: SyntheticTrack.generate(legs: legs))
        let polar = PolarBuilder().build(track: t, wind: wind)

        let tacking = try! #require(polar.tackingAngle)
        #expect(abs(tacking - 90) < 12, "tacking angle \(tacking)")

        let gybing = try! #require(polar.gybingAngle)
        #expect(abs(gybing - 70) < 12, "gybing angle \(gybing)")
    }

    @Test("An honest session scores symmetric; a one-sided one does not")
    func symmetryDetectsAFavouredSide() {
        let wind = Wind(directionFrom: 0, source: .manual, confidence: 1)

        func polar(portSpeed: Double, starboardSpeed: Double) -> PolarAnalysis {
            let legs: [SyntheticTrack.Leg] = [
                .init(speed: portSpeed, heading: 60, duration: 60, transition: 3),
                .init(speed: starboardSpeed, heading: 300, duration: 60, transition: 3),
                .init(speed: portSpeed, heading: 60, duration: 60, transition: 3),
                .init(speed: starboardSpeed, heading: 300, duration: 60, transition: 3),
            ]
            return PolarBuilder().build(
                track: builder.build(from: SyntheticTrack.generate(legs: legs)),
                wind: wind
            )
        }

        let even = polar(portSpeed: 10, starboardSpeed: 10)
        #expect(even.symmetry > 0.9)
        #expect(even.tackSpeedDelta < 0.06)

        let lopsided = polar(portSpeed: 12, starboardSpeed: 7)
        #expect(lopsided.symmetry < even.symmetry)
        #expect(lopsided.weakerTack == .starboard)
        #expect(lopsided.tackSpeedDelta > 0.2)
    }

    @Test("Best upwind VMG lands on a sensible angle")
    func bestUpwindVMG() {
        let wind = Wind(directionFrom: 0, source: .manual, confidence: 1)
        // Sail a spread of upwind angles. Speed rises as the angle opens, so the
        // VMG optimum should sit in the middle of the range, not at either end.
        var legs: [SyntheticTrack.Leg] = []
        for (twa, speed) in [(30.0, 5.0), (45, 8.0), (60, 9.5), (75, 10.0)] {
            legs.append(.init(speed: speed, heading: twa, duration: 60, transition: 3))
            legs.append(.init(speed: speed, heading: 360 - twa, duration: 60, transition: 3))
        }
        let t = builder.build(from: SyntheticTrack.generate(legs: legs))
        let polar = PolarBuilder().build(track: t, wind: wind)

        let best = try! #require(polar.bestUpwindVMG)
        // 45° × 8 = 5.66, 60° × 9.5 = 4.75, 30° × 5 = 4.33 → 45° wins.
        #expect(abs(abs(best.angle) - 45) < 12, "best upwind VMG at \(best.angle)°")
        #expect(best.vmg > 4)
    }
}

private extension Run {
    /// A minimal run used only to exercise the tack convention.
    static func probe(twa: Double) -> Run {
        Run(
            index: 0, startIndex: 0, endIndex: 1,
            startElapsed: 0, endElapsed: 1,
            distance: 10, averageSpeed: 10, maxSpeed: 10,
            meanHeading: 0, straightness: 1,
            startCoordinate: .init(latitude: 0, longitude: 0),
            endCoordinate: .init(latitude: 0, longitude: 0),
            trueWindAngle: twa
        )
    }
}
