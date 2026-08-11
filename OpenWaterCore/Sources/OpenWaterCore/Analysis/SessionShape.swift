import Foundation

/// What kind of session this was, geometrically.
///
/// Everything else the analysis produces treats a session as a bag of runs. But
/// an afternoon of laps at one spot and a twelve-kilometre downwind run are not
/// the same thing, and until now they got the same report — the downwinder was
/// described by its gybe count and told nothing about the run it actually was.
///
/// The distinction is cheap to make: how far you finished from where you
/// started, how straight you got there, and — when the wind is known — whether
/// that line pointed downwind.
public struct SessionShape: Hashable, Sendable, Codable {

    public enum Kind: String, Sendable, Codable {

        /// You finished roughly where you started. Laps, a session at a
        /// launch, an out-and-back.
        case aroundASpot

        /// A point-to-point run with the wind behind you.
        case downwinder

        /// A point-to-point run that was not downwind — a crossing, a
        /// delivery, a coastal run on a reach.
        case crossing

        public var displayName: String {
            switch self {
            case .aroundASpot: "At one spot"
            case .downwinder: "Downwinder"
            case .crossing: "Crossing"
            }
        }
    }

    public let kind: Kind

    /// Straight-line metres from the first fix to the last.
    public let netDisplacement: Double

    /// Net displacement ÷ distance travelled, 0–1. Zero means you came back to
    /// where you started; one means you sailed a straight line and never turned.
    public let straightness: Double

    /// Bearing from start to finish, `nil` when you barely moved.
    public let netBearing: Double?

    /// Degrees between the net bearing and dead downwind. `nil` without wind.
    public let downwindAlignment: Double?

    /// The separate runs of a shuttle day, in time order. One leg for an
    /// ordinary session; several when the rider was driven back up the road.
    public let legs: [SessionLeg]

    public var isPointToPoint: Bool { kind != .aroundASpot }

    public init(
        kind: Kind,
        netDisplacement: Double,
        straightness: Double,
        netBearing: Double?,
        downwindAlignment: Double?,
        legs: [SessionLeg]
    ) {
        self.kind = kind
        self.netDisplacement = netDisplacement
        self.straightness = straightness
        self.netBearing = netBearing
        self.downwindAlignment = downwindAlignment
        self.legs = legs
    }

    public static let empty = SessionShape(
        kind: .aroundASpot, netDisplacement: 0, straightness: 0,
        netBearing: nil, downwindAlignment: nil, legs: []
    )
}

/// One continuous run of a session, between the times the rider was carried
/// back to the top.
public struct SessionLeg: Hashable, Sendable, Codable, Identifiable {

    public let id: Int

    public let startIndex: Int
    public let endIndex: Int
    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval

    public let startCoordinate: Geo.Coordinate
    public let endCoordinate: Geo.Coordinate

    /// Distance actually travelled along the track.
    public let distance: Double

    /// Straight-line distance between the ends.
    public let netDisplacement: Double

    public let averageSpeed: Double

    /// Bearing from this leg's start to its end.
    public let bearing: Double

    /// Degrees off dead downwind. `nil` without wind.
    public let alignment: Double?

    /// Whether this leg reads as a downwind run rather than as riding about.
    public let isDownwind: Bool

    /// Whether this leg went somewhere in a straight enough line for its
    /// bearing to describe a course rather than a drift.
    ///
    /// Optional in storage for the same reason as `SessionSummary.shape`.
    private let storedIsRun: Bool?

    public var isRun: Bool { storedIsRun ?? false }

    public var duration: TimeInterval { endElapsed - startElapsed }

    public var straightness: Double {
        distance > 0 ? min(1, netDisplacement / distance) : 0
    }

    public init(
        id: Int, startIndex: Int, endIndex: Int,
        startElapsed: TimeInterval, endElapsed: TimeInterval,
        startCoordinate: Geo.Coordinate, endCoordinate: Geo.Coordinate,
        distance: Double, netDisplacement: Double, averageSpeed: Double,
        bearing: Double, alignment: Double?, isDownwind: Bool, isRun: Bool
    ) {
        self.id = id
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.distance = distance
        self.netDisplacement = netDisplacement
        self.averageSpeed = averageSpeed
        self.bearing = bearing
        self.alignment = alignment
        self.isDownwind = isDownwind
        self.storedIsRun = isRun
    }
}

public enum SessionShapeAnalyzer {

    /// A leg has to cover this much ground end-to-end to be a run somewhere
    /// rather than a lap. Below it, a session is at a spot.
    public static let minimumLegDisplacement: Double = 1000

    /// How far off dead downwind a leg may point and still be a downwind run.
    /// Generous on purpose: riders pick a line that works with the swell, and
    /// on a big day that can sit thirty degrees off the gradient.
    public static let downwindTolerance: Double = 50

    /// Without wind, a leg has to be this straight before we will call it a
    /// downwinder on geometry alone.
    public static let straightnessWithoutWind: Double = 0.5

    /// Silence between runs that means the rider stopped riding, seconds.
    ///
    /// On its own this proves nothing. A real session is full of five-minute
    /// gaps — sitting on the board, a drink, a chat, a wing swap — and an
    /// early version split on silence alone and cut one afternoon at one spot
    /// into five "runs", each break being 140 to 290 seconds while the rider
    /// had moved less than 160 metres. Being stopped is not being carried.
    public static let transportGap: TimeInterval = 120

    /// How far the rider moved between one run ending and the next beginning.
    /// This is the signal that matters: a shuttle always *takes you somewhere*.
    public static let transportJump: Double = 800

    /// With a long silence to support it, a smaller move still counts — the
    /// rider stopped, and when they started again they were somewhere else.
    public static let transportJumpAfterGap: Double = 400

    /// How long the speed has to spend below the moving floor, in total,
    /// before the rider counts as stopped. Long enough to rule out one bad
    /// fix, and nothing more — see `stoppedFor` for why it is not longer.
    public static let stopDip: TimeInterval = 3

    public static func analyse(
        track: Track, runs: [Run], wind: Wind?, flights: [Flight] = [],
        stoppedBelow: Double = 0, minimumStop: TimeInterval = stopDip
    ) -> SessionShape {
        guard let first = track.points.first?.coordinate,
              let last = track.points.last?.coordinate else { return .empty }

        let netDisplacement = Geo.distance(first, last)
        let total = track.totalDistance
        let straightness = total > 0 ? min(1, netDisplacement / total) : 0

        // Under a hundred metres the bearing is noise, not a direction.
        let netBearing = netDisplacement > 100 ? Geo.bearing(from: first, to: last) : nil
        let alignment = netBearing.flatMap { bearing in
            wind.map { Solar.runAlignment(bearing: bearing, windFrom: $0.directionFrom) }
        }

        let legs = self.legs(track: track, runs: runs, wind: wind, flights: flights,
                             stoppedBelow: stoppedBelow, minimumStop: minimumStop)

        // Where the session as a whole finished decides this, not any one leg
        // inside it. A first version asked whether *any* leg looked downwind,
        // and a lap session at one spot answered yes — one long reach down the
        // river is a straight, wind-aligned kilometre, and the session got
        // reported as a downwinder despite finishing six metres from where it
        // launched. A rider who ends up back at their car did not do a
        // downwinder, whatever any single stretch of it looked like.
        let kind: SessionShape.Kind
        let downwindLegs = legs.filter(\.isDownwind)
        if netDisplacement < minimumLegDisplacement || straightness < 0.25 {
            // The exception, and the only one: a shuttle day really does end
            // near where it started, because the last drive brings you back.
            // It needs *several* legs, each separated by a genuine transport
            // jump, and each downwind in its own right.
            kind = downwindLegs.count >= 2 ? .downwinder : .aroundASpot
        } else if let alignment, alignment <= downwindTolerance {
            kind = .downwinder
        } else if alignment == nil && straightness >= straightnessWithoutWind {
            kind = .downwinder
        } else {
            kind = .crossing
        }

        return SessionShape(
            kind: kind,
            netDisplacement: netDisplacement,
            straightness: straightness,
            netBearing: netBearing,
            downwindAlignment: alignment,
            legs: legs
        )
    }

    /// Split the session where the rider was transported, and describe each
    /// piece.
    ///
    /// Deliberately not "detect the car". A drive shows up in the data two
    /// ways depending on whether the rider stopped recording, and both are
    /// visible from the runs alone: either a long silence between them, or a
    /// jump between where one ended and the next began that no transition on
    /// the water can produce. Trying to classify the drive itself would mean
    /// guessing at road speeds and getting it wrong for anyone who paddles
    /// back.
    static func legs(
        track: Track, runs: [Run], wind: Wind?, flights: [Flight] = [],
        stoppedBelow: Double = 0, minimumStop: TimeInterval = stopDip
    ) -> [SessionLeg] {
        guard !runs.isEmpty else { return [] }

        var groups: [[Run]] = [[runs[0]]]
        for run in runs.dropFirst() {
            let previous = groups[groups.count - 1][groups[groups.count - 1].count - 1]
            let silence = run.startElapsed - previous.endElapsed
            let jump = Geo.distance(previous.endCoordinate, run.startCoordinate)
            let carried = jump >= transportJump
                || (silence >= transportGap && jump >= transportJumpAfterGap)

            // A leg never splits inside a flight. The flights arrive already
            // joined across gaps too short to be a fall — that is the rider's
            // own twenty seconds, §4 — so a dip below the moving floor with
            // the ride carrying on either side of it is a moment inside one
            // ride, not one ride ending and another beginning. On a reported
            // shuttle day the stop test alone cut legs at eight-second dips
            // the flight join had deliberately absorbed.
            let insideOneRide = flights.contains {
                previous.endElapsed >= $0.startElapsed - 1
                    && run.startElapsed <= $0.endElapsed + 1
            }
            let stopped = !insideOneRide && stoppedFor(
                from: previous.endIndex, to: run.startIndex, in: track,
                below: stoppedBelow, atLeast: minimumStop
            )
            if carried || stopped {
                groups.append([run])
            } else {
                groups[groups.count - 1].append(run)
            }
        }

        // A leg is a ride. Splitting at stops leaves the groups between them
        // standing on their own, and those are the drift between two swims,
        // the paddle back out — real time and real distance, but the
        // *between* of the session, not rows in it. They stay in the
        // accounting as the off-foil gap separating the legs either side.
        // With no flight data every group stays: nothing is known about
        // touchdowns there, and silence is better than a guess.
        var kept = groups
        if !flights.isEmpty {
            kept = kept.filter { group in
                group.contains { run in
                    flights.contains {
                        run.endElapsed > $0.startElapsed && run.startElapsed < $0.endElapsed
                    }
                }
            }
        }

        return kept.enumerated().compactMap { index, group in
            leg(id: index, runs: group, track: track, wind: wind)
        }
    }

    /// Did the rider come to a stop between these two runs, long enough for
    /// the run to be over?
    ///
    /// This is the difference between falling and sinking, and it is not a
    /// question of *how long* — it is a question of how slow. Measured on a
    /// reported parawing downwinder: the rider dropped off the foil nine
    /// times, and in eight of them the slowest moment was three to six knots.
    /// They were still on the board, sinking off the foil in a lull and
    /// pumping back onto it. The ninth bottomed out at **0.2 knots**, which is
    /// a person in the water. The rider's own account of that session — a
    /// short ride, one fall, then a long run — matches the one gap, not the
    /// nine.
    ///
    /// So the bar is the sport's own moving speed, which already means "this
    /// rider is under way". The seconds below it are counted **in total, not
    /// in a row**. A swimmer in open water does not read as still: on a
    /// reported ocean downwinder — 28 knots and nine feet of swell — every
    /// one of eight swims bottomed out between 0.3 and 1.7 knots, but the
    /// bobbing spiked the GPS speed over the bar every few seconds, so a
    /// rule that wanted twenty *consecutive* quiet seconds found one swim in
    /// eight and reported a session of nine falls as two runs. The pumping
    /// rider it must not catch never touches the bar at all — 2.9 knots was
    /// the slowest in nine gaps — so the floor here only rules out a single
    /// bad fix, and nothing more.
    private static func stoppedFor(
        from start: Int, to end: Int, in track: Track,
        below speed: Double, atLeast seconds: TimeInterval
    ) -> Bool {
        guard speed > 0, end > start,
              start >= 0, end < track.count, track.count == track.elapsed.count
        else { return false }

        var below: TimeInterval = 0
        for i in (start + 1)...end where track.speed[i] < speed {
            below += track.elapsed[i] - track.elapsed[i - 1]
            if below >= seconds { return true }
        }
        return false
    }

    private static func leg(id: Int, runs: [Run], track: Track, wind: Wind?) -> SessionLeg? {
        guard let first = runs.first, let last = runs.last else { return nil }

        let startIndex = first.startIndex
        let endIndex = last.endIndex
        guard startIndex < track.count, endIndex < track.count else { return nil }

        // Along-track distance rather than the sum of the runs, so the slow
        // bits between runs — a fall, a water start — count toward the leg.
        let distance = max(0, track.cumulativeDistance[endIndex] - track.cumulativeDistance[startIndex])
        let startCoordinate = first.startCoordinate
        let endCoordinate = last.endCoordinate
        let netDisplacement = Geo.distance(startCoordinate, endCoordinate)
        let elapsed = track.elapsed[endIndex] - track.elapsed[startIndex]
        let bearing = Geo.bearing(from: startCoordinate, to: endCoordinate)
        let alignment = wind.map { Solar.runAlignment(bearing: bearing, windFrom: $0.directionFrom) }

        // A leg has to be a *run* before its direction means anything.
        //
        // This is where a reported bug lived. A leg of 6.88 km that displaced
        // only 1.65 km is an hour of laps, not a run — but the net drift of
        // those laps happened to point 1° off dead downwind, so it was labelled
        // a dead-downwind run and drawn as one. Bearing is only meaningful for
        // a line; over a zigzag it describes the drift, which is a different
        // thing entirely and not one anybody asked about.
        //
        // So straightness gates both branches, not just the one without wind.
        let straightness = distance > 0 ? min(1, netDisplacement / distance) : 0
        let isRun = netDisplacement >= minimumLegDisplacement
            && straightness >= straightnessWithoutWind
        let isDownwind: Bool
        if !isRun {
            isDownwind = false
        } else if let alignment {
            isDownwind = alignment <= downwindTolerance
        } else {
            // No wind to check against, and being this straight over this far
            // is the only evidence left.
            isDownwind = true
        }

        return SessionLeg(
            id: id,
            startIndex: startIndex,
            endIndex: endIndex,
            startElapsed: track.elapsed[startIndex],
            endElapsed: track.elapsed[endIndex],
            startCoordinate: startCoordinate,
            endCoordinate: endCoordinate,
            distance: distance,
            netDisplacement: netDisplacement,
            averageSpeed: elapsed > 0 ? distance / elapsed : 0,
            bearing: bearing,
            alignment: alignment,
            isDownwind: isDownwind,
            isRun: isRun
        )
    }
}
