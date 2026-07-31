import Foundation
import Testing
@testable import OpenWaterCore

/// The live path and the post-session path have to agree.
///
/// They are separate implementations on purpose — the live one is incremental
/// so it can run once per second on a watch battery — which means they can
/// drift apart without anything failing to compile. These tests pin the places
/// where that drift would actually be visible to a rider.
@Suite("Live analyzer")
struct LiveAnalyzerTests {

    @Test("Heading is derived from movement when the receiver gives no course")
    func derivesCourseWhenMissing() {
        // Several receivers, and most imported files, carry no course channel.
        // The post-session builder derives it; the live path must too, or the
        // angles screen shows a compass stuck on north for the whole session.
        var points = SyntheticTrack.constantSpeed(9, duration: 60, heading: 90)
        for i in points.indices { points[i].course = nil }

        let analyzer = LiveAnalyzer(sport: .wingfoil)
        for point in points { analyzer.add(point) }

        let heading = analyzer.metrics.heading
        #expect(Geo.angleSeparation(heading, 90) < 12,
                "heading came out as \(heading)°, expected ≈90°")
    }

    @Test("A supplied course is preferred over a derived one")
    func prefersReportedCourse() {
        var points = SyntheticTrack.constantSpeed(9, duration: 30, heading: 90)
        // Claim a different course than the movement implies; the receiver's
        // own value is the better measurement and should win.
        for i in points.indices { points[i].course = 200 }

        let analyzer = LiveAnalyzer(sport: .wingfoil)
        for point in points { analyzer.add(point) }

        #expect(Geo.angleSeparation(analyzer.metrics.heading, 200) < 2)
    }

    @Test("Live speed and distance track the post-session figures")
    func agreesWithPostSessionAnalysis() {
        let points = SyntheticTrack.wingSession(runs: 6, runDuration: 60)

        let analyzer = LiveAnalyzer(sport: .wingfoil)
        for point in points { analyzer.add(point) }

        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let summary = SessionAnalyzer(sport: .wingfoil).analyse(track)

        // Distance is a straight sum either way, so it should match closely.
        #expect(abs(analyzer.metrics.distance - summary.distance) < 20,
                "live \(analyzer.metrics.distance) vs final \(summary.distance)")

        // Peak speed differs slightly by design: the live filter is forward-only
        // because a two-pass filter needs the future, so live peaks lag a little.
        // They must still be in the same place.
        #expect(abs(analyzer.metrics.maxSpeed - summary.maxSpeed) < 0.5,
                "live max \(analyzer.metrics.maxSpeed) vs final \(summary.maxSpeed)")
    }

    @Test("Live window bests are ordered the way the categories require")
    func windowOrdering() {
        let points = SyntheticTrack.wingSession(runs: 8, runDuration: 70)
        let analyzer = LiveAnalyzer(sport: .wingfoil)
        for point in points { analyzer.add(point) }

        let two = analyzer.metrics.best(.time(seconds: 2))
        let ten = analyzer.metrics.best(.time(seconds: 10))
        let hundred = analyzer.metrics.best(.distance(metres: 100))
        let fiveHundred = analyzer.metrics.best(.distance(metres: 500))

        #expect(two > 0 && ten > 0 && hundred > 0 && fiveHundred > 0)
        #expect(two >= ten - 1e-6, "2 s (\(two)) should not be slower than 10 s (\(ten))")
        #expect(hundred >= fiveHundred - 1e-6,
                "100 m (\(hundred)) should not be slower than 500 m (\(fiveHundred))")
        #expect(analyzer.metrics.fiveByTen <= ten + 1e-6,
                "5 × 10 s average should not beat the single best 10 s")
    }

    @Test("Out-of-order and duplicate fixes are rejected rather than corrupting the arrays")
    func rejectsBadFixes() {
        let points = SyntheticTrack.constantSpeed(9, duration: 30)
        let analyzer = LiveAnalyzer(sport: .wingfoil)
        for point in points { analyzer.add(point) }

        let distanceBefore = analyzer.metrics.distance
        // Replay an old fix: the prefix arrays everything downstream depends on
        // are only monotonic if this is dropped.
        analyzer.add(points[5])
        analyzer.add(points[5])

        #expect(analyzer.metrics.distance == distanceBefore)
    }
}
