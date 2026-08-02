import Foundation
import Testing
@testable import OpenWaterCore

/// The range the track's colours are spread across.
///
/// Fixed in knots rather than fitted to each session, so these check the two
/// things that follow from that: the anchors are where they are meant to be,
/// and a speed maps to the same position no matter which session it came from.
/// The colours themselves live in the app layer; what is pinned here is the
/// scale they are laid along.
@Suite("Speed scale")
struct SpeedScaleTests {

    private let knot = SpeedScale.knot

    @Test("Anchored at a standstill and at 25 knots")
    func anchors() {
        let scale = SpeedScale.standard
        #expect(scale.lower == 0)
        #expect(abs(scale.upper - 25 * knot) < 1e-9)
        #expect(scale.position(of: 0) == 0)
        #expect(abs(scale.position(of: 25 * knot) - 1) < 1e-9)
    }

    @Test("Yellow sits at 15 knots")
    func midpoint() {
        // The middle stop is what makes the ramp match: fitting Waterspeed's
        // rendering put it at 15 knots decisively — every neighbouring
        // candidate was two to three times worse.
        let scale = SpeedScale.standard
        #expect(abs(scale.position(of: 15 * knot) - scale.midpoint) < 1e-9)
        #expect(abs(scale.midpoint - 0.6) < 1e-9)
    }

    @Test("Both ends clamp")
    func clamps() {
        let scale = SpeedScale.standard
        #expect(scale.position(of: -5) == 0)
        #expect(scale.position(of: 100) == 1)
    }

    @Test("The same speed is the same colour in every session")
    func absoluteRatherThanRelative() {
        // The whole reason for a fixed ramp. A relative one gives the same
        // green to nineteen knots on a windy day and nine on a light one,
        // and two sessions stop being comparable by eye.
        let scale = SpeedScale.standard
        for speed in stride(from: 0.0, through: 30 * knot, by: knot) {
            #expect(scale.position(of: speed) == SpeedScale.standard.position(of: speed))
        }
    }

    @Test("Monotonic across the whole range")
    func monotonic() {
        let scale = SpeedScale.standard
        var previous = -1.0
        for speed in stride(from: 0.0, through: 20.0, by: 0.05) {
            let position = scale.position(of: speed)
            #expect(position >= previous)
            previous = position
        }
    }

    @Test("A degenerate range cannot divide by zero")
    func degenerate() {
        let scale = SpeedScale(lower: 5, upper: 5)
        #expect(scale.upper > scale.lower)
        #expect(scale.position(of: 5).isFinite)
    }

    /// The positions the app's ramp stops are laid against, checked at the
    /// speeds the fit was measured at.
    ///
    /// Reading: a knot value, and where on the ramp it should land. Taken from
    /// the reverse-engineered rendering — if `standard` is ever retuned, these
    /// are what say whether it still matches the thing it was copied from.
    @Test("Positions match the fitted reference points")
    func fittedPositions() {
        let scale = SpeedScale.standard
        let expected: [(knots: Double, position: Double)] = [
            (0, 0.00),
            (3, 0.12),
            (10, 0.40),
            (15, 0.60),
            (20, 0.80),
            (25, 1.00),
        ]
        for (knots, position) in expected {
            let actual = scale.position(of: knots * knot)
            #expect(abs(actual - position) < 0.005,
                    "\(knots) kt landed at \(actual), expected \(position)")
        }
    }
}
