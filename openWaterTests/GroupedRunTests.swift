import OpenWaterCore
import XCTest
@testable import openWater

/// The rule that decides how many runs a rider is told they did.
///
/// This drives two screens — the Runs tab and the Downwind list — and it has
/// already been wrong in production: a lapping afternoon reported thirty-four
/// downwind runs for a session the rider counted six of. Every one of those
/// screens was checked by eye, on one file, which is exactly how the fault got
/// in and stayed.
///
/// So the merge is pinned here instead. Synthetic lanes, because the point is
/// the rule rather than the water: what starts a new run, what gets absorbed
/// into the current one, and what a run's kind is when its stretches disagree.
final class GroupedRunTests: XCTestCase {

    /// A lane on a given point of sail, `metres` long, following the last one.
    ///
    /// Built by decoding rather than by calling the memberwise initialiser,
    /// which is internal to OpenWaterCore. A lane is `Codable` already, so
    /// this needs no new production API — widening one for a test's sake
    /// would be the tail wagging the dog.
    private func lane(
        _ id: Int, _ point: PointOfSail, metres: Double, from start: TimeInterval
    ) throws -> SessionRibbon.Lane {
        let json: [String: Any] = [
            "id": id,
            "runIndex": id,
            "startElapsed": start,
            "endElapsed": start + metres / 5,    // ~5 m/s, so time follows distance
            "distance": metres,
            "averageSpeed": 5,
            "maxSpeed": 6,
            "heading": 0,
            "pointOfSail": point.rawValue,
            "trueWindAngle": point == .running ? 180 : (point == .closeHauled ? 45 : 90),
            "foilingFraction": 1,
            "cells": [],
        ]
        return try JSONDecoder().decode(
            SessionRibbon.Lane.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    /// Builds consecutive lanes from `(point, metres)` pairs.
    private func lanes(_ steps: [(PointOfSail, Double)]) throws -> [SessionRibbon.Lane] {
        var out: [SessionRibbon.Lane] = []
        var clock: TimeInterval = 0
        for (index, step) in steps.enumerated() {
            let lane = try lane(index, step.0, metres: step.1, from: clock)
            clock = lane.endElapsed
            out.append(lane)
        }
        return out
    }

    // MARK: The merge

    func testConsecutiveStretchesOnOnePointOfSailAreOneRun() throws {
        // Six weaves down the river is one downwind run, not six.
        let runs = GroupedRun.group(try lanes(Array(repeating: (.running, 300), count: 6)))

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.kind, .downwind)
        XCTAssertEqual(runs.first?.lanes.count, 6)
        XCTAssertEqual(runs.first?.distance ?? 0, 1800, accuracy: 0.001)
    }

    func testChangingPointOfSailStartsANewRun() throws {
        let runs = GroupedRun.group(try lanes([
            (.running, 400), (.running, 400),      // downwind
            (.closeHauled, 500),                    // beat back
            (.running, 600),                        // downwind again
        ]))

        XCTAssertEqual(runs.map(\.kind), [.downwind, .upwind, .downwind])
    }

    func testRunsAreNumberedWithinTheirOwnKind() throws {
        let runs = GroupedRun.group(try lanes([
            (.running, 400), (.closeHauled, 400),
            (.running, 400), (.closeHauled, 400),
            (.running, 400),
        ]))

        XCTAssertEqual(runs.filter { $0.kind == .downwind }.map(\.number), [1, 2, 3])
        XCTAssertEqual(runs.filter { $0.kind == .upwind }.map(\.number), [1, 2])
    }

    // MARK: Absorbing the turn

    /// The bug that made six downwinders into thirty-four.
    ///
    /// Bearing away from a beat crosses the reaching band for a few seconds.
    /// Treating that as a leg splits the run either side of every single turn.
    func testAShortStretchDoesNotSplitARun() throws {
        let runs = GroupedRun.group(try lanes([
            (.running, 500),
            (.reaching, 30),        // the bear-away, well under the 60 m bar
            (.running, 500),
        ]))

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.kind, .downwind)
    }

    func testALongStretchOnAnotherPointOfSailDoesSplit() throws {
        let runs = GroupedRun.group(try lanes([
            (.running, 500),
            (.reaching, 900),       // a genuine reach, not a turn
            (.running, 500),
        ]))

        XCTAssertEqual(runs.map(\.kind), [.downwind, .reaching, .downwind])
    }

    // MARK: Naming a mixed run

    /// A run's kind comes from the distance sailed on each point of sail
    /// inside it, not from whichever stretch happened to come first — so a
    /// run that opens with a short reach and then runs for a mile is downwind.
    func testKindFollowsTheDistanceNotTheFirstStretch() throws {
        let runs = GroupedRun.group(try lanes([
            (.reaching, 40),        // absorbed: too short to start anything
            (.running, 2000),
        ]))

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.kind, .downwind)
    }

    // MARK: Degenerate input

    func testNoLanesMakeNoRuns() throws {
        XCTAssertTrue(GroupedRun.group([]).isEmpty)
    }

    func testLanesOutOfOrderAreSortedBeforeGrouping() throws {
        // The ribbon hands them over in time order today. If that ever stops
        // being true, the merge must not silently produce a different answer.
        let ordered = try lanes([(.running, 400), (.closeHauled, 400), (.running, 400)])
        let shuffled = [ordered[2], ordered[0], ordered[1]]

        XCTAssertEqual(GroupedRun.group(shuffled).map(\.kind),
                       GroupedRun.group(ordered).map(\.kind))
    }

    // MARK: Aggregates

    func testARunSpansFromItsFirstStretchToItsLast() throws {
        let input = try lanes([(.running, 500), (.running, 500), (.running, 500)])
        let run = GroupedRun.group(input).first

        XCTAssertEqual(run?.startElapsed, input.first?.startElapsed)
        XCTAssertEqual(run?.endElapsed, input.last?.endElapsed)
        XCTAssertEqual(run?.maxSpeed ?? 0, 6, accuracy: 0.001)
    }

    /// Degrees off dead downwind, which the list prints as "38° off".
    func testAlignmentIsMeasuredFromDeadDownwind() throws {
        let runs = GroupedRun.group(try lanes([(.running, 800)]))

        // True wind angle 180 is dead downwind, so zero degrees off it.
        XCTAssertEqual(runs.first?.alignment ?? .nan, 0, accuracy: 0.001)
    }
}
