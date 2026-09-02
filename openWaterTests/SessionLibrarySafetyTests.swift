import OpenWaterCore
import SwiftData
import XCTest
@testable import openWater

/// The library must never say "saved" about a session it does not hold.
///
/// The recorder releases its crash log on that word, so a false yes is the
/// difference between a session that can be recovered and one that is gone.
/// Three ways the word used to be false are pinned here: an archive that
/// would not encode, a store that would not open, and a copy from the watch
/// that overwrote what the rider had written on the phone.
@MainActor
final class SessionLibrarySafetyTests: XCTestCase {

    /// Kept alive for the reason `RecentlyDeletedTests` gives — and the
    /// libraries with them: a `@MainActor` library released at the end of a
    /// test method dies inside the runtime's actor-deinit shim with a
    /// double free, nothing to do with the code under test.
    private static var containers: [ModelContainer] = []
    private static var libraries: [SessionLibrary] = []

    private func makeLibrary(isEphemeral: Bool = false) throws -> SessionLibrary {
        let container = try ModelContainer(
            for: StoredSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        Self.containers.append(container)
        let library = SessionLibrary(context: container.mainContext, isEphemeral: isEphemeral)
        Self.libraries.append(library)
        return library
    }

    private func makeSession() -> Session {
        var points = SyntheticTrack.constantSpeed(12, duration: 120, heading: 90)
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

    // MARK: An archive that will not encode

    func testUnencodableSessionIsNotReportedSaved() throws {
        let library = try makeLibrary()
        var session = makeSession()
        // JSON has no spelling for NaN, and the encoder throws on it. This is
        // the realistic route in: a division by zero somewhere in a summary.
        session.swellHeight = .nan

        let result = library.save(session)

        XCTAssertNil(result.stored, "no row should be built for a session that cannot be encoded")
        XCTAssertFalse(result.persisted, "persisted is the word the recorder deletes its log on")
        XCTAssertTrue(library.allSessions().isEmpty, "nothing half-written should be left in the store")
    }

    func testUnencodableUpdateLeavesTheExistingRowAlone() throws {
        let library = try makeLibrary()
        let session = makeSession()
        let stored = try XCTUnwrap(library.save(session).stored)
        let before = stored.archiveData

        var broken = session
        broken.swellHeight = .nan
        let result = library.save(broken)

        XCTAssertFalse(result.persisted)
        XCTAssertEqual(stored.archiveData, before, "a failed re-encode must not touch the archive")
    }

    // MARK: A store that will not open

    func testEphemeralLibraryNeverReportsPersisted() throws {
        let library = try makeLibrary(isEphemeral: true)
        let result = library.save(makeSession())

        XCTAssertNotNil(result.stored, "the session is usable for the length of this launch")
        XCTAssertFalse(result.persisted, "but nothing about it survives the next one")
    }

    // MARK: A copy from the watch

    func testWatchCopyKeepsWhatTheRiderWrote() throws {
        let library = try makeLibrary()
        let fromWatch = makeSession()
        let stored = try XCTUnwrap(library.save(fromWatch).stored)

        var edited = fromWatch
        edited.title = "Dawn patrol"
        edited.notes = "Best gybe of the year on the second run."
        edited.gearIDs = [UUID()]
        library.save(edited)
        XCTAssertEqual(stored.title, "Dawn patrol")

        // The outbox re-sends the same file on the next reconnect.
        let again = library.save(fromWatch, policy: .keepRiderEdits)
        XCTAssertTrue(again.persisted)
        XCTAssertEqual(stored.title, "Dawn patrol")
        XCTAssertEqual(stored.notes, "Best gybe of the year on the second run.")
        XCTAssertEqual(stored.gearIDs.count, 1)
    }

    func testAnEditHereCanStillClearANote() throws {
        let library = try makeLibrary()
        var session = makeSession()
        session.notes = "Written in haste."
        let stored = try XCTUnwrap(library.save(session).stored)

        session.notes = ""
        library.save(session)
        XCTAssertEqual(stored.notes, "", "an edit made on the phone is the truth, blanks included")
    }
}
