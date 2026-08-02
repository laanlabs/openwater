import OpenWaterCore
import UIKit
import XCTest
@testable import openWater

/// The track's colour ramp, checked against the thing it was copied from.
///
/// The reference colours below are measured, not chosen. Two sessions we hold
/// the GPX for were rendered by Waterspeed and screenshotted; each track was
/// projected back onto its own screenshot and the pixel under every fix read
/// off. The medians of those readings, per knot, are what this file pins.
///
/// It is here because the ramp is easy to "improve" and impossible to eyeball.
/// If someone later swaps the interpolation to hue, or nudges a stop, the track
/// will still look plausible and will no longer match — and nobody would notice
/// until a rider put the two apps side by side again.
final class SpeedRampTests: XCTestCase {

    /// Two sessions, each with the scale its own track produces and the
    /// colours Waterspeed drew it in.
    ///
    /// The pair is the point: one session averaging 15.4 knots and one
    /// averaging 9.0 get the same colours at *different* speeds, which is what
    /// says the ramp is per session rather than fixed. A single session cannot
    /// tell those apart, and the first attempt at this — fitted to session one
    /// alone — came out fixed and rendered session two uniformly orange.
    private struct Reference {
        let name: String
        let mean: Double        // knots
        let top: Double         // knots, the 97th percentile
        let colours: [(knots: Double, rgb: (Int, Int, Int))]
    }

    private let references = [
        Reference(name: "wingfoil, mean 15.4 kt", mean: 15.40, top: 22.20, colours: [
            (3,  (232,  79,  52)),
            (9,  (238, 151,  61)),
            (11, (240, 167,  61)),
            (13, (240, 188,  66)),
            (15, (244, 203,  69)),
            (17, (214, 202,  68)),
            (19, (174, 191,  66)),
            (21, (138, 177,  65)),
        ]),
        Reference(name: "downwind, mean 9.0 kt", mean: 8.98, top: 13.04, colours: [
            (1,  (234,  71,  53)),
            (3,  (232, 105,  53)),
            (8,  (236, 198,  68)),
            (9,  (229, 207,  70)),
            (10, (209, 202,  68)),
            (11, (178, 192,  66)),
            (12, (156, 184,  66)),
            (13, (127, 174,  68)),
        ]),
    ]

    private func channels(_ colour: UIColor) -> (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    func testMatchesTheReferenceRenders() {
        // Twelve units of 255 is under five percent, and inside what the
        // measurement itself resolves — each reference colour is a median over
        // antialiased screenshot pixels, some of them where one leg of the
        // track crosses another. It is not a specification.
        let tolerance = 12

        for reference in references {
            let scale = SpeedScale(
                lower: 0,
                upper: reference.top * SpeedScale.knot,
                midpoint: reference.mean / reference.top
            )
            for (knots, expected) in reference.colours {
                let actual = channels(speedRampColour(knots * SpeedScale.knot, scale: scale))
                let delta = max(abs(actual.0 - expected.0),
                                abs(actual.1 - expected.1),
                                abs(actual.2 - expected.2))
                XCTAssertLessThanOrEqual(
                    delta, tolerance,
                    "\(reference.name) at \(Int(knots)) kt: got \(actual), reference \(expected)"
                )
            }
        }
    }

    /// Yellow lands on the mean, wherever the mean happens to be.
    ///
    /// The failure this catches is subtle and would look fine: interpolate the
    /// three stops evenly instead of bending at the midpoint and every session
    /// still gets a red-to-green ramp — just with its yellow in the wrong
    /// place, which is exactly how the fixed version looked wrong.
    func testYellowLandsOnTheMean() {
        for reference in references {
            let scale = SpeedScale(
                lower: 0,
                upper: reference.top * SpeedScale.knot,
                midpoint: reference.mean / reference.top
            )
            let atMean = channels(speedRampColour(reference.mean * SpeedScale.knot, scale: scale))
            XCTAssertEqual(atMean.0, 238, accuracy: 3, reference.name)
            XCTAssertEqual(atMean.1, 211, accuracy: 3, reference.name)
            XCTAssertEqual(atMean.2, 69, accuracy: 3, reference.name)
        }
    }

    /// Red at a standstill through yellow to green, not the other way round.
    ///
    /// The direction is the part most likely to be "fixed" by someone who
    /// assumes red means fast. On the water the question is where you were
    /// going *well*, so green is the good end and the gybes come out red.
    func testRunsRedToGreen() {
        let scale = SpeedScale(lower: 0, upper: 13 * SpeedScale.knot, midpoint: 0.69)
        let slow = channels(speedRampColour(0, scale: scale))
        let fast = channels(speedRampColour(20 * SpeedScale.knot, scale: scale))
        XCTAssertGreaterThan(slow.0, slow.1, "the bottom of the ramp should be red")
        XCTAssertGreaterThan(fast.1, fast.0, "the top of the ramp should be green")
    }

    func testClampsAtBothEnds() {
        let scale = SpeedScale(lower: 0, upper: 13 * SpeedScale.knot, midpoint: 0.69)
        XCTAssertEqual(channels(speedRampColour(-5, scale: scale)).0,
                       channels(speedRampColour(0, scale: scale)).0)
        XCTAssertEqual(channels(speedRampColour(40 * SpeedScale.knot, scale: scale)).1,
                       channels(speedRampColour(13 * SpeedScale.knot, scale: scale)).1)
    }

    /// Interpolated in RGB, not through hue.
    ///
    /// A hue sweep between the same endpoints passes through colours neither
    /// stop contains — red to yellow goes via a vivid orange — and stops
    /// matching. Halfway between red and yellow, every channel should be the
    /// average of the two.
    func testInterpolatesInRGB() {
        let scale = SpeedScale(lower: 0, upper: 25 * SpeedScale.knot, midpoint: 0.6)
        let a = channels(speedRampColour(0, scale: scale))
        let b = channels(speedRampColour(15 * SpeedScale.knot, scale: scale))
        let middle = channels(speedRampColour(7.5 * SpeedScale.knot, scale: scale))
        XCTAssertEqual(middle.0, (a.0 + b.0) / 2, accuracy: 1)
        XCTAssertEqual(middle.1, (a.1 + b.1) / 2, accuracy: 1)
        XCTAssertEqual(middle.2, (a.2 + b.2) / 2, accuracy: 1)
    }
}
