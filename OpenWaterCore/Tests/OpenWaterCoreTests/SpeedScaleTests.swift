import Foundation
import Testing
@testable import OpenWaterCore

/// The range the track's colours are spread across.
///
/// Every one of these is a shape of session that made the old ramp — anchored
/// to `0.35 × maxSpeed … maxSpeed` — come out as one flat colour. A single
/// spike well above the riding speed was enough to do it, and that is the
/// normal case rather than an unlucky one.
@Suite("Speed scale")
struct SpeedScaleTests {

    /// Riding held between `low` and `high`, plus one brief spike.
    private func session(low: Double, high: Double, spike: Double) -> [Double] {
        var speeds = (0..<600).map { i in
            low + (high - low) * (Double(i % 60) / 59)
        }
        speeds.append(spike)
        return speeds
    }

    @Test("One spike does not flatten the rest of the session")
    func spikeDoesNotSwallowTheRange() {
        // 7–10 m/s of riding with a single 13 m/s burst. Under the old rule the
        // ramp ran 4.55–13, so all the riding landed between 0.29 and 0.64 —
        // green to green.
        let speeds = session(low: 7, high: 10, spike: 13)
        let scale = SpeedScale(speeds: speeds, movingAbove: 1)

        let bottom = scale.position(of: 7.2)
        let top = scale.position(of: 9.8)
        #expect(top - bottom > 0.7,
                "riding spans only \(top - bottom) of the ramp; it should use most of it")
    }

    @Test("The tails clip rather than stretching the middle")
    func tailsClip() {
        let scale = SpeedScale(speeds: session(low: 7, high: 10, spike: 13), movingAbove: 1)
        #expect(scale.position(of: 13) == 1)
        #expect(scale.position(of: 0) == 0)
        #expect(scale.position(of: 100) == 1)
    }

    @Test("Drifting does not drag the bottom of the ramp down")
    func slowSamplesAreExcluded() {
        // Half the session sat at a standstill. Those samples are drawn muted,
        // and letting them into the calculation is what compressed the riding
        // into the top of the ramp.
        var speeds = Array(repeating: 0.2, count: 600)
        speeds += session(low: 8, high: 11, spike: 12)

        let scale = SpeedScale(speeds: speeds, movingAbove: 1)
        #expect(scale.lower > 5, "bottom of the ramp came out at \(scale.lower)")
        #expect(scale.position(of: 8.2) < 0.3)
        #expect(scale.position(of: 10.8) > 0.7)
    }

    @Test("A session ridden at one speed is not turned into a light show")
    func flatSessionGetsAnHonestSpan() {
        // A tow, or a long straight reach: almost no spread. Stretching a full
        // rainbow over half a knot would render GPS noise as colour.
        let speeds = (0..<600).map { i in 9.0 + Double(i % 3) * 0.05 }
        let scale = SpeedScale(speeds: speeds, movingAbove: 1)

        #expect(scale.upper - scale.lower >= 1,
                "span of \(scale.upper - scale.lower) is narrower than the noise")
        // And the middle of that span is still where the riding was.
        #expect(abs(scale.position(of: 9.05) - 0.5) < 0.15)
    }

    @Test("Too few samples to judge falls back rather than inventing a range")
    func tinyTrackFallsBack() {
        let scale = SpeedScale(speeds: [4, 6, 8], movingAbove: 1)
        #expect(scale.upper == 8)
        #expect(scale.lower == 8 * 0.35)
    }

    @Test("An empty track cannot produce a divide by zero")
    func emptyIsSafe() {
        let scale = SpeedScale(speeds: [], movingAbove: 1)
        #expect(scale.upper > scale.lower)
        #expect(scale.position(of: 5).isFinite)
    }

    @Test("The scale is monotonic")
    func monotonic() {
        let scale = SpeedScale(speeds: session(low: 6, high: 12, spike: 15), movingAbove: 1)
        var previous = -1.0
        for speed in stride(from: 0.0, through: 20.0, by: 0.25) {
            let position = scale.position(of: speed)
            #expect(position >= previous)
            previous = position
        }
    }
}
