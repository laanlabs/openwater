import Foundation

/// The range of speeds a track's colours are spread across.
///
/// Three anchors, and each one is measured rather than chosen:
///
/// - **Red at a standstill.** Not at the session's slowest sample — at zero. A
///   rider sitting on the board is red in every session, which is what makes
///   the colour mean something on its own.
/// - **Yellow at the session's mean speed.** This is the anchor that makes the
///   whole thing work, and the one that is impossible to guess. It puts the
///   middle of the ramp at *your* average, so warm means below your day and
///   green means above it.
/// - **Green at the 97th percentile.** The top few samples are usually a GPS
///   spike or one freak gust, and anchoring to the maximum lets a single bad
///   fix drain the colour out of everything else.
///
/// All three were reverse-engineered from Waterspeed's rendering of two
/// sessions we hold the tracks for — see `SpeedScaleTests`. The mean anchor is
/// not a close call: fitting to the median instead is half again as wrong
/// (joint RMS 7.7 against 4.9 out of 255).
///
/// The cost of a per-session scale is real and worth stating: the same green is
/// a different speed in a light session and a windy one, so two sessions cannot
/// be compared by eye. It buys the thing that matters more — every session
/// using the whole ramp, so the fast parts of *this* ride are visible. A fixed
/// scale was tried first and made an ordinary session uniformly orange.
public struct SpeedScale: Hashable, Sendable {

    /// Speeds at or below this draw at the bottom of the ramp, m/s.
    public let lower: Double

    /// Speeds at or above this draw at the top of the ramp, m/s.
    public let upper: Double

    /// Where the middle stop sits between the two, 0–1.
    public let midpoint: Double

    public init(lower: Double, upper: Double, midpoint: Double = 0.5) {
        self.lower = lower
        // A degenerate range would divide by zero and paint everything one
        // colour, which is the thing this type exists to prevent.
        self.upper = max(upper, lower + 0.5)
        self.midpoint = max(0.05, min(0.95, midpoint))
    }

    public static let knot = 0.514444

    /// Something usable for a track with nothing in it to measure.
    public static let fallback = SpeedScale(
        lower: 0, upper: 20 * knot, midpoint: 0.55
    )

    /// Build the scale for a track from its own speeds.
    ///
    /// - Parameter speeds: every sample, m/s, in any order. Stationary samples
    ///   are *kept*: they are part of the session and they pull the mean down,
    ///   which is correct — a ride with long pauses genuinely has a lower
    ///   average, and its riding should read as further above that average.
    public init(speeds: [Double]) {
        let usable = speeds.filter { $0.isFinite && $0 >= 0 }
        guard usable.count >= 20 else {
            self = .fallback
            return
        }

        let sorted = usable.sorted()
        let mean = usable.reduce(0, +) / Double(usable.count)
        // The 97th percentile rather than the maximum. Between about the 95th
        // and the 98th the fit is indistinguishable; what matters is not using
        // the last sample, because one spike should not decide the scale.
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.97).rounded()))
        let top = sorted[index]

        // A session with no spread — a tow, a drift — would otherwise stretch
        // the full ramp over GPS noise.
        let upper = max(top, mean + 1.0, 1.0)
        self.init(lower: 0, upper: upper, midpoint: mean / upper)
    }

    /// Where a speed sits on the ramp, 0–1, clamped at both ends.
    public func position(of speed: Double) -> Double {
        max(0, min(1, (speed - lower) / (upper - lower)))
    }

    /// The speed at the middle stop, m/s — the session's mean.
    public var middleSpeed: Double {
        lower + (upper - lower) * midpoint
    }
}
