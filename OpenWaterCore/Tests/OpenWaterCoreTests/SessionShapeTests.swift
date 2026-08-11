import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Session shape")
struct SessionShapeTests {

    let builder = TrackBuilder()

    /// A straight run at a steady speed on one heading.
    private func straightTrack(
        heading: Double,
        speed: Double = 8,
        duration: TimeInterval = 900
    ) -> Track {
        builder.build(from: SyntheticTrack.constantSpeed(speed, duration: duration, heading: heading))
    }

    private func shape(_ track: Track, wind: Wind?) -> SessionShape {
        let runs = RunSegmenter.forSport(.wingfoil).segment(track)
        return SessionShapeAnalyzer.analyse(track: track, runs: runs, wind: wind)
    }

    // MARK: - Classification

    @Test("A straight run with the wind behind it is a downwinder")
    func straightRunWithTheWindIsADownwinder() {
        // Sailing 180° (due south) with the wind from the north.
        let track = straightTrack(heading: 180)
        let wind = Wind(directionFrom: 0, speed: 9, source: .manual, confidence: 1)
        let result = shape(track, wind: wind)

        #expect(result.kind == .downwinder)
        #expect(result.netDisplacement > SessionShapeAnalyzer.minimumLegDisplacement)
        #expect(result.straightness > 0.95, "a constant heading is a straight line")
        #expect(result.downwindAlignment ?? 999 < 5, "dead downwind")
        #expect(result.legs.count == 1)
        #expect(result.legs.first?.isDownwind == true)
    }

    @Test("The same run across the wind is a crossing, not a downwinder")
    func crossWindRunIsACrossing() {
        // Sailing due south with the wind from the east: a beam reach.
        let track = straightTrack(heading: 180)
        let wind = Wind(directionFrom: 90, speed: 9, source: .manual, confidence: 1)
        let result = shape(track, wind: wind)

        #expect(result.kind == .crossing)
        #expect(result.downwindAlignment ?? 0 > SessionShapeAnalyzer.downwindTolerance)
        #expect(result.legs.first?.isDownwind == false)
    }

    @Test("An out-and-back finishes where it started, so it is a session at one spot")
    func outAndBackIsAtOneSpot() {
        let legs = [
            SyntheticTrack.Leg(speed: 8, heading: 180, duration: 400, transition: 6),
            SyntheticTrack.Leg(speed: 8, heading: 0, duration: 400, transition: 6),
        ]
        let track = builder.build(from: SyntheticTrack.generate(legs: legs))
        let wind = Wind(directionFrom: 0, speed: 9, source: .manual, confidence: 1)
        let result = shape(track, wind: wind)

        #expect(result.kind == .aroundASpot)
        #expect(result.straightness < 0.2, "you came back to where you started")
        let noneDownwind = result.legs.filter(\.isDownwind).isEmpty
        #expect(noneDownwind)
    }

    @Test("A lap session is at one spot however long it lasts")
    func lapsAreAtOneSpot() {
        let track = builder.build(from: SyntheticTrack.wingSession())
        let wind = Wind(directionFrom: 20, speed: 9, source: .manual, confidence: 1)
        let result = shape(track, wind: wind)

        #expect(result.kind == .aroundASpot)
    }

    // MARK: - Shuttle days

    @Test("A silence long enough to be a drive splits the session into two legs")
    func aShuttleSplitsIntoLegs() {
        // Two runs down the same line, with a twenty-minute break between them
        // and the second starting well upwind of where the first finished —
        // the shape of a shuttle, whichever way the rider recorded it.
        var points = SyntheticTrack.constantSpeed(8, duration: 600, heading: 180)
        let secondStart = points[0].timestamp.addingTimeInterval(600 + 20 * 60)
        var second = SyntheticTrack.constantSpeed(8, duration: 600, heading: 180)
        second = second.map { point in
            var moved = point
            moved.timestamp = secondStart.addingTimeInterval(point.timestamp.timeIntervalSince(second[0].timestamp))
            return moved
        }
        points.append(contentsOf: second)

        let track = builder.build(from: points)
        let wind = Wind(directionFrom: 0, speed: 9, source: .manual, confidence: 1)
        let result = shape(track, wind: wind)

        #expect(result.legs.count == 2, "the drive back is a break between runs")
        let everyLegDownwind = result.legs.filter { !$0.isDownwind }.isEmpty
        #expect(everyLegDownwind)
        #expect(result.kind == .downwinder)
    }

    @Test("A rest between runs is not a shuttle")
    func aBreakIsNotTransport() {
        // Reported from a real Gorge session: an afternoon of laps at one spot
        // came back as five separate "runs". The breaks were 140–290 seconds
        // and the rider had moved 84–160 metres in them. Being stopped is not
        // being carried, and splitting on silence alone said it was.
        var points = SyntheticTrack.constantSpeed(8, duration: 300, heading: 180)
        let last = points[points.count - 1]
        let resumeAt = last.timestamp.addingTimeInterval(280)

        // Restart five minutes later, ninety metres away — a rider sitting on
        // their board having a drink, not a rider in a car.
        let origin = Geo.destination(from: last.coordinate, bearing: 90, distance: 90)
        var second = SyntheticTrack.constantSpeed(8, duration: 300, heading: 0)
        let shiftLat = origin.latitude - second[0].latitude
        let shiftLon = origin.longitude - second[0].longitude
        let base = second[0].timestamp
        second = second.map { point in
            var moved = point
            moved.timestamp = resumeAt.addingTimeInterval(point.timestamp.timeIntervalSince(base))
            moved.latitude += shiftLat
            moved.longitude += shiftLon
            return moved
        }
        points.append(contentsOf: second)

        let track = builder.build(from: points)
        let result = shape(track, wind: nil)
        #expect(result.legs.count == 1, "a five-minute rest 90 m away is a break, not a drive")
    }

    @Test("Laps stay laps even when one stretch of them looks like a downwind run")
    func oneDownwindLegDoesNotMakeADownwinder() {
        // The other half of the same report. A lap session contains long
        // straight reaches, and one of them was 1.6 km dead downwind — so
        // asking "is any leg downwind?" called the whole afternoon a
        // downwinder despite it finishing metres from where it launched.
        let legs = [
            SyntheticTrack.Leg(speed: 8, heading: 180, duration: 500, transition: 6),
            SyntheticTrack.Leg(speed: 8, heading: 0, duration: 500, transition: 6),
        ]
        let track = builder.build(from: SyntheticTrack.generate(legs: legs))
        let wind = Wind(directionFrom: 0, speed: 9, source: .manual, confidence: 1)
        let result = shape(track, wind: wind)

        #expect(result.netDisplacement < SessionShapeAnalyzer.minimumLegDisplacement)
        #expect(result.kind == .aroundASpot,
                "you finished where you started, whatever any one stretch looked like")
    }

    @Test("A leg of laps is not a run, whichever way its drift points")
    func zigzagDriftIsNotACourse() {
        // Reported: a leg covering 6.88 km that displaced only 1.65 km was
        // labelled a run "1° off dead downwind". It was an hour of laps whose
        // net drift happened to point downwind. A bearing describes a course
        // only over a line; over a zigzag it describes the drift.
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<12 {
            legs.append(.init(speed: 8, heading: 170, duration: 120, transition: 6))
            legs.append(.init(speed: 8, heading: 355, duration: 110, transition: 6))
        }
        let track = builder.build(from: SyntheticTrack.generate(legs: legs))
        let wind = Wind(directionFrom: 350, speed: 9, source: .manual, confidence: 1)
        let result = shape(track, wind: wind)

        let leg = try? #require(result.legs.first)
        #expect(leg?.straightness ?? 1 < SessionShapeAnalyzer.straightnessWithoutWind,
                "precondition: this drifts rather than runs")
        #expect(leg?.isRun == false, "laps are not a run")
        #expect(leg?.isDownwind == false, "and so cannot be a downwind one")
        #expect(result.kind == .aroundASpot)
    }

    @Test("An ordinary session is one leg")
    func ordinarySessionIsOneLeg() {
        let track = builder.build(from: SyntheticTrack.wingSession())
        let result = shape(track, wind: nil)
        #expect(result.legs.count == 1, "no drive, no split")
    }

    // MARK: - Without wind

    @Test("Without wind a long straight line is still read as a downwinder")
    func geometryCarriesItWithoutWind() {
        let track = straightTrack(heading: 200)
        let result = shape(track, wind: nil)

        #expect(result.downwindAlignment == nil, "nothing to measure against")
        #expect(result.kind == .downwinder, "this straight over this far was not laps")
    }

    @Test("Without wind, laps are still laps")
    func lapsWithoutWind() {
        let track = builder.build(from: SyntheticTrack.wingSession())
        let result = shape(track, wind: nil)
        #expect(result.kind == .aroundASpot)
    }

    // MARK: - Degenerate input

    @Test("An empty track has a shape rather than a crash")
    func emptyTrack() {
        let track = builder.build(from: [])
        let result = SessionShapeAnalyzer.analyse(track: track, runs: [], wind: nil)
        #expect(result.kind == .aroundASpot)
        #expect(result.legs.isEmpty)
        #expect(result.netBearing == nil)
    }
}

@Suite("Glide direction")
struct GlideDirectionTests {

    let builder = TrackBuilder()

    /// Pump-and-glide cycles on a fixed heading.
    private func cycles(heading: Double) -> Track {
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<8 {
            legs.append(.init(speed: 5, heading: heading, duration: 6))
            legs.append(.init(speed: 9, heading: heading, duration: 12, transition: 2))
        }
        return builder.build(from: SyntheticTrack.generate(legs: legs))
    }

    private func glideCount(heading: Double, windFrom: Double?) -> Int {
        let track = cycles(heading: heading)
        let wind = windFrom.map { Wind(directionFrom: $0, speed: 9, source: .manual, confidence: 1) }
        return DownwindAnalyzer.forSport(.downwindSUP)
            .analyse(track: track, flights: [], wind: wind, movingTime: track.duration)
            .glideCount
    }

    @Test("Riding away from the wind produces glides")
    func downwindProducesGlides() {
        #expect(glideCount(heading: 180, windFrom: 0) > 0)
    }

    @Test("The same riding into the wind produces none")
    func upwindProducesNothing() {
        // The bug a rider reported: an upwind session came back with
        // thirty-four glides, the first sailed forty-six degrees off the wind.
        // Flying, fast and not decelerating describes a good beat as well as a
        // glide — only the direction tells them apart.
        #expect(glideCount(heading: 0, windFrom: 0) == 0, "a beat is not a glide")
    }

    @Test("A beam reach is not a glide either")
    func beamReachProducesNothing() {
        #expect(glideCount(heading: 90, windFrom: 0) == 0, "a bump cannot push you sideways")
    }

    @Test("Without wind there is nothing to check against, so candidates stand")
    func withoutWindCandidatesStand() {
        #expect(glideCount(heading: 0, windFrom: nil) > 0)
    }

    @Test("A beam reach is still not a glide at 95 degrees")
    func justAbaftTheBeamIsNotEnough() {
        // Riders put the line deeper than the beam: a shade below ninety is
        // still riding across the swell rather than being carried by it.
        #expect(glideCount(heading: 95, windFrom: 0) == 0)
    }

    @Test("Big swell in light wind still gives glides")
    func slowGlidesInBigSwellStillCount() {
        // The reason the speed test is relative. A fixed 6 m/s bar for a wing
        // was rejecting real glides whenever the swell was doing the work and
        // the wind was light — the rider is slower than usual, and every glide
        // that day falls under an absolute threshold set for a windy one.
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<8 {
            legs.append(.init(speed: 3.0, heading: 180, duration: 6))
            legs.append(.init(speed: 5.5, heading: 180, duration: 12, transition: 2))
        }
        let track = builder.build(from: SyntheticTrack.generate(legs: legs))
        let wind = Wind(directionFrom: 0, speed: 6, source: .manual, confidence: 1)
        let summary = DownwindAnalyzer.forSport(.wingfoil)
            .analyse(track: track, flights: [], wind: wind, movingTime: track.duration)

        #expect(summary.glideCount > 0, "5.5 m/s is fast for this day even if slow in general")
    }

    @Test("Powered riding at the day's ordinary pace is not a glide")
    func ridingAlongIsNotGliding() {
        // The other side of the same test: holding one speed the whole way is
        // riding, not gliding, however fast it is. Without a rise above the
        // rider's own pace there is nothing to say the swell did anything.
        let track = builder.build(from: SyntheticTrack.constantSpeed(9, duration: 600, heading: 180))
        let wind = Wind(directionFrom: 0, speed: 12, source: .manual, confidence: 1)
        let summary = DownwindAnalyzer.forSport(.wingfoil)
            .analyse(track: track, flights: [], wind: wind, movingTime: track.duration)

        // Nothing at all: with no lull before it, there is no rise, and
        // without a rise nothing says the water did the work.
        #expect(summary.glideCount == 0)
    }
}

@Suite("Glide continuity")
struct GlideContinuityTests {

    let builder = TrackBuilder()
    let wind = Wind(directionFrom: 0, speed: 9, source: .manual, confidence: 1)

    /// A long downwind ride with one brief dip in the middle.
    func rideWithADip() -> Track {
        builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 4.0, heading: 180, duration: 10),   // the lull it rises out of
            .init(speed: 9.0, heading: 180, duration: 30, transition: 2),
            .init(speed: 6.5, heading: 180, duration: 3),    // a gust dropping off
            .init(speed: 9.0, heading: 180, duration: 30, transition: 2),
        ]))
    }

    func glides(_ track: Track, tolerance: TimeInterval, flights: [Flight] = []) -> [Glide] {
        var a = DownwindAnalyzer.forSport(.wingfoil)
        a.glideGapTolerance = tolerance
        return a.analyse(track: track, flights: flights, wind: wind, movingTime: track.duration).glides
    }

    @Test("A brief dip does not end a glide")
    func aDipDoesNotEndAGlide() {
        // What a rider reported: one continuous downwind run drawn as a dozen
        // separate dashes, because a single fix under the speed floor ends a
        // glide and starts another.
        let track = rideWithADip()
        #expect(glides(track, tolerance: 0).count == 2, "precondition: it fragments without bridging")
        #expect(glides(track, tolerance: 20).count == 1, "one ride, one glide")
    }

    @Test("Bridging never crosses a touchdown")
    func aTouchdownEndsIt() {
        // Dropping off the foil genuinely ends a glide — it is the whole point
        // of the "linked" figure — so no tolerance may cross one.
        let track = rideWithADip()
        // Flights either side of the dip, so the dip is time on the water.
        let last = track.count - 1
        let flights = [
            Flight(id: 0, startElapsed: 10, endElapsed: 39, startIndex: 10, endIndex: 39,
                   distance: 270, averageSpeed: 9, maxSpeed: 9,
                   takeoffSpeed: 9, landingSpeed: 9, confidence: 0.9),
            Flight(id: 1, startElapsed: 43, endElapsed: 70, startIndex: 43, endIndex: last,
                   distance: 270, averageSpeed: 9, maxSpeed: 9,
                   takeoffSpeed: 9, landingSpeed: 9, confidence: 0.9),
        ]
        #expect(glides(track, tolerance: 60, flights: flights).count == 2,
                "a touchdown is a real break, whatever the tolerance")
    }

    @Test("Bridging never crosses pumping")
    func pumpingEndsIt() {
        // The protection for the sport the feature was built for. On a SUP the
        // gap between glides is work, and the accelerometer says so — so the
        // ten glides of a pump-and-glide session stay ten however generous the
        // tolerance is.
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<10 {
            legs.append(.init(speed: 3.0, heading: 180, duration: 6))
            legs.append(.init(speed: 9.0, heading: 180, duration: 12, transition: 2))
        }
        let track = builder.build(from: SyntheticTrack.generate(legs: legs))
        var a = DownwindAnalyzer.forSport(.downwindSUP)
        a.glideGapTolerance = 60
        let summary = a.analyse(track: track, flights: [], wind: wind, movingTime: track.duration)
        #expect(summary.glideCount == 10, "pumping between bumps is not one long glide")
    }
}

@Suite("Shallow dips")
struct ShallowDipTests {

    let builder = TrackBuilder()

    /// A flight with one dip in the middle, of a given depth and length.
    func flightWithDip(to speed: Double, for seconds: TimeInterval) -> [Flight] {
        let track = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 9.0, heading: 180, duration: 60),
            .init(speed: speed, heading: 180, duration: seconds),
            .init(speed: 9.0, heading: 180, duration: 60),
        ]))
        return FoilDetector(thresholds: SportThresholds.forSport(.wingfoil)).detect(in: track)
    }

    @Test("A shallow four-second dip is a lull, not a landing")
    func shallowDipDoesNotLand() {
        // Reported: a rider up for a whole downwind run had it cut into six
        // flights by dips of three to five seconds that never fell below
        // 7.6 knots. Takeoff is 4.5 m/s, so 4.0 is a wing going slightly soft
        // in a lull — the board never touched.
        #expect(flightWithDip(to: 4.0, for: 4).count == 1)
    }

    @Test("A deep four-second dip is kept, but does not end the ride")
    func deepShortDipIsRecordedNotSplit() {
        // The speed really did fall away — which is what happens when a foil
        // comes down, because the board is suddenly a boat. But four seconds
        // later the rider is up again, and nobody falls and recovers in four
        // seconds. This used to be asserted as two flights, on nothing but
        // intuition; a rider put the floor at twenty to thirty.
        let flights = flightWithDip(to: 1.5, for: 4)
        #expect(flights.count == 1, "four seconds is not a fall and a recovery")
        #expect(flights.first?.dips.count == 1, "the dip is real and has to be kept")
    }

    @Test("A deep dip long enough to be a fall does split the flight")
    func deepLongDipLands() {
        #expect(flightWithDip(to: 1.5, for: 30).count == 2)
    }

    @Test("A long shallow dip is still a landing")
    func longShallowDipLands() {
        // Shallow only buys a few seconds. Sitting at 4.0 m/s for half a minute
        // is displacement riding, whatever it started as.
        #expect(flightWithDip(to: 4.0, for: 30).count == 2)
    }
}

@Suite("Speed over ground and current")
struct CurrentTests {

    let builder = TrackBuilder()
    let wind = Wind(directionFrom: 0, speed: 10, source: .manual, confidence: 1)

    /// A river session: downwind is against the current and so reads slower
    /// over the ground than upwind does, for the same effort on the water.
    func riverLaps() -> Track {
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<3 {
            // Upwind, carried by the current.
            legs.append(.init(speed: 7.0, heading: 0, duration: 120, transition: 4))
            // Round up, lose speed.
            legs.append(.init(speed: 3.0, heading: 180, duration: 8, transition: 4))
            // Downwind, pushing into the current.
            legs.append(.init(speed: 5.0, heading: 180, duration: 120, transition: 2))
        }
        return builder.build(from: SyntheticTrack.generate(legs: legs))
    }

    @Test("The downwind pace sets the bar, not the session's")
    func referenceIsDirectional() {
        let track = riverLaps()
        let a = DownwindAnalyzer.forSport(.wingfoil)
        let sessionWide = a.typicalRidingSpeed(in: track)
        let downwindOnly = a.typicalRidingSpeed(in: track, wind: wind)

        #expect(downwindOnly < sessionWide,
                "the current makes downwind slower over the ground")
        #expect(downwindOnly * a.glideSpeedFraction < 5.0,
                "and the bar has to sit under the pace it is judging")
    }

    @Test("Glides are found downwind against a current")
    func glidesSurviveTheCurrent() {
        // The bug this came from: the floor was the whole-session median, which
        // the current-assisted upwind legs pushed above the rider's typical
        // downwind speed. More than half the riding a glide could happen in was
        // below the bar it had to clear, and a long continuous run came out as
        // a scatter of fragments.
        let track = riverLaps()
        let summary = DownwindAnalyzer.forSport(.wingfoil)
            .analyse(track: track, flights: [], wind: wind, movingTime: track.duration)

        #expect(summary.glideCount > 0, "the downwind legs are glides")
        #expect((summary.longestGlide?.duration ?? 0) > 60,
                "and each is one long one, not a scatter")
    }
}

@Suite("Quiet is relative to the rig")
struct PumpEnergyTests {

    let builder = TrackBuilder()
    let wind = Wind(directionFrom: 0, speed: 9, source: .manual, confidence: 1)

    /// Pump-and-glide where every reading is scaled up, as a noisier board or
    /// a differently-mounted device would produce.
    func cycles(noiseScale: Double) -> Track {
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<10 {
            legs.append(.init(speed: 3.0, heading: 180, duration: 6))
            legs.append(.init(speed: 9.0, heading: 180, duration: 12, transition: 2))
        }
        var points = SyntheticTrack.generate(legs: legs)
        for i in points.indices {
            if let sd = points[i].verticalAccelSD { points[i].verticalAccelSD = sd * noiseScale }
        }
        return builder.build(from: points)
    }

    private func glides(_ track: Track) -> Int {
        DownwindAnalyzer.forSport(.downwindSUP, thresholds: Sport.downwindSUP.thresholds)
            .analyse(track: track, flights: [], wind: wind, movingTime: track.duration).glideCount
    }

    @Test("A noisy rig finds the same glides as a quiet one")
    func noiseDoesNotMatter() {
        // A real parawing session read a median of 1.86 against a fixed bar of
        // 0.9 and reported no glides at all — every sample was "working"
        // because the whole recording sat above the line.
        let quiet = glides(cycles(noiseScale: 1))
        let noisy = glides(cycles(noiseScale: 5))
        #expect(quiet > 0)
        #expect(noisy == quiet, "scaling every reading must not change what was a glide")
    }

    @Test("Pumping still ends a glide however noisy the rig")
    func pumpingStillCounts() {
        // The guard that matters: the pump legs are five times the glide legs
        // whatever the scale, so they stay separate glides rather than merging
        // into one long one.
        #expect(glides(cycles(noiseScale: 5)) == 10)
    }
}

@Suite("One turn is one turn")
struct ManeuverMergingTests {

    let builder = TrackBuilder()

    /// Laps: each one ends in a turn, so the turn count should track the run
    /// count. Two independent parts of the analysis describing the same events
    /// have to agree, and before merging they disagreed by a factor of two.
    @Test("The turn count agrees with the run count")
    func turnsMatchRuns() {
        let track = builder.build(from: SyntheticTrack.wingSession(runs: 20))
        let summary = SessionAnalyzer(sport: .wingfoil).analyse(track)

        let runs = summary.runs.count
        let turns = summary.maneuverSummary.total
        #expect(runs > 1, "precondition: this session has laps")
        #expect(turns <= runs + 2,
                "\(turns) turns for \(runs) runs — one turn is being counted more than once")
        #expect(turns >= runs / 2, "\(turns) turns for \(runs) runs — turns are being missed")
    }

    @Test("Detections a moment apart are one turn")
    func adjacentDetectionsMerge() {
        let detector = ManeuverDetector.forSport(.parawing)
        func turn(id: Int, start: Double, end: Double, change: Double) -> Maneuver {
            Maneuver(id: id, startElapsed: start, endElapsed: end,
                     startIndex: Int(start), endIndex: Int(end), kind: .gybe,
                     exitTack: .port, headingChange: change,
                     entrySpeed: 10, exitSpeed: 9, minimumSpeed: 8,
                     recoveryTime: nil, radius: nil, stayedOnFoil: true,
                     score: 80, confidence: 0.9)
        }
        // Three detections a second apart: a rider carving out of one turn and
        // straight into the exit of it.
        let clustered = [turn(id: 0, start: 10, end: 14, change: 40),
                         turn(id: 1, start: 15, end: 18, change: 35),
                         turn(id: 2, start: 19, end: 22, change: 20)]
        let one = detector.merged(clustered)
        #expect(one.count == 1)
        #expect(one[0].startElapsed == 10 && one[0].endElapsed == 22, "it spans the whole turn")
        #expect(one[0].headingChange == 95, "and turned through all of it")

        // The same three, a minute apart: three turns.
        let separate = [turn(id: 0, start: 10, end: 14, change: 40),
                        turn(id: 1, start: 80, end: 84, change: 35),
                        turn(id: 2, start: 150, end: 154, change: 20)]
        #expect(detector.merged(separate).count == 3)
    }

    @Test("A merged turn is dry only if the rider stayed up throughout")
    func drynessSurvivesMerging() {
        let detector = ManeuverDetector.forSport(.parawing)
        func part(_ start: Double, _ end: Double, dry: Bool?) -> Maneuver {
            Maneuver(id: 0, startElapsed: start, endElapsed: end,
                     startIndex: Int(start), endIndex: Int(end), kind: .gybe,
                     exitTack: .port, headingChange: 30,
                     entrySpeed: 10, exitSpeed: 9, minimumSpeed: 8,
                     recoveryTime: nil, radius: nil, stayedOnFoil: dry,
                     score: 80, confidence: 0.9)
        }
        #expect(detector.merged([part(10, 12, dry: true), part(13, 15, dry: true)])
            .first?.stayedOnFoil == true)
        #expect(detector.merged([part(10, 12, dry: true), part(13, 15, dry: false)])
            .first?.stayedOnFoil == false, "touching down in any part of it is a wet turn")
    }
}

@Suite("Smoothness adapts, but only where it should")
struct SmoothnessBarTests {

    let builder = TrackBuilder()

    func track(_ legs: [SyntheticTrack.Leg], accelSD: @escaping (Double) -> Double) -> Track {
        builder.build(from: SyntheticTrack.generate(legs: legs).map { point in
            var p = point
            p.verticalAccelSD = accelSD(p.speed ?? 0)
            return p
        })
    }

    @Test("A noisy rig that was sometimes flying gets a higher bar")
    func bimodalLoosens() {
        // Quiet in the air and rough on the water, but both above the sport's
        // fixed figure — a real parawing session read a median of 1.86 against
        // a bar of 1.6, so over half of it could not be flying whatever the
        // speed said.
        // Enough of each for both quarters of the distribution to be real:
        // the test asks whether the rough quarter is well above the quiet one.
        let t = track([
            .init(speed: 9, heading: 90, duration: 60),
            .init(speed: 2, heading: 90, duration: 60, transition: 3),
            .init(speed: 9, heading: 90, duration: 60, transition: 3),
        ], accelSD: { $0 > 4.5 ? 1.8 : 4.0 })

        let detector = FoilDetector.forSport(.wingfoil)
        #expect(detector.smoothnessBar(for: t) > detector.thresholds.foilSmoothnessSD)
        #expect(!detector.detect(in: t).isEmpty, "the flying stretches are flights")
    }

    @Test("A rider planing the whole way gets no benefit")
    func unimodalHolds() {
        // One population and no quiet phase: raising the bar to meet it would
        // call every fast sample a flight, which is the false positive the
        // smoothness veto exists to prevent.
        let t = track([.init(speed: 9, heading: 90, duration: 90)], accelSD: { _ in 3.0 })
        let detector = FoilDetector.forSport(.wingfoil)
        #expect(detector.smoothnessBar(for: t) == detector.thresholds.foilSmoothnessSD)
        #expect(detector.detect(in: t).isEmpty, "planing is not flying")
    }

    @Test("A quiet rig is left exactly as it was")
    func quietRigUnchanged() {
        let t = track([
            .init(speed: 2, heading: 90, duration: 20),
            .init(speed: 9, heading: 90, duration: 60, transition: 3),
        ], accelSD: { $0 > 4.5 ? 0.4 : 2.5 })
        let detector = FoilDetector.forSport(.wingfoil)
        #expect(detector.smoothnessBar(for: t) == detector.thresholds.foilSmoothnessSD,
                "the bar never drops, and never rises without cause")
    }
}


@Suite("Coming down costs speed")
struct RoughnessDoesNotLandTests {

    let builder = TrackBuilder()

    func track(_ legs: [SyntheticTrack.Leg], accelSD: @escaping (Int, Double) -> Double) -> Track {
        var raw = SyntheticTrack.generate(legs: legs)
        for i in raw.indices { raw[i].verticalAccelSD = accelSD(i, raw[i].speed ?? 0) }
        return builder.build(from: raw)
    }

    @Test("A bang at full speed does not end a flight")
    func roughnessSpikeIsNotALanding() {
        // The reported case: a rider up for the whole run had it cut into
        // seven flights by six roughness spikes — landings from jumps and hard
        // chop — reading three times the smoothness bar for a few seconds
        // while they carried on at ten knots. Not one gap held a single sample
        // below flying speed.
        let t = track([.init(speed: 9, heading: 180, duration: 200)]) { index, _ in
            (60...66).contains(index) || (130...136).contains(index) ? 9.0 : 0.5
        }
        let flights = FoilDetector.forSport(.parawing).detect(in: t)
        #expect(flights.count == 1, "came back as \(flights.count) flights")
        #expect((flights.first?.duration ?? 0) > 180, "and it should span nearly the whole run")
    }

    @Test("Actually coming down still ends it")
    func realLandingStillSplits() {
        // Speed falls away, which is what happens when the board becomes a
        // boat — and it takes far longer than a spike to get going again.
        let t = track([
            .init(speed: 9, heading: 180, duration: 80),
            .init(speed: 1.5, heading: 180, duration: 40, transition: 2),
            .init(speed: 9, heading: 180, duration: 80, transition: 2),
        ]) { _, speed in speed > 4.5 ? 0.5 : 3.0 }

        #expect(FoilDetector.forSport(.parawing).detect(in: t).count == 2,
                "a real landing is a real break")
    }
}

@Suite("A run ends where the rider stopped")
struct RunEndsAtAStopTests {

    let builder = TrackBuilder()
    let wind = Wind(directionFrom: 270, speed: 10, source: .manual, confidence: 1)

    /// A downwind ride, an interruption of a given speed and length, then more
    /// of the same ride.
    private func legs(interruptedAt speed: Double, for seconds: TimeInterval) -> [SessionLeg] {
        let track = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 240),
            .init(speed: speed, heading: 90, duration: seconds, transition: 3),
            .init(speed: 9, heading: 90, duration: 600, transition: 3),
        ]))
        let runs = RunSegmenter.forSport(.parawing).segment(track)
        return SessionShapeAnalyzer.legs(
            track: track, runs: runs, wind: wind,
            stoppedBelow: Sport.parawing.thresholds.movingSpeed,
            minimumStop: Sport.parawing.thresholds.foilMinimumRecovery
        )
    }

    @Test("Sinking off the foil and pumping back on is one run")
    func sinkingIsNotAStop() {
        // Measured on the session that prompted this: eight of the rider's
        // nine drops off the foil bottomed out between three and six knots.
        // They were on the board the whole time.
        #expect(legs(interruptedAt: 2.0, for: 40).count == 1)
    }

    @Test("A swim in the middle of a downwinder ends the run")
    func aStopSplitsTheLeg() {
        // The ninth bottomed out at 0.2 knots, which is a person in the water,
        // and the rider counted the session as two runs because of it.
        #expect(legs(interruptedAt: 0.1, for: 60).count == 2)
    }

    @Test("A moment through the moving threshold is not a stop")
    func aBriefStopIsNotAStop() {
        // Long enough to be slow, far too short to have fallen and recovered.
        #expect(legs(interruptedAt: 0.1, for: 5).count == 1)
    }
}
