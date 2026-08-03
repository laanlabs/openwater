import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Session repair")
struct SessionRepairTests {

    /// A steady beam reach with position spikes injected at known places.
    ///
    /// The spikes displace fixes sideways without touching their Doppler
    /// channel — the exact signature of multipath: the position lies while the
    /// carrier does not.
    private func spikedPoints(
        spikesAt seconds: [Int],
        width: Int = 1,
        offset metres: Double = 60
    ) -> [TrackPoint] {
        var points = SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 300),
        ])
        let metresPerDegree = 111_320.0
        for start in seconds {
            for w in 0..<width where start + w < points.count {
                points[start + w].latitude += metres / metresPerDegree
            }
        }
        return points
    }

    private func session(from points: [TrackPoint]) -> Session {
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let summary = SessionAnalyzer(sport: .wingfoil).analyse(track)
        return Session(
            sport: .wingfoil,
            startDate: track.startDate ?? Date(),
            endDate: track.endDate ?? Date(),
            track: track,
            wind: summary.wind,
            summary: summary
        )
    }

    @Test("The scrub removes exactly the injected spikes")
    func scrubFindsInjectedSpikes() {
        let clean = SpikeScrub().clean(spikedPoints(spikesAt: [60, 150, 240]))
        #expect(clean.removed == 3, "removed \(clean.removed)")
    }

    @Test("A two-sample spike needs the second pass, and gets it")
    func scrubHandlesWideSpikes() {
        let clean = SpikeScrub().clean(spikedPoints(spikesAt: [100], width: 2))
        #expect(clean.removed == 2, "removed \(clean.removed)")
    }

    @Test("An honest track loses nothing — including its corners")
    func scrubLeavesHonestTracksAlone() {
        // Hard gybes everywhere: the manoeuvre a naive filter eats.
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 8, heading: 60, duration: 40, transition: 3),
            .init(speed: 8, heading: 240, duration: 40, transition: 3),
            .init(speed: 8, heading: 60, duration: 40, transition: 3),
            .init(speed: 8, heading: 240, duration: 40, transition: 3),
        ])
        let clean = SpikeScrub().clean(points)
        #expect(clean.removed == 0, "ate \(clean.removed) fixes of real riding")
    }

    @Test("Doppler agreement protects a genuinely fast fix")
    func scrubTrustsDoppler() {
        // The same sideways jump, but this time the receiver's own speed
        // channel says the sprint was real. Not ours to delete.
        var points = spikedPoints(spikesAt: [100])
        points[100].speed = 60
        let clean = SpikeScrub().clean(points)
        #expect(clean.removed == 0)
    }

    @Test("Duplicate-and-de-spike drops the fake max and keeps the original")
    func duplicateRemovesSpikes() {
        // An imported-GPX shape: no Doppler channel, so speed is derived from
        // positions and a spike really does become the session max — and a
        // displacement small enough (20 m over a second) to slip under the
        // builder's own plausibility gate. This is precisely the customer the
        // scrub exists for; anything bigger the builder already catches.
        var points = spikedPoints(spikesAt: [100], width: 2, offset: 20)
        for i in points.indices { points[i].speed = nil }
        let original = session(from: points)
        let originalMax = original.track.speed.max() ?? 0
        #expect(original.track.speedSource == .derived)
        #expect(originalMax > 8, "spike missing from fixture: max \(originalMax)")

        let (copy, removed) = original.duplicatedRemovingSpikes()
        #expect(removed == 2)
        #expect(copy.id != original.id)
        let copyMax = copy.track.speed.max() ?? 0
        #expect(copyMax < 8, "spike survived: \(copyMax) m/s on a 6 m/s track")
        // The original is untouched — same identity, same numbers.
        #expect((original.track.speed.max() ?? 0) == originalMax)
    }

    @Test("A plain duplicate is the same session under a new identity")
    func plainDuplicate() {
        var original = session(from: spikedPoints(spikesAt: []))
        original.title = "Big Wednesday"
        let copy = original.duplicated()
        #expect(copy.id != original.id)
        #expect(copy.title == "Big Wednesday (copy)")
        #expect(copy.track.count == original.track.count)
        #expect(copy.summary?.distance == original.summary?.distance)
    }

    @Test("Removing the max cuts the peak and is fully reversible")
    func removeMaxSpeed() throws {
        // A genuine 25 s burst: this is the rider deciding the number is
        // wrong, so the repair must work on real riding too.
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 6, heading: 90, duration: 120),
            .init(speed: 14, heading: 90, duration: 25, transition: 3),
            .init(speed: 6, heading: 90, duration: 120, transition: 3),
        ])
        let original = session(from: points)
        let originalMax = original.track.speed.max() ?? 0
        #expect(originalMax > 12)

        let repaired = try #require(original.removingMaxSpeed())
        #expect(repaired.previousMax == originalMax)
        #expect(repaired.newMax < originalMax * 0.8,
                "cut left \(repaired.newMax) of \(originalMax)")
        // Reversible: the cut is a trim removal, not a deletion.
        #expect(repaired.session.trim.isTrimmed)
        let restored = repaired.session.trimmed(to: .none)
        let restoredMax = restored.track.speed.max() ?? 0
        #expect(abs(restoredMax - originalMax) < 0.01)
    }
}

@Suite("Placeholder channels")
struct PlaceholderChannelTests {

    @Test("An all-zero course channel is ignored and courses derived")
    func constantCourseIsPlaceholder() {
        // Waterspeed's GPX writes <gpxtpx:course>0.00</gpxtpx:course> on every
        // point. Taken literally it points a whole session due north.
        var points = SyntheticTrack.generate(legs: [
            .init(speed: 8, heading: 120, duration: 120),
            .init(speed: 8, heading: 250, duration: 120, transition: 5),
        ])
        for i in points.indices { points[i].course = 0 }

        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let distinct = Set(track.course.map { ($0 / 10).rounded() })
        #expect(distinct.count > 1, "every course is still \(track.course.first ?? -1)")

        // And the polar spreads over angles instead of collapsing to one bin.
        let wind = Wind(directionFrom: 10, speed: 9, source: .manual, confidence: 1)
        let polar = PolarBuilder().build(track: track, wind: wind)
        #expect(polar.bins.filter(\.isSubstantial).count >= 2,
                "polar collapsed to \(polar.bins.count) bin(s)")
    }

    @Test("A genuine course channel is still believed")
    func realCourseIsKept() {
        var points = SyntheticTrack.generate(legs: [
            .init(speed: 8, heading: 90, duration: 60),
        ])
        // A real receiver's course wobbles around the truth.
        for i in points.indices { points[i].course = 90 + Double(i % 7) - 3 }
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let mean = track.course.reduce(0, +) / Double(track.course.count)
        #expect(abs(mean - 90) < 5, "mean course drifted to \(mean)")
    }
}
