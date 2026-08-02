import Foundation

/// The range of speeds a track is coloured across, and where the ramp's stops
/// sit inside it.
///
/// Fixed in knots rather than derived from each session. That is a deliberate
/// choice and it has a real cost, so it is worth writing down: a light-wind
/// session that never passes eight knots comes out entirely red and orange, and
/// a kite session spent above twenty-five is entirely green. A ramp scaled to
/// each session's own spread would give both of those full contrast.
///
/// It is fixed anyway because a colour that means the same thing in every
/// session is worth more than contrast within one. With an absolute ramp,
/// yellow is fifteen knots in January and fifteen knots in July, two sessions
/// can be compared by eye, and a rider learns what the colours mean once. With
/// a relative ramp the same green is nineteen knots on a windy day and nine on
/// a light one, and the map stops being a measurement.
///
/// The numbers here are not invented. They are fitted from Waterspeed's
/// rendering of a known track — see `SpeedScaleTests` — because matching a tool
/// riders already read fluently beats being subtly different for no reason.
public struct SpeedScale: Hashable, Sendable {

    /// Speeds at or below this draw at the bottom of the ramp, m/s.
    public let lower: Double

    /// Speeds at or above this draw at the top of the ramp, m/s.
    public let upper: Double

    /// Where the middle stop sits between the two, 0–1.
    public let midpoint: Double

    public init(lower: Double, upper: Double, midpoint: Double = 0.6) {
        self.lower = lower
        // A degenerate range would divide by zero and paint everything one
        // colour, which is the thing this type exists to prevent.
        self.upper = max(upper, lower + 0.5)
        self.midpoint = max(0.01, min(0.99, midpoint))
    }

    public static let knot = 0.514444

    /// The ramp every session is drawn with.
    ///
    /// Red at a standstill, yellow at 15 knots, green at 25 and above. Fitted
    /// to within a few units of 255 across the whole range of a real recording;
    /// the stops land on round numbers, which is presumably how they were
    /// chosen in the first place.
    public static let standard = SpeedScale(
        lower: 0,
        upper: 25 * knot,
        // 15 kt of a 25 kt range.
        midpoint: 15.0 / 25.0
    )

    /// Where a speed sits on the ramp, 0–1, clamped at both ends.
    public func position(of speed: Double) -> Double {
        max(0, min(1, (speed - lower) / (upper - lower)))
    }
}
