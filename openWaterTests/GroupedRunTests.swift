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
        _ id: Int, _ point: PointOfSail, metres: Double, from start: TimeInterval,
        heading: Double = 0, trueWindAngle: Double? = nil
    ) throws -> SessionRibbon.Lane {
        let json: [String: Any] = [
            "id": id,
            "runIndex": id,
            "startElapsed": start,
            "endElapsed": start + metres / 5,    // ~5 m/s, so time follows distance
            "distance": metres,
            "averageSpeed": 5,
            "maxSpeed": 6,
            "heading": heading,
            "pointOfSail": point.rawValue,
            "trueWindAngle": trueWindAngle ?? (point == .running ? 180 : (point == .closeHauled ? 45 : 90)),
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

    // MARK: Coming off the foil

    /// A flight over `[start, end]` seconds.
    private func flight(_ id: Int, _ start: TimeInterval, _ end: TimeInterval) throws -> Flight {
        let json: [String: Any] = [
            "id": id,
            "startElapsed": start, "endElapsed": end,
            "startIndex": id * 2, "endIndex": id * 2 + 1,
            "distance": (end - start) * 5,
            "averageSpeed": 5, "maxSpeed": 6,
            "takeoffSpeed": 4, "landingSpeed": 3,
            "confidence": 1,
        ]
        return try JSONDecoder().decode(
            Flight.self, from: JSONSerialization.data(withJSONObject: json)
        )
    }

    /// The complaint this rule exists for: one point of sail, seven swims,
    /// reported as a single thirty-six-minute reach.
    func testATouchdownEndsTheRun() throws {
        // Three 100 s reaches in a row — one run on point of sail alone.
        let input = try lanes(Array(repeating: (PointOfSail.reaching, 500), count: 3))
        XCTAssertEqual(GroupedRun.group(input).count, 1)

        // Same stretches, but the rider swam ten seconds between each.
        let flights = [
            try flight(0, 0, 95),
            try flight(1, 105, 195),
            try flight(2, 205, 295),
        ]
        let runs = GroupedRun.group(input, flights: flights)

        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.map(\.kind), [.reaching, .reaching, .reaching])
        XCTAssertEqual(runs.map(\.number), [1, 2, 3])
    }

    func testStretchesInsideOneFlightStayOneRun() throws {
        let input = try lanes(Array(repeating: (PointOfSail.reaching, 500), count: 3))
        let runs = GroupedRun.group(input, flights: [try flight(0, 0, 300)])

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.lanes.count, 3)
    }

    /// The foil detector ends a flight the instant the board touches. A tap
    /// and a swim are not the same event, and only one of them ends a run.
    func testAMomentaryTouchdownDoesNotEndTheRun() throws {
        let input = try lanes(Array(repeating: (PointOfSail.reaching, 500), count: 2))
        let runs = GroupedRun.group(input, flights: [
            try flight(0, 0, 100),
            try flight(1, 101, 200),      // back up after a second
        ])

        XCTAssertEqual(runs.count, 1)
    }

    /// A point-of-sail change still splits inside a single flight — a rider
    /// who gybes without touching down did two runs, not one.
    func testPointOfSailStillSplitsWithinAFlight() throws {
        let input = try lanes([(.running, 600), (.closeHauled, 600)])
        let runs = GroupedRun.group(input, flights: [try flight(0, 0, 240)])

        XCTAssertEqual(runs.map(\.kind), [.downwind, .upwind])
    }

    /// No flights means a non-foiling sport, where the old rule is the right
    /// one. This must not fragment a windsurfer's session into single lanes.
    func testWithoutFlightsGroupingIsUnchanged() throws {
        let input = try lanes(Array(repeating: (PointOfSail.reaching, 500), count: 4))

        XCTAssertEqual(GroupedRun.group(input, flights: []).count, 1)
    }

    /// A run is a ride. The stretches sailed on the water between rides are
    /// the swim back out — they never join a flight, and on a foiling session
    /// they are not runs at all.
    func testWaterborneStretchesAreNotRuns() throws {
        let input = try lanes(Array(repeating: (PointOfSail.reaching, 500), count: 3))
        // Only the first stretch was flown; the other two were the paddle back.
        let runs = GroupedRun.group(input, flights: [try flight(0, 0, 100)])

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.lanes.count, 1)
    }

    /// The same stretches on a session with no flight detection at all are
    /// still runs — dropping them there would empty a windsurfer's list.
    func testWaterborneStretchesSurviveWithoutFlightDetection() throws {
        let input = try lanes(Array(repeating: (PointOfSail.reaching, 500), count: 3))

        XCTAssertEqual(GroupedRun.group(input, flights: []).count, 1)
        XCTAssertEqual(GroupedRun.group(input, flights: []).first?.lanes.count, 3)
    }

    /// The leading-stretch merge must not reach across a touchdown either.
    func testAShortOpeningStretchDoesNotMergeAcrossATouchdown() throws {
        let input = try lanes([(.reaching, 40), (.running, 2000)])
        let runs = GroupedRun.group(input, flights: [
            try flight(0, 0, 8),           // got up, came straight down
            try flight(1, 100, 500),       // and then had the actual run
        ])

        XCTAssertEqual(runs.count, 2)
    }

    // MARK: Turning back the way you came

    /// A reach out and a reach back are two runs to the rider and one point
    /// of sail to the segmenter. This is why a session with forty-eight turns
    /// could report eleven runs.
    func testTurningBackTheWayYouCameStartsANewRun() throws {
        // Same point of sail, opposite directions: 90° out, 270° back.
        let outbound = try lane(0, .reaching, metres: 600, from: 0, heading: 90)
        let back = try lane(1, .reaching, metres: 600,
                            from: outbound.endElapsed, heading: 270)

        let runs = GroupedRun.group([outbound, back], flights: [try flight(0, 0, 400)])

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map(\.isLinked), [false, true],
                       "Gybed onto the way back without touching down")
    }

    /// And the case that must not break with it: weaving down a downwinder
    /// changes heading constantly and is still one run down.
    func testWeavingDownwindIsStillOneRun() throws {
        // 40° either side of dead downwind, five weaves.
        var weaves: [SessionRibbon.Lane] = []
        var clock: TimeInterval = 0
        for i in 0..<5 {
            let lane = try lane(i, .running, metres: 400, from: clock,
                                heading: i.isMultiple(of: 2) ? 140 : 220)
            clock = lane.endElapsed
            weaves.append(lane)
        }

        let runs = GroupedRun.group(weaves, flights: [try flight(0, 0, 500)])

        XCTAssertEqual(runs.count, 1, "Eighty degrees apart is a weave, not a turn back")
    }

    // MARK: Linked runs

    /// Turning without dropping off the foil is the thing riders chase, and
    /// it is invisible in a list of runs unless the run says so.
    func testRunsInOneFlightAreLinked() throws {
        // Gybed twice without touching down: three runs, one ride.
        let input = try lanes([(.running, 600), (.closeHauled, 600), (.running, 600)])
        let runs = GroupedRun.group(input, flights: [try flight(0, 0, 400)])

        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.map(\.isLinked), [false, true, true],
                       "The first run is not linked to anything; the other two are")
    }

    func testARunAfterATouchdownIsNotLinked() throws {
        let input = try lanes(Array(repeating: (PointOfSail.reaching, 500), count: 3))
        let runs = GroupedRun.group(input, flights: [
            try flight(0, 0, 95), try flight(1, 105, 195), try flight(2, 205, 295),
        ])

        XCTAssertEqual(runs.map(\.isLinked), [false, false, false])
    }

    /// Without flight detection nothing is known about touchdowns, and every
    /// run would share a nil ride — claiming a whole windsurfing session was
    /// linked when the app cannot see the foil at all.
    func testNothingIsLinkedWithoutFlightDetection() throws {
        let input = try lanes([(.running, 600), (.closeHauled, 600), (.running, 600)])
        let runs = GroupedRun.group(input, flights: [])

        XCTAssertFalse(runs.contains { $0.isLinked })
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

    // MARK: One word for one stretch

    /// A wing working 70° off the wind is upwind by the rule the runs use
    /// (`UpwindLegFinder.upwindLimit`, 90°) and "reaching" by `PointOfSail`'s
    /// 55° sailboat boundary. The filter chips over the stretch list have to
    /// read the angle the way the run rows do, or the "Upwind" chip hides
    /// stretches the rows beneath it call upwind. (The *leg* row keeps the
    /// point-of-sail majority rule on purpose — see `SessionLeg.kind(in:)`.)
    func testTheUpwindChipAgreesWithTheRunRule() throws {
        let stretch = try lane(0, .reaching, metres: 800, from: 0, trueWindAngle: 70)

        let runs = GroupedRun.group([stretch])
        XCTAssertEqual(runs.first?.kind, .upwind, "the run rule calls 70° upwind")
        XCTAssertTrue(RibbonView.Leg.upwind.matches(stretch),
                      "the stretch filter must call the same lane upwind")
        XCTAssertFalse(RibbonView.Leg.reaching.matches(stretch))
    }

    func testWithoutAnAngleTheFilterFallsBackToThePointOfSail() throws {
        var json: [String: Any] = [
            "id": 0, "runIndex": 0, "startElapsed": 0, "endElapsed": 100,
            "distance": 500, "averageSpeed": 5, "maxSpeed": 6, "heading": 0,
            "pointOfSail": PointOfSail.closeHauled.rawValue, "foilingFraction": 1, "cells": [],
        ]
        json["trueWindAngle"] = nil
        let stretch = try JSONDecoder().decode(
            SessionRibbon.Lane.self, from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertTrue(RibbonView.Leg.upwind.matches(stretch))
    }
}
