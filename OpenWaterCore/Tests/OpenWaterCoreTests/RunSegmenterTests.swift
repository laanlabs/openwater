import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Run segmenter")
struct RunSegmenterTests {

    let builder = TrackBuilder()

    @Test("A straight line is one run")
    func straightLineIsOneRun() {
        let t = builder.build(from: SyntheticTrack.constantSpeed(10, duration: 120))
        let runs = RunSegmenter().segment(t)
        #expect(runs.count == 1)
        #expect(runs[0].straightness > 0.99)
        #expect(abs(runs[0].meanHeading - 90) < 2)
    }

    @Test("Back-and-forth reaches split into separate runs")
    func reachesSplit() {
        // Four reaches with gybes between them.
        let t = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 60, duration: 60),
            .init(speed: 5, heading: 300, duration: 6, transition: 3),
            .init(speed: 10, heading: 300, duration: 60),
            .init(speed: 5, heading: 60, duration: 6, transition: 3),
            .init(speed: 10, heading: 60, duration: 60),
            .init(speed: 5, heading: 300, duration: 6, transition: 3),
            .init(speed: 10, heading: 300, duration: 60),
        ]))
        let runs = RunSegmenter().segment(t)
        #expect(runs.count == 4, "got \(runs.count) runs: \(runs.map { Int($0.meanHeading) })")

        // Headings should alternate between the two reaches.
        for (i, run) in runs.enumerated() {
            let expected: Double = i.isMultiple(of: 2) ? 60 : 300
            #expect(Geo.angleSeparation(run.meanHeading, expected) < 15,
                    "run \(i) heading \(run.meanHeading), expected ≈\(expected)")
        }
    }

    @Test("Heading noise inside a reach does not split it")
    func noiseDoesNotSplit() {
        // A rider bouncing through chop: the heading wobbles ±30° every few
        // seconds but the reach is continuous.
        var legs: [SyntheticTrack.Leg] = []
        for i in 0..<20 {
            let wobble: Double = i.isMultiple(of: 2) ? 30 : -30
            legs.append(.init(speed: 9, heading: 90 + wobble, duration: 3, transition: 1))
        }
        let t = builder.build(from: SyntheticTrack.generate(legs: legs))
        let runs = RunSegmenter().segment(t)
        #expect(runs.count == 1, "chop wobble split the reach into \(runs.count) runs")
    }

    @Test("Stopping ends a run and restarting begins a new one")
    func stopEndsRun() {
        let t = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 60),
            .init(speed: 0, heading: 90, duration: 60),
            .init(speed: 9, heading: 90, duration: 60),
        ]))
        let runs = RunSegmenter().segment(t)
        #expect(runs.count == 2)
        // The gap between them is the swim.
        #expect(runs[1].startElapsed - runs[0].endElapsed > 40)
    }

    @Test("Runs shorter than the minimum are discarded")
    func shortRunsDiscarded() {
        let t = builder.build(from: SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 60),
            .init(speed: 0, heading: 90, duration: 20),
            .init(speed: 9, heading: 90, duration: 2),   // 18 m — noise
            .init(speed: 0, heading: 90, duration: 20),
            .init(speed: 9, heading: 90, duration: 60),
        ]))
        let runs = RunSegmenter().segment(t)
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.distance >= 40 })
    }

    @Test("Run statistics match the leg they came from")
    func runStatistics() {
        let t = builder.build(from: SyntheticTrack.constantSpeed(12, duration: 100))
        let runs = RunSegmenter().segment(t)
        #expect(runs.count == 1)
        let r = runs[0]
        #expect(abs(r.averageSpeed - 12) < 0.2)
        #expect(abs(r.maxSpeed - 12) < 0.2)
        #expect(abs(r.distance - 1200) < 30)
        #expect(abs(r.duration - 99) < 2)
    }
}
