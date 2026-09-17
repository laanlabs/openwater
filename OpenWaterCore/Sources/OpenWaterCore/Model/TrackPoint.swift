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

    /// Every vertical user-acceleration sample since the previous fix, m/s²,
    /// in order, at the motion provider's 10 Hz — about ten per point.
    ///
    /// Recorded so airtime can be *timed* rather than computed. The two
    /// summaries above collapse a second into a spread and a peak, and a
    /// jump's pop and slam land in the same second or the next one — which
    /// cannot time an event that lasts one to two seconds. Airtime is
    /// therefore derived from height under gravity, and a wing does not
    /// fall under gravity: it glides. A rider whose thirteen wing jumps read
    /// 0.8–1.3 s each said every one was longer than that, and they were
    /// right, because a metre of height under a wing is not a metre of
    /// free fall. The interval between the takeoff impulse and the landing
    /// impact, at a tenth of a second, is the measurement; this is the
    /// channel it will be read from once a session has been recorded with it.
    ///
    /// Hundredths of a metre per second squared, to keep the archive small.
    public var verticalAccelSamples: [Double]?

    /// Height above where the barometer was zeroed at the start of the
    /// session, metres. Nil on a recording made before the watch read it, and
    /// on any device without the sensor.
    ///
    /// This is the channel jumps are actually visible in. GPS altitude on a
    /// wrist is filtered to the point of uselessness for a hop — a measured
    /// wingfoil session whose rider counted about fifteen jumps of three to
    /// ten feet showed a *largest* excursion of 1.27 m, with vertical accuracy
    /// reported as 3 m, and most jumps compressed into a single sample that
    /// cannot be told from a receiver glitch. The barometer has none of those
    /// problems: it resolves to roughly a tenth of a metre, it samples on its
    /// own schedule rather than the receiver's, and it does not care whether
    /// the sky is visible.
    ///
    /// Relative, not absolute. `CMAltimeter` reports height against wherever
    /// it started, which is exactly what a jump needs and saves having to know
    /// the sea-level pressure. Weather moves it over hours; a jump is over in
    /// two seconds, so the drift never enters the measurement.
    public var baroAltitude: Double?

    /// The newer absolute-altitude API, recorded beside `baroAltitude` so the
    /// two can be compared on one recording. Metres above sea level. See
    /// `BarometerProvider.absoluteAltitude` for why both exist.
    public var absoluteAltitude: Double?

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
        verticalAccelSamples: [Double]? = nil,
        baroAltitude: Double? = nil,
        absoluteAltitude: Double? = nil,
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
        self.verticalAccelSamples = verticalAccelSamples
        self.baroAltitude = baroAltitude
        self.absoluteAltitude = absoluteAltitude
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
