import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Distance splits")
struct SplitTests {

    /// Exactly 10 m/s in a straight line for 1000 s — 10 km, and every
    /// kilometre should take exactly 100 s.
    private func steadyTrack() -> Track {
        let points = SyntheticTrack.constantSpeed(10, duration: 1000, heading: 90)
        return TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
    }

    @Test("Even splits of an even session are even")
    func steadySplits() {
        let splits = SplitAnalyzer.splits(of: steadyTrack(), every: 1000)
        #expect(splits.count >= 9)

        for split in splits where split.isComplete {
            #expect(abs(split.distance - 1000) < 0.001)
            // Interpolating the boundary is what buys this tolerance; snapping
            // to the nearest fix would put it out by up to a sample.
            #expect(abs(split.duration - 100) < 1.5,
                    "split \(split.number) took \(split.duration) s")
            #expect(abs(split.averageSpeed - 10) < 0.2)
        }
    }

    @Test("Splits tile the session without gaps or overlap")
    func splitsCoverTheSession() {
        let track = steadyTrack()
        let splits = SplitAnalyzer.splits(of: track, every: 750)

        let total = splits.reduce(0) { $0 + $1.distance }
        #expect(abs(total - track.totalDistance) < 1,
                "splits covered \(total) of \(track.totalDistance) m")

        for (previous, next) in zip(splits, splits.dropFirst()) {
            #expect(abs(previous.endTime - next.startTime) < 0.001,
                    "gap between split \(previous.number) and \(next.number)")
        }
        #expect(splits.first?.startTime == 0)
    }

    @Test("The leftover distance is reported, not dropped")
    func partialFinalSplit() {
        // 10 km at 10 m/s, cut into 3 km splits: 3 + 3 + 3 + 1.
        let splits = SplitAnalyzer.splits(of: steadyTrack(), every: 3000)
        let last = splits.last

        #expect(splits.count == 4)
        #expect(last?.isComplete == false)
        #expect((last?.distance ?? 0) > 500 && (last?.distance ?? 0) < 1500)
        let allButLastComplete = splits.dropLast().allSatisfy(\.isComplete)
        #expect(allButLastComplete)
    }

    @Test("A slower split reads as slower")
    func splitsTrackTheSpeedProfile() {
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 12, heading: 90, duration: 200),
            .init(speed: 5, heading: 90, duration: 400, transition: 5),
        ])
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let splits = SplitAnalyzer.splits(of: track, every: 1000)

        #expect(splits.count >= 2)
        #expect(splits[0].averageSpeed > splits[splits.count - 1].averageSpeed,
                "the fast leg should not be the slow one")
        #expect(splits[0].maxSpeed > 10)
    }

    @Test("A session shorter than one split still produces one")
    func shortSession() {
        let points = SyntheticTrack.constantSpeed(5, duration: 60, heading: 0)
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let splits = SplitAnalyzer.splits(of: track, every: 1000)

        #expect(splits.count == 1)
        #expect(splits[0].isComplete == false)
    }

    @Test("An empty track produces no splits rather than a crash")
    func emptyTrack() {
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: [])
        #expect(SplitAnalyzer.splits(of: track, every: 1000).isEmpty)
    }
}
