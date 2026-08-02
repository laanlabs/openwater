import Foundation
import Testing
@testable import OpenWaterCore

/// Where the three colour anchors land for a given track.
///
/// The numbers below are measured. Two sessions we hold the GPX for were
/// rendered by Waterspeed and screenshotted; each track was projected back onto
/// its screenshot and the pixel under every fix read off. Fitting three stops to
/// those readings put them at zero, the session's **mean** speed, and its 97th
/// percentile — in both sessions, with the same three colours.
///
/// The mean anchor is the whole thing, and it is the part that would never be
/// guessed. Fitting to the median instead is half again as wrong across the two
/// sessions (joint RMS 7.7 against 4.9 out of 255), and fitting to the midpoint
/// of the range is worse still.
@Suite("Speed scale")
struct SpeedScaleTests {

    private let knot = SpeedScale.knot

    /// A track whose mean and 97th percentile are known by construction.
    private func speeds(mean: Double, top: Double, count: Int = 400) -> [Double] {
        // Symmetric around the mean so the mean is exactly `mean`, with the
        // spread set so the 97th percentile lands on `top`.
        let half = (top - mean) / 0.97
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)      // 0…1
            return mean + (t - 0.5) * 2 * half
        }
    }

    @Test("Red is a standstill, not the slowest sample")
    func bottomIsZero() {
        // A rider sitting on the board is red in every session — which is what
        // lets the colour mean something without reading the legend.
        let scale = SpeedScale(speeds: speeds(mean: 8 * knot, top: 14 * knot))
        #expect(scale.lower == 0)
        #expect(scale.position(of: 0) == 0)
    }

    @Test("Yellow sits at the session's mean speed")
    func middleIsTheMean() {
        for (mean, top) in [(8.98, 13.04), (15.40, 22.20), (4.0, 6.5)] {
            let scale = SpeedScale(speeds: speeds(mean: mean * knot, top: top * knot))
            let atMean = scale.position(of: mean * knot)
            #expect(abs(atMean - scale.midpoint) < 0.02,
                    "mean \(mean) kt landed at \(atMean), midpoint is \(scale.midpoint)")
        }
    }

    @Test("The two sessions this was fitted from reproduce their anchors")
    func matchesTheFittedSessions() {
        // Session 1: mean 15.40 kt, p97 22.2 kt. Session 2: mean 8.98, p97 13.04.
        for (mean, top) in [(15.40, 22.20), (8.98, 13.04)] {
            let scale = SpeedScale(speeds: speeds(mean: mean * knot, top: top * knot))
            #expect(abs(scale.upper - top * knot) < 0.3 * knot,
                    "top came out at \(scale.upper / knot) kt, expected \(top)")
            #expect(abs(scale.middleSpeed - mean * knot) < 0.3 * knot,
                    "mean came out at \(scale.middleSpeed / knot) kt, expected \(mean)")
        }
    }

    @Test("One spike does not decide the scale")
    func topIsAPercentileNotTheMaximum() {
        // The reason for the 97th percentile rather than the maximum: a single
        // bad fix at thirty knots would otherwise drain the colour out of an
        // entire session.
        var normal = speeds(mean: 9 * knot, top: 13 * knot)
        let clean = SpeedScale(speeds: normal)
        normal.append(30 * knot)
        let spiked = SpeedScale(speeds: normal)
        #expect(abs(spiked.upper - clean.upper) < 0.5 * knot,
                "one spike moved the top from \(clean.upper / knot) to \(spiked.upper / knot) kt")
    }

    @Test("Time spent stopped counts towards the mean")
    func stationarySamplesPullTheMeanDown() {
        // A ride with long pauses genuinely has a lower average, and its riding
        // should read as further above that average. Dropping the stopped
        // samples would hide exactly that.
        let riding = speeds(mean: 10 * knot, top: 14 * knot)
        let withPauses = riding + Array(repeating: 0, count: riding.count / 2)
        #expect(SpeedScale(speeds: withPauses).middleSpeed
                < SpeedScale(speeds: riding).middleSpeed)
    }

    @Test("A session ridden at one speed does not become a light show")
    func flatSessionIsGivenAnHonestSpan() {
        let scale = SpeedScale(speeds: Array(repeating: 9 * knot, count: 400))
        #expect(scale.upper - scale.lower >= 1)
        #expect(scale.position(of: 9 * knot).isFinite)
    }

    @Test("Both ends clamp")
    func clamps() {
        let scale = SpeedScale(speeds: speeds(mean: 9 * knot, top: 13 * knot))
        #expect(scale.position(of: -5) == 0)
        #expect(scale.position(of: 100) == 1)
    }

    @Test("Monotonic across the whole range")
    func monotonic() {
        let scale = SpeedScale(speeds: speeds(mean: 9 * knot, top: 13 * knot))
        var previous = -1.0
        for speed in stride(from: 0.0, through: 20.0, by: 0.05) {
            let position = scale.position(of: speed)
            #expect(position >= previous)
            previous = position
        }
    }

    @Test("Too few samples falls back rather than inventing a range")
    func tinyTrack() {
        let scale = SpeedScale(speeds: [4, 6, 8])
        #expect(scale == .fallback)
        #expect(scale.position(of: 5).isFinite)
    }

    @Test("An empty track cannot divide by zero")
    func empty() {
        let scale = SpeedScale(speeds: [])
        #expect(scale.upper > scale.lower)
        #expect(scale.position(of: 5).isFinite)
    }
}
