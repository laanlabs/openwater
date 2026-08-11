import Foundation
import Testing
@testable import OpenWaterCore

/// The timeline exists so wind arithmetic happens on components — the tests
/// here are mostly the classic degree-averaging traps, plus the nowcast decay.
@Suite("Wind timeline")
struct WindTimelineTests {

    let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ hours: Double) -> Date { epoch.addingTimeInterval(hours * 3600) }

    // MARK: - Components

    @Test("Speed and direction survive the round trip through components")
    func componentRoundTrip() {
        for (speed, from) in [(10.0, 350.0), (3.5, 0.0), (18.0, 106.0), (7.0, 271.5)] {
            let sample = WindTimeline.Sample(time: epoch, speed: speed, directionFrom: from)
            #expect(abs(sample.speed - speed) < 1e-9)
            #expect(Geo.angleSeparation(sample.directionFrom, from) < 1e-9)
        }
    }

    @Test("A northerly has the meteorological signs")
    func meteorologicalConvention() {
        // Wind *from* the north blows toward the south: no eastward part,
        // a negative northward part.
        let northerly = WindTimeline.Sample(time: epoch, speed: 10, directionFrom: 0)
        #expect(abs(northerly.u) < 1e-9)
        #expect(abs(northerly.v + 10) < 1e-9)
        // From the east: blowing west, so u is negative.
        let easterly = WindTimeline.Sample(time: epoch, speed: 10, directionFrom: 90)
        #expect(abs(easterly.u + 10) < 1e-9)
        #expect(abs(easterly.v) < 1e-9)
    }

    // MARK: - Interpolation

    @Test("Interpolation crosses north the short way")
    func interpolationAcrossNorth() {
        let timeline = WindTimeline(samples: [
            .init(time: at(0), speed: 10, directionFrom: 350),
            .init(time: at(1), speed: 10, directionFrom: 10),
        ])
        let mid = try! #require(timeline.wind(at: at(0.5)))
        // The naive answer is 180°. The vector answer is 0°.
        #expect(Geo.angleSeparation(mid.directionFrom, 0) < 0.5)
        // Two 10 m/s vectors 20° apart average slightly short of 10 — that
        // shrinkage is honest, not a bug.
        #expect(mid.speed > 9.7 && mid.speed <= 10)
    }

    @Test("Outside the span the nearest sample answers, but only within the slack")
    func slackAtTheEnds() {
        let timeline = WindTimeline(samples: [
            .init(time: at(0), speed: 8, directionFrom: 270),
            .init(time: at(2), speed: 12, directionFrom: 270),
        ])
        #expect(timeline.wind(at: at(-0.5))?.speed == 8)
        #expect(timeline.wind(at: at(2.5))?.speed == 12)
        #expect(timeline.wind(at: at(-2)) == nil)
        #expect(timeline.wind(at: at(4)) == nil)
    }

    @Test("Gusts interpolate, and a one-sided gust reads through")
    func gustInterpolation() {
        let timeline = WindTimeline(samples: [
            .init(time: at(0), u: -5, v: 0, gust: 10),
            .init(time: at(1), u: -5, v: 0, gust: 14),
            .init(time: at(2), u: -5, v: 0, gust: nil),
        ])
        #expect(abs((timeline.wind(at: at(0.5))?.gust ?? 0) - 12) < 1e-9)
        #expect(timeline.wind(at: at(1.5))?.gust == 14)
    }

    @Test("Samples are ordered no matter how they arrive")
    func sortsOnInit() {
        let timeline = WindTimeline(samples: [
            .init(time: at(2), speed: 12, directionFrom: 90),
            .init(time: at(0), speed: 8, directionFrom: 90),
            .init(time: at(1), speed: 10, directionFrom: 90),
        ])
        #expect(timeline.samples.map(\.time) == [at(0), at(1), at(2)])
        #expect(abs((timeline.wind(at: at(0.5))?.speed ?? 0) - 9) < 1e-9)
    }

    // MARK: - Averaging

    @Test("The strong wind out-votes the zephyr about direction")
    func speedWeightedDirection() {
        // 2 m/s from the north, then 10 m/s from the east. An unweighted
        // circular mean says 45°; the day plainly blew from nearer east.
        let timeline = WindTimeline(samples: [
            .init(time: at(0), speed: 2, directionFrom: 0),
            .init(time: at(1), speed: 10, directionFrom: 90),
        ])
        let wind = try! #require(timeline.averaged(over: DateInterval(start: at(0), end: at(1))))
        #expect(Geo.angleSeparation(wind.directionFrom, 90) < 15)
        // Speed is the mean of the speeds, not the shrunken vector length.
        #expect(abs((wind.speed ?? 0) - 6) < 1e-9)
        #expect(wind.source == .external)
    }

    @Test("A shifty day still reports its strength")
    func shiftyDayKeepsItsSpeed() {
        // 10 m/s swinging through 90°: the mean vector is short, the day
        // was not light.
        let timeline = WindTimeline(samples: [
            .init(time: at(0), speed: 10, directionFrom: 315),
            .init(time: at(1), speed: 10, directionFrom: 0),
            .init(time: at(2), speed: 10, directionFrom: 45),
        ])
        let wind = try! #require(timeline.averaged(over: DateInterval(start: at(0), end: at(2))))
        #expect(abs((wind.speed ?? 0) - 10) < 1e-9)
        #expect(Geo.angleSeparation(wind.directionFrom, 0) < 0.5)
    }

    @Test("Opposing winds cancel to no direction at all")
    func calmMeanIsNil() {
        // Equal and opposite: the mean vector is zero and any direction
        // would be an invention. The guide's rule is to say nothing.
        let timeline = WindTimeline(samples: [
            .init(time: at(0), speed: 10, directionFrom: 0),
            .init(time: at(1), speed: 10, directionFrom: 180),
        ])
        #expect(timeline.averaged(over: DateInterval(start: at(0), end: at(1))) == nil)
    }

    @Test("The biggest gust is the one reported")
    func gustIsTheMaximum() {
        let timeline = WindTimeline(samples: [
            .init(time: at(0), speed: 8, directionFrom: 270, gust: 11),
            .init(time: at(1), speed: 9, directionFrom: 270, gust: 16),
            .init(time: at(2), speed: 8, directionFrom: 270, gust: 12),
        ])
        let wind = timeline.averaged(over: DateInterval(start: at(0), end: at(2)))
        #expect(wind?.gust == 16)
    }

    @Test("A short window between samples still averages")
    func windowBetweenSamples() {
        let timeline = WindTimeline(samples: [
            .init(time: at(0), speed: 8, directionFrom: 200),
            .init(time: at(3), speed: 12, directionFrom: 220),
        ])
        // Twenty minutes in the middle of the gap: no sample falls inside
        // even with the slack, so the midpoint interpolation answers.
        let window = DateInterval(start: at(1.4), duration: 1200)
        let wind = timeline.averaged(over: window)
        #expect(wind != nil)
    }

    @Test("Round-trips through Codable")
    func codable() throws {
        let timeline = WindTimeline(samples: [
            .init(time: at(0), speed: 8, directionFrom: 200, gust: 12),
            .init(time: at(1), speed: 9, directionFrom: 210),
        ])
        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(WindTimeline.self, from: data)
        #expect(decoded == timeline)
    }

    @Test("A session without a timeline still decodes")
    func sessionBackwardCompatible() throws {
        let session = Session(
            sport: .wingfoil, startDate: at(0), endDate: at(1),
            track: TrackBuilder().build(from: [])
        )
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(session)) as! [String: Any]
        object.removeValue(forKey: "windTimeline")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Session.self, from: stripped)
        #expect(decoded.windTimeline == nil)
    }
}

@Suite("Wind nowcast")
struct WindNowcastTests {

    let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ hours: Double) -> Date { epoch.addingTimeInterval(hours * 3600) }

    /// A steady 5 m/s westerly, hourly for twelve hours.
    private var steadyModel: WindTimeline {
        WindTimeline(samples: (0...12).map {
            .init(time: at(Double($0)), speed: 5, directionFrom: 270)
        })
    }

    @Test("The innovation is fully believed now and decays toward the model")
    func decay() {
        // The station reads 8 where the model says 5, same direction.
        let observation = WindTimeline.Sample(time: at(0), speed: 8, directionFrom: 270)
        let corrected = WindNowcast(tauHours: 3).corrected(steadyModel, by: observation)

        // At the observation's moment the correction is whole: the series
        // starts from what was measured, not from what was modelled.
        #expect(abs((corrected.wind(at: at(0.01))?.speed ?? 0) - 8) < 0.1)
        // One tau later: 5 + 3/e ≈ 6.1.
        #expect(abs((corrected.wind(at: at(3))?.speed ?? 0) - (5 + 3 / M_E)) < 0.05)
        // Half a day out the station's opinion has expired.
        #expect(abs((corrected.wind(at: at(12))?.speed ?? 0) - 5) < 0.1)
    }

    @Test("Hours before the observation are not rewritten")
    func pastLeftAlone() {
        let observation = WindTimeline.Sample(time: at(6), speed: 9, directionFrom: 270)
        let corrected = WindNowcast().corrected(steadyModel, by: observation)
        #expect(abs((corrected.wind(at: at(2))?.speed ?? 0) - 5) < 1e-9)
    }

    @Test("A directional disagreement corrects as a vector")
    func vectorInnovation() {
        // Model says westerly, the buoy says southwesterly at the same
        // strength — the corrected near-term direction leans southwest.
        let observation = WindTimeline.Sample(time: at(0), speed: 5, directionFrom: 225)
        let corrected = WindNowcast(tauHours: 3).corrected(steadyModel, by: observation)
        let soon = try! #require(corrected.wind(at: at(0.25)))
        #expect(Geo.angleSeparation(soon.directionFrom, 225) < 8)
    }

    @Test("An observation the model cannot meet changes nothing")
    func noModelNoInnovation() {
        let observation = WindTimeline.Sample(time: at(24), speed: 9, directionFrom: 270)
        let corrected = WindNowcast().corrected(steadyModel, by: observation)
        #expect(corrected == steadyModel)
    }
}
