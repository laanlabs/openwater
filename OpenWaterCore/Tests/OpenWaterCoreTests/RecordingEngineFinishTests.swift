import Foundation
import Testing
@testable import OpenWaterCore

/// What happens to a rider's session when they press stop.
///
/// This is the one path in the app where a bug costs somebody a session they
/// cannot get back, so the guarantees are pinned here rather than left to the
/// shells to get right independently.
@Suite("Recording engine finish")
@MainActor
struct RecordingEngineFinishTests {

    private func engine() -> RecordingEngine {
        let engine = RecordingEngine(deviceModel: "test", appVersion: "test")
        engine.autoPauseEnabled = false
        return engine
    }

    @Test("A saved session leaves no log behind to be offered back")
    func finishClearsItsLog() {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        for point in SyntheticTrack.constantSpeed(9, duration: 120) {
            engine.ingest(point)
        }
        let session = engine.finish { _ in true }
        #expect(session != nil)

        let leftBehind = Set(TrackLog.unfinishedLogs()).subtracting(before)
        defer { leftBehind.forEach(TrackLog.delete) }

        #expect(leftBehind.isEmpty,
                "a session that saved cleanly left \(leftBehind.count) log(s) on disk")

        engine.checkForRecoverableSession()
        defer { engine.dismissRecovery() }
        #expect(engine.recoverable == nil,
                "a session that saved cleanly is being offered back as unfinished")
    }

    @Test("A session the shell could not save keeps its log, and is offered back")
    func failedSaveKeepsItsLog() {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        for point in SyntheticTrack.constantSpeed(9, duration: 120) {
            engine.ingest(point)
        }

        // The shell says no: out of space, an encoder that threw, a store that
        // would not take it. The rider pressed stop either way.
        let session = engine.finish { _ in false }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        #expect(session != nil, "the session should still come back so the shell can retry")

        engine.checkForRecoverableSession()
        #expect(engine.recoverable != nil,
                "a session that could not be saved was left with no way back")
        #expect(engine.recoverable?.pointCount == 120)
    }

    @Test("Too few fixes to build a session leaves nothing behind")
    func tooShortLeavesNothing() {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        engine.ingest(SyntheticTrack.constantSpeed(9, duration: 120)[0])

        var offered = false
        let session = engine.finish { _ in offered = true; return true }

        let leftBehind = Set(TrackLog.unfinishedLogs()).subtracting(before)
        defer { leftBehind.forEach(TrackLog.delete) }

        #expect(session == nil)
        #expect(!offered, "a one-fix session should never reach the shell")
        #expect(leftBehind.isEmpty, "a single fix is not worth offering back")
    }

    @Test("A recovery that cannot be saved stays on offer")
    func failedRecoveryKeepsItsLog() {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        for point in SyntheticTrack.constantSpeed(9, duration: 120) {
            engine.ingest(point)
        }
        engine.finish { _ in false }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        engine.checkForRecoverableSession()
        let candidate = engine.recoverable
        #expect(candidate != nil)

        // The rider taps Recover and the write fails again. This log is the
        // only copy in existence, so spending it here would lose the session.
        let recovered = engine.recover(candidate!, save: { _ in false })
        #expect(recovered == nil)
        #expect(FileManager.default.fileExists(atPath: candidate!.url.path),
                "the only copy of the session was deleted by a failed recovery")

        // And it can still be rescued on a later try.
        let retried = engine.recover(candidate!, save: { _ in true })
        #expect(retried != nil)
        #expect(!FileManager.default.fileExists(atPath: candidate!.url.path))
    }

    @Test("Pressing stop twice does not build the session twice")
    func secondStopIsANoOp() {
        let before = Set(TrackLog.unfinishedLogs())

        let engine = engine()
        engine.start(sport: .wingfoil)
        for point in SyntheticTrack.constantSpeed(9, duration: 120) {
            engine.ingest(point)
        }

        var saves = 0
        let first = engine.finish { _ in saves += 1; return true }
        let second = engine.finish { _ in saves += 1; return true }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        #expect(first != nil)
        #expect(second == nil, "the second press should find nothing left to end")
        #expect(saves == 1, "the session was handed to the shell \(saves) times")
    }

    @Test("A log whose session the shell already holds is cleaned up, not offered")
    func alreadySavedLogIsDropped() {
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
        engine.finish { session in savedID = session.id; return false }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        engine.checkForRecoverableSession(isAlreadySaved: { $0 == savedID })
        #expect(engine.recoverable == nil,
                "a session already in the library was offered back as unfinished")
        #expect(Set(TrackLog.unfinishedLogs()).subtracting(before).isEmpty,
                "the leftover log should have been deleted, not kept forever")
    }

    @Test("Dealing with one interrupted session brings up the next")
    func recoveryOffersEveryOrphan() {
        let before = Set(TrackLog.unfinishedLogs())

        for _ in 0..<2 {
            let engine = engine()
            engine.start(sport: .wingfoil)
            for point in SyntheticTrack.constantSpeed(9, duration: 120) {
                engine.ingest(point)
            }
            engine.finish { _ in false }
        }
        defer {
            Set(TrackLog.unfinishedLogs()).subtracting(before).forEach(TrackLog.delete)
        }

        let engine = engine()
        engine.checkForRecoverableSession()
        let first = engine.recoverable
        #expect(first != nil)

        engine.dismissRecovery()
        let second = engine.recoverable
        #expect(second != nil, "the second orphan was never offered")
        #expect(second?.url != first?.url)

        #expect(engine.recover(second!, save: { _ in true }) != nil)
        #expect(engine.recoverable == nil, "nothing should be left once both are dealt with")
    }
}
