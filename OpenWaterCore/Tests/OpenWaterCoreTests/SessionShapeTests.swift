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
}
