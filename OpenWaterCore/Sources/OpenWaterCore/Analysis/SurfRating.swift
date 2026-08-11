import Foundation

/// The app's opinion of the surf, 0–5, with every point earned or lost
/// stated in words.
///
/// A rating is an opinion — the strip's wind-effect colours are facts, and
/// the app has kept the two apart on purpose. This is the opinion, asked
/// for out loud and labelled as ours wherever it appears. Three rules keep
/// it honest. Energy, not height, sets the base: a metre at fifteen seconds
/// outworks more chop than it looks like. The wind is judged against the
/// shore, never against the swell — and without a shore bearing the score
/// is capped at 3 and says so, because rating surf without knowing which
/// way the beach faces is guessing. And safety is not in here at all:
/// warnings are a gate on their own row, not a deduction that a big enough
/// swell could buy back.
public struct SurfRating: Hashable, Sendable {

    /// 0 is flat or blown out; 5 is the day you cancel things for.
    public let score: Int
    /// Why, one clause per influence, never empty.
    public let reasons: [Reason]

    public enum Reason: Hashable, Sendable {
        /// Nothing worth paddling for.
        case flat
        /// The dominant train, as arrived at the beach.
        case swell(heightM: Double, periodS: Double)
        /// The facing blocked most of the sea — fraction is what got past.
        case exposureGated(fraction: Double)
        /// Wind judged against the shore.
        case wind(ShoreGeometry.WindRelation, kn: Double)
        /// Too little wind to matter — glassy, the best kind of nothing.
        case glassy
        /// The dominant train is short-period chop.
        case shortPeriod
        /// No shore bearing: the cap at 3, worn openly.
        case noShoreBearing

        /// The clause a screen prints — kept beside the enum so the words
        /// and the arithmetic cannot drift apart.
        public var words: String {
            switch self {
            case .flat:
                "flat, or close enough"
            case .swell(let height, let period):
                String(format: "%.1f m at %.0f s", height, period)
            case .exposureGated(let fraction):
                fraction <= 0.05
                    ? "the swell cannot reach this facing"
                    : "this facing blocks most of the swell"
            case .wind(let relation, let kn):
                "\(Int(kn.rounded())) kn \(relation.rawValue)"
            case .glassy:
                "barely any wind"
            case .shortPeriod:
                "short-period chop"
            case .noShoreBearing:
                "capped — beach facing unknown"
            }
        }
    }

    /// Rate a moment. Trains as the model states them; shore when the spot
    /// knows its facing; wind as speed and the direction it comes from.
    public static func rate(trains: [SwellTrain],
                            shore: ShoreGeometry?,
                            windKn: Double?,
                            windFromDeg: Double?) -> SurfRating {
        // Energy through the facing. Without a shore the gate is open —
        // and the cap below owns what that not-knowing costs.
        let raw = trains.reduce(0.0) { $0 + SwellMath.energy($1) }
        let arrived = trains.reduce(0.0) { total, train in
            let gate = shore.flatMap { geometry in
                train.directionFromDeg.map {
                    geometry.exposure(swellFromDeg: $0, periodS: train.periodS)
                }
            } ?? 1
            return total + SwellMath.energy(train) * gate
        }

        var reasons: [Reason] = []
        if shore != nil, raw > 2, arrived < raw * 0.5 {
            reasons.append(.exposureGated(fraction: raw > 0 ? arrived / raw : 0))
        }

        // Not enough energy to rate: a 0.4 m 5 s dribble lands here.
        guard arrived >= 2 else {
            reasons.append(.flat)
            return SurfRating(score: 0, reasons: reasons)
        }

        // The base, 0–4, from energy that actually arrives. The steps are
        // a stated heuristic on Hs²·Te: ~0.7 m at 8 s clears the first bar,
        // a metre at 10 s the second, two metres at 14 s the fourth.
        let base: Int = switch arrived {
        case ..<8: 1
        case ..<20: 2
        case ..<60: 3
        default: 4
        }
        var score = base

        // The dominant train speaks for the sea.
        if let dominant = trains.max(by: { SwellMath.energy($0) < SwellMath.energy($1) }) {
            let period = dominant.periodS ?? SwellMath.assumedPeriodS
            reasons.append(.swell(heightM: dominant.heightM, periodS: period))
            if period < 8 {
                score -= 1
                reasons.append(.shortPeriod)
            }
        }

        // Wind, only against a known shore — the swell-relative proxy is
        // good enough to colour a strip and not good enough to score with.
        if let shore, let windKn, let windFromDeg {
            if windKn < 4 {
                score += 1
                reasons.append(.glassy)
            } else {
                let relation = shore.windRelation(windFromDeg: windFromDeg)
                switch relation {
                case .offshore:
                    score += windKn <= 15 ? 1 : 0
                case .crossShore:
                    score -= windKn > 15 ? 1 : 0
                case .onshore:
                    score -= windKn > 18 ? 2 : windKn > 10 ? 1 : 0
                }
                reasons.append(.wind(relation, kn: windKn))
            }
        }

        // Not knowing the beach caps the ceiling, not the floor.
        if shore == nil {
            score = min(score, 3)
            reasons.append(.noShoreBearing)
        }

        return SurfRating(score: max(0, min(5, score)), reasons: reasons)
    }
}
