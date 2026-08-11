import Foundation
import Testing
@testable import OpenWaterCore

/// The land-cell guard and the verification arithmetic — the two pieces of
/// model comparison that fail quietly when they fail.
@Suite("Swell blend")
struct SwellBlendTests {

    let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ hours: Double) -> Date { epoch.addingTimeInterval(hours * 3600) }

    // MARK: - The land-cell guard

    @Test("A dry cell is masked when a sibling shows real sea")
    func dryCellMasked() {
        let wet: [Double?] = [1.2, 1.3, 1.1]
        let dry: [Double?] = [0.0, 0.0, 0.01]
        #expect(SwellBlend.landMaskedSeries([wet, dry]) == IndexSet([1]))
    }

    @Test("A flat-calm day masks nobody")
    func flatCalmMasksNobody() {
        // Every model hugging zero is agreement about a calm sea, not
        // three dry cells.
        let a: [Double?] = [0.0, 0.01, 0.02]
        let b: [Double?] = [0.0, 0.0, 0.0]
        #expect(SwellBlend.landMaskedSeries([a, b]).isEmpty)
    }

    @Test("Null series and small seas are left alone")
    func smallSeaSurvives() {
        // 0.2 m is a real (tiny) sea, above the dry floor — not masked
        // even beside a 2 m sibling.
        let big: [Double?] = [2.0, 2.1]
        let small: [Double?] = [0.2, 0.2]
        let nulls: [Double?] = [nil, nil]
        #expect(SwellBlend.landMaskedSeries([big, small]).isEmpty)
        // An all-null series pattern-matches a dry cell (its peak is 0) —
        // callers drop those before the guard, as the fetcher does.
        #expect(SwellBlend.landMaskedSeries([big, nulls]) == IndexSet([1]))
    }

    // MARK: - Buckets

    @Test("Half-hourly readings average into their hour")
    func bucketsAverage() {
        let buckets = SwellBlend.hourBuckets([
            (at: at(0), value: 1.0),
            (at: at(0.1), value: 2.0),
            (at: at(1), value: 3.0),
        ])
        let base = Int((epoch.timeIntervalSince1970 / 3600).rounded())
        #expect(buckets[base] == 1.5)
        #expect(buckets[base + 1] == 3.0)
    }

    // MARK: - Scoring

    @Test("A perfect forecast scores zero, and future hours do not count")
    func perfectForecast() {
        let times = (0..<60).map { at(Double($0)) }
        let observed = SwellBlend.hourBuckets(times.map { (at: $0, value: 1.0) })
        let forecast: [Double?] = Array(repeating: 1.0, count: 60)
        // Now sits at hour 50: only 51 hours have happened, still enough.
        let mae = SwellBlend.meanAbsoluteError(
            times: times, forecast: forecast, observedByHour: observed, upTo: at(50))
        #expect(mae == 0)
        // With now at hour 10, only 11 truths exist — an anecdote, not a
        // record.
        #expect(SwellBlend.meanAbsoluteError(
            times: times, forecast: forecast, observedByHour: observed, upTo: at(10)) == nil)
    }

    @Test("A biased forecast scores its bias")
    func biasedForecast() {
        let times = (0..<60).map { at(Double($0)) }
        let observed = SwellBlend.hourBuckets(times.map { (at: $0, value: 1.0) })
        let forecast: [Double?] = Array(repeating: 1.5, count: 60)
        let mae = SwellBlend.meanAbsoluteError(
            times: times, forecast: forecast, observedByHour: observed, upTo: at(59))
        #expect(abs((mae ?? 0) - 0.5) < 1e-9)
    }

    @Test("Persistence of a steady sea is perfect, of a building sea is its growth")
    func persistenceBaseline() {
        let steady = SwellBlend.hourBuckets((0..<80).map { (at: at(Double($0)), value: 2.0) })
        #expect(SwellBlend.persistenceError(observedByHour: steady, leadHours: 24) == 0)

        // Growing 0.1 m every hour: 24 hours out, persistence is off by 2.4.
        let building = SwellBlend.hourBuckets((0..<80).map {
            (at: at(Double($0)), value: Double($0) * 0.1)
        })
        let error = SwellBlend.persistenceError(observedByHour: building, leadHours: 24)
        #expect(abs((error ?? 0) - 2.4) < 1e-9)
    }

    @Test("Too few paired observations is no baseline at all")
    func persistenceNeedsData() {
        let sparse = SwellBlend.hourBuckets((0..<30).map { (at: at(Double($0)), value: 1.0) })
        #expect(SwellBlend.persistenceError(observedByHour: sparse, leadHours: 24) == nil)
    }
}
