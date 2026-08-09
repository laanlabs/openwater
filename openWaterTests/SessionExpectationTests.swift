import CoreLocation
import OpenWaterCore
import XCTest
@testable import openWater

/// Every real recording, analysed, checked against what it said last time.
///
/// Every analytical change this project has made was judged by opening the
/// app and looking at one session. That is how a lapping afternoon came to
/// report thirty-four downwind runs, how the glide clock lost seventy-six
/// seconds, and how a fix for one file quietly moved the numbers on six
/// others that nobody reopened.
///
/// This runs the whole `testdata` directory through the analysis and diffs
/// the result against a committed expectation. It is not a correctness test —
/// the recorded numbers are only ever "what it did last time" — it is a
/// change detector, so a tweak aimed at one session cannot move another
/// without saying so.
///
/// **The recordings are not in the repository and never will be**; they are
/// riders' GPS traces. The expectations are, because they carry no
/// coordinates — counts, distances and durations only. Without the
/// recordings this test skips rather than fails, so a fresh clone stays
/// green.
///
/// **Keyed by filename.** The recordings are named `test-1`, `test-2` and so
/// on precisely so that the key gives nothing away — the names riders'
/// devices write carry the rider's own name, which is why the originals were
/// renamed rather than keyed around.
///
/// To accept new numbers after a deliberate change:
///
/// ```
/// scripts/record-expectations.sh
/// ```
///
/// The `TEST_RUNNER_` prefix in that script is not decoration: `xcodebuild`
/// does not pass the shell environment to the test process, and strips that
/// prefix on the way in. Without it the variable never arrives and the run
/// silently checks instead of recording.
///
/// Then read the diff in `git diff` before committing it. That diff is the
/// point of the whole file: it is the change, stated in the rider's numbers.
final class SessionExpectationTests: XCTestCase {

    /// What we pin. Deliberately the numbers a rider reads, not internals —
    /// a refactor should not churn this file, and a change a rider would
    /// notice always should.
    struct Expectation: Codable, Equatable {
        var sport: String
        var points: Int
        var duration: Double
        var distance: Double
        var maxSpeed: Double
        var averageMovingSpeed: Double

        var flights: Int
        var timeOnFoil: Double
        var foilingFraction: Double

        var turns: Int
        var falls: Int
        var jumps: Int

        var glides: Int
        var glideTime: Double

        var stretches: Int
        var runsDownwind: Int
        var runsReaching: Int
        var runsUpwind: Int
        /// Runs entered without touching down — the thing riders chase.
        var runsLinked: Int

        var windDirection: Double?
        var windSource: String?
    }

    // MARK: Where things live

    /// The repository root, found by walking up from this source file.
    ///
    /// `#filePath` rather than the test bundle, because the bundle lives in
    /// DerivedData and knows nothing about the checkout.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)       // …/openWaterTests/ThisFile.swift
            .deletingLastPathComponent()      // …/openWaterTests
            .deletingLastPathComponent()      // …/openWater
    }

    private static var recordingsDirectory: URL {
        repositoryRoot.appendingPathComponent("testdata")
    }

    private static var expectationsDirectory: URL {
        repositoryRoot
            .appendingPathComponent("openWaterTests")
            .appendingPathComponent("Expectations")
    }

    private var isRecording: Bool {
        ProcessInfo.processInfo.environment["OPENWATER_RECORD_EXPECTATIONS"] == "1"
    }

    /// Every recording we can read, in a stable order.
    private func recordings() throws -> [URL] {
        let directory = Self.recordingsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["gpx", "fit", "tcx", "csv", "openwater"].contains($0.pathExtension.lowercased()) }
            // Numerically: "test-10" sorts before "test-2" as a string.
            .sorted {
                let a = Int($0.deletingPathExtension().lastPathComponent
                    .components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
                let b = Int($1.deletingPathExtension().lastPathComponent
                    .components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
                return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
            }
    }

    // MARK: Measuring

    /// Analyse one file exactly as an import would.
    private func measure(_ url: URL) throws
        -> (key: String, expectation: Expectation, session: Session,
            summary: SessionSummary, runs: [GroupedRun]) {
        let data = try Data(contentsOf: url)
        let session = try load(data, named: url.lastPathComponent)
        guard let summary = session.summary else {
            throw XCTSkip("\(url.lastPathComponent) produced no analysis")
        }

        let runs = GroupedRun.group(summary.ribbon.lanes, flights: summary.flights)
        var byKind: [GroupedRun.Kind: Int] = [:]
        for run in runs { byKind[run.kind, default: 0] += 1 }

        let expectation = Expectation(
            sport: session.sport.rawValue,
            points: session.track.points.count,
            duration: summary.duration,
            distance: summary.distance,
            maxSpeed: summary.maxSpeed,
            averageMovingSpeed: summary.averageMovingSpeed,
            flights: summary.flights.count,
            timeOnFoil: summary.foil.timeOnFoil,
            foilingFraction: summary.foil.foilingFraction,
            turns: summary.maneuvers.count,
            falls: summary.fallSummary.count,
            jumps: summary.jumps.count,
            glides: summary.downwind.glides.count,
            glideTime: summary.downwind.glideTime,
            stretches: summary.ribbon.lanes.count,
            runsDownwind: byKind[.downwind] ?? 0,
            runsReaching: byKind[.reaching] ?? 0,
            runsUpwind: byKind[.upwind] ?? 0,
            runsLinked: runs.filter(\.isLinked).count,
            windDirection: summary.wind?.directionFrom,
            windSource: summary.wind?.source.rawValue
        )

        return (url.deletingPathExtension().lastPathComponent,
                expectation, session, summary, runs)
    }

    /// Turn a file into an analysed session the way the app's import does.
    ///
    /// The two paths differ and the difference matters. An archive already
    /// knows its sport, its wind and its swell, and re-analysing one as
    /// wingfoil would measure a parawing session against the wrong
    /// thresholds for flights, turns and glides. A GPX knows none of that, so
    /// it gets the same wingfoil default the import sheet offers.
    private func load(_ data: Data, named name: String) throws -> Session {
        guard TrackImporter.detectFormat(data) == .openwater else {
            return try TrackImporter.read(data).makeSession(sport: .wingfoil)
        }
        if let bundle = try? SessionArchiveBundle.decode(data),
           let first = bundle.sessions.first {
            return first
        }
        return try SessionArchive.decode(data).upToDateSession()
    }

    // MARK: Putting them on a simulator

    /// Write each recording out as a titled `.openwater` archive.
    ///
    /// Loading these into a simulator by hand means ten trips through the
    /// import sheet and ten sessions labelled with whatever the recording
    /// device called them — which is the rider's own name, and unreadable
    /// besides. An archive carries its own title and sport, and imports
    /// without a confirmation step, so ten `simctl openurl` calls put the
    /// whole set on a device already named test-1 to test-10.
    ///
    /// Off unless asked for. `scripts/load-simulator.sh` runs it.
    func testWriteTitledArchives() throws {
        let destination = ProcessInfo.processInfo.environment["OPENWATER_ARCHIVE_OUT"]
        try XCTSkipIf(destination == nil, "Set OPENWATER_ARCHIVE_OUT to write archives")

        let out = URL(fileURLWithPath: destination!, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for file in try recordings() {
            let name = file.deletingPathExtension().lastPathComponent
            var session = try load(try Data(contentsOf: file), named: file.lastPathComponent)
            session.title = name

            let path = out.appendingPathComponent("\(name).openwater")
            try SessionArchive(session: session).encoded().write(to: path)
            print("wrote \(path.lastPathComponent) — \(session.sport.displayName)")
        }
    }

    // MARK: The readable half

    /// A page per recording, in prose and tables.
    ///
    /// The JSON next to it is for the machine: it fails a build when a number
    /// moves. This is for the rider: it says where the session was, what the
    /// conditions were, and lists every run the analysis found, so the
    /// question "is this actually right?" can be answered by reading rather
    /// than by opening the app and tapping through four screens.
    ///
    /// Anything below the notes marker is preserved across re-records. That
    /// is where the ground truth goes — what the rider says the session was —
    /// and it would be worthless if regenerating wiped it.
    private func document(
        for session: Session, summary: SessionSummary, runs: [GroupedRun],
        place: String?, existing: String?
    ) -> String {
        var out = ""

        let date = DateFormatter()
        date.dateFormat = "d MMMM yyyy 'at' HH:mm"
        date.timeZone = TimeZone(identifier: "UTC")
        date.locale = Locale(identifier: "en_US_POSIX")

        out += "# \(place ?? "Unknown water") — \(date.string(from: session.startDate)) UTC\n\n"
        out += "\(session.sport.displayName) · \(duration(summary.duration)) · "
        out += "\(kilometres(summary.distance)) · \(knots(summary.maxSpeed)) max\n\n"

        // What kind of session it was.
        out += "## The session\n\n"
        out += "- Shape: **\(summary.shape.kind.displayName)**"
        if summary.shape.legs.count > 1 {
            out += ", in \(summary.shape.legs.count) legs (split where recording stopped)"
        }
        out += "\n"
        out += "- Net displacement \(kilometres(summary.shape.netDisplacement)), "
        out += "straightness \(String(format: "%.2f", summary.shape.straightness)) "
        out += "_(0 = back where you started, 1 = a straight line)_\n"
        if let alignment = summary.shape.downwindAlignment {
            out += "- \(Int(alignment.rounded()))° off dead downwind overall\n"
        }
        out += "- Average moving speed \(knots(summary.averageMovingSpeed))\n"
        out += "\n"

        // Conditions.
        out += "## Conditions\n\n"
        if let wind = summary.wind {
            let source = wind.source == .manual ? "set by the rider" : "estimated from the track"
            out += "- **Wind** \(cardinal(wind.directionFrom)) "
            out += "\(Int(wind.directionFrom.rounded()))° — _\(source)_\n"
            out += "- **Wind speed** "
            out += wind.hasSpeed ? "\(knots(wind.speed ?? 0))\n" : "_not set_\n"
        } else {
            out += "- **Wind** _not known_ — upwind and downwind cannot be told apart without it\n"
        }
        if let swell = session.swellHeight, swell > 0.05 {
            out += "- **Swell** \(String(format: "%.1f", swell)) m"
            if let from = session.swellDirection {
                out += " from \(cardinal(from)) \(Int(from.rounded()))°"
            } else {
                out += " _(direction not set)_"
            }
            out += "\n"
        } else {
            out += "- **Swell** _not set_\n"
        }
        out += "\n"

        // Foiling and events.
        out += "## On the water\n\n"
        out += "| | |\n|---|---|\n"
        out += "| On foil | \(Int((summary.foil.foilingFraction * 100).rounded()))% · "
        out += "\(duration(summary.foil.timeOnFoil)) across \(summary.flights.count) flights |\n"
        out += "| Turns | \(summary.maneuvers.count) |\n"
        out += "| Falls | \(summary.fallSummary.count) |\n"
        out += "| Jumps | \(summary.jumps.count) |\n"
        out += "| Glides | \(summary.downwind.glides.count) · \(duration(summary.downwind.glideTime)) gliding |\n"
        out += "\n"

        // The runs.
        out += "## Runs\n\n"
        out += "The segmenter found **\(summary.ribbon.lanes.count) stretches**, which group into "
        out += "**\(runs.count) runs**, "
        out += "**\(runs.filter(\.isLinked).count) of them linked** — entered without touching "
        out += "down. A run ends at a change of point of sail or a touchdown; stretches sailed "
        out += "off the foil are not runs.\n\n"

        for kind in [GroupedRun.Kind.downwind, .reaching, .upwind] {
            let group = runs.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            out += "### \(kind.title) · \(group.count)\n\n"
            out += "| # | Distance | Duration | Avg | Max | Off downwind | Stretches |\n"
            out += "|--:|---:|---:|---:|---:|---:|---:|\n"
            for run in group {
                out += "| \(run.number) "
                out += "| \(metresOrKilometres(run.distance)) "
                out += "| \(duration(run.duration)) "
                out += "| \(knots(run.averageSpeed)) "
                out += "| \(knots(run.maxSpeed)) "
                out += "| \(run.alignment.map { "\(Int($0.rounded()))°" } ?? "—") "
                out += "| \(run.lanes.count) |\n"
            }
            out += "\n"
        }

        out += Self.notesMarker + "\n\n"
        if let existing, let range = existing.range(of: Self.notesMarker) {
            // Keep whatever the rider wrote, exactly as they wrote it.
            let kept = existing[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out += kept.isEmpty ? Self.notesTemplate : kept + "\n"
        } else {
            out += Self.notesTemplate
        }
        return out
    }

    private static let notesMarker =
        "<!-- Anything below this line is yours. Re-recording will not touch it. -->"

    private static let notesTemplate = """
        ## What this session actually was

        _How many runs would you say you did? Where did you launch and land?
        Anything the numbers above get wrong?_

        - Runs I'd count:
        - Conditions as I remember them:
        - What looks wrong:
        """

    // MARK: Formatting
    //
    // Done here rather than through the app's `Format`, which reads the
    // rider's unit preferences — a document that changes because somebody
    // switched to mph would diff for no reason.

    private func knots(_ metresPerSecond: Double) -> String {
        String(format: "%.1f kn", metresPerSecond * 1.94384)
    }

    private func kilometres(_ metres: Double) -> String {
        String(format: "%.2f km", metres / 1000)
    }

    private func metresOrKilometres(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres.rounded())) m" : kilometres(metres)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    private func cardinal(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((degrees / 22.5).rounded()) % 16
        return points[(index + 16) % 16]
    }

    /// The nearest place name, at town level.
    ///
    /// Deliberately coarse. A launch site is public knowledge; the track that
    /// reaches it is not, which is why the recordings stay out of the
    /// repository. Reverse geocoding runs only while recording, so the check
    /// pass never touches the network.
    private func placeName(for track: Track) async -> String? {
        guard let middle = track.points[safe: track.points.count / 2] else { return nil }
        let location = CLLocation(latitude: middle.latitude, longitude: middle.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        else { return nil }
        let parts = [mark.locality ?? mark.subAdministrativeArea,
                     mark.administrativeArea].compactMap { $0 }
        return parts.isEmpty ? mark.country : parts.joined(separator: ", ")
    }

    // MARK: The test

    func testEveryRecordingMatchesItsExpectation() async throws {
        let files = try recordings()
        try XCTSkipIf(files.isEmpty, """
            No recordings in \(Self.recordingsDirectory.path).

            They are deliberately not in the repository — they are riders' GPS \
            traces. Put your own .gpx/.fit/.openwater files there to run this.
            """)

        try FileManager.default.createDirectory(
            at: Self.expectationsDirectory, withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var recorded = 0
        var checked = 0

        for file in files {
            let (key, actual, session, summary, runs) = try measure(file)
            let path = Self.expectationsDirectory.appendingPathComponent("\(key).json")

            guard !isRecording else {
                try encoder.encode(actual).write(to: path)

                let page = Self.expectationsDirectory.appendingPathComponent("\(key).md")
                let existing = try? String(contentsOf: page, encoding: .utf8)
                let text = document(for: session, summary: summary, runs: runs,
                                    place: await placeName(for: session.track),
                                    existing: existing)
                try text.write(to: page, atomically: true, encoding: .utf8)

                recorded += 1
                continue
            }

            guard let stored = try? Data(contentsOf: path),
                  let expected = try? JSONDecoder().decode(Expectation.self, from: stored)
            else {
                XCTFail("""
                    No expectation for \(key) (\(file.lastPathComponent)).

                    Re-run with OPENWATER_RECORD_EXPECTATIONS=1 to record one, \
                    then read the diff before committing it.
                    """)
                continue
            }

            checked += 1
            compare(actual, against: expected, key: key, file: file.lastPathComponent)
        }

        if isRecording {
            print("Recorded \(recorded) expectation(s) into \(Self.expectationsDirectory.path)")
        } else {
            XCTAssertGreaterThan(checked, 0, "No expectations were checked")
        }
    }

    /// Field by field, so a failure names the number that moved rather than
    /// printing two walls of JSON.
    private func compare(
        _ actual: Expectation, against expected: Expectation, key: String, file: String
    ) {
        func check(_ name: String, _ a: Int, _ b: Int) {
            XCTAssertEqual(a, b, "\(key) (\(file)): \(name) \(b) → \(a)")
        }
        // Doubles carry a tolerance because the analysis is floating point and
        // a rebuild can move the last digit. Anything a rider would notice is
        // far outside this.
        func check(_ name: String, _ a: Double, _ b: Double, _ tolerance: Double = 0.01) {
            XCTAssertEqual(a, b, accuracy: tolerance,
                           "\(key) (\(file)): \(name) \(b) → \(a)")
        }

        XCTAssertEqual(actual.sport, expected.sport, "\(key) (\(file)): sport")
        check("points", actual.points, expected.points)
        check("duration", actual.duration, expected.duration)
        check("distance", actual.distance, expected.distance, 0.5)
        check("maxSpeed", actual.maxSpeed, expected.maxSpeed)
        check("averageMovingSpeed", actual.averageMovingSpeed, expected.averageMovingSpeed)

        check("flights", actual.flights, expected.flights)
        check("timeOnFoil", actual.timeOnFoil, expected.timeOnFoil, 0.5)
        check("foilingFraction", actual.foilingFraction, expected.foilingFraction, 0.001)

        check("turns", actual.turns, expected.turns)
        check("falls", actual.falls, expected.falls)
        check("jumps", actual.jumps, expected.jumps)

        check("glides", actual.glides, expected.glides)
        check("glideTime", actual.glideTime, expected.glideTime, 0.5)

        check("stretches", actual.stretches, expected.stretches)
        check("downwind runs", actual.runsDownwind, expected.runsDownwind)
        check("reaching runs", actual.runsReaching, expected.runsReaching)
        check("upwind runs", actual.runsUpwind, expected.runsUpwind)
        check("linked runs", actual.runsLinked, expected.runsLinked)

        XCTAssertEqual(actual.windSource, expected.windSource, "\(key) (\(file)): wind source")
        if let a = actual.windDirection, let b = expected.windDirection {
            check("wind direction", a, b, 0.5)
        } else {
            XCTAssertEqual(actual.windDirection == nil, expected.windDirection == nil,
                           "\(key) (\(file)): wind direction presence")
        }
    }
}
