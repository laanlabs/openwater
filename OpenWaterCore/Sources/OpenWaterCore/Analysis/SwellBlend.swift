import Foundation

/// The failure-prone arithmetic behind comparing wave models — pure, so it
/// can be tested without a network in sight.
///
/// Two jobs. First, the land-cell guard: a wave model whose nearest grid
/// cell is dry land answers 0.0 every hour rather than null, and averaged
/// naively one dry model halves a real swell. Second, the scoring used to
/// verify models against a buoy: hour-bucketed observations, mean absolute
/// error over hours that have actually happened, and the persistence
/// baseline every forecast must beat before it deserves the name.
public enum SwellBlend {

    /// Indices of height series that read as a dry grid cell: never above
    /// `floor` while some sibling clears `signal`.
    ///
    /// Both bars matter. On a genuinely flat day every model hugs zero, and
    /// dropping any of them would be inventing disagreement — so nothing is
    /// masked unless another model shows real sea. The floor is above
    /// zero because dry cells occasionally leak a stray centimetre.
    public static func landMaskedSeries(_ heights: [[Double?]],
                                        floor: Double = 0.05,
                                        signal: Double = 0.3) -> IndexSet {
        let peaks = heights.map { series in
            series.compactMap { $0 }.max() ?? 0
        }
        guard peaks.contains(where: { $0 >= signal }) else { return [] }
        return IndexSet(peaks.indices.filter { peaks[$0] < floor })
    }

    /// Observations averaged into hour buckets, keyed by whole hours since
    /// the epoch — buoys report at :10 or :50, models on the hour, and this
    /// is the meeting point.
    public static func hourBuckets(_ readings: [(at: Date, value: Double)]) -> [Int: Double] {
        var buckets: [Int: (total: Double, count: Int)] = [:]
        for reading in readings {
            let hour = Int((reading.at.timeIntervalSince1970 / 3600).rounded())
            let sum = buckets[hour] ?? (0, 0)
            buckets[hour] = (sum.total + reading.value, sum.count + 1)
        }
        return buckets.mapValues { $0.total / Double($0.count) }
    }

    /// Mean absolute error of a forecast series against bucketed
    /// observations, counting only hours at or before `now` — the request's
    /// tail is still forecast, where truth does not exist yet. `nil` when
    /// fewer than `minimumSamples` hours have both a forecast and a truth:
    /// a couple of days of overlap is an anecdote, not a record.
    public static func meanAbsoluteError(
        times: [Date],
        forecast: [Double?],
        observedByHour: [Int: Double],
        upTo now: Date,
        minimumSamples: Int = 48
    ) -> Double? {
        let gaps = times.indices.compactMap { index -> Double? in
            guard times[index] <= now,
                  index < forecast.count, let was = forecast[index],
                  let truth = observedByHour[Int((times[index].timeIntervalSince1970 / 3600).rounded())]
            else { return nil }
            return abs(was - truth)
        }
        guard gaps.count >= minimumSamples else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    /// The persistence baseline: how wrong "in `leadHours` it will be what
    /// it is now" has been, over the same observations. A model that cannot
    /// beat this number is not forecasting.
    public static func persistenceError(
        observedByHour: [Int: Double],
        leadHours: Int,
        minimumSamples: Int = 48
    ) -> Double? {
        let gaps = observedByHour.compactMap { hour, value -> Double? in
            guard let later = observedByHour[hour + leadHours] else { return nil }
            return abs(later - value)
        }
        guard gaps.count >= minimumSamples else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count)
    }
}
