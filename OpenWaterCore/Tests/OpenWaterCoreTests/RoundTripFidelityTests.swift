import Foundation
import Testing
@testable import OpenWaterCore

/// The check that actually matters for import/export.
///
/// It is easy to write a format reader that parses without error and still
/// loses the thing you cared about — a dropped speed channel, a timestamp
/// rounded to the second, a truncated coordinate. None of that shows up as a
/// parse failure; it shows up as your 24-knot peak reading 22 after a round
/// trip.
///
/// So rather than checking that the bytes survive, these tests run the **full
/// analysis** on both sides and compare the headline numbers a rider would
/// actually look at.
@Suite("Round-trip fidelity")
struct RoundTripFidelityTests {

    /// A realistic session with flights, gybes and varying speed.
    private func session() -> Session {
        var points = SyntheticTrack.wingSession(runs: 10, runDuration: 80)
        for i in points.indices {
            points[i].verticalAccelSD = (points[i].speed ?? 0) > 5 ? 0.4 : 2.6
        }
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let summary = SessionAnalyzer(
            configuration: .init(sport: .wingfoil, categories: SpeedCategory.all)
        ).analyse(track)
        return Session(
            sport: .wingfoil,
            startDate: track.startDate ?? Date(),
            endDate: track.endDate ?? Date(),
            track: track,
            spotName: "Round Trip Bay",
            summary: summary
        )
    }

    private func headline(_ session: Session) -> (max: Double, best500: Double, distance: Double, flights: Int) {
        let summary = session.summary!
        return (
            summary.maxSpeed,
            summary.result(for: .distance(metres: 500))?.speed ?? 0,
            summary.distance,
            summary.foil.flightCount
        )
    }

    @Test("Speed-carrying formats preserve the headline numbers",
          arguments: [FileFormat.gpx, .tcx, .csv, .openwater])
    func headlineNumbersSurvive(format: FileFormat) throws {
        let original = session()
        let reference = headline(original)

        let data: Data
        switch format {
        case .gpx: data = GPX.write(session: original)
        case .tcx: data = TCX.write(session: original)
        case .csv: data = CSV.write(session: original)
        case .openwater: data = try SessionArchive(session: original).encoded()
        case .fit: return   // read-only
        }

        let restored = try TrackImporter.read(data).makeSession(sport: .wingfoil)
        let result = headline(restored)

        #expect(restored.track.count == original.track.count,
                "\(format.displayName) lost points: \(original.track.count) → \(restored.track.count)")

        // Tolerance depends on what the format can physically carry.
        //
        // The archive and CSV both store `speedAccuracy`, which is the weight the
        // smoother uses, so they reproduce the original numbers almost exactly.
        // GPX and TCX have nowhere to put it — the reader has to say "unknown"
        // and the filter falls back to its default — so a small, unavoidable
        // shift is expected. Pretending otherwise by loosening every tolerance
        // would hide a genuine regression in the lossless formats.
        let tolerance: Double = (format == .gpx || format == .tcx) ? 0.08 : 0.02

        #expect(abs(result.max - reference.max) < tolerance,
                "\(format.displayName) max speed drifted: \(reference.max) → \(result.max)")
        #expect(abs(result.best500 - reference.best500) < tolerance,
                "\(format.displayName) best 500 m drifted: \(reference.best500) → \(result.best500)")
        #expect(abs(result.distance - reference.distance) < 5,
                "\(format.displayName) distance drifted: \(reference.distance) → \(result.distance)")
    }

    @Test("Doppler speed survives every writable format")
    func speedSourcePreserved() throws {
        let original = session()
        #expect(original.track.speedSource == .doppler)

        for data in [
            GPX.write(session: original),
            TCX.write(session: original),
            CSV.write(session: original),
            try SessionArchive(session: original).encoded(),
        ] {
            let restored = try TrackImporter.read(data).makeSession(sport: .wingfoil)
            #expect(restored.track.speedSource == .doppler,
                    "a format dropped the speed channel and fell back to derived speed")
        }
    }

    @Test("The archive is the only format that preserves motion data")
    func motionDataIsArchiveOnly() throws {
        let original = session()
        #expect(original.summary?.foil.flightCount ?? 0 > 0)

        // The archive carries every channel, so flights survive.
        let archive = try TrackImporter.read(
            try SessionArchive(session: original).encoded()
        ).makeSession(sport: .wingfoil)
        #expect(archive.summary?.foil.usedMotionData == true)
        #expect(archive.summary?.foil.flightCount == original.summary?.foil.flightCount)

        // GPX has nowhere to put accelerometer data, so flight detection falls
        // back to speed alone. It must say so rather than quietly claiming the
        // same confidence.
        let gpx = try TrackImporter.read(GPX.write(session: original))
            .makeSession(sport: .wingfoil)
        #expect(gpx.summary?.foil.usedMotionData == false)
        if let flight = gpx.summary?.flights.first {
            #expect(flight.confidence < 0.6)
        }
    }

    @Test("Privacy trimming applies to every export format")
    func privacyAppliesEverywhere() throws {
        let original = session()
        let privacy = PrivacySettings(endpointMaskRadius: 300, maskEndpoints: true)
        let trimmed = privacy.apply(to: original)

        #expect(trimmed.track.count < original.track.count,
                "the endpoint trim removed nothing")

        // Whichever format it goes out as, the trimmed track is what ships.
        for data in [
            GPX.write(session: trimmed),
            TCX.write(session: trimmed),
            CSV.write(session: trimmed),
        ] {
            let restored = try TrackImporter.read(data)
            #expect(restored.points.count == trimmed.track.count)

            // The guarantee is that the *endpoints* no longer reveal the launch
            // and landing, which is what identifies them. Interior passes over
            // the same water are not removed — see `PrivacySettings.trim` — so
            // asserting that no point comes near the launch would be asserting
            // something the feature does not claim, and would fail on any bay
            // session that sails back over its own start.
            let originalStart = original.track.points[0].coordinate
            let originalEnd = original.track.points[original.track.count - 1].coordinate

            guard let newStart = restored.points.first?.coordinate,
                  let newEnd = restored.points.last?.coordinate else {
                Issue.record("trimmed track had no points")
                continue
            }

            #expect(Geo.distance(newStart, originalStart) >= 290,
                    "the shared track still starts at the launch point")
            #expect(Geo.distance(newEnd, originalEnd) >= 290,
                    "the shared track still ends at the landing point")
        }
    }
}
