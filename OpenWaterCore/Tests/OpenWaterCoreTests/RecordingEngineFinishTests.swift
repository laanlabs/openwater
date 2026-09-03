import Foundation
import Testing
@testable import OpenWaterCore

/// What happens to a rider's session when they press stop.
///
/// This is the one path in the app where a bug costs somebody a session they
/// cannot get back, so the guarantees are pinned here rather than left to the
/// shells to get right independently.
@Suite("Recording engine finish", .serialized)
@MainActor
struct RecordingEngineFinishTests {

    private func engine() -> RecordingEngine {
        let engine = RecordingEngine(deviceModel: "test", appVersion: "test")
        engine.autoPauseEnabled = false
        return engine
    }

    @Test("A saved session leaves no log behind to be offered back")
    func finishClearsItsLog() async {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        for point in SyntheticTrack.constantSpeed(9, duration: 120) {
            engine.ingest(point)
        }
        let session = await engine.finish { _ in true }
        #expect(session != nil)

        let leftBehind = Set(TrackLog.unfinishedLogs()).subtracting(before)
        defer { leftBehind.forEach(TrackLog.delete) }

        #expect(leftBehind.isEmpty,
                "a session that saved cleanly left \(leftBehind.count) log(s) on disk")

        await engine.checkForRecoverableSession()
        #expect(engine.recoverable == nil,
                "a session that saved cleanly is being offered back as unfinished")
        await engine.dismissRecovery()
    }

    @Test("A session the shell could not save keeps its log, and is offered back")
    func failedSaveKeepsItsLog() async {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        for point in SyntheticTrack.constantSpeed(9, duration: 120) {
            engine.ingest(point)
        }

        // The shell says no: out of space, an encoder that threw, a store that
        // would not take it. The rider pressed stop either way.
        let session = await engine.finish { _ in false }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        #expect(session != nil, "the session should still come back so the shell can retry")

        await engine.checkForRecoverableSession()
        #expect(engine.recoverable != nil,
                "a session that could not be saved was left with no way back")
        #expect(engine.recoverable?.pointCount == 120)
    }

    @Test("Too few fixes to build a session leaves nothing behind")
    func tooShortLeavesNothing() async {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        engine.ingest(SyntheticTrack.constantSpeed(9, duration: 120)[0])

        var offered = false
        let session = await engine.finish { _ in offered = true; return true }

        let leftBehind = Set(TrackLog.unfinishedLogs()).subtracting(before)
        defer { leftBehind.forEach(TrackLog.delete) }

        #expect(session == nil)
        #expect(!offered, "a one-fix session should never reach the shell")
        #expect(leftBehind.isEmpty, "a single fix is not worth offering back")
    }

    @Test("A recovery that cannot be saved stays on offer")
    func failedRecoveryKeepsItsLog() async {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        for point in SyntheticTrack.constantSpeed(9, duration: 120) {
            engine.ingest(point)
        }
        await engine.finish { _ in false }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        await engine.checkForRecoverableSession()
        let candidate = engine.recoverable
        #expect(candidate != nil)

        // The rider taps Recover and the write fails again. This log is the
        // only copy in existence, so spending it here would lose the session.
        let recovered = await engine.recover(candidate!, save: { _ in false })
        #expect(recovered == nil)
        #expect(FileManager.default.fileExists(atPath: candidate!.url.path),
                "the only copy of the session was deleted by a failed recovery")

        // And it can still be rescued on a later try.
        let retried = await engine.recover(candidate!, save: { _ in true })
        #expect(retried != nil)
        #expect(!FileManager.default.fileExists(atPath: candidate!.url.path))
    }

    @Test("Pressing stop twice does not build the session twice")
    func secondStopIsANoOp() async {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        for point in SyntheticTrack.constantSpeed(9, duration: 120) {
            engine.ingest(point)
        }

        var saves = 0
        let first = await engine.finish { _ in saves += 1; return true }
        let second = await engine.finish { _ in saves += 1; return true }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        #expect(first != nil)
        #expect(second == nil, "the second press should find nothing left to end")
        #expect(saves == 1, "the session was handed to the shell \(saves) times")
    }

    @Test("A log whose session the shell already holds is cleaned up, not offered")
    func alreadySavedLogIsDropped() async {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        for point in SyntheticTrack.constantSpeed(9, duration: 120) {
            engine.ingest(point)
        }
        // The write landed but the shell answered no — a save that reported
        // failure after committing, say. The library has the session; the
        // log is a leftover.
        var savedID: UUID?
        await engine.finish { session in savedID = session.id; return false }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        await engine.checkForRecoverableSession(isAlreadySaved: { $0 == savedID })
        #expect(engine.recoverable == nil,
                "a session already in the library was offered back as unfinished")
        #expect(Set(TrackLog.unfinishedLogs()).subtracting(before).isEmpty,
                "the leftover log should have been deleted, not kept forever")
    }

    @Test("Dealing with one interrupted session brings up the next")
    func recoveryOffersEveryOrphan() async {
        let before = Set(TrackLog.unfinishedLogs())

        for _ in 0..<2 {
            let engine = engine()
            engine.start(sport: .wingfoil)
            for point in SyntheticTrack.constantSpeed(9, duration: 120) {
                engine.ingest(point)
            }
            await engine.finish { _ in false }
        }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        let engine = engine()
        await engine.checkForRecoverableSession()
        let first = engine.recoverable
        #expect(first != nil)

        await engine.dismissRecovery()
        let second = engine.recoverable
        #expect(second != nil, "the second orphan was never offered")
        #expect(second?.url != first?.url)

        let recovered = await engine.recover(second!, save: { _ in true })
        #expect(recovered != nil)
        #expect(engine.recoverable == nil, "nothing should be left once both are dealt with")
    }
}
