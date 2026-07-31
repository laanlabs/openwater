import Foundation

/// A single GNSS fix plus whatever sensors were sampled alongside it.
///
/// This is the raw unit of recording. It is deliberately generous with optionals
/// because imported files from other vendors carry wildly different channels,
/// and the analysis layer has to cope with all of them.
public struct TrackPoint: Hashable, Sendable, Codable {

    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double

    /// Metres above the WGS-84 ellipsoid. Rarely useful on the water, but it is
    /// the strongest jump signal we have.
    public var altitude: Double?

    /// Doppler-derived speed in m/s as reported by the receiver.
    ///
    /// This is the good number: it comes from the carrier frequency shift, not
    /// from differencing two noisy positions. `nil` when the receiver did not
    /// supply it (most imported GPX files).
    public var speed: Double?

    /// Course over ground, degrees clockwise from true north.
    public var course: Double?

    /// Radius of 68 % confidence in metres. Negative means the fix is invalid.
    public var horizontalAccuracy: Double

    /// Vertical accuracy in metres. Negative means unavailable.
    public var verticalAccuracy: Double?

    /// Accuracy of `speed` in m/s. Negative means unavailable.
    ///
    /// Records are gated on this: a 40-knot spike with a 12 m/s speed accuracy
    /// is noise, not a personal best.
    public var speedAccuracy: Double?

    /// Standard deviation of user vertical acceleration over the sample window,
    /// m/s². Low means the ride is smooth — i.e. flying.
    public var verticalAccelSD: Double?

    /// Peak vertical acceleration in the window, m/s². Used for jump detection.
    public var verticalAccelPeak: Double?

    public var heartRate: Double?

    /// Pumps or strokes per minute, if estimated live.
    public var cadence: Double?

    public init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        speed: Double? = nil,
        course: Double? = nil,
        horizontalAccuracy: Double = -1,
        verticalAccuracy: Double? = nil,
        speedAccuracy: Double? = nil,
        verticalAccelSD: Double? = nil,
        verticalAccelPeak: Double? = nil,
        heartRate: Double? = nil,
        cadence: Double? = nil
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speedAccuracy = speedAccuracy
        self.verticalAccelSD = verticalAccelSD
        self.verticalAccelPeak = verticalAccelPeak
        self.heartRate = heartRate
        self.cadence = cadence
    }

    public var coordinate: Geo.Coordinate {
        Geo.Coordinate(latitude: latitude, longitude: longitude)
    }

    /// Whether the receiver considered the position usable at all.
    public var hasValidPosition: Bool {
        horizontalAccuracy >= 0
            && latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
            && !(latitude == 0 && longitude == 0)
    }

    /// Whether `speed` is a trustworthy Doppler measurement.
    public var hasValidSpeed: Bool {
        guard let speed, speed >= 0, speed.isFinite else { return false }
        if let sa = speedAccuracy, sa < 0 { return false }
        return true
    }
}
