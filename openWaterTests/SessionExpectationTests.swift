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
/// **Keyed by start date, not by filename.** Filenames carry riders' names;
/// a start date identifies a recording just as well, survives a rename, and
/// says nothing about who was on the water.
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
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Measuring

    /// Analyse one file exactly as an import would.
    private func measure(_ url: URL) throws -> (key: String, expectation: Expectation) {
        let data = try Data(contentsOf: url)
        let imported = try TrackImporter.read(data)

        // Sport is not in a GPX file, and it sets every threshold for
        // flights, turns and glides. The import sheet defaults to wingfoil
        // and so does this — an expectation measured under a different sport
        // would be measuring something else.
        let session = imported.makeSession(sport: .wingfoil)
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
            windDirection: summary.wind?.directionFrom,
            windSource: summary.wind?.source.rawValue
        )

        return (key(for: session), expectation)
    }

    /// A recording's identity: when it started, to the second, in UTC.
    private func key(for session: Session) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: session.startDate)
    }

    // MARK: The test

    func testEveryRecordingMatchesItsExpectation() throws {
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
            let (key, actual) = try measure(file)
            let path = Self.expectationsDirectory.appendingPathComponent("\(key).json")

            guard !isRecording else {
                try encoder.encode(actual).write(to: path)
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

        XCTAssertEqual(actual.windSource, expected.windSource, "\(key) (\(file)): wind source")
        if let a = actual.windDirection, let b = expected.windDirection {
            check("wind direction", a, b, 0.5)
        } else {
            XCTAssertEqual(actual.windDirection == nil, expected.windDirection == nil,
                           "\(key) (\(file)): wind direction presence")
        }
    }
}
