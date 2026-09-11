import Foundation
import OpenWaterCore

/// Stepping from one camera to the next one along the coast.
///
/// Cameras are reached today by going back to a list and picking another,
/// which is the wrong shape for the thing riders actually do with them: look
/// east along the beach, then a bit further east, then further still, to see
/// where the line is breaking. On the South Fork that is East Hampton, then
/// Atlantic Beach, then Hither Hills, then Montauk Point — four cameras on one
/// stretch of water, and today four trips back through a grid.
///
/// So a direction is a move. "East" means *the nearest camera in the eastern
/// quarter of the compass*, measured from where you are standing now rather
/// than from where the chain began — which is what makes it a chain: each hop
/// re-measures, so pressing east four times walks the coast instead of running
/// out at the edge of one search radius.
public enum CamCompass {

    public enum Direction: String, CaseIterable, Sendable, Identifiable {
        case north, east, south, west

        public var id: String { rawValue }

        /// True bearing at the middle of this direction's wedge.
        public var centre: Double {
            switch self {
            case .north: 0
            case .east: 90
            case .south: 180
            case .west: 270
            }
        }

        public var letter: String {
            switch self {
            case .north: "N"
            case .east: "E"
            case .south: "S"
            case .west: "W"
            }
        }

        public var symbol: String {
            switch self {
            case .north: "arrow.up"
            case .east: "arrow.right"
            case .south: "arrow.down"
            case .west: "arrow.left"
            }
        }
    }

    /// Half the width of a direction's wedge, in degrees.
    ///
    /// Forty-five, so the four wedges tile the compass exactly: every camera
    /// that is not on top of you lies in exactly one direction, and no camera
    /// is unreachable because it fell between two of them. A narrower wedge
    /// would read as "more precisely east" and behave as "east is often
    /// empty", which on a coast that runs ENE — most of Long Island's south
    /// shore — would be most of the cameras a rider wants.
    public static let halfWidth: Double = 45

    /// Cameras sitting effectively on top of the origin are not a direction.
    ///
    /// A beach with three cameras on one pole has three rows in the guide at
    /// the same coordinate, and a bearing between two points a few metres
    /// apart is noise — it would send "east" to the camera beside the one you
    /// are watching, then "west" straight back to it. Those angles belong to
    /// the existing arrows, which step within a place; this steps between
    /// places.
    public static let minimumSeparation: Double = 250

    /// The nearest camera in one direction, or nil if that way is empty.
    public static func next(
        from origin: Geo.Coordinate,
        towards direction: Direction,
        among cameras: [SpotGuideStore.GuideResource],
        excluding excludedIDs: Set<String> = []
    ) -> SpotGuideStore.GuideResource? {
        cameras
            .filter { $0.kind == .camera && !excludedIDs.contains($0.id) }
            .compactMap { camera -> (SpotGuideStore.GuideResource, Double)? in
                let metres = Geo.distance(origin, camera.coordinate)
                guard metres >= minimumSeparation else { return nil }
                let bearing = Geo.bearing(from: origin, to: camera.coordinate)
                guard abs(difference(bearing, direction.centre)) <= halfWidth else { return nil }
                // Measured here rather than trusted from the resource, whose
                // own `metres` and `bearing` were filled in relative to
                // whatever spot the query was made from — not to the camera
                // the rider is presently watching.
                var measured = camera
                measured.metres = metres
                measured.bearing = bearing
                return (measured, metres)
            }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// All four at once, for a control that names where each direction goes.
    ///
    /// A compass whose arrows are live or dead, and which says "Hither Hills,
    /// 7 mi" before it is pressed, is a different control from four blind
    /// arrows — on a television especially, where a press that turns out to
    /// lead nowhere costs a rider their place.
    public static func neighbours(
        from origin: Geo.Coordinate,
        among cameras: [SpotGuideStore.GuideResource],
        excluding excludedIDs: Set<String> = []
    ) -> [Direction: SpotGuideStore.GuideResource] {
        var found: [Direction: SpotGuideStore.GuideResource] = [:]
        for direction in Direction.allCases {
            found[direction] = next(from: origin, towards: direction,
                                    among: cameras, excluding: excludedIDs)
        }
        return found
    }

    /// Signed degrees from `b` to `a`, in −180…180.
    static func difference(_ a: Double, _ b: Double) -> Double {
        let raw = (a - b).truncatingRemainder(dividingBy: 360)
        if raw > 180 { return raw - 360 }
        if raw < -180 { return raw + 360 }
        return raw
    }
}
