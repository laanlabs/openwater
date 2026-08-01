import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Session trim")
struct SessionTrimTests {

    /// Ten minutes of sitting still, twenty of sailing, five more of sitting —
    /// the shape of a real recording where somebody hit record on the beach and
    /// stopped it back at the car.
    private func session() -> Session {
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 0.1, heading: 90, duration: 600),
            .init(speed: 9, heading: 120, duration: 1200, transition: 10),
            .init(speed: 0.1, heading: 120, duration: 300, transition: 10),
        ])
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

    @Test("Trimming lifts the averages that dead time was dragging down")
    func trimImprovesAverages() {
        let original = session()
        let before = try! #require(original.summary)

        let trimmed = original.trimmed(to: SessionTrim(startOffset: 600, endOffset: 1800))
        let after = try! #require(trimmed.summary)

        #expect(after.duration < before.duration)
        #expect(after.averageSpeed > before.averageSpeed,
                "average was \(before.averageSpeed), should rise once the sitting is cut")
        // Essentially all the distance was covered while sailing. Not exactly
        // all: the fixture drifts at 0.1 m/s rather than sitting perfectly
        // still, which over fifteen minutes is a real hundred metres — as it
        // would be on the water.
        #expect(after.distance > before.distance * 0.95,
                "trimmed \(after.distance) of \(before.distance) — the trim cut into the sailing")
        #expect(after.distance <= before.distance)
    }

    @Test("Nothing is deleted — a trim can be widened again")
    func trimIsReversible() {
        let original = session()
        let originalPoints = original.track.count

        let trimmed = original.trimmed(to: SessionTrim(startOffset: 600, endOffset: 1800))
        #expect(trimmed.track.count < originalPoints)
        // The full recording is still there behind the trim.
        #expect(trimmed.rawPoints.count == originalPoints)

        let restored = trimmed.trimmed(to: .none)
        #expect(restored.track.count == originalPoints)
        #expect(restored.summary?.distance == original.summary?.distance)
        #expect(restored.summary?.maxSpeed == original.summary?.maxSpeed)
        // And with no trim in force it stops carrying a second copy.
        #expect(restored.untrimmedPoints == nil)
    }

    @Test("An untrimmed session does not store its track twice")
    func noDuplicateStorageWhenUntrimmed() {
        let original = session()
        #expect(original.untrimmedPoints == nil)
        #expect(!original.trim.isTrimmed)
    }

    @Test("A suggested trim finds the sailing and leaves the sitting out")
    func suggestsSensibleTrim() {
        let original = session()
        let suggestion = try! #require(original.suggestedTrim())

        // Riding starts around 600 s in; the suggestion should land near there
        // with a little padding, not chop into the sailing.
        #expect(suggestion.startOffset > 500)
        #expect(suggestion.startOffset < 620)

        let end = try! #require(suggestion.endOffset)
        #expect(end > 1780)
        #expect(end < 1900)
    }

    @Test("A session that is riding throughout gets no suggestion")
    func noSuggestionWhenNothingToTrim() {
        let points = SyntheticTrack.constantSpeed(9, duration: 900)
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let session = Session(
            sport: .wingfoil,
            startDate: track.startDate ?? Date(),
            endDate: track.endDate ?? Date(),
            track: track,
            summary: SessionAnalyzer(sport: .wingfoil).analyse(track)
        )
        #expect(session.suggestedTrim() == nil)
    }

    @Test("Trimming survives an archive round trip")
    func trimSurvivesEncoding() throws {
        let trimmed = session().trimmed(to: SessionTrim(startOffset: 600, endOffset: 1800))
        let data = try SessionArchive(session: trimmed).encoded()
        let restored = try SessionArchive.decode(data).session

        #expect(restored.trim == trimmed.trim)
        #expect(restored.rawPoints.count == trimmed.rawPoints.count)
        #expect(restored.track.count == trimmed.track.count)
    }
}

@Suite("Trimming a trimmed session")
struct NestedTrimTests {

    /// Ten minutes of sitting, twenty of sailing, five of sitting again.
    private func session() -> Session {
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 0.1, heading: 90, duration: 600),
            .init(speed: 9, heading: 120, duration: 1200, transition: 10),
            .init(speed: 0.1, heading: 120, duration: 300, transition: 10),
        ])
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

    @Test("A second selection is measured from what is on screen, not the recording")
    func narrowingComposes() {
        let first = SessionTrim(startOffset: 600, endOffset: 1800)
        // The rider now sees a 20-minute session and drags in one minute at
        // each end. In their clock that is 60 … 1140.
        let second = first.narrowed(start: 60, end: 1140)

        #expect(second.startOffset == 660)
        #expect(second.endOffset == 1740)
    }

    @Test("Leaving the end alone keeps 'to the end' rather than pinning it")
    func openEndedStaysOpen() {
        let open = SessionTrim(startOffset: 600, endOffset: nil)
        let narrowed = open.narrowed(start: 30, end: nil)

        #expect(narrowed.startOffset == 630)
        #expect(narrowed.endOffset == nil, "an open end must not become a timestamp")
    }

    @Test("Trimming twice keeps the result inside the recording")
    func nestedTrimStaysInBounds() throws {
        let original = session()
        let recording = original.track.duration

        let once = original.trimmed(to: SessionTrim(startOffset: 600, endOffset: 1800))
        let visible = once.track.duration
        #expect(visible < recording)

        // Narrow by a minute at each end, in the visible session's clock.
        let twice = once.trimmed(to: once.trim.narrowed(start: 60, end: visible - 60))

        #expect(twice.track.duration < visible)
        #expect(twice.trim.startOffset >= once.trim.startOffset)
        #expect((twice.trim.endOffset ?? recording) <= recording,
                "a second trim ran past the end of the recording")
        // Still reversible all the way back.
        #expect(twice.rawPoints.count == original.track.count)
    }
}

@Suite("The original recording survives")
struct TrimRestoreTests {

    private func session() -> Session {
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 0.1, heading: 90, duration: 600),
            .init(speed: 9, heading: 120, duration: 1200, transition: 10),
            .init(speed: 0.1, heading: 120, duration: 300, transition: 10),
        ])
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

    /// The promise the trim UI makes out loud — "nothing is deleted" — has to
    /// survive being written to disk and read back, or it is a lie the moment
    /// the app is relaunched.
    @Test("A trim survives an archive round trip and can still be undone")
    func originalSurvivesTheArchive() throws {
        let original = session()
        let originalCount = original.track.count
        let originalDuration = original.track.duration

        let trimmed = original.trimmed(to: SessionTrim(startOffset: 600, endOffset: 1800))
        #expect(trimmed.track.count < originalCount)

        // Out to disk and back, exactly as the library stores it.
        let data = try SessionArchive(session: trimmed).encoded()
        let reloaded = try SessionArchive.decode(data).upToDateSession()

        #expect(reloaded.trim.isTrimmed)
        #expect(reloaded.track.count == trimmed.track.count)
        #expect(reloaded.rawPoints.count == originalCount,
                "the untrimmed recording did not survive the archive")

        // And restoring from the reloaded copy gives back the whole recording.
        let restored = reloaded.trimmed(to: .none)
        #expect(restored.track.count == originalCount)
        #expect(abs(restored.track.duration - originalDuration) < 0.001)
        #expect(!restored.trim.isTrimmed)
    }

    @Test("Restoring after two trims returns the whole recording, not the first cut")
    func restoreFromNestedTrim() throws {
        let original = session()
        let originalCount = original.track.count

        let once = original.trimmed(to: SessionTrim(startOffset: 600, endOffset: 1800))
        let visible = once.track.duration
        let twice = once.trimmed(to: once.trim.narrowed(start: 60, end: visible - 60))

        let data = try SessionArchive(session: twice).encoded()
        let restored = try SessionArchive.decode(data).upToDateSession().trimmed(to: .none)

        #expect(restored.track.count == originalCount)
        #expect(restored.untrimmedPoints == nil, "an untrimmed session should not carry a second copy")
    }
}

@Suite("Removing a segment")
struct SegmentRemovalTests {

    /// Out for ten minutes, a ten-minute stop in the middle, then ten more.
    /// The stop is in a different place, so bridging it would invent distance.
    private func session() -> Session {
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 90, duration: 600),
            .init(speed: 0.05, heading: 90, duration: 600, transition: 5),
            .init(speed: 10, heading: 90, duration: 600, transition: 5),
        ])
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

    @Test("The removed stretch is gone and the rest survives")
    func removalDropsTheMiddle() throws {
        let original = session()
        let edited = original.trimmed(to: original.trim.removing(start: 600, end: 1200))

        #expect(edited.trim.isTrimmed)
        #expect(edited.trim.cuts.count == 1)
        #expect(edited.track.count < original.track.count)
        // Both ends are still there.
        #expect(edited.track.duration > 1100, "the surviving ends were cut too")
    }

    /// The reason this needed work in the builder rather than only in the model.
    @Test("Joining the ends does not invent distance across the gap")
    func noPhantomDistanceAcrossTheJoin() throws {
        let original = session()
        let sailed = original.track.totalDistance

        let edited = original.trimmed(to: original.trim.removing(start: 600, end: 1200))

        // The middle was a stop, so almost no distance should be lost — and
        // crucially none should be *gained* by drawing a line across the join.
        #expect(edited.track.totalDistance <= sailed + 1,
                "the join added \(edited.track.totalDistance - sailed) m nobody sailed")
        #expect(edited.track.totalDistance > sailed * 0.9)
    }

    @Test("A removal survives the archive and can still be undone")
    func removalIsReversible() throws {
        let original = session()
        let originalCount = original.track.count

        let edited = original.trimmed(to: original.trim.removing(start: 600, end: 1200))
        let data = try SessionArchive(session: edited).encoded()
        let reloaded = try SessionArchive.decode(data).upToDateSession()

        #expect(reloaded.trim.cuts.count == 1)
        #expect(reloaded.track.count == edited.track.count)
        #expect(reloaded.rawPoints.count == originalCount)

        let restored = reloaded.trimmed(to: .none)
        #expect(restored.track.count == originalCount)
        #expect(!restored.trim.isTrimmed)
    }

    @Test("Overlapping cuts merge instead of piling up")
    func cutsMerge() {
        let trim = SessionTrim()
            .removing(start: 600, end: 1200)
            .removing(start: 1100, end: 1500)
        #expect(trim.cuts.count == 1)
        #expect(trim.cuts[0].start == 600)
        #expect(trim.cuts[0].end == 1500)
    }

    @Test("Saving as a new activity leaves the original alone")
    func newActivityIsStandalone() throws {
        let original = session()
        let edited = original.trimmed(to: original.trim.removing(start: 600, end: 1200))
        let copy = edited.savedAsNewActivity()

        #expect(copy.id != original.id)
        #expect(copy.track.count == edited.track.count)
        // The copy *is* the edit — no trim, and no second copy of the recording.
        #expect(!copy.trim.isTrimmed)
        #expect(copy.untrimmedPoints == nil)
        // And the session it came from is untouched.
        #expect(edited.rawPoints.count == original.track.count)
    }
}
