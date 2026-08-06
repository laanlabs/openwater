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

    public var duration: TimeInterval { endElapsed - startElapsed }

    public var straightness: Double {
        distance > 0 ? min(1, netDisplacement / distance) : 0
    }

    public init(
        id: Int, startIndex: Int, endIndex: Int,
        startElapsed: TimeInterval, endElapsed: TimeInterval,
        startCoordinate: Geo.Coordinate, endCoordinate: Geo.Coordinate,
        distance: Double, netDisplacement: Double, averageSpeed: Double,
        bearing: Double, alignment: Double?, isDownwind: Bool
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

    /// Silence between runs that means the rider stopped riding, seconds. A
    /// water start after a fall is thirty seconds; a shuttle is minutes.
    public static let transportGap: TimeInterval = 120

    /// A jump between where one run ended and the next began that no
    /// transition on the water produces — you were carried.
    public static let transportJump: Double = 800

    public static func analyse(track: Track, runs: [Run], wind: Wind?) -> SessionShape {
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

        let legs = self.legs(track: track, runs: runs, wind: wind)

        let kind: SessionShape.Kind
        if legs.contains(where: \.isDownwind) {
            kind = .downwinder
        } else if netDisplacement >= minimumLegDisplacement && straightness >= 0.4 {
            kind = .crossing
        } else {
            kind = .aroundASpot
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
    static func legs(track: Track, runs: [Run], wind: Wind?) -> [SessionLeg] {
        guard !runs.isEmpty else { return [] }

        var groups: [[Run]] = [[runs[0]]]
        for run in runs.dropFirst() {
            let previous = groups[groups.count - 1][groups[groups.count - 1].count - 1]
            let silence = run.startElapsed - previous.endElapsed
            let jump = Geo.distance(previous.endCoordinate, run.startCoordinate)
            if silence >= transportGap || jump >= transportJump {
                groups.append([run])
            } else {
                groups[groups.count - 1].append(run)
            }
        }

        return groups.enumerated().compactMap { index, group in
            leg(id: index, runs: group, track: track, wind: wind)
        }
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

        let straightness = distance > 0 ? min(1, netDisplacement / distance) : 0
        let isDownwind: Bool
        if netDisplacement < minimumLegDisplacement {
            isDownwind = false
        } else if let alignment {
            isDownwind = alignment <= downwindTolerance
        } else {
            // No wind to check against, so geometry has to carry it: a line
            // this straight over this distance was not laps.
            isDownwind = straightness >= straightnessWithoutWind
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
            isDownwind: isDownwind
        )
    }
}
