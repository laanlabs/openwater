import Foundation
import Testing
@testable import OpenWaterCore

/// The accuracy gate must not be able to delete a session.
///
/// Written from a real recording. Forty-eight minutes of parawinging came back
/// as 189 points in 22 short bursts, with gaps of up to three minutes between
/// them and four of the "bursts" being a single fix. The receiver had been
/// running at 1 Hz the whole time — what removed the rest was a flat 12-metre
/// accuracy limit meeting a phone that spent the session with a body between it
/// and the sky. Nothing reported it; the session simply came out mostly empty,
/// and because legs beyond `maxBridgedGap` contribute no distance, most of the
/// distance went with it.
///
/// The tests below fix the shape of that recording in place, so the gate can
/// never quietly go back to being an absolute standard rather than an outlier
/// test.
@Suite("Accuracy gate")
struct AccuracyGateTests {

    /// A session recorded in ordinary conditions: honest 1 Hz fixes, most of
    /// them softer than any strict limit would like.
    private func pocketSession(
        duration: TimeInterval = 2900,
        typicalAccuracy: Double = 22
    ) -> [TrackPoint] {
        var points = SyntheticTrack.constantSpeed(9, duration: duration, heading: 95)
        for i in points.indices {
            // A slow wander around the typical value, with occasional good
            // fixes — the pattern that produced isolated single-point bursts.
            let wobble = sin(Double(i) / 37) * 6 + sin(Double(i) / 5) * 3
            points[i].horizontalAccuracy = max(4, typicalAccuracy + wobble)
        }
        return points
    }

    @Test("A session of soft fixes survives instead of being decimated")
    func softSessionSurvives() {
        let raw = pocketSession()
        let track = TrackBuilder(options: .forSport(.parawing)).build(from: raw)

        // The real recording kept 6.5% of its span. Anything in that territory
        // is the bug, not a strict filter doing its job.
        #expect(Double(track.points.count) / Double(raw.count) > 0.98,
                "kept only \(track.points.count) of \(raw.count) fixes")
    }

    @Test("Distance survives too, which is what the holes really cost")
    func distanceSurvives() {
        let raw = pocketSession()
        let strict = TrackBuilder(options: absoluteGate()).build(from: raw)
        let adaptive = TrackBuilder(options: .forSport(.parawing)).build(from: raw)

        // 9 m/s for 2900 s is a bit over 26 km. Legs longer than
        // `maxBridgedGap` contribute nothing, so under the old gate the holes
        // ate the distance as well as the track.
        let expected = 9.0 * 2900
        #expect(adaptive.totalDistance > expected * 0.9,
                "\(Int(adaptive.totalDistance)) m of an expected \(Int(expected)) m")
        #expect(adaptive.totalDistance > strict.totalDistance * 2,
                "the adaptive gate should be recovering most of a session the flat limit threw away")
    }

    @Test("A clean recording is judged exactly as strictly as before")
    func cleanRecordingIsUnaffected() {
        // The whole risk of a relative gate is that it loosens a good session.
        // It must not: median 5 m with a spread of 1 m stays far under the
        // strict limit, so the strict limit is what governs.
        var raw = SyntheticTrack.constantSpeed(11, duration: 600, heading: 40)
        for i in raw.indices { raw[i].horizontalAccuracy = 4 + Double(i % 3) }

        let builder = TrackBuilder(options: .forSport(.wingfoil))
        #expect(builder.resolvedAccuracyLimit(for: raw)
                == SportThresholds.forSport(.wingfoil).maxHorizontalAccuracy)
        #expect(builder.build(from: raw).points.count == raw.count)
    }

    @Test("Outliers in a clean recording are still thrown out")
    func outliersStillRejected() {
        var raw = SyntheticTrack.constantSpeed(11, duration: 600, heading: 40)
        for i in raw.indices { raw[i].horizontalAccuracy = 5 }
        // A handful of genuinely bad fixes — under a fifth of the recording, so
        // the gate has no reason to relax for them.
        for i in stride(from: 0, to: raw.count, by: 20) { raw[i].horizontalAccuracy = 180 }

        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: raw)
        #expect(track.points.allSatisfy { $0.horizontalAccuracy <= 12 })
        #expect(track.rejections.contains { $0.reason == .poorAccuracy })
    }

    @Test("The gate never relaxes past the point where a fix means nothing")
    func ceilingIsRespected() {
        var raw = SyntheticTrack.constantSpeed(9, duration: 600, heading: 90)
        for i in raw.indices { raw[i].horizontalAccuracy = 400 }

        let options = TrackBuilder.Options.forSport(.parawing)
        let limit = TrackBuilder(options: options).resolvedAccuracyLimit(for: raw)
        #expect(limit == options.accuracyCeiling)
        // And a recording made entirely of fixes that bad still comes out
        // empty, because holes are the truthful answer at that point.
        #expect(TrackBuilder(options: options).build(from: raw).points.isEmpty)
    }

    @Test("The limit actually applied is reported, not just applied")
    func limitIsReported() {
        let soft = TrackBuilder(options: .forSport(.parawing)).build(from: pocketSession())
        let strictLimit = SportThresholds.forSport(.parawing).maxHorizontalAccuracy

        #expect((soft.quality.accuracyLimitUsed ?? 0) > strictLimit,
                "a rider has to be able to see that the bar was lowered for them")

        var clean = SyntheticTrack.constantSpeed(11, duration: 300, heading: 10)
        for i in clean.indices { clean[i].horizontalAccuracy = 4 }
        let good = TrackBuilder(options: .forSport(.parawing)).build(from: clean)
        #expect(good.quality.accuracyLimitUsed == strictLimit)
    }

    @Test("A short recording is not given a relaxed gate on no evidence")
    func tooFewFixesToJudge() {
        // Ten fixes cannot establish what this receiver's normal spread is, and
        // guessing from three of them would relax the gate for a session that
        // might just be starting badly.
        var raw = Array(SyntheticTrack.constantSpeed(9, duration: 5, heading: 90))
        for i in raw.indices { raw[i].horizontalAccuracy = 40 }

        let builder = TrackBuilder(options: .forSport(.parawing))
        #expect(builder.resolvedAccuracyLimit(for: raw)
                == SportThresholds.forSport(.parawing).maxHorizontalAccuracy)
    }

    @Test("A minority of bad fixes cannot argue the gate open for itself")
    func outliersDoNotWidenTheGate() {
        // The reason the spread is measured with a median and a MAD: a mean and
        // a standard deviation would be dragged up by exactly the fixes the
        // gate exists to remove, and a bad enough tail would talk its way in.
        var raw = SyntheticTrack.constantSpeed(11, duration: 900, heading: 40)
        for i in raw.indices { raw[i].horizontalAccuracy = 5 }
        for i in raw.indices where i % 4 == 0 { raw[i].horizontalAccuracy = 250 }

        let builder = TrackBuilder(options: .forSport(.wingfoil))
        #expect(builder.resolvedAccuracyLimit(for: raw)
                == SportThresholds.forSport(.wingfoil).maxHorizontalAccuracy)
    }

    /// The gate as it behaved before: a flat limit, whatever it costs.
    private func absoluteGate() -> TrackBuilder.Options {
        var options = TrackBuilder.Options.forSport(.parawing)
        options.accuracyOutlierSigmas = 0
        return options
    }
}
