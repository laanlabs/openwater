import Foundation
import Testing
@testable import OpenWaterCore

/// These tests all work the same way: build a track whose answer is known by
/// construction, then check the analyzer finds it. Synthetic tracks are exact,
/// so tolerances are tight — a loose tolerance here would hide the very
/// interpolation errors the continuous-window machinery exists to avoid.
@Suite("Speed analyzer")
struct SpeedAnalyzerTests {

    let analyzer = SpeedAnalyzer()
    let builder = TrackBuilder()

    func track(_ points: [TrackPoint]) -> Track { builder.build(from: points) }

    // MARK: - Time windows

    @Test("Constant speed gives that speed for every time window")
    func constantSpeedTimeWindows() {
        let t = track(SyntheticTrack.constantSpeed(10, duration: 300))

        for seconds in [2.0, 10, 30, 60] {
            let r = analyzer.evaluate(.time(seconds: seconds), on: t)
            #expect(r.isValid)
            #expect(abs(r.speed - 10) < 0.05, "\(seconds)s window gave \(r.speed)")
            #expect(abs(r.duration - seconds) < 0.001)
        }
    }

    @Test("Finds a short burst embedded in a slow run")
    func burstInSlowRun() {
        // 60 s at 5 m/s, then exactly 10 s at 20 m/s, then 60 s at 5 m/s.
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 5, heading: 90, duration: 60),
            .init(speed: 20, heading: 90, duration: 10),
            .init(speed: 5, heading: 90, duration: 60),
        ])
        let t = track(points)

        let ten = analyzer.evaluate(.time(seconds: 10), on: t)
        #expect(ten.isValid)
        // The Kalman filter shaves a little off an instantaneous step change;
        // anything above 19 m/s means the peak survived smoothing.
        #expect(ten.speed > 19, "10 s window gave \(ten.speed)")
        #expect(ten.speed <= 20.01)
        // And it should be located at the burst, not somewhere arbitrary.
        #expect(ten.startElapsed >= 58 && ten.startElapsed <= 62)

        // A 30 s window straddles the burst and must come out lower.
        let thirty = analyzer.evaluate(.time(seconds: 30), on: t)
        #expect(thirty.speed < ten.speed)
        #expect(thirty.speed > 5)
    }

    @Test("Window longer than the session is reported unavailable, not zero")
    func windowLongerThanSession() {
        let t = track(SyntheticTrack.constantSpeed(10, duration: 60))
        let r = analyzer.evaluate(.time(seconds: 3600), on: t)
        #expect(!r.isValid)
        #expect(r.invalidReason == .notEnoughDuration)
    }

    // MARK: - Distance windows

    @Test("Constant speed gives that speed for every distance window")
    func constantSpeedDistanceWindows() {
        // 10 m/s for 400 s == 4 km, enough for every standard distance.
        let t = track(SyntheticTrack.constantSpeed(10, duration: 400))

        for metres in [100.0, 250, 500, 1000, 1852] {
            let r = analyzer.evaluate(.distance(metres: metres), on: t)
            #expect(r.isValid)
            #expect(abs(r.speed - 10) < 0.05, "\(metres)m gave \(r.speed)")
            #expect(abs(r.distance - metres) < 0.001)
            #expect(abs(r.duration - metres / 10) < 0.05)
        }
    }

    @Test("Distance window beyond the track's total distance is unavailable")
    func distanceBeyondTrack() {
        let t = track(SyntheticTrack.constantSpeed(5, duration: 60))   // 300 m
        let r = analyzer.evaluate(.distance(metres: 1852), on: t)
        #expect(!r.isValid)
        #expect(r.invalidReason == .notEnoughDistance)
    }

    @Test("A stop before a run is not charged against the run")
    func stopBeforeRunIsExcluded() {
        // Sit still for 120 s, then cover 500 m at 10 m/s.
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 0, heading: 90, duration: 120),
            .init(speed: 10, heading: 90, duration: 60),
        ])
        let t = track(points)

        let r = analyzer.evaluate(.distance(metres: 500), on: t)
        #expect(r.isValid)
        // If the stationary period leaked into the window the answer would
        // collapse toward 500/170 ≈ 2.9 m/s.
        #expect(r.speed > 9, "500 m gave \(r.speed) — the stop leaked in")
        #expect(r.startElapsed > 100)
    }

    // MARK: - 5 × 10 s

    @Test("5 × 10 s picks five separate bursts, not one repeated")
    func fiveByTenPicksDistinctBursts() {
        // Five 10 s bursts at 20 m/s separated by 30 s of 5 m/s.
        var legs: [SyntheticTrack.Leg] = [.init(speed: 5, heading: 90, duration: 30)]
        for _ in 0..<5 {
            legs.append(.init(speed: 20, heading: 90, duration: 10))
            legs.append(.init(speed: 5, heading: 90, duration: 30))
        }
        let t = track(SyntheticTrack.generate(legs: legs))

        let r = analyzer.evaluate(.multiTime(count: 5, seconds: 10), on: t)
        #expect(r.isValid)
        #expect(r.segments.count == 5)
        #expect(r.speed > 18, "5×10 gave \(r.speed)")

        // The segments must not overlap in time.
        let sorted = r.segments.sorted { $0.startElapsed < $1.startElapsed }
        for i in 1..<sorted.count {
            #expect(sorted[i].startElapsed >= sorted[i - 1].endElapsed - 1e-6,
                    "segments \(i - 1) and \(i) overlap")
        }
    }

    @Test("5 × 10 s beats greedy selection when greed is a trap")
    func fiveByTenBeatsGreedy() {
        // Layout designed so the single fastest 10 s window straddles two
        // bursts: taking it greedily blocks both, while the optimal answer
        // takes the two bursts separately.
        //
        // 12 m/s for 6 s, 30 m/s for 4 s, 30 m/s for 4 s, 12 m/s for 6 s ...
        // The straddling window across the middle is the fastest single 10 s,
        // but the two 10 s windows either side of it total more.
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<3 {
            legs.append(.init(speed: 8, heading: 90, duration: 20))
            legs.append(.init(speed: 22, heading: 90, duration: 8))
            legs.append(.init(speed: 8, heading: 90, duration: 4))
            legs.append(.init(speed: 22, heading: 90, duration: 8))
        }
        legs.append(.init(speed: 8, heading: 90, duration: 20))
        let t = track(SyntheticTrack.generate(legs: legs))

        let r = analyzer.evaluate(.multiTime(count: 5, seconds: 10), on: t)
        #expect(r.isValid)
        #expect(r.segments.count == 5)

        // Whatever it picked, it must be at least as good as a greedy pass.
        let greedy = greedyFiveByTen(track: t, seconds: 10, count: 5)
        #expect(r.speed >= greedy - 1e-6,
                "optimal \(r.speed) should not lose to greedy \(greedy)")
    }

    /// Reference greedy implementation, used only to assert the DP never loses.
    private func greedyFiveByTen(track t: Track, seconds: TimeInterval, count: Int) -> Double {
        var candidates: [(start: TimeInterval, end: TimeInterval, distance: Double)] = []
        for e in t.elapsed {
            for end in [e, e + seconds] {
                let start = end - seconds
                guard start >= 0, end <= t.duration else { continue }
                candidates.append((start, end, t.distance(atElapsed: end) - t.distance(atElapsed: start)))
            }
        }
        candidates.sort { $0.distance > $1.distance }
        var taken: [(start: TimeInterval, end: TimeInterval, distance: Double)] = []
        for c in candidates where taken.count < count {
            if taken.allSatisfy({ c.end <= $0.start + 1e-9 || c.start >= $0.end - 1e-9 }) {
                taken.append(c)
            }
        }
        guard taken.count == count else { return 0 }
        return taken.reduce(0) { $0 + $1.distance / seconds } / Double(count)
    }

    // MARK: - Alpha

    @Test("Alpha finds an out-and-back loop, and may use less than the cap")
    func alphaOnLoop() {
        // Out 300 m, gybe, back 300 m. The community rule is *at most* 500 m
        // between gates — the winning segment here is whatever out-and-back
        // slice closes within 50 m, and the sailed path can legitimately be
        // shorter than the cap. Requiring exactly 500 m under-reported real
        // sessions: the fast gybe is usually short, and stretching the window
        // to the full allowance drags in slow water around it.
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 90, duration: 30),
            .init(speed: 10, heading: 270, duration: 30, transition: 4),
        ])
        let t = track(points)

        let r = analyzer.evaluate(.alpha(metres: 500, proximity: 50), on: t)
        #expect(r.isValid, "alpha not found: \(String(describing: r.invalidReason))")
        #expect(r.speed > 5 && r.speed < 11)
        #expect(r.distance <= 500.001, "alpha used \(r.distance) m of a 500 m cap")
        #expect(r.distance > 100, "degenerate alpha segment: \(r.distance) m")
    }

    @Test("A straight line has no alpha")
    func alphaNeedsATurn() {
        let t = track(SyntheticTrack.constantSpeed(12, duration: 200))
        let r = analyzer.evaluate(.alpha(metres: 500, proximity: 50), on: t)
        #expect(!r.isValid)
        #expect(r.invalidReason == .didNotReturnToStart)
    }

    @Test("A wide loop that never returns close enough fails proximity")
    func alphaNeedsProximity() {
        // A big rectangle: it turns plenty but the 500 m mark is far from any
        // start point.
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 10, heading: 0, duration: 40),
            .init(speed: 10, heading: 90, duration: 40, transition: 3),
            .init(speed: 10, heading: 180, duration: 40, transition: 3),
        ])
        let t = track(points)
        let r = analyzer.evaluate(.alpha(metres: 500, proximity: 50), on: t)
        #expect(!r.isValid)
    }

    // MARK: - Ordering invariants

    @Test("Shorter windows are never slower than longer ones")
    func windowMonotonicity() {
        let t = track(SyntheticTrack.wingSession())

        let two = analyzer.evaluate(.time(seconds: 2), on: t)
        let ten = analyzer.evaluate(.time(seconds: 10), on: t)
        let sixty = analyzer.evaluate(.time(seconds: 60), on: t)
        #expect(two.speed >= ten.speed - 1e-6)
        #expect(ten.speed >= sixty.speed - 1e-6)

        let d100 = analyzer.evaluate(.distance(metres: 100), on: t)
        let d500 = analyzer.evaluate(.distance(metres: 500), on: t)
        let d1852 = analyzer.evaluate(.distance(metres: 1852), on: t)
        #expect(d100.speed >= d500.speed - 1e-6)
        #expect(d500.speed >= d1852.speed - 1e-6)
    }

    @Test("The best single 10 s is never slower than the 5 × 10 s average")
    func singleBeatsMulti() {
        let t = track(SyntheticTrack.wingSession())
        let single = analyzer.evaluate(.time(seconds: 10), on: t)
        let multi = analyzer.evaluate(.multiTime(count: 5, seconds: 10), on: t)
        #expect(single.speed >= multi.speed - 1e-6)
    }

    @Test("Alpha is never faster than a plain 500 m")
    func alphaNeverBeatsStraight500() {
        let t = track(SyntheticTrack.wingSession())
        let alpha = analyzer.evaluate(.alpha(metres: 500, proximity: 50), on: t)
        let plain = analyzer.evaluate(.distance(metres: 500), on: t)
        if alpha.isValid && plain.isValid {
            #expect(alpha.speed <= plain.speed + 1e-6)
        }
    }

    // MARK: - Confidence

    @Test("Derived-speed tracks are less confident than Doppler ones")
    func confidenceReflectsSpeedSource() {
        let doppler = track(SyntheticTrack.constantSpeed(12, duration: 200))
        let derived = track(SyntheticTrack.generate(
            legs: [.init(speed: 12, heading: 90, duration: 200)],
            speedAccuracy: nil
        ))
        #expect(doppler.speedSource == .doppler)
        #expect(derived.speedSource == .derived)

        let a = analyzer.evaluate(.distance(metres: 500), on: doppler)
        let b = analyzer.evaluate(.distance(metres: 500), on: derived)
        #expect(a.confidence > b.confidence)
    }
}
