import Foundation
import Testing
@testable import OpenWaterCore

/// What a pause does to a recording — which is, since 2026-09-26, nothing that
/// cannot be undone.
///
/// Written from a wing session recorded on a phone on 2026-09-24. The rider's
/// map came back with two straight lines across it, forty-nine and twenty-two
/// minutes long. The receiver had not lost the sky: the motion buffer on the
/// first fix after each hole held one second of samples, which only happens
/// when the recorder was draining it — alive, listening, and throwing every
/// fix away because the state said `.paused`. Two taps on a wet screen in a
/// pocket cost seventy-one minutes that no edit could bring back.
///
/// An extension of the finish suite rather than a suite of its own, because
/// both leave logs in the one on-disk `TrackLog` directory, and two suites
/// run concurrently however serialized each is inside — the finish tests
/// were finding this file's 180-fix logs and offering them back.
extension RecordingEngineFinishTests {

    private func pausingEngine(autoPause: Bool = false) -> RecordingEngine {
        let engine = RecordingEngine(deviceModel: "test", appVersion: "test")
        engine.autoPauseEnabled = autoPause
        return engine
    }

    /// Three minutes at nine metres a second, one fix a second, one straight
    /// line — so a stretch cut from the middle shows up as distance missing.
    private var ride: [TrackPoint] {
        SyntheticTrack.constantSpeed(9, duration: 180)
    }

    @Test("A pause keeps every fix and cuts them from the session, not the archive")
    func pauseIsACutNotAHole() async {
        let engine = pausingEngine()
        let points = ride
        engine.start(sport: .wingfoil, at: points[0].timestamp)

        for point in points[0..<60] { engine.ingest(point) }
        engine.pause(at: points[60].timestamp.addingTimeInterval(-0.2))
        #expect(engine.state == .paused)
        for point in points[60..<120] { engine.ingest(point) }
        engine.resume(at: points[120].timestamp.addingTimeInterval(-0.2))
        #expect(engine.state == .recording)
        for point in points[120..<180] { engine.ingest(point) }

        #expect(engine.recordedPoints.count == 180,
                "the fixes from the pause were dropped: \(engine.recordedPoints.count) kept of 180")

        guard let session = await engine.finish(at: points[179].timestamp.addingTimeInterval(1), save: { _ in true }) else {
            Issue.record("no session came back")
            return
        }

        // The pause is on the session, by name.
        #expect(session.pauses?.count == 1)
        #expect(session.pauses?.first?.cause == .rider)
        #expect(session.pauses?.first?.duration ?? 0 > 59)

        // And it is a cut: the paused minute is out of the numbers…
        #expect(session.trim.cuts.count == 1)
        #expect(session.track.count == 120,
                "\(session.track.count) fixes in the session; the paused minute should be out")
        // The leg across the cut is still bridged for distance, exactly as a
        // cut the rider made in Trim would be: under ten minutes at a
        // plausible speed, the straight line stands. See `GapBridgingTests`.
        // What the cut takes out is the time, and the fixes.

        // …but still in the archive, so the cut can be undone.
        #expect(session.rawPoints.count == 180)
        let restored = session.trimmed(to: .none)
        #expect(restored.track.count == 180)
        let full = restored.summary?.distance ?? 0
        #expect(full > 9 * 178 && full < 9 * 182,
                "undoing the cut should give back the whole ride, got \(Int(full)) m")
    }

    @Test("Ending while paused closes the pause where the session ends")
    func finishClosesAnOpenPause() async {
        let engine = pausingEngine()
        let points = ride
        engine.start(sport: .wingfoil, at: points[0].timestamp)
        for point in points[0..<120] { engine.ingest(point) }
        engine.pause(at: points[120].timestamp.addingTimeInterval(-0.2))
        for point in points[120..<180] { engine.ingest(point) }

        guard let session = await engine.finish(at: points[179].timestamp.addingTimeInterval(1), save: { _ in true }) else {
            Issue.record("no session came back")
            return
        }
        #expect(session.pauses?.first?.end != nil, "the pause was left open")
        #expect(session.track.count == 120)
        #expect(session.rawPoints.count == 180)
    }

    @Test("Auto-pause lets the clock go again when the rider is moving")
    func autoPauseResumesOnItsOwn() {
        let engine = pausingEngine(autoPause: true)
        var resumed = 0
        engine.onAutoResume = { resumed += 1 }

        // Half a minute riding, a minute sitting, half a minute riding.
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 30),
            .init(speed: 0.2, heading: 90, duration: 60),
            .init(speed: 9, heading: 90, duration: 30),
        ])
        engine.start(sport: .wingfoil, at: points[0].timestamp)

        for point in points[0..<90] { engine.ingest(point) }
        #expect(engine.state == .paused, "sitting for a minute should have auto-paused")
        #expect(engine.pauses.last?.cause == .auto)

        for point in points[90..<120] { engine.ingest(point) }
        #expect(engine.state == .recording,
                "riding again for half a minute should have ended the auto-pause")
        #expect(resumed == 1)
        #expect(engine.pauses.last?.end != nil)
        // Back within a few seconds of moving, not at the end of the leg.
        let pausedFor = engine.pauses.last?.duration ?? 0
        #expect(pausedFor < 30, "auto-pause lasted \(Int(pausedFor)) s; should have ended within seconds of moving")
        #expect(engine.recordedPoints.count == 120, "fixes were lost during the auto-pause")
        engine.discard()
    }

    @Test("A pause the rider made is not ended for them")
    func riderPauseIsTheirs() {
        let engine = pausingEngine(autoPause: true)
        let points = ride
        engine.start(sport: .wingfoil, at: points[0].timestamp)
        for point in points[0..<30] { engine.ingest(point) }
        engine.pause(at: points[30].timestamp)
        for point in points[30..<180] { engine.ingest(point) }
        #expect(engine.state == .paused, "the rider's pause was ended by the engine")
        #expect(engine.recordedPoints.count == 180)
        engine.discard()
    }

    @Test("A recovered session remembers its pauses")
    func recoveryKeepsPauses() async {
        let before = Set(TrackLog.unfinishedLogs())
        let points = ride

        // The recording that dies: paused for its middle minute, then gone.
        let dying = pausingEngine()
        dying.start(sport: .wingfoil, at: points[0].timestamp)
        for point in points[0..<60] { dying.ingest(point) }
        dying.pause(at: points[60].timestamp.addingTimeInterval(-0.2))
        for point in points[60..<120] { dying.ingest(point) }
        dying.resume(at: points[120].timestamp.addingTimeInterval(-0.2))
        for point in points[120..<180] { dying.ingest(point) }
        dying.flush()

        defer {
            dying.discard()
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        // The next launch.
        let next = pausingEngine()
        await next.checkForRecoverableSession()
        guard let candidate = next.recoverable else {
            Issue.record("the interrupted session was not offered back")
            return
        }
        #expect(candidate.pointCount == 180)

        guard let session = await next.recover(candidate, save: { _ in true }) else {
            Issue.record("recovery built no session")
            return
        }
        #expect(session.pauses?.count == 1)
        #expect(session.pauses?.first?.cause == .rider)
        #expect(session.trim.cuts.count == 1)
        #expect(session.track.count == 120,
                "recovered with \(session.track.count) fixes; the paused minute should be cut")
        #expect(session.rawPoints.count == 180)
    }

    @Test("The log keeps events beside the fixes, and a pause left open is closed at the last fix")
    func logRoundTripsEvents() throws {
        let points = ride
        let log = try TrackLog(
            sessionID: UUID(), sport: .wingfoil, startDate: points[0].timestamp,
            deviceModel: "test", appVersion: "test"
        )
        defer { TrackLog.delete(log.url) }

        for point in points[0..<10] { log.append(point) }
        log.append(TrackLog.Event(.pause, at: points[10].timestamp, cause: .auto))
        for point in points[10..<20] { log.append(point) }
        log.finish()

        let contents = try TrackLog.read(log.url)
        #expect(contents.points.count == 20)
        #expect(contents.events.count == 1)
        #expect(contents.events.first?.cause == .auto)
        let pauses = contents.pauses
        #expect(pauses.count == 1)
        #expect(pauses.first?.cause == .auto)
        #expect(pauses.first?.end == points[19].timestamp.addingTimeInterval(1),
                "an open pause should close just after the last fix")
    }
}

/// Where a track may be drawn as a line.
@Suite("Track gaps")
struct TrackGapTests {

    private func track(withHole hole: TimeInterval) -> Track {
        var points = SyntheticTrack.constantSpeed(9, duration: 60)
        let after = SyntheticTrack.constantSpeed(
            9, duration: 60,
            heading: 90
        ).map { point -> TrackPoint in
            var moved = point
            moved.timestamp = point.timestamp.addingTimeInterval(60 + hole)
            // Carry on from where the first half ended, so the hole is in
            // time only and the implied-speed gate has nothing to say.
            moved.latitude = points.last!.latitude
            moved.longitude = points.last!.longitude + (point.longitude - points[0].longitude)
            return moved
        }
        points.append(contentsOf: after)
        return TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
    }

    @Test("A long hole splits the drawing; a short one does not")
    func splitsOnLongHoles() {
        let holed = track(withHole: 300)
        let pieces = holed.contiguousRanges()
        #expect(pieces.count == 2, "a five-minute hole should split the line, got \(pieces.count) piece(s)")
        #expect(pieces.first?.upperBound == 59)
        #expect(pieces.last?.lowerBound == 60)
        #expect(pieces.map(\.count).reduce(0, +) == holed.count, "every fix should land in exactly one piece")

        let wobble = track(withHole: 10)
        #expect(wobble.contiguousRanges().count == 1, "a ten-second gap is a wobble, not a hole")
    }

    @Test("A sub-range is split the same way, in the track's own indices")
    func splitsInsideARange() {
        let holed = track(withHole: 300)
        let pieces = holed.contiguousRanges(in: 40...80)
        #expect(pieces == [40...59, 60...80])
        #expect(holed.contiguousRanges(in: 0...30) == [0...30])
        #expect(holed.contiguousRanges(in: 70...500).first == 70...(holed.count - 1))
    }
}
