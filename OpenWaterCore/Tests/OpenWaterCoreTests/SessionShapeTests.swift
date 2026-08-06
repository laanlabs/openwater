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
