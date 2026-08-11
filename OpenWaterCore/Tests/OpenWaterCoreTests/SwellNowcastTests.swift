import Foundation
import Testing
@testable import OpenWaterCore

/// The multiplicative decay, its clamp, and the cases where no honest
/// correction exists.
@Suite("Swell nowcast")
struct SwellNowcastTests {

    let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ hours: Double) -> Date { epoch.addingTimeInterval(hours * 3600) }

    /// A steady one-metre sea, hourly for a day.
    private var steadyModel: [SwellNowcast.Sample] {
        (0...24).map { .init(at: at(Double($0)), heightM: 1.0) }
    }

    private func height(_ samples: [SwellNowcast.Sample], at hours: Double) -> Double? {
        samples.first { $0.at == at(hours) }?.heightM
    }

    @Test("The reading is fully believed now and the ratio decays toward 1")
    func decay() throws {
        let correction = try #require(SwellNowcast(tauHours: 6)
            .corrected(steadyModel, byObservedHeight: 1.5, at: at(0)))

        #expect(correction.ratio == 1.5)
        #expect(correction.modelAtObservation == 1.0)
        // At the reading's moment the series is the reading.
        #expect(abs((height(correction.samples, at: 0) ?? 0) - 1.5) < 1e-9)
        // One tau later the exponent is 1/e: 1.5^0.368 ≈ 1.16.
        #expect(abs((height(correction.samples, at: 6) ?? 0) - pow(1.5, exp(-1))) < 1e-9)
        // A day later the buoy's opinion has expired.
        #expect(abs((height(correction.samples, at: 24) ?? 0) - 1.0) < 0.02)
    }

    @Test("Hours before the reading are not rewritten")
    func pastLeftAlone() throws {
        let correction = try #require(SwellNowcast()
            .corrected(steadyModel, byObservedHeight: 2, at: at(6)))
        #expect(height(correction.samples, at: 2) == 1.0)
    }

    @Test("The clamp holds when a buoy reads three times the model")
    func clampHolds() throws {
        let correction = try #require(SwellNowcast()
            .corrected(steadyModel, byObservedHeight: 3.0, at: at(0)))
        #expect(correction.ratio == 2)
        #expect(abs((height(correction.samples, at: 0) ?? 0) - 2.0) < 1e-9)
        // And symmetrically for a buoy far below the model.
        let low = try #require(SwellNowcast()
            .corrected(steadyModel, byObservedHeight: 0.1, at: at(0)))
        #expect(low.ratio == 0.5)
    }

    @Test("No series, a distant reading, or a flat model correct nothing")
    func noHonestRatio() {
        let nowcast = SwellNowcast()
        #expect(nowcast.corrected([], byObservedHeight: 1, at: at(0)) == nil)
        // Two days past the series' end — beyond any slack.
        #expect(nowcast.corrected(steadyModel, byObservedHeight: 1, at: at(72)) == nil)
        // A modelled sea of a centimetre: dividing by it would launder
        // noise into a doubling.
        let flat: [SwellNowcast.Sample] = (0...4).map { .init(at: at(Double($0)), heightM: 0.01) }
        #expect(nowcast.corrected(flat, byObservedHeight: 0.5, at: at(0)) == nil)
    }

    @Test("The correction scales with the sea instead of adding a constant")
    func multiplicative() throws {
        // A sea building from 1 m to 2 m: a ratio of 1.5 at the start
        // means +0.5 m now but proportionally more on the bigger hours,
        // less as it decays. Concretely: never negative, and the corrected
        // series stays between model and model × ratio.
        let building: [SwellNowcast.Sample] = (0...12).map {
            .init(at: at(Double($0)), heightM: 1.0 + Double($0) / 12)
        }
        let correction = try #require(SwellNowcast(tauHours: 6)
            .corrected(building, byObservedHeight: 1.5, at: at(0)))
        for (index, sample) in correction.samples.enumerated() {
            let model = building[index].heightM
            #expect(sample.heightM >= model)
            #expect(sample.heightM <= model * 1.5 + 1e-9)
        }
    }
}
