import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Session editing")
struct SessionEditingTests {

    private func session(sport: Sport = .wingfoil) -> Session {
        var points = SyntheticTrack.wingSession(runs: 8, runDuration: 60)
        for i in points.indices {
            points[i].verticalAccelSD = (points[i].speed ?? 0) > 5 ? 0.4 : 2.6
        }
        let track = TrackBuilder(options: .forSport(sport)).build(from: points)
        let summary = SessionAnalyzer(sport: sport).analyse(track)
        return Session(
            sport: sport,
            startDate: track.startDate ?? Date(),
            endDate: track.endDate ?? Date(),
            track: track,
            wind: summary.wind,
            summary: summary
        )
    }

    @Test("Renaming does not re-run the analysis")
    func cosmeticEditsSkipReanalysis() {
        let original = session()
        var edits = Session.Edits(session: original)
        edits.title = "Evening blast"
        edits.spotName = "Napeague"
        edits.notes = "Big 1100, 4m wing."

        #expect(!original.requiresReanalysis(for: edits))

        let edited = original.applying(edits)
        #expect(edited.title == "Evening blast")
        #expect(edited.spotName == "Napeague")
        #expect(edited.notes == "Big 1100, 4m wing.")

        // The numbers must be untouched, not merely similar — nothing they
        // depend on changed.
        #expect(edited.summary?.maxSpeed == original.summary?.maxSpeed)
        #expect(edited.summary?.foil.flightCount == original.summary?.foil.flightCount)
        #expect(edited.track.count == original.track.count)
    }

    @Test("Changing the sport re-runs the analysis")
    func sportChangeReanalyses() {
        let original = session(sport: .wingfoil)
        #expect((original.summary?.foil.flightCount ?? 0) > 0)

        var edits = Session.Edits(session: original)
        edits.sport = .windsurf
        #expect(original.requiresReanalysis(for: edits))

        let edited = original.applying(edits)
        #expect(edited.sport == .windsurf)

        // Windsurfing has no flight phase, so the flights must be gone. This is
        // the whole reason a sport change cannot be a cosmetic edit: leaving the
        // old numbers would report foil flights on a windsurf session.
        #expect(edited.summary?.foil.flightCount == 0)
        #expect(edited.summary?.flights.isEmpty == true)
        #expect(edited.summary?.fallSummary.count == 0)

        // The track is rebuilt too, since ingest filters are sport-specific.
        #expect(edited.summary?.distance ?? 0 > 0)
    }

    @Test("Setting the wind by hand re-runs the analysis and overrides the estimate")
    func windChangeReanalyses() {
        let original = session()
        // The estimator will have produced something from the track shape.
        #expect(original.wind?.source.isEstimate == true)

        var edits = Session.Edits(session: original)
        edits.windDirection = 275
        edits.windSpeed = 9

        #expect(original.requiresReanalysis(for: edits))

        let edited = original.applying(edits)
        #expect(edited.wind?.directionFrom == 275)
        #expect(edited.wind?.source == .manual)
        #expect(edited.wind?.speed == 9)
        #expect(edited.wind?.confidence == 1)

        // Angles are derived from the wind, so they must have moved with it.
        #expect(edited.summary?.polar?.wind.directionFrom == 275)
    }

    @Test("An estimated wind is not pre-filled as if the rider had entered it")
    func estimateIsNotPresentedAsInput() {
        let original = session()
        #expect(original.wind != nil)
        #expect(original.wind?.source.isEstimate == true)

        let edits = Session.Edits(session: original)
        // Showing the estimate in the field would turn a guess into a value the
        // rider appears to have asserted, and saving would promote it to manual.
        #expect(edits.windDirection == nil)
        #expect(!original.requiresReanalysis(for: edits))
    }

    @Test("Clearing a title removes it rather than storing an empty string")
    func clearingTitle() {
        var original = session()
        original.title = "Old name"

        var edits = Session.Edits(session: original)
        edits.title = "   "

        let edited = original.applying(edits)
        #expect(edited.title == nil)
        #expect(edited.displayTitle == edited.sport.displayName)
    }

    @Test("Display title falls back through title, spot, then sport")
    func displayTitleFallback() {
        var s = session()
        #expect(s.displayTitle == "Wingfoil")

        s.spotName = "Napeague Harbor"
        #expect(s.displayTitle == "Napeague Harbor")
        #expect(s.displaySubtitle == "Wingfoil")

        s.title = "Evening blast"
        #expect(s.displayTitle == "Evening blast")
        #expect(s.displaySubtitle == "Napeague Harbor")
    }
}
