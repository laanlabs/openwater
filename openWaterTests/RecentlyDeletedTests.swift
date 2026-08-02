import OpenWaterCore
import SwiftData
import XCTest
@testable import openWater

/// Deleting a session must be recoverable, and purging must not be early.
///
/// This is the one piece of the app where a bug destroys data that cannot be
/// re-created — a rider's afternoon on the water. Worth pinning down: an
/// off-by-one in the retention window is invisible until the day somebody goes
/// looking for a session that should still have been there.
@MainActor
final class RecentlyDeletedTests: XCTestCase {

    private var library: SessionLibrary!

    /// Every container made during the run, kept alive deliberately.
    ///
    /// Releasing an in-memory `ModelContainer` inside a test host that already
    /// has one of its own crashes the process in `tearDown` — a double free in
    /// SwiftData's own teardown, nothing to do with the code under test. Each
    /// test still gets a fresh empty store; the old ones simply outlive it.
    private static var containers: [ModelContainer] = []

    override func setUpWithError() throws {
        let container = try ModelContainer(
            for: StoredSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        Self.containers.append(container)
        library = SessionLibrary(context: container.mainContext)
    }

    /// A short synthetic session, fast enough to hold a record.
    private func makeSession(maxSpeed: Double = 15) -> Session {
        var points = SyntheticTrack.constantSpeed(maxSpeed, duration: 120, heading: 90)
        for i in points.indices { points[i].horizontalAccuracy = 5 }
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        var session = Session(
            sport: .wingfoil,
            startDate: points[0].timestamp,
            endDate: points[points.count - 1].timestamp,
            track: track
        )
        session.summary = SessionAnalyzer(sport: .wingfoil).analyse(track)
        return session
    }

    func testDeleteIsRecoverable() throws {
        let stored = library.save(makeSession())
        XCTAssertFalse(stored.isTrashed)

        library.delete(stored)
        XCTAssertTrue(stored.isTrashed)
        XCTAssertEqual(library.trashedSessions().count, 1)
        // Still on disk, in full — the point of the whole feature.
        XCTAssertFalse(stored.archiveData.isEmpty)

        library.restore(stored)
        XCTAssertFalse(stored.isTrashed)
        XCTAssertTrue(library.trashedSessions().isEmpty)
    }

    func testTrashedSessionsDoNotHoldRecords() throws {
        let fast = library.save(makeSession(maxSpeed: 20))
        XCTAssertFalse(library.records.isEmpty, "a saved session should set records")

        library.delete(fast)
        XCTAssertTrue(library.records.isEmpty,
                      "a deleted session must not keep holding the record book")

        library.restore(fast)
        XCTAssertFalse(library.records.isEmpty, "restoring should bring the record back")
    }

    func testPurgeKeepsAnythingInsideTheWindow() throws {
        let stored = library.save(makeSession())
        library.delete(stored)
        // One day short of the deadline. It stays.
        stored.deletedAt = Date.now
            .addingTimeInterval(-StoredSession.trashRetention + 86_400)

        library.purgeExpiredTrash()
        XCTAssertEqual(library.trashedSessions().count, 1)
        XCTAssertEqual(stored.daysLeftInTrash, 1)
    }

    func testPurgeRemovesAnythingPastTheWindow() throws {
        let stored = library.save(makeSession())
        library.delete(stored)
        stored.deletedAt = Date.now
            .addingTimeInterval(-StoredSession.trashRetention - 60)

        library.purgeExpiredTrash()
        XCTAssertTrue(library.trashedSessions().isEmpty)
        XCTAssertTrue(library.allSessions().isEmpty)
    }

    func testBackupsLeaveDeletedSessionsOut() throws {
        let kept = library.save(makeSession())
        let removed = library.save(makeSession(maxSpeed: 12))
        library.delete(removed)

        let data = try library.exportAll()
        let bundle = try SessionArchiveBundle.decode(data)
        XCTAssertEqual(bundle.sessions.count, 1)
        XCTAssertEqual(bundle.sessions.first?.id, kept.id)
    }
}
