import Foundation

/// A detected jump.
public struct Jump: Hashable, Sendable, Codable, Identifiable {

    public let id: Int

    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval
    public let startIndex: Int
    public let endIndex: Int

    /// Seconds in the air.
    public let airtime: TimeInterval

    /// Estimated height in metres, from hangtime under gravity.
    public let height: Double

    /// Speed going in — the thing that made the jump possible.
    public let takeoffSpeed: Double

    /// Speed on landing. Keeping it is what separates a jump from a crash.
    public let landingSpeed: Double

    /// Distance covered while airborne.
    public let distance: Double

    /// 0–1. Named honestly: this is a detection, not a measurement.
    public let confidence: Double

    public init(
        id: Int, startElapsed: TimeInterval, endElapsed: TimeInterval,
        startIndex: Int, endIndex: Int, airtime: TimeInterval, height: Double,
        takeoffSpeed: Double, landingSpeed: Double, distance: Double, confidence: Double
    ) {
        self.id = id
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.airtime = airtime
        self.height = height
        self.takeoffSpeed = takeoffSpeed
        self.landingSpeed = landingSpeed
        self.distance = distance
        self.confidence = confidence
    }

    /// Fraction of takeoff speed kept through the landing.
    public var landingRetention: Double {
        takeoffSpeed > 0 ? min(2, landingSpeed / takeoffSpeed) : 0
    }
}

public struct JumpSummary: Hashable, Sendable, Codable {
    public let count: Int
    public let bestAirtime: TimeInterval
    public let bestHeight: Double
    public let totalAirtime: TimeInterval
    public let highest: Jump?
    public let longest: Jump?

    public init(
        count: Int, bestAirtime: TimeInterval, bestHeight: Double,
        totalAirtime: TimeInterval, highest: Jump?, longest: Jump?
    ) {
        self.count = count
        self.bestAirtime = bestAirtime
        self.bestHeight = bestHeight
        self.totalAirtime = totalAirtime
        self.highest = highest
        self.longest = longest
    }

    public static let none = JumpSummary(
        count: 0, bestAirtime: 0, bestHeight: 0, totalAirtime: 0,
        highest: nil, longest: nil
    )

    public init(jumps: [Jump]) {
        guard !jumps.isEmpty else { self = .none; return }
        self.init(
            count: jumps.count,
            bestAirtime: jumps.map(\.airtime).max() ?? 0,
            bestHeight: jumps.map(\.height).max() ?? 0,
            totalAirtime: jumps.reduce(0) { $0 + $1.airtime },
            highest: jumps.max { $0.height < $1.height },
            longest: jumps.max { $0.airtime < $1.airtime }
        )
    }
}

/// Detects jumps from free-fall in the accelerometer.
///
/// The signature is unambiguous when motion data exists: in the air the only
/// force on the board is gravity, so the *user* acceleration the device reports
/// (gravity already removed) collapses toward zero, then spikes hard on landing.
/// That near-zero window bracketed by a landing spike is a jump, and almost
/// nothing else on the water produces it.
///
/// Height comes from hangtime. A projectile that is in the air for `t` seconds
/// reaches `g·t²/8` at its apex — the classic result, since it spends `t/2` going
/// up. It assumes takeoff and landing are at the same level, which for a jump off
/// a wave into a trough is optimistic; the number is reported as an estimate.
///
/// Without motion data, jumps are not reported at all. GPS altitude on a wrist is
/// nowhere near good enough to detect a two-metre hop, and inventing jumps from
/// speed dips would be worse than staying silent.
public struct JumpDetector: Sendable {

    /// User acceleration magnitude below this counts as free fall, m/s².
    public var freeFallThreshold: Double

    /// Landing spike must exceed this, m/s².
    public var landingThreshold: Double

    /// Shortest airtime worth reporting.
    public var minimumAirtime: TimeInterval

    /// Longest plausible airtime — anything more is a sensor fault, not a boost.
    public var maximumAirtime: TimeInterval

    /// Minimum takeoff speed. You cannot jump from a standstill.
    public var minimumTakeoffSpeed: Double

    public init(
        freeFallThreshold: Double = 2.5,
        landingThreshold: Double = 12,
        minimumAirtime: TimeInterval = 0.6,
        maximumAirtime: TimeInterval = 8,
        minimumTakeoffSpeed: Double = 3.0
    ) {
        self.freeFallThreshold = freeFallThreshold
        self.landingThreshold = landingThreshold
        self.minimumAirtime = minimumAirtime
        self.maximumAirtime = maximumAirtime
        self.minimumTakeoffSpeed = minimumTakeoffSpeed
    }

    /// The detector for a sport, honouring the rider's own thresholds.
    ///
    /// `thresholds` is passed in rather than read from the sport, because the
    /// rider's overrides live on top of the sport's defaults and only the
    /// caller has them. Forgetting to pass them is the bug that made the
    /// glide settings inert for a day.
    public static func forSport(_ sport: Sport, thresholds: SportThresholds? = nil) -> JumpDetector {
        let t = thresholds ?? sport.thresholds
        var d = JumpDetector(
            freeFallThreshold: t.jumpFreeFall,
            landingThreshold: t.jumpLandingSpike,
            minimumAirtime: t.jumpMinimumAirtime,
            minimumTakeoffSpeed: t.jumpMinimumTakeoffSpeed
        )
        switch sport {
        case .kitesurf, .kitefoil:
            // Kites boost properly and land softly under canopy.
            d.maximumAirtime = 12
        case .windsurf:
            d.maximumAirtime = 6
        case .wingfoil, .parawing:
            d.maximumAirtime = 5
        default:
            break
        }
        return d
    }

    public func detect(in track: Track) -> [Jump] {
        // Requires motion data. Without it we say nothing rather than guess.
        guard track.points.contains(where: { $0.verticalAccelPeak != nil }) else { return [] }
        guard track.count >= 3 else { return [] }

        var jumps: [Jump] = []
        var i = 0

        while i < track.count {
            guard let sd = track.points[i].verticalAccelSD,
                  let peak = track.points[i].verticalAccelPeak,
                  sd <= freeFallThreshold, peak <= freeFallThreshold * 2,
                  track.speed[i] >= minimumTakeoffSpeed else {
                i += 1
                continue
            }

            // Extend through the quiet window.
            var j = i
            while j + 1 < track.count,
                  let sd = track.points[j + 1].verticalAccelSD,
                  sd <= freeFallThreshold,
                  track.elapsed[j + 1] - track.elapsed[i] <= maximumAirtime {
                j += 1
            }

            let airtime = track.elapsed[j] - track.elapsed[i]

            // The landing spike is the confirmation. Without it this is just a
            // smooth patch of water — or a foil flight, which is exactly the
            // false positive we must not produce.
            let landed = j + 1 < track.count
                && (track.points[j + 1].verticalAccelPeak ?? 0) >= landingThreshold

            if landed, airtime >= minimumAirtime, airtime <= maximumAirtime {
                let height = 9.80665 * airtime * airtime / 8
                let distance = track.cumulativeDistance[j] - track.cumulativeDistance[i]

                // Confidence: a longer quiet window and a harder landing spike
                // both make the call safer.
                let spike = track.points[min(j + 1, track.count - 1)].verticalAccelPeak ?? 0
                var confidence = min(1, airtime / 2) * 0.5
                    + min(1, spike / (landingThreshold * 2)) * 0.5
                confidence *= 0.6 + 0.4 * min(1, track.quality.score / 80)

                jumps.append(Jump(
                    id: jumps.count,
                    startElapsed: track.elapsed[i],
                    endElapsed: track.elapsed[j],
                    startIndex: i,
                    endIndex: j,
                    airtime: airtime,
                    height: height,
                    takeoffSpeed: track.speed[max(0, i - 1)],
                    landingSpeed: track.speed[min(track.count - 1, j + 1)],
                    distance: distance,
                    confidence: max(0, min(1, confidence))
                ))
                i = j + 2
            } else {
                i = j + 1
            }
        }

        return jumps
    }
}
