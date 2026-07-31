import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Ride state, falls and the ribbon")
struct RideStateTests {

    let builder = TrackBuilder()

    /// Flying, then off and stopped in the water, then flying again — a fall.
    func fallTrack() -> Track {
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 60),
            .init(speed: 0.2, heading: 90, duration: 25, transition: 2),
            .init(speed: 9, heading: 90, duration: 60, transition: 4),
        ])
        for i in raw.indices {
            raw[i].verticalAccelSD = (raw[i].speed ?? 0) > 4.5 ? 0.4 : 2.5
        }
        return builder.build(from: raw)
    }

    @Test("A stop straight after a flight is classified as a fall")
    func fallIsDetected() {
        let t = fallTrack()
        let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
        let classifier = RideStateClassifier.forSport(.wingfoil)
        let states = classifier.classify(track: t, flights: flights)

        #expect(states.contains(.foiling))
        #expect(states.contains(.fall))

        let summary = classifier.falls(track: t, states: states, flights: flights)
        #expect(summary.count == 1)
        let fall = try! #require(summary.falls.first)
        #expect(fall.gotBackUp)
        #expect(fall.speedBefore > 5)
        #expect(summary.timeLost > 10)
    }

    @Test("A stop with no preceding flight is a stop, not a fall")
    func stopWithoutFlightIsNotAFall() {
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 1.0, heading: 90, duration: 40),    // never gets going
            .init(speed: 0.1, heading: 90, duration: 40),
            .init(speed: 1.0, heading: 90, duration: 40),
        ])
        for i in raw.indices { raw[i].verticalAccelSD = 2.5 }
        let t = builder.build(from: raw)

        let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
        #expect(flights.isEmpty)

        let classifier = RideStateClassifier.forSport(.wingfoil)
        let states = classifier.classify(track: t, flights: flights)
        #expect(states.contains(.stopped))
        #expect(!states.contains(.fall))
        #expect(classifier.falls(track: t, states: states, flights: flights).count == 0)
    }

    @Test("A brief touchdown is not counted as a fall")
    func touchdownIsNotAFall() {
        // Comes off the foil but keeps moving fast and gets straight back up.
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 60),
            .init(speed: 6, heading: 90, duration: 4, transition: 1),
            .init(speed: 9, heading: 90, duration: 60, transition: 2),
        ])
        for i in raw.indices {
            raw[i].verticalAccelSD = (raw[i].speed ?? 0) > 7 ? 0.4 : 3.0
        }
        let t = builder.build(from: raw)

        let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
        let classifier = RideStateClassifier.forSport(.wingfoil)
        let states = classifier.classify(track: t, flights: flights)
        let summary = classifier.falls(track: t, states: states, flights: flights)

        #expect(summary.count == 0, "a 4 s touchdown at speed was miscounted as a fall")
        #expect(flights.count >= 1)
    }

    @Test("Segments cover the whole track with no gaps or overlaps")
    func segmentsTileTheTrack() {
        let t = fallTrack()
        let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
        let classifier = RideStateClassifier.forSport(.wingfoil)
        let states = classifier.classify(track: t, flights: flights)
        let segments = classifier.segments(track: t, states: states)

        #expect(!segments.isEmpty)
        #expect(segments[0].startIndex == 0)
        #expect(segments[segments.count - 1].endIndex == t.count - 1)

        // Consecutive segments share their boundary sample, so the drawn track
        // has no holes at state changes.
        for i in 1..<segments.count {
            #expect(segments[i].startIndex == segments[i - 1].endIndex,
                    "segments \(i - 1)/\(i) do not join: \(segments[i - 1].endIndex) then \(segments[i].startIndex)")
            #expect(segments[i].state != segments[i - 1].state,
                    "segments \(i - 1) and \(i) have the same state and should have merged")
        }
    }

    @Test("Clean-streak length reflects the gap between falls")
    func cleanStreak() {
        // Ride for a long time, fall, then ride a short time.
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 200),
            .init(speed: 0.2, heading: 90, duration: 20, transition: 2),
            .init(speed: 9, heading: 90, duration: 40, transition: 3),
        ])
        for i in raw.indices {
            raw[i].verticalAccelSD = (raw[i].speed ?? 0) > 4.5 ? 0.4 : 2.5
        }
        let t = builder.build(from: raw)

        let flights = FoilDetector.forSport(.wingfoil).detect(in: t)
        let classifier = RideStateClassifier.forSport(.wingfoil)
        let states = classifier.classify(track: t, flights: flights)
        let summary = classifier.falls(track: t, states: states, flights: flights)

        #expect(summary.count == 1)
        // The long first stretch is the streak, not the short final one.
        #expect(summary.longestCleanStreak > 150)
        #expect(summary.longestCleanDistance > 1000)
    }

    @Test("The ribbon gives every run its own lane")
    func ribbonLanesMatchRuns() {
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 60, duration: 60),
            .init(speed: 5, heading: 300, duration: 6, transition: 3),
            .init(speed: 10, heading: 300, duration: 60),
            .init(speed: 5, heading: 60, duration: 6, transition: 3),
            .init(speed: 10, heading: 60, duration: 60),
        ])
        for i in raw.indices { raw[i].verticalAccelSD = 0.4 }
        let t = builder.build(from: raw)

        let summary = SessionAnalyzer(sport: .wingfoil).analyse(t)
        let ribbon = summary.ribbon

        #expect(ribbon.lanes.count == summary.runs.filter { $0.distance >= 50 }.count)
        #expect(ribbon.lanes.count >= 3)
        #expect(ribbon.maxLaneDistance > 0)

        // Lanes must be in time order — the whole point is that they do not
        // overlap the way the map does.
        for i in 1..<ribbon.lanes.count {
            #expect(ribbon.lanes[i].startElapsed >= ribbon.lanes[i - 1].startElapsed)
        }

        // Cells within a lane run left to right and stay inside it.
        for lane in ribbon.lanes {
            #expect(!lane.cells.isEmpty, "lane \(lane.id) has no cells to draw")
            for cell in lane.cells {
                #expect(cell.start >= 0 && cell.end <= 1.0001)
                #expect(cell.end >= cell.start)
            }
        }

        // And something joins each consecutive pair.
        #expect(ribbon.connectors.count == max(0, ribbon.lanes.count - 1))
    }

    @Test("A session with a fall shows it as a connector between lanes")
    func ribbonMarksFalls() {
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 60, duration: 60),
            .init(speed: 0.2, heading: 60, duration: 25, transition: 2),
            .init(speed: 10, heading: 60, duration: 60, transition: 4),
        ])
        for i in raw.indices {
            raw[i].verticalAccelSD = (raw[i].speed ?? 0) > 4.5 ? 0.4 : 2.5
        }
        let t = builder.build(from: raw)
        let summary = SessionAnalyzer(sport: .wingfoil).analyse(t)

        #expect(summary.fallSummary.count == 1)
        #expect(summary.ribbon.connectors.contains { $0.kind == .fall })
    }

    @Test("Non-foiling sports get no falls")
    func noFallsForNonFoilingSports() {
        let t = fallTrack()
        let summary = SessionAnalyzer(sport: .windsurf).analyse(t)
        #expect(summary.fallSummary.count == 0)
        #expect(summary.flights.isEmpty)
        // But the states are still produced, so the map is still legible.
        #expect(!summary.states.isEmpty)
        #expect(!summary.segments.isEmpty)
    }
}
