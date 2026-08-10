import Foundation

/// Geodesy helpers. Everything here is pure and platform-free so the analysis
/// layer never has to import CoreLocation.
public enum Geo {

    /// WGS-84 mean earth radius, metres.
    public static let earthRadius: Double = 6_371_008.8

    /// A latitude/longitude pair in degrees.
    public struct Coordinate: Hashable, Sendable, Codable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    // MARK: - Distance

    /// Great-circle distance in metres (haversine).
    ///
    /// Accurate enough for our purposes: over the ~500 m runs we care about the
    /// spherical/ellipsoidal difference is well under a centimetre.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180

        let sinHalfLat = sin(dLat / 2)
        let sinHalfLon = sin(dLon / 2)
        let h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLon * sinHalfLon
        return 2 * earthRadius * asin(min(1, sqrt(max(0, h))))
    }

    // MARK: - Bearing

    /// Initial great-circle bearing from `a` to `b`, degrees clockwise from true north, `0..<360`.
    public static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalizeDegrees(atan2(y, x) * 180 / .pi)
    }

    /// Point reached by travelling `distance` metres from `origin` on `bearing` degrees.
    public static func destination(from origin: Coordinate, bearing: Double, distance: Double) -> Coordinate {
        let angular = distance / earthRadius
        let brg = bearing * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180

        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(brg))
        let lon2 = lon1 + atan2(
            sin(brg) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )
        return Coordinate(
            latitude: lat2 * 180 / .pi,
            longitude: normalizeLongitude(lon2 * 180 / .pi)
        )
    }

    // MARK: - Angles

    /// Wrap to `0..<360`.
    public static func normalizeDegrees(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Wrap to `-180..<180`.
    public static func normalizeLongitude(_ degrees: Double) -> Double {
        let r = (degrees + 180).truncatingRemainder(dividingBy: 360)
        return (r < 0 ? r + 360 : r) - 180
    }

    /// Smallest signed difference `to - from`, in `-180...180`.
    ///
    /// Positive means `to` is clockwise of `from`.
    public static func angleDelta(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Absolute separation between two bearings, `0...180`.
    public static func angleSeparation(_ a: Double, _ b: Double) -> Double {
        abs(angleDelta(from: a, to: b))
    }

    /// Circular mean of a set of bearings in degrees. `nil` for an empty input.
    ///
    /// Optionally weighted — we weight headings by distance sailed so a long
    /// reach counts for more than a brief wobble.
    public static func circularMean(_ degrees: [Double], weights: [Double]? = nil) -> Double? {
        guard !degrees.isEmpty else { return nil }
        var x = 0.0, y = 0.0
        for (i, d) in degrees.enumerated() {
            let w = weights.map { i < $0.count ? $0[i] : 0 } ?? 1
            let r = d * .pi / 180
            x += w * cos(r)
            y += w * sin(r)
        }
        guard x != 0 || y != 0 else { return nil }
        return normalizeDegrees(atan2(y, x) * 180 / .pi)
    }

    /// Bisector of two bearings, taking the short way around.
    ///
    /// For 350° and 10° this gives 0°, not 180°.
    public static func bisector(_ a: Double, _ b: Double) -> Double {
        normalizeDegrees(a + angleDelta(from: a, to: b) / 2)
    }
}

/// Binary search over a sorted array of times.
///
/// Track timestamps are sorted by construction, and several screens need
/// "the samples between these two moments". Scanning for that is fine once
/// and ruinous per run: a view drawing a hundred runs turns a linear scan
/// into a quadratic one, on every render.
public extension Array where Element == TimeInterval {

    /// The first index whose value is at or after `value`, or nil if none is.
    func firstIndex(atOrAfter value: TimeInterval) -> Int? {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low < count ? low : nil
    }

    /// The last index whose value is at or before `value`, or nil if none is.
    func lastIndex(atOrBefore value: TimeInterval) -> Int? {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}
