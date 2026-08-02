import Foundation

/// The range of speeds a track is coloured across.
///
/// Anchoring the ramp to `0.35 × maxSpeed … maxSpeed` looked reasonable and
/// produced flat, one-colour tracks. The reason is that `maxSpeed` is a single
/// instant — often a spike two or three knots above anything held for longer
/// than a second. A session where the riding sits between 14 and 19 knots but
/// touched 26 once has every one of those samples land between 0.3 and 0.6 of
/// the ramp: all green, no contrast, and the map says nothing about which runs
/// were the good ones.
///
/// So the ends come from the distribution instead. The tenth and ninetieth
/// percentiles of the samples actually drawn put the full sweep of colour
/// across the speeds a rider spent the session at, which is the comparison they
/// are making when they look. The fastest tenth clips to red and the slowest
/// tenth to blue — deliberately. Clipping the tails is what buys resolution in
/// the middle, where all the riding is.
public struct SpeedScale: Hashable, Sendable {

    /// Speeds at or below this draw at the bottom of the ramp, m/s.
    public let lower: Double

    /// Speeds at or above this draw at the top of the ramp, m/s.
    public let upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        // A degenerate range would divide by zero and paint everything one
        // colour, which is the bug this type exists to fix.
        self.upper = max(upper, lower + 0.5)
    }

    /// Build a scale from the samples that will be drawn.
    ///
    /// - Parameters:
    ///   - speeds: every sample's speed in m/s, in any order.
    ///   - movingAbove: samples at or below this are excluded. Time spent
    ///     drifting is drawn muted rather than coloured, and letting it into
    ///     the calculation drags the bottom of the ramp down to nothing —
    ///     which is how the old scale ended up compressing all the riding into
    ///     its upper half.
    public init(speeds: [Double], movingAbove: Double = 0) {
        let riding = speeds.filter { $0 > movingAbove && $0.isFinite }.sorted()

        // Too few samples to talk about a distribution. Fall back to the whole
        // range, which at least cannot be worse than one colour.
        guard riding.count >= 20 else {
            let top = max(speeds.max() ?? 1, 1)
            self.init(lower: top * 0.35, upper: top)
            return
        }

        func percentile(_ p: Double) -> Double {
            let index = Int((Double(riding.count - 1) * p).rounded())
            return riding[min(max(0, index), riding.count - 1)]
        }

        let low = percentile(0.10)
        let high = percentile(0.90)

        // A session ridden at one speed — a tow, a long reach — has almost no
        // spread, and stretching a full rainbow across half a knot would turn
        // GPS noise into a light show. Widen to something honest instead.
        let span = high - low
        let minimumSpan = max(1.0, high * 0.15)
        guard span >= minimumSpan else {
            let middle = (high + low) / 2
            self.init(lower: middle - minimumSpan / 2, upper: middle + minimumSpan / 2)
            return
        }

        self.init(lower: low, upper: high)
    }

    /// Where a speed sits on the ramp, 0–1, clamped at both ends.
    public func position(of speed: Double) -> Double {
        max(0, min(1, (speed - lower) / (upper - lower)))
    }
}
