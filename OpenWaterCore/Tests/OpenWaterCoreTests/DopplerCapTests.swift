import Foundation
import Testing
@testable import OpenWaterCore

/// A GPS receiver measures speed twice, by two unrelated methods: it differences
/// positions, and it reads the Doppler shift on the carrier. The second is far
/// the better of the two over a short window — it does not care that the
/// position wandered 40 m sideways when the antenna went under a wave, because
/// nothing about the carrier frequency moved.
///
/// So the short windows are ranked and reported on the Doppler figure plus a
/// tolerance, while distance keeps summing raw positions. A single bad fix used
/// to buy a 46-knot personal best on a session that never passed 16.
@Suite("Doppler cap")
struct DopplerCapTests {

    let analyzer = SpeedAnalyzer()
    let builder = TrackBuilder()

    /// A steady run at `speed`, with one sample displaced sideways by `jump`
    /// metres — the classic multipath glitch. Every fix carries an honest
    /// Doppler reading throughout, including the displaced one.
    func trackWithGlitch(
        speed: Double = 5,
        duration: TimeInterval = 200,
        jump: Double = 44,
        atSecond: Int = 100
    ) -> Track {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let metresPerDegree = 111_320.0
        var points: [TrackPoint] = []
        for i in 0...Int(duration) {
            let along = speed * Double(i)
            let sideways = i == atSecond ? jump : 0
            points.append(TrackPoint(
                timestamp: start.addingTimeInterval(Double(i)),
                latitude: 47 + sideways / metresPerDegree,
                longitude: -122 + along / (metresPerDegree * cos(47 * .pi / 180)),
                speed: speed,
                course: 90,
                horizontalAccuracy: 5
            ))
        }
        return builder.build(from: points)
    }

    @Test("A single position glitch cannot buy a personal best")
    func glitchIsVetoed() {
        let t = trackWithGlitch()
        #expect(t.speedSource != .derived)

        // 44 m in a second is 85 knots. Positions alone would hand that, or
        // half of it, to the 2 s window.
        let two = analyzer.evaluate(.time(seconds: 2), on: t)
        #expect(two.isValid)
        #expect(two.speed <= 5 * analyzer.dopplerTolerance + 0.01, "2 s gave \(two.speed) m/s")

        for seconds in [2.0, 10, 30] {
            let r = analyzer.evaluate(.time(seconds: seconds), on: t)
            #expect(r.speed <= 5 * analyzer.dopplerTolerance + 0.01)
        }
    }

    @Test("The veto leaves an honest run alone")
    func honestRunIsUntouched() {
        // Same shape, no glitch: the answer must still be the real speed and
        // not the speed minus a safety margin.
        let clean = trackWithGlitch(jump: 0)
        let two = analyzer.evaluate(.time(seconds: 2), on: clean)
        #expect(abs(two.speed - 5) < 0.2, "2 s gave \(two.speed) m/s")
    }

    @Test("Distance is summed raw — the cap is about speed, not length")
    func distanceIsUnaffected() {
        let glitched = trackWithGlitch()
        let clean = trackWithGlitch(jump: 0)
        // The detour out and back is ~88 m of genuinely travelled path as far
        // as the positions are concerned, and openWater does not second-guess
        // it: two receivers disagreeing by a percent on a session's length is
        // ordinary, one of them claiming 46 knots is not.
        #expect(glitched.totalDistance > clean.totalDistance)
    }

    @Test("A track with no Doppler channel is left uncapped")
    func derivedTracksAreNotCapped() {
        // Most imported GPX has no speed channel at all, so positions are the
        // only witness there is. Deriving a ceiling from them and then applying
        // it to themselves would be circular — and would silently rewrite every
        // imported session's numbers.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let metresPerDegree = 111_320.0
        var points: [TrackPoint] = []
        for i in 0...200 {
            let along = 5.0 * Double(i)
            points.append(TrackPoint(
                timestamp: start.addingTimeInterval(Double(i)),
                latitude: 47 + (i == 100 ? 44 : 0) / metresPerDegree,
                longitude: -122 + along / (metresPerDegree * cos(47 * .pi / 180)),
                speed: nil,
                horizontalAccuracy: 5
            ))
        }
        let t = builder.build(from: points)
        #expect(t.speedSource == .derived)

        let two = analyzer.evaluate(.time(seconds: 2), on: t)
        #expect(two.speed > 10, "derived track was capped anyway: \(two.speed) m/s")
    }

    @Test("Distance windows pick the fastest stretch, not the noisiest")
    func distanceWindowsRankOnCappedSpeed() {
        // Two legs: a slow one carrying a fat position glitch, then a genuinely
        // fast one. Ranking candidates by raw elapsed time picks the glitch —
        // it looks like it covered 100 m in no time — and then reports the slow
        // Doppler from inside it. Ranking on the capped speed picks the leg
        // that was actually quick.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let metresPerDegree = 111_320.0
        let lonScale = metresPerDegree * cos(47 * .pi / 180)
        var points: [TrackPoint] = []
        var along = 0.0
        for i in 0..<400 {
            let fast = i >= 250
            let speed = fast ? 12.0 : 3.0
            along += speed
            let sideways = (!fast && i == 120) ? 60.0 : 0
            points.append(TrackPoint(
                timestamp: start.addingTimeInterval(Double(i)),
                latitude: 47 + sideways / metresPerDegree,
                longitude: -122 + along / lonScale,
                speed: speed,
                course: 90,
                horizontalAccuracy: 5
            ))
        }
        let t = builder.build(from: points)

        let hundred = analyzer.evaluate(.distance(metres: 100), on: t)
        #expect(hundred.isValid)
        #expect(hundred.speed > 10, "100 m gave \(hundred.speed) m/s — it took the glitch")
        #expect(hundred.startElapsed > 200, "100 m landed at \(hundred.startElapsed) s, not on the fast leg")
    }

    @Test("The range index answers the same as a plain scan")
    func indexMatchesScan() {
        let t = trackWithGlitch(duration: 300)
        let index = SpeedAnalyzer.ReportedSpeedIndex(track: t)
        for (t0, t1) in [(0.0, 300.0), (10.0, 11.0), (99.0, 101.0), (250.0, 299.0), (5.0, 5.0)] {
            #expect(index.peak(from: t0, to: t1) == t.peakReportedSpeed(fromElapsed: t0, toElapsed: t1),
                    "range \(t0)–\(t1)")
        }
    }
}
