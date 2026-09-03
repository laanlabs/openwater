import Foundation
import Testing
@testable import OpenWaterCore

/// What a session remembers about where it came from.
@Suite("Import identity")
struct ImportIdentityTests {

    private func imported(_ points: [TrackPoint]) -> ImportedTrack {
        ImportedTrack(points: points, name: nil, sportHint: nil, format: .gpx, warnings: [])
    }

    @Test("The same file makes the same session twice")
    func stableIDIsStable() {
        let points = SyntheticTrack.constantSpeed(9, duration: 120)
        #expect(imported(points).stableID == imported(points).stableID)
        #expect(imported(points).makeSession(sport: .wingfoil).id
                == imported(points).makeSession(sport: .wingfoil).id)
    }

    @Test("A different recording makes a different session")
    func differentTracksDiffer() {
        let a = SyntheticTrack.constantSpeed(9, duration: 120)
        let b = Array(a.dropLast())
        #expect(imported(a).stableID != imported(b).stableID)
    }

    @Test("An import keeps its lenient filter through a rebuild")
    func importedFilterSurvivesRebuild() throws {
        let session = imported(SyntheticTrack.constantSpeed(9, duration: 120)).makeSession(sport: .wingfoil)
        #expect(session.trackFilter == .lenient)
        #expect(session.trackBuilderOptions.maxHorizontalAccuracy == TrackBuilder.Options.lenient.maxHorizontalAccuracy)

        var stale = session
        stale.summary = nil
        let rebuilt = SessionArchive(session: stale).upToDateSession()
        #expect(rebuilt.trackFilter == .lenient)
        #expect(rebuilt.summary != nil)
    }

    @Test("A recording is stamped with the clock it was made on")
    func recordingCarriesItsZone() {
        let points = SyntheticTrack.constantSpeed(9, duration: 60)
        let session = RecordingEngine.buildSession(
            id: UUID(), sport: .wingfoil, startDate: points[0].timestamp,
            endDate: points[points.count - 1].timestamp, points: points,
            wind: nil, deviceModel: "test", appVersion: "test"
        )
        #expect(session.timeZone == TimeZone.current.identifier)
        #expect(session.zone.identifier == TimeZone.current.identifier)

        let imported = self.imported(points).makeSession(sport: .wingfoil)
        #expect(imported.timeZone == nil, "an import does not know where it was recorded")
    }
}
