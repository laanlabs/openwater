import Foundation
import Testing
@testable import OpenWaterCore

/// Every real recording in `testdata/` goes through the full pipeline, and the
/// parts of the analysis that describe the same events have to agree.
///
/// Synthetic tracks are clean in exactly the ways real ones are not, and every
/// analytical fault found this week — false touchdowns, fragmented glides, a
/// turn counted three times, upwind reported on a downwind run — was invisible
/// to the synthetic suite and obvious the moment a real file went through. So
/// the real files are fixtures now, and the invariants they exposed are
/// asserted on all of them, forever.
@Suite("Real sessions stay consistent")
struct RealSessionConsistencyTests {

    /// The repo's testdata directory, found relative to this source file.
    static var testdata: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // the file → OpenWaterCoreTests
            .deletingLastPathComponent()  // → Tests
            .deletingLastPathComponent()  // → OpenWaterCore
            .deletingLastPathComponent()  // → the repo root
            .appendingPathComponent("testdata")
    }

    struct Fixture: CustomTestStringConvertible {
        let url: URL
        var testDescription: String { url.lastPathComponent }
    }

    static var fixtures: [Fixture] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: testdata, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["gpx", "openwater"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(Fixture.init)
    }

    /// Sport from the filename, the way a rider would name their own exports.
    private func sport(for url: URL) -> Sport {
        let name = url.lastPathComponent.lowercased()
        if name.contains("parawing") { return .parawing }
        if name.contains("sup") { return .downwindSUP }
        return .wingfoil
    }

    private func analysed(_ url: URL) throws -> (Track, SessionSummary, Sport) {
        if url.pathExtension.lowercased() == "openwater" {
            let session = try SessionArchive.decode(Data(contentsOf: url)).session
            let summary = SessionAnalyzer(
                configuration: .init(sport: session.sport, categories: SpeedCategory.all,
                                     wind: session.wind?.source == .manual ? session.wind : nil)
            ).analyse(session.track)
            return (session.track, summary, session.sport)
        }
        let track = TrackBuilder().build(from: try GPX.read(Data(contentsOf: url)).points)
        let s = sport(for: url)
        let summary = SessionAnalyzer(
            configuration: .init(sport: s, categories: SpeedCategory.all)
        ).analyse(track)
        return (track, summary, s)
    }

    /// The suite is only as good as its fixtures, and an empty parametrised
    /// test passes silently — which is how a moved folder would quietly turn
    /// every one of these checks off.
    @Test("The fixtures are actually there")
    func fixturesExist() {
        #expect(!Self.fixtures.isEmpty,
                "no test files at \(Self.testdata.path) — the consistency checks below ran on nothing")
    }

    @Test("The pieces of the analysis agree with each other", arguments: fixtures)
    func consistent(fixture: Fixture) throws {
        let (track, s, sportUsed) = try analysed(fixture.url)
        let name = fixture.url.lastPathComponent

        // Time can only nest one way.
        #expect(s.movingTime <= s.duration + 1)
        #expect(s.foil.timeOnFoil <= s.movingTime + 1,
                "\(name): more time on foil than moving")

        // A glide is flying, so with flights present glide time fits inside
        // foil time.
        if !s.flights.isEmpty {
            #expect(s.downwind.glideTime <= s.foil.timeOnFoil + 1,
                    "\(name): more time gliding than flying")
        }

        // Touchdowns are the gaps between flights, by definition.
        #expect(s.foil.touchdownCount == max(0, s.flights.count - 1),
                "\(name): touchdowns disagree with flights")

        // One turn is one turn. The run count is not the right bound — a
        // real session (alphonso 05-30) has 15 genuine turns against 11 runs,
        // because the scraps between quick turns fall under the run minimums
        // and vanish. What *does* betray double counting is spacing: when the
        // detector reports one turn several times the gaps collapse to a
        // second or two, and real turns are separated by riding.
        if s.maneuvers.count > 2 {
            let gaps = zip(s.maneuvers.dropFirst(), s.maneuvers)
                .map { $0.startElapsed - $1.endElapsed }
                .sorted()
            #expect(gaps[gaps.count / 2] >= 5,
                    "\(name): median gap between turns is \(Int(gaps[gaps.count / 2]))s — one turn is being counted repeatedly")
        }
        #expect(s.maneuverSummary.total <= s.runs.count * 2 + 4,
                "\(name): \(s.maneuverSummary.total) turns for \(s.runs.count) runs")

        // Every glide is sailed downwind of the configured angle when the
        // wind is known — a beat is not a glide.
        if let wind = s.wind {
            let bar = sportUsed.thresholds.glideDownwindAngle
            for glide in s.downwind.glides where glide.endIndex < track.count {
                let heading = Geo.bearing(from: track.points[glide.startIndex].coordinate,
                                          to: track.points[glide.endIndex].coordinate)
                #expect(Geo.angleSeparation(heading, wind.directionFrom) > bar - 1,
                        "\(name): glide \(glide.id) sailed \(Int(Geo.angleSeparation(heading, wind.directionFrom)))° off the wind")
            }
        }

        // The downwind aggregates describe the glide list they ship with.
        let listed = s.downwind.glides
        #expect(s.downwind.glideCount == listed.count, "\(name): glide count disagrees with the list")
        // Time gliding covers every second of gliding; the list holds only
        // the glides long enough to be worth naming. So the total is at least
        // the sum of the list, and never more than the time spent moving.
        //
        // This used to demand equality, which is what let a real defect hide:
        // 76 seconds of genuine rising downwind gliding on the Rufus parawing
        // run fell under the five-second bar and were discarded with their
        // time, reporting 44% for a session that glided 57% of the way.
        let summedTime = listed.reduce(0) { $0 + $1.duration }
        #expect(s.downwind.glideTime >= summedTime - 2,
                "\(name): glide time \(Int(s.downwind.glideTime))s is under its own list's \(Int(summedTime))s")
        #expect(s.downwind.glideTime <= s.movingTime + 2,
                "\(name): glide time \(Int(s.downwind.glideTime))s exceeds moving time \(Int(s.movingTime))s")

        // A linked glide's whole approach was flown, so a session with no
        // touchdowns at all cannot have unlinked glides after its first.
        if s.foil.touchdownCount == 0, listed.count > 1 {
            #expect(listed.dropFirst().filter { !$0.connected }.isEmpty,
                    "\(name): unlinked glides in a session that never touched down")
        }

        // Shape and legs tell one story.
        let shape = s.shape
        if shape.kind == .aroundASpot {
            #expect(shape.legs.filter(\.isDownwind).count < 2,
                    "\(name): a session at one spot with several downwind runs is a shuttle day")
        }
        if shape.kind == .downwinder {
            #expect(shape.legs.contains(where: \.isDownwind) || shape.downwindAlignment ?? 999 <= 50,
                    "\(name): called a downwinder with nothing downwind in it")
        }
        for leg in shape.legs {
            #expect(leg.endElapsed > leg.startElapsed, "\(name): inverted leg")
            #expect(leg.distance >= leg.netDisplacement - 1,
                    "\(name): a leg cannot displace further than it travelled")
        }
    }
}
