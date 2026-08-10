import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Foil detection")
struct FoilDetectorTests {

    let builder = TrackBuilder()

    /// Build a track where the motion channel is set explicitly, so the
    /// detector's two inputs can be varied independently.
    func track(legs: [SyntheticTrack.Leg], accelSD: (Double) -> Double) -> Track {
        let raw = SyntheticTrack.generate(legs: legs).map { point -> TrackPoint in
            var p = point
            p.verticalAccelSD = accelSD(p.speed ?? 0)
            return p
        }
        return builder.build(from: raw)
    }

    @Test("A sustained fast smooth stretch is one flight")
    func singleFlight() {
        let t = track(legs: [
            .init(speed: 2, heading: 90, duration: 20),
            .init(speed: 9, heading: 90, duration: 60, transition: 3),
            .init(speed: 2, heading: 90, duration: 20, transition: 3),
        ], accelSD: { $0 > 4.5 ? 0.4 : 2.5 })

        let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
        #expect(flights.count == 1)
        let f = try! #require(flights.first)
        #expect(f.duration > 50)
        #expect(f.averageSpeed > 8)
    }

    @Test("Fast but rough riding is not a flight")
    func roughRidingIsNotFlying() {
        // Fast enough to clear the takeoff threshold, but the board is slamming
        // — this is planing, not flying, and it is the false positive that a
        // speed-only detector produces.
        let t = track(legs: [
            .init(speed: 9, heading: 90, duration: 90),
        ], accelSD: { _ in 3.0 })

        let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
        #expect(flights.isEmpty, "rough riding reported as \(flights.count) flights")
    }

    @Test("A brief touchdown does not split one flight into two")
    func briefTouchdownDoesNotSplitFlight() {
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 120),
        ])
        // One second of roughness in the middle: a clipped wingtip, not a landing.
        for i in raw.indices {
            let elapsed = raw[i].timestamp.timeIntervalSince(raw[0].timestamp)
            raw[i].verticalAccelSD = (elapsed >= 60 && elapsed < 61) ? 3.0 : 0.4
        }
        let flights = FoilDetector.forSport(.wingfoil).detect(in: builder.build(from: raw))
        #expect(flights.count == 1, "a 1 s touchdown split the flight into \(flights.count)")
    }

    /// A flight, a slow patch of a given length, and a flight.
    private func trackWithTouchdown(seconds: TimeInterval) -> Track {
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 60),
            .init(speed: 2, heading: 90, duration: seconds, transition: 2),
            .init(speed: 9, heading: 90, duration: 60, transition: 3),
        ])
        for i in raw.indices {
            raw[i].verticalAccelSD = (raw[i].speed ?? 0) > 4.5 ? 0.4 : 2.5
        }
        return builder.build(from: raw)
    }

    @Test("A real touchdown does split the flight")
    func realTouchdownSplitsFlight() {
        // Thirty seconds at walking pace. Long enough to have fallen, swum to
        // the board and got back up, which is what makes it two rides rather
        // than one — this test used to say fifteen, and a rider told us that
        // is not enough time for anybody to do any of that.
        let t = trackWithTouchdown(seconds: 30)
        let detector = FoilDetector.forSport(.wingfoil)
        let flights = detector.detect(in: t)
        #expect(flights.count == 2)

        let summary = detector.summarise(flights: flights, track: t, movingTime: t.duration)
        #expect(summary.touchdownCount == 1)
        #expect(summary.flightCount == 2)
        #expect(summary.foilingFraction > 0.5 && summary.foilingFraction < 1.0)
    }

    @Test("A touchdown too short to be a fall is one flight with a dip in it")
    func briefLandingIsADipNotTwoRides() {
        // The same shape, half the time in the water. Nobody falls and
        // recovers in fifteen seconds, so this is one ride — but the fifteen
        // seconds are real and every part of the analysis that asks about a
        // moment rather than about a ride still has to see them.
        let t = trackWithTouchdown(seconds: 15)
        let detector = FoilDetector.forSport(.wingfoil)
        let flights = detector.detect(in: t)

        #expect(flights.count == 1, "fifteen seconds is not a fall and a recovery")
        #expect(flights.first?.dips.count == 1, "the dip has to be kept, not swallowed")

        let summary = detector.summarise(flights: flights, track: t, movingTime: t.duration)
        #expect(summary.flightCount == 1)
        #expect(summary.touchdownCount == 0)
        #expect(summary.foilingFraction < 1.0,
                "the dipped seconds are inside the flight and are not time on foil")

        // And the instant-by-instant answer still says down in the middle.
        let mask = detector.flyingMask(flights: flights, count: t.count)
        let middle = t.count / 2
        #expect(mask[middle] == false, "the mask must not claim the rider was up in the dip")
    }

    @Test("Non-foiling sports never report flights")
    func nonFoilingSportsReportNothing() {
        let t = track(legs: [.init(speed: 15, heading: 90, duration: 120)],
                      accelSD: { _ in 0.3 })
        #expect(FoilDetector.forSport(.windsurf).detect(in: t).isEmpty)
        #expect(FoilDetector.forSport(.kitesurf).detect(in: t).isEmpty)
        #expect(!FoilDetector.forSport(.wingfoil).detect(in: t).isEmpty)
    }

    @Test("Without motion data the call is made on speed alone and says so")
    func noMotionDataLowersConfidence() {
        var raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 90)])
        for i in raw.indices { raw[i].verticalAccelSD = nil }
        let t = builder.build(from: raw)

        let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
        #expect(!flights.isEmpty)
        #expect(flights[0].confidence < 0.6, "speed-only flights must not claim high confidence")
    }
}

@Suite("Maneuver detection")
struct ManeuverDetectorTests {

    let builder = TrackBuilder()
    let wind = Wind(directionFrom: 0, source: .manual, confidence: 1)

    @Test("A turn through downwind is a gybe; a turn through the wind is a tack")
    func classification() {
        // Wind from the north.
        // Gybe: broad reach on one side (140°) round through 180 to the other (220°).
        let gybeTrack = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 140, duration: 40),
            .init(speed: 6, heading: 220, duration: 8, transition: 5),
            .init(speed: 10, heading: 220, duration: 40),
        ]))
        let gybes = ManeuverDetector.forSport(.wingfoil).detect(in: gybeTrack, wind: wind)
        #expect(gybes.count == 1, "expected 1 maneuver, got \(gybes.map(\.kind))")
        #expect(gybes.first?.kind == .gybe)

        // Tack: close hauled 40° round through 0 to 320°.
        let tackTrack = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 8, heading: 40, duration: 40),
            .init(speed: 4, heading: 320, duration: 8, transition: 5),
            .init(speed: 8, heading: 320, duration: 40),
        ]))
        let tacks = ManeuverDetector.forSport(.wingfoil).detect(in: tackTrack, wind: wind)
        #expect(tacks.count == 1, "expected 1 maneuver, got \(tacks.map(\.kind))")
        #expect(tacks.first?.kind == .tack)
    }

    @Test("Without a wind estimate turns are reported as turns, not guessed")
    func noWindMeansNoClassification() {
        let t = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 140, duration: 40),
            .init(speed: 6, heading: 220, duration: 8, transition: 5),
            .init(speed: 10, heading: 220, duration: 40),
        ]))
        let m = ManeuverDetector.forSport(.wingfoil).detect(in: t, wind: nil)
        #expect(m.count == 1)
        #expect(m.first?.kind == .turn)
        #expect(m.first?.exitTack == nil)
    }

    @Test("Speed loss and retention describe the turn")
    func speedMetrics() {
        // Enter at 12, drop to 4 through the turn, power back up to 11.
        let t = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 12, heading: 140, duration: 40),
            .init(speed: 4, heading: 220, duration: 6, transition: 4),
            .init(speed: 11, heading: 220, duration: 40, transition: 2),
        ]))
        let m = try! #require(ManeuverDetector.forSport(.wingfoil)
            .detect(in: t, wind: wind).first)

        #expect(m.entrySpeed > 11)
        #expect(m.minimumSpeed < 6)
        #expect(m.speedLoss > 0.5)
        #expect(m.recoveryTime != nil)

        // Exit speed is sampled after a settling beat, so it measures whether
        // the rider came out of the turn going — not the bottom of the turn,
        // which `minimumSpeed` already reports.
        #expect(m.exitSpeed > m.minimumSpeed,
                "exit \(m.exitSpeed) should exceed the turn minimum \(m.minimumSpeed)")
        // Well up from the 4 m/s bottom, though short of the 11 m/s the leg
        // eventually reaches — the smoother lags a hard ramp by design.
        #expect(m.exitSpeed > 6.5)
    }

    @Test("A dry gybe scores above a wet one")
    func dryGybeScoresHigher() {
        func gybe(minSpeed: Double, onFoil: Bool) -> Maneuver {
            var raw = SyntheticTrack.generate(legs: [
                .init(speed: 11, heading: 140, duration: 40),
                .init(speed: minSpeed, heading: 220, duration: 6, transition: 4),
                .init(speed: 11, heading: 220, duration: 40, transition: 4),
            ])
            for i in raw.indices {
                // On a dry gybe the board never slams; on a wet one it does.
                raw[i].verticalAccelSD = onFoil ? 0.4 : ((raw[i].speed ?? 0) > 6 ? 0.4 : 3.0)
            }
            let t = builder.build(from: raw)
            let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
            return ManeuverDetector.forSport(.wingfoil)
                .detect(in: t, wind: wind, flights: flights).first!
        }

        let dry = gybe(minSpeed: 8, onFoil: true)
        let wet = gybe(minSpeed: 2, onFoil: false)

        #expect(dry.isDry)
        #expect(!wet.isDry)
        #expect(dry.score > wet.score)
        #expect(dry.speedLoss < wet.speedLoss)
    }

    @Test("Chop and small course corrections are not maneuvers")
    func wobbleIsNotAManeuver() {
        var legs: [SyntheticTrack.Leg] = []
        for i in 0..<30 {
            legs.append(.init(
                speed: 10,
                heading: 140 + (i.isMultiple(of: 2) ? 20 : -20),
                duration: 3, transition: 1
            ))
        }
        let t = builder.build(from: SyntheticTrack.generate(legs: legs))
        let m = ManeuverDetector.forSport(.wingfoil).detect(in: t, wind: wind)
        #expect(m.isEmpty, "chop produced \(m.count) phantom maneuvers")
    }

    @Test("Summary counts and dry rate add up")
    func summaryArithmetic() {
        var legs: [SyntheticTrack.Leg] = []
        for i in 0..<6 {
            let heading: Double = i.isMultiple(of: 2) ? 140 : 220
            let next: Double = i.isMultiple(of: 2) ? 220 : 140
            legs.append(.init(speed: 10, heading: heading, duration: 40))
            legs.append(.init(speed: 6, heading: next, duration: 6, transition: 4))
        }
        var raw = SyntheticTrack.generate(legs: legs)
        for i in raw.indices { raw[i].verticalAccelSD = 0.4 }   // all dry
        let t = builder.build(from: raw)

        let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
        let m = ManeuverDetector.forSport(.wingfoil).detect(in: t, wind: wind, flights: flights)
        let summary = ManeuverSummary(maneuvers: m)

        #expect(summary.total == m.count)
        #expect(summary.gybes + summary.tacks + summary.carves <= summary.total)
        #expect(summary.dryGybeRate == 1.0)
        #expect(summary.meanScore > 0)
        #expect(summary.byExitTack.values.reduce(0, +) == m.filter { $0.exitTack != nil }.count)
    }
}

@Suite("Downwind glides")
struct DownwindAnalyzerTests {

    let builder = TrackBuilder()

    @Test("Pump-then-glide cycles are segmented into glides")
    func glidesAreFound() {
        // Six cycles: 6 s of pumping (rough, speed flat) then 12 s of glide
        // (quiet, speed building).
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<6 {
            legs.append(.init(speed: 5.5, heading: 200, duration: 6))
            legs.append(.init(speed: 8.5, heading: 200, duration: 12, transition: 2))
        }
        var raw = SyntheticTrack.generate(legs: legs)
        for i in raw.indices {
            // Pumping is work: high accelerometer energy at low speed.
            raw[i].verticalAccelSD = (raw[i].speed ?? 0) < 7 ? 1.6 : 0.35
        }
        let t = builder.build(from: raw)

        let analyzer = DownwindAnalyzer.forSport(.downwindSUP)
        let flights = FoilDetector.forSport(.downwindSUP).detect(in: t)
        let summary = analyzer.analyse(track: t, flights: flights, wind: nil, movingTime: t.duration)

        #expect(summary.glideCount >= 4, "found \(summary.glideCount) glides")
        #expect(summary.glideFraction > 0.3)
        #expect(summary.glideFraction < 1.0)
        #expect(summary.usedMotionData)
        let longest = try! #require(summary.longestGlide)
        #expect(longest.duration > 5)
    }

    @Test("Constant grinding with no glides reports none")
    func noGlidesWhenAlwaysWorking() {
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 200, duration: 300),
        ])
        for i in raw.indices { raw[i].verticalAccelSD = 1.8 }   // pumping throughout
        let t = builder.build(from: raw)

        let summary = DownwindAnalyzer.forSport(.downwindSUP)
            .analyse(track: t, flights: [], wind: nil, movingTime: t.duration)
        #expect(summary.glideCount == 0)
        #expect(summary.glideFraction == 0)
    }

    @Test("Bump period is recovered from the speed oscillation")
    func bumpPeriodFromSpeedTrace() {
        // Speed oscillating with a 10 s period, as when riding a swell train.
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<30 {
            legs.append(.init(speed: 6, heading: 200, duration: 5, transition: 2))
            legs.append(.init(speed: 10, heading: 200, duration: 5, transition: 2))
        }
        let t = builder.build(from: SyntheticTrack.generate(legs: legs))

        let period = try! #require(DownwindAnalyzer.forSport(.downwindSUP).bumpPeriod(of: t))
        #expect(abs(period - 10) < 2.5, "bump period estimated at \(period) s")
    }

    @Test("Without motion data glides are still found but flagged low confidence")
    func noMotionDataLowersConfidence() {
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<6 {
            legs.append(.init(speed: 5, heading: 200, duration: 6))
            legs.append(.init(speed: 9, heading: 200, duration: 12, transition: 2))
        }
        var raw = SyntheticTrack.generate(legs: legs)
        for i in raw.indices { raw[i].verticalAccelSD = nil }
        let t = builder.build(from: raw)

        let summary = DownwindAnalyzer.forSport(.downwindSUP)
            .analyse(track: t, flights: [], wind: nil, movingTime: t.duration)
        #expect(!summary.usedMotionData)
        #expect(summary.confidence < 0.5)
        #expect(summary.averagePumpsPerGlide == nil, "pump counts need motion data")
    }
}

@Suite("Session analyzer")
struct SessionAnalyzerTests {

    let builder = TrackBuilder()

    @Test("A full wing session produces a coherent summary")
    func endToEnd() {
        let t = builder.build(from: SyntheticTrack.wingSession())
        let summary = SessionAnalyzer(sport: .wingfoil).analyse(t)

        #expect(summary.analysisVersion == SessionSummary.currentVersion)
        #expect(summary.distance > 0)
        #expect(summary.maxSpeed > 0)
        #expect(summary.movingTime > 0)
        #expect(summary.movingTime <= summary.duration)
        #expect(summary.averageMovingSpeed >= summary.averageSpeed)
        #expect(!summary.runs.isEmpty)
        #expect(summary.wind != nil)
        #expect(summary.polar != nil)
        #expect(!summary.speedResults.isEmpty)

        // The max instantaneous speed can never be beaten by any averaged window.
        for r in summary.speedResults where r.isValid {
            #expect(r.speed <= summary.maxSpeed + 1e-6,
                    "\(r.category.shortName) at \(r.speed) exceeds max \(summary.maxSpeed)")
        }
    }

    @Test("Non-wind sports skip the wind and polar stages entirely")
    func nonWindSportsSkipWindStages() {
        let t = builder.build(from: SyntheticTrack.constantSpeed(4, duration: 300))
        let summary = SessionAnalyzer(sport: .kayak).analyse(t)
        #expect(summary.wind == nil)
        #expect(summary.polar == nil)
        #expect(summary.flights.isEmpty)
        #expect(summary.distance > 0)
    }

    @Test("Moving time excludes the time spent stopped")
    func movingTimeExcludesStops() {
        let t = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 90, duration: 100),
            .init(speed: 0, heading: 90, duration: 100),
            .init(speed: 10, heading: 90, duration: 100),
        ]))
        let summary = SessionAnalyzer(sport: .wingfoil).analyse(t)
        #expect(abs(summary.movingTime - 200) < 15, "moving time \(summary.movingTime)")
        #expect(summary.duration > 290)
    }
}
