import Foundation

/// A modelled wave-height series corrected by one fresh buoy reading.
///
/// The wave sibling of `WindNowcast`, with one deliberate difference: the
/// wind's innovation is additive, in components, because wind is a vector
/// whose errors add. A wave height is a positive scalar whose error is
/// proportional — a model 30% low on a small swell is 30% low on a big one
/// — so the correction here is a *ratio*, decayed by raising it to a
/// shrinking power: at the reading's moment the series starts from what was
/// measured, and hours later the ratio has relaxed to 1 and the model
/// speaks for itself again. Multiplicative also means the correction can
/// never invent a negative sea.
///
/// Total height only. Matching modelled swell trains to measured ones is
/// an assignment problem the research guide warns about, and half the
/// buoys do not resolve the split anyway.
public struct SwellNowcast: Hashable, Sendable {

    public struct Sample: Hashable, Sendable {
        public var at: Date
        public var heightM: Double

        public init(at: Date, heightM: Double) {
            self.at = at
            self.heightM = heightM
        }
    }

    public struct Correction: Hashable, Sendable {
        /// Observed over modelled at the reading's moment, after the clamp.
        public var ratio: Double
        /// What the model said the sea was when the buoy measured it.
        public var modelAtObservation: Double
        /// The series with the ratio decayed through it.
        public var samples: [Sample]
    }

    /// Hours for the ratio to decay most of the way back to 1. Twice the
    /// wind nowcast's three, because swell evolves slowly — a buoy's
    /// disagreement this morning still says something after lunch.
    public var tauHours: Double

    public init(tauHours: Double = 6) {
        self.tauHours = tauHours
    }

    /// The series corrected by one observation, or nil when there is no
    /// honest ratio to form: an empty series, a reading outside the hours
    /// the model covers (padded by 45 minutes, like the wind timeline's
    /// slack), or a modelled sea so near flat that dividing by it would
    /// launder noise into a huge correction.
    ///
    /// The ratio is clamped to [0.5, 2] — a buoy reading three times the
    /// model is more likely a different piece of water than a threefold
    /// model error, and the clamp keeps a bad pairing from doubling a
    /// forecast twice over. Samples before the reading are left alone; the
    /// past is not improved by correcting it.
    public func corrected(_ series: [Sample],
                          byObservedHeight observed: Double,
                          at time: Date) -> Correction? {
        let sorted = series.sorted { $0.at < $1.at }
        guard let modelled = interpolate(sorted, at: time), modelled >= 0.05 else { return nil }

        let ratio = min(2, max(0.5, observed / modelled))
        let samples = sorted.map { sample -> Sample in
            let leadHours = sample.at.timeIntervalSince(time) / 3600
            guard leadHours >= 0 else { return sample }
            let weight = exp(-leadHours / tauHours)
            var adjusted = sample
            adjusted.heightM = sample.heightM * pow(ratio, weight)
            return adjusted
        }
        return Correction(ratio: ratio, modelAtObservation: modelled, samples: samples)
    }

    /// Linear interpolation between the bracketing samples, with the wind
    /// timeline's 45-minute slack past either end.
    private func interpolate(_ sorted: [Sample], at time: Date) -> Double? {
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let slack: TimeInterval = 45 * 60
        if time <= first.at {
            return time >= first.at.addingTimeInterval(-slack) ? first.heightM : nil
        }
        if time >= last.at {
            return time <= last.at.addingTimeInterval(slack) ? last.heightM : nil
        }
        guard let upper = sorted.firstIndex(where: { $0.at >= time }) else { return nil }
        let b = sorted[upper]
        guard upper > 0 else { return b.heightM }
        let a = sorted[upper - 1]
        let width = b.at.timeIntervalSince(a.at)
        guard width > 0 else { return b.heightM }
        let t = time.timeIntervalSince(a.at) / width
        return a.heightM + (b.heightM - a.heightM) * t
    }
}
