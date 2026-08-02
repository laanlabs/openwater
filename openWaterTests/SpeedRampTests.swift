import OpenWaterCore
import UIKit
import XCTest
@testable import openWater

/// The track's colour ramp, checked against the thing it was copied from.
///
/// The reference colours below are measured, not chosen. A session recorded in
/// openWater was exported as GPX, imported into Waterspeed, and screenshotted;
/// each of that track's samples was then projected back onto the screenshot and
/// the pixel under it read. The medians of those readings, per knot, are what
/// this file pins.
///
/// It is here because the ramp is easy to "improve" and impossible to eyeball.
/// If someone later swaps the interpolation to hue, or nudges a stop, the track
/// will still look plausible and will no longer match — and nobody would notice
/// until a rider put the two apps side by side again.
final class SpeedRampTests: XCTestCase {

    /// Waterspeed's colour at each whole knot, read off the reference render.
    private let reference: [(knots: Double, rgb: (Int, Int, Int))] = [
        (3,  (232,  79,  52)),
        (9,  (239, 151,  61)),
        (10, (237, 155,  60)),
        (11, (238, 173,  62)),
        (12, (237, 174,  63)),
        (13, (240, 188,  66)),
        (14, (241, 196,  68)),
        (15, (243, 205,  70)),
        (16, (234, 210,  70)),
        (17, (214, 203,  68)),
        (18, (195, 197,  67)),
        (19, (175, 191,  66)),
        (20, (157, 185,  66)),
        (21, (134, 176,  69)),
    ]

    private func channels(_ colour: UIColor) -> (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    func testMatchesTheReferenceRender() {
        // Eight units of 255 is under three percent, and well inside what the
        // measurement itself can resolve — the reference is a median over
        // antialiased pixels from a screenshot, not a specification.
        let tolerance = 8

        for (knots, expected) in reference {
            let speed = knots * SpeedScale.knot
            let actual = channels(speedRampColour(speed, scale: .standard))
            let delta = max(abs(actual.0 - expected.0),
                            abs(actual.1 - expected.1),
                            abs(actual.2 - expected.2))
            XCTAssertLessThanOrEqual(
                delta, tolerance,
                "at \(Int(knots)) kt: got \(actual), reference \(expected)"
            )
        }
    }

    /// Red at a standstill through yellow to green, not the other way round.
    ///
    /// The direction is the part most likely to be "fixed" by someone who
    /// assumes red means fast. On the water the question is where you were
    /// going *well*, so green is the good end and the gybes come out red.
    func testRunsRedToGreen() {
        let slow = channels(speedRampColour(0, scale: .standard))
        let fast = channels(speedRampColour(25 * SpeedScale.knot, scale: .standard))
        XCTAssertGreaterThan(slow.0, slow.1, "the bottom of the ramp should be red")
        XCTAssertGreaterThan(fast.1, fast.0, "the top of the ramp should be green")
    }

    func testClampsAtBothEnds() {
        XCTAssertEqual(channels(speedRampColour(-5, scale: .standard)).0,
                       channels(speedRampColour(0, scale: .standard)).0)
        XCTAssertEqual(channels(speedRampColour(40 * SpeedScale.knot, scale: .standard)).1,
                       channels(speedRampColour(25 * SpeedScale.knot, scale: .standard)).1)
    }

    /// Interpolated in RGB, not through hue.
    ///
    /// A hue sweep between the same endpoints passes through colours neither
    /// stop contains — red to yellow goes via a vivid orange — and stops
    /// matching. Halfway between red and yellow, every channel should be the
    /// average of the two.
    func testInterpolatesInRGB() {
        let a = channels(speedRampColour(0, scale: .standard))
        let b = channels(speedRampColour(15 * SpeedScale.knot, scale: .standard))
        let middle = channels(speedRampColour(7.5 * SpeedScale.knot, scale: .standard))
        XCTAssertEqual(middle.0, (a.0 + b.0) / 2, accuracy: 1)
        XCTAssertEqual(middle.1, (a.1 + b.1) / 2, accuracy: 1)
        XCTAssertEqual(middle.2, (a.2 + b.2) / 2, accuracy: 1)
    }
}
