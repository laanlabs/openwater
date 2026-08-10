import Foundation
import Testing
@testable import OpenWaterCore

/// What a jump is, and what a bumpy downwind run is.
///
/// These exist because of one report. A rider sent back a parawing run with
/// the note "this should be all one single down wind run with no jumps", and
/// the app had found nine — one of them claiming nineteen metres of air. The
/// cause was a fixed free-fall threshold of 2.5 m/s²: **982 of that session's
/// 1,345 samples were under it**, so the free-fall clause was true for most
/// of the session and the only thing separating a "jump" from ordinary riding
/// was a landing spike, which chop supplies all day.
@Suite("Jump detection")
struct JumpDetectorTests {

    let builder = TrackBuilder()

    /// A long smooth ride, optionally with a genuinely silent window in it.
    ///
    /// `quiet` is what a device in free fall reads: gravity is already removed
    /// from user acceleration, so with nothing supporting the board there is
    /// almost nothing left to measure. `riding` is the measured median of a
    /// real parawing session on the foil — quiet, but nowhere near silent.
    func ride(freeFallAt: Range<Int>? = nil, chopHitsEvery: Int? = nil) -> Track {
        var raw = SyntheticTrack.generate(legs: [
            .init(speed: 9, heading: 90, duration: 180),
        ])
        for i in raw.indices {
            // A little spread, so the quiet quarter is a real quarter rather
            // than one repeated number.
            raw[i].verticalAccelSD = 1.4 + Double(i % 5) * 0.15
            raw[i].verticalAccelPeak = 6 + Double(i % 3)

            if let window = freeFallAt, window.contains(i) {
                raw[i].verticalAccelSD = 0.12
                raw[i].verticalAccelPeak = 0.3
            }
            if let window = freeFallAt, i == window.upperBound {
                raw[i].verticalAccelPeak = 22          // the landing
            }
            if let every = chopHitsEvery, i % every == 0 {
                raw[i].verticalAccelPeak = 18          // a hard chop hit
            }
        }
        return builder.build(from: raw)
    }

    @Test("Smooth foiling through chop is not a jump")
    func smoothRidingIsNotAJump() {
        // The reported session, in miniature: never silent, but always under
        // the old fixed bar, and hit hard by chop often enough to supply a
        // landing spike whenever one was wanted.
        let jumps = JumpDetector.forSport(.parawing).detect(in: ride(chopHitsEvery: 20))
        #expect(jumps.isEmpty, "reported \(jumps.count) jumps on a rider who never left the water")
    }

    @Test("A genuinely silent window ending in a landing is a jump")
    func realJumpIsStillFound() {
        // The fix must not simply switch jumps off. Free fall reads an order
        // of magnitude quieter than riding, and that is still detectable.
        let jumps = JumpDetector.forSport(.parawing).detect(in: ride(freeFallAt: 100..<103))
        #expect(jumps.count == 1)
        #expect((jumps.first?.airtime ?? 0) >= 1)
    }

    @Test("The free-fall bar comes down to meet a quiet session")
    func barIsRelativeToTheSession() {
        let detector = JumpDetector.forSport(.parawing)
        let bar = detector.freeFallBar(for: ride())

        #expect(bar < detector.freeFallThreshold,
                "a session quieter than the fixed bar has to bring the bar down with it")
        #expect(bar < 1.4, "the bar has to sit under ordinary riding, not over it")
    }

    @Test("The bar never rises above the sport's own ceiling")
    func barNeverLoosens() {
        // A rough session must not be given a *higher* free-fall bar than the
        // sport allows — that direction invents jumps, which is the failure
        // this is all about.
        var raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 120)])
        for i in raw.indices {
            raw[i].verticalAccelSD = 9
            raw[i].verticalAccelPeak = 20
        }
        let detector = JumpDetector.forSport(.parawing)
        let bar = detector.freeFallBar(for: builder.build(from: raw))

        #expect(bar == detector.freeFallThreshold)
    }

    @Test("Without motion data nothing is claimed")
    func noMotionNoJumps() {
        let raw = SyntheticTrack.generate(legs: [.init(speed: 9, heading: 90, duration: 120)])
        #expect(JumpDetector.forSport(.parawing).detect(in: builder.build(from: raw)).isEmpty)
    }
}
