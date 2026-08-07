import Foundation

/// A direction change: a gybe, a tack, or a carve that is neither.
///
/// For a wing or parawing rider this is the unit of progress. Nobody counts
/// their max speed twice a season, but everyone knows their gybe percentage, and
/// watching it climb is the reason to keep opening the app.
public struct Maneuver: Hashable, Sendable, Codable, Identifiable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Turned through the wind, bow passing head-to-wind.
        case tack
        /// Turned through downwind, stern passing through the wind.
        case gybe
        /// A significant heading change that did not cross the wind axis.
        case carve
        /// A direction change with no wind reference available.
        case turn

        public var displayName: String {
            switch self {
            case .tack: "Tack"
            case .gybe: "Gybe"
            case .carve: "Carve"
            case .turn: "Turn"
            }
        }
    }

    public let id: Int

    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval

    public let startIndex: Int
    public let endIndex: Int

    public let kind: Kind

    /// Which tack the rider ended up on.
    public let exitTack: Tack?

    /// Total heading change through the turn, degrees, signed. Positive is a
    /// turn to starboard (clockwise).
    public let headingChange: Double

    /// Speed entering the turn, m/s — the average of the two seconds before it.
    public let entrySpeed: Double

    /// Speed leaving it.
    public let exitSpeed: Double

    /// The slowest point of the turn, which is where a gybe is won or lost.
    public let minimumSpeed: Double

    /// Fraction of entry speed lost at the bottom, 0–1.
    public var speedLoss: Double {
        entrySpeed > 0 ? max(0, min(1, 1 - minimumSpeed / entrySpeed)) : 0
    }

    /// Fraction of entry speed recovered on exit, can exceed 1.
    public var speedRetention: Double {
        entrySpeed > 0 ? exitSpeed / entrySpeed : 0
    }

    /// Seconds from the slowest point back to 90 % of entry speed.
    /// `nil` if the rider never got back up to it — a blown gybe.
    public let recoveryTime: TimeInterval?

    /// Radius of the turn in metres. A tight, high-speed carve has a small one.
    public let radius: Double?

    /// Whether the rider stayed on the foil the whole way through. This is the
    /// binary every foiler cares about, so it is stored, not derived in the view.
    public let stayedOnFoil: Bool?

    /// 0–100. Speed retention dominates, with credit for staying up and for not
    /// dawdling through the turn.
    public let score: Double

    /// 0–1 detection confidence, so a marginal call can be shown as marginal
    /// rather than asserted.
    public let confidence: Double

    public var duration: TimeInterval { endElapsed - startElapsed }

    /// Whether the turn was completed without touching down. Named the way
    /// riders say it.
    public var isDry: Bool { stayedOnFoil == true }

    /// What actually happened through the turn, in the four words a rider
    /// would use. Derived, not stored: everything it needs is already on the
    /// maneuver, and deriving it means every session ever recorded gets an
    /// outcome without a recompute.
    public enum Outcome: String, Sendable, CaseIterable {
        /// Never came off the foil.
        case clean
        /// Touched down but got back up to speed.
        case touchdown
        /// Came off and never recovered entry speed — a blown turn.
        case blown
        /// No foil-state channel to judge by.
        case unknown

        public var displayName: String {
            switch self {
            case .clean: "Clean"
            case .touchdown: "Touchdown"
            case .blown: "Blown"
            case .unknown: "Unknown"
            }
        }
    }

    public var outcome: Outcome {
        switch stayedOnFoil {
        case .none: return .unknown
        case .some(true): return .clean
        case .some(false): return recoveryTime != nil ? .touchdown : .blown
        }
    }

    /// Whether the rider came out of the turn still sailing — clean or with a
    /// touchdown, but not blown. This is the number in "landed 4 of 6 gybes".
    public var isLanded: Bool {
        switch outcome {
        case .clean, .touchdown: true
        case .blown, .unknown: false
        }
    }

    public init(
        id: Int,
        startElapsed: TimeInterval,
        endElapsed: TimeInterval,
        startIndex: Int,
        endIndex: Int,
        kind: Kind,
        exitTack: Tack?,
        headingChange: Double,
        entrySpeed: Double,
        exitSpeed: Double,
        minimumSpeed: Double,
        recoveryTime: TimeInterval?,
        radius: Double?,
        stayedOnFoil: Bool?,
        score: Double,
        confidence: Double
    ) {
        self.id = id
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.kind = kind
        self.exitTack = exitTack
        self.headingChange = headingChange
        self.entrySpeed = entrySpeed
        self.exitSpeed = exitSpeed
        self.minimumSpeed = minimumSpeed
        self.recoveryTime = recoveryTime
        self.radius = radius
        self.stayedOnFoil = stayedOnFoil
        self.score = score
        self.confidence = confidence
    }
}

/// Session-level roll-up of the maneuvers.
public struct ManeuverSummary: Hashable, Sendable, Codable {

    public let total: Int
    public let gybes: Int
    public let tacks: Int
    public let carves: Int

    /// Gybes completed without touching down, as a fraction of gybes attempted.
    /// `nil` when foil state is unknown.
    public let dryGybeRate: Double?
    public let dryTackRate: Double?

    public let meanSpeedLoss: Double
    public let bestScore: Double
    public let meanScore: Double

    /// Counts split by the tack exited onto, which is how you find the side you
    /// have been quietly avoiding.
    public let byExitTack: [Tack: Int]

    /// Mean score per exit tack — the honest version of "my toeside is fine".
    public let scoreByExitTack: [Tack: Double]

    public let fastest: Maneuver?
    public let best: Maneuver?

    public init(
        total: Int, gybes: Int, tacks: Int, carves: Int,
        dryGybeRate: Double?, dryTackRate: Double?,
        meanSpeedLoss: Double, bestScore: Double, meanScore: Double,
        byExitTack: [Tack: Int], scoreByExitTack: [Tack: Double],
        fastest: Maneuver?, best: Maneuver?
    ) {
        self.total = total
        self.gybes = gybes
        self.tacks = tacks
        self.carves = carves
        self.dryGybeRate = dryGybeRate
        self.dryTackRate = dryTackRate
        self.meanSpeedLoss = meanSpeedLoss
        self.bestScore = bestScore
        self.meanScore = meanScore
        self.byExitTack = byExitTack
        self.scoreByExitTack = scoreByExitTack
        self.fastest = fastest
        self.best = best
    }

    public static let empty = ManeuverSummary(
        total: 0, gybes: 0, tacks: 0, carves: 0,
        dryGybeRate: nil, dryTackRate: nil,
        meanSpeedLoss: 0, bestScore: 0, meanScore: 0,
        byExitTack: [:], scoreByExitTack: [:],
        fastest: nil, best: nil
    )
}

/// Finds and classifies direction changes.
///
/// Detection works on *cumulative* heading change inside a sliding window rather
/// than on instantaneous turn rate. Turn rate is far too noisy at 1 Hz — a
/// rider bouncing through chop registers 30°/s spikes constantly — whereas the
/// cumulative change over a few seconds only reaches 90° if the rider genuinely
/// went round.
///
/// Classification uses the wind: a turn whose heading sweeps *through* the
/// upwind axis is a tack, one that sweeps through downwind is a gybe, and one
/// that crosses neither is a carve. Without a wind estimate everything is a
/// plain `turn`, which is honest rather than guessing.
public struct ManeuverDetector: Sendable {

    /// Minimum cumulative heading change to count, degrees.
    public var minimumHeadingChange: Double

    /// Longest a turn may take.
    public var maximumDuration: TimeInterval

    /// Ignore turns below this entry speed — a rider paddling around in circles
    /// waiting for a gust is not gybing.
    public var minimumEntrySpeed: Double

    /// Window used to measure entry and exit speed.
    public var speedWindow: TimeInterval

    /// Delay after the turn completes before exit speed is sampled.
    ///
    /// Without this, "exit speed" is measured the instant the heading stops
    /// changing — which is the bottom of the turn, so it just duplicates
    /// `minimumSpeed`. Waiting a couple of seconds makes it answer the question
    /// riders actually care about: did you come out of it *going*.
    public var exitSettleTime: TimeInterval

    /// Sport thresholds, used for the on-foil test.
    public var thresholds: SportThresholds

    public init(
        minimumHeadingChange: Double = 70,
        maximumDuration: TimeInterval = 12,
        minimumEntrySpeed: Double = 3.0,
        speedWindow: TimeInterval = 2.5,
        exitSettleTime: TimeInterval = 2.0,
        thresholds: SportThresholds = SportThresholds.forSport(.wingfoil)
    ) {
        self.minimumHeadingChange = minimumHeadingChange
        self.maximumDuration = maximumDuration
        self.minimumEntrySpeed = minimumEntrySpeed
        self.speedWindow = speedWindow
        self.exitSettleTime = exitSettleTime
        self.thresholds = thresholds
    }

    /// The detector for a sport, honouring the rider's own thresholds.
    ///
    /// The thresholds have to arrive here rather than being assigned to
    /// `thresholds` afterwards: that property is only consulted for the on-foil
    /// test, while `minimumHeadingChange` is copied out at construction. An
    /// override assigned later changed nothing, which is how the turn setting
    /// came to be inert.
    public static func forSport(_ sport: Sport, thresholds: SportThresholds? = nil) -> ManeuverDetector {
        let t = thresholds ?? sport.thresholds
        return ManeuverDetector(
            minimumHeadingChange: t.maneuverHeadingChange,
            maximumDuration: t.maneuverMaxDuration,
            minimumEntrySpeed: max(2.0, t.movingSpeed * 2),
            thresholds: t
        )
    }

    // MARK: - Detect

    public func detect(in track: Track, wind: Wind?, flights: [Flight] = []) -> [Maneuver] {
        guard track.count >= 5 else { return [] }

        var maneuvers: [Maneuver] = []
        var i = 0

        while i < track.count - 1 {
            guard track.speed[i] >= minimumEntrySpeed else { i += 1; continue }

            // Walk forward accumulating signed heading change until either the
            // threshold is met or the time budget runs out.
            var cumulative = 0.0
            var j = i + 1
            var crossed = false

            while j < track.count, track.elapsed[j] - track.elapsed[i] <= maximumDuration {
                cumulative += Geo.angleDelta(from: track.course[j - 1], to: track.course[j])
                if abs(cumulative) >= minimumHeadingChange {
                    crossed = true
                    break
                }
                j += 1
            }

            guard crossed else { i += 1; continue }

            // Extend while the turn is still going in the same direction, so a
            // 180° gybe is captured whole rather than clipped at 70°.
            var end = j
            var total = cumulative
            let sign = cumulative > 0 ? 1.0 : -1.0
            while end + 1 < track.count,
                  track.elapsed[end + 1] - track.elapsed[i] <= maximumDuration {
                let step = Geo.angleDelta(from: track.course[end], to: track.course[end + 1])
                guard step * sign > -3 else { break }   // small counter-wobble tolerated
                total += step
                end += 1
            }

            if let m = makeManeuver(
                id: maneuvers.count,
                from: i, to: end,
                headingChange: total,
                in: track, wind: wind, flights: flights
            ) {
                maneuvers.append(m)
                // Skip past the turn plus a beat, so the exit is not immediately
                // re-detected as another turn.
                i = end + 1
            } else {
                i += 1
            }
        }

        return maneuvers
    }

    // MARK: - Construction

    private func makeManeuver(
        id: Int,
        from start: Int,
        to end: Int,
        headingChange: Double,
        in track: Track,
        wind: Wind?,
        flights: [Flight]
    ) -> Maneuver? {
        guard end > start else { return nil }

        let startTime = track.elapsed[start]
        let endTime = track.elapsed[end]

        let entrySpeed = meanSpeed(in: track, from: startTime - speedWindow, to: startTime)
        let exitSpeed = meanSpeed(
            in: track,
            from: endTime + exitSettleTime,
            to: endTime + exitSettleTime + speedWindow
        )
        guard entrySpeed >= minimumEntrySpeed else { return nil }

        var minimumSpeed = Double.infinity
        var minimumIndex = start
        for k in start...end where track.speed[k] < minimumSpeed {
            minimumSpeed = track.speed[k]
            minimumIndex = k
        }
        guard minimumSpeed.isFinite else { return nil }

        // Recovery: how long from the bottom of the turn back to 90 % of entry.
        var recovery: TimeInterval?
        let target = entrySpeed * 0.9
        var k = minimumIndex
        while k < track.count, track.elapsed[k] - track.elapsed[minimumIndex] <= 30 {
            if track.speed[k] >= target {
                recovery = track.elapsed[k] - track.elapsed[minimumIndex]
                break
            }
            k += 1
        }

        // Radius from the arc: r = distance travelled / angle swept.
        let arc = track.cumulativeDistance[end] - track.cumulativeDistance[start]
        let radians = abs(headingChange) * .pi / 180
        let radius: Double? = radians > 0.1 ? arc / radians : nil

        // Classification against the wind axis.
        let (kind, exitTack) = classify(
            from: start, to: end, headingChange: headingChange, in: track, wind: wind
        )

        // Did any flight span the whole turn?
        let stayedOnFoil: Bool? = flights.isEmpty
            ? nil
            : flights.contains { $0.startElapsed <= startTime && $0.endElapsed >= endTime }

        let score = scoreManeuver(
            entrySpeed: entrySpeed,
            exitSpeed: exitSpeed,
            minimumSpeed: minimumSpeed,
            duration: endTime - startTime,
            stayedOnFoil: stayedOnFoil
        )

        // Confidence drops for marginal heading changes, slow turns, and
        // stretches with poor GPS.
        var confidence = min(1, abs(headingChange) / 120)
        confidence *= min(1, entrySpeed / (minimumEntrySpeed * 1.5))
        if track.largestGap(fromElapsed: startTime, toElapsed: endTime) > 3 {
            confidence *= 0.5
        }
        confidence *= 0.6 + 0.4 * min(1, track.quality.score / 80)

        return Maneuver(
            id: id,
            startElapsed: startTime,
            endElapsed: endTime,
            startIndex: start,
            endIndex: end,
            kind: kind,
            exitTack: exitTack,
            headingChange: headingChange,
            entrySpeed: entrySpeed,
            exitSpeed: exitSpeed,
            minimumSpeed: minimumSpeed,
            recoveryTime: recovery,
            radius: radius,
            stayedOnFoil: stayedOnFoil,
            score: score,
            confidence: max(0, min(1, confidence))
        )
    }

    /// A turn is a tack if the heading swept across the eye of the wind, a gybe
    /// if it swept across dead downwind, and a carve if it did neither.
    ///
    /// The test is done on the *signed sweep* rather than on the endpoints,
    /// because a turn from 30° to 330° could be either depending on which way
    /// the rider went round.
    private func classify(
        from start: Int,
        to end: Int,
        headingChange: Double,
        in track: Track,
        wind: Wind?
    ) -> (Maneuver.Kind, Tack?) {
        guard let wind else { return (.turn, nil) }

        let entryTWA = wind.trueWindAngle(heading: track.course[start])
        let exitTWA = wind.trueWindAngle(heading: track.course[end])
        let exitTack: Tack = exitTWA < 0 ? .starboard : .port

        // Swept TWA path: TWA changes by exactly the heading change.
        let sweepStart = entryTWA
        let sweepEnd = entryTWA + headingChange

        // Did the swept interval contain 0 (head to wind) or ±180 (dead
        // downwind)? Work in the un-normalised sweep so direction is preserved.
        let lo = min(sweepStart, sweepEnd)
        let hi = max(sweepStart, sweepEnd)

        func sweepContains(_ target: Double) -> Bool {
            // The target repeats every 360°.
            var t = target + 360 * (lo / 360).rounded(.down)
            while t < lo { t += 360 }
            return t <= hi
        }

        let crossedUpwind = sweepContains(0)
        let crossedDownwind = sweepContains(180) || sweepContains(-180)

        if crossedUpwind && !crossedDownwind { return (.tack, exitTack) }
        if crossedDownwind && !crossedUpwind { return (.gybe, exitTack) }
        if crossedUpwind && crossedDownwind {
            // Swept more than a full side — take whichever axis is nearer the
            // middle of the turn.
            let mid = (sweepStart + sweepEnd) / 2
            let normalised = abs(Geo.normalizeDegrees(mid + 180) - 180)
            return (normalised < 90 ? .tack : .gybe, exitTack)
        }
        return (.carve, exitTack)
    }

    /// Turn quality, 0–100.
    ///
    /// Weighted to reflect what actually makes a good gybe: you kept your speed,
    /// you got it back quickly, and you did not fall off the foil.
    private func scoreManeuver(
        entrySpeed: Double,
        exitSpeed: Double,
        minimumSpeed: Double,
        duration: TimeInterval,
        stayedOnFoil: Bool?
    ) -> Double {
        guard entrySpeed > 0 else { return 0 }

        // How much speed survived the bottom of the turn.
        let retention = min(1, minimumSpeed / entrySpeed)
        // How much came back afterwards.
        let recovery = min(1, exitSpeed / entrySpeed)
        // Quick turns score better; 4 s is par, 12 s is a scored zero.
        let brevity = max(0, min(1, (12 - duration) / 8))

        var score = 45 * retention + 30 * recovery + 15 * brevity

        switch stayedOnFoil {
        case .some(true): score += 10
        case .some(false): break
        case .none: score += 5     // unknown: neither rewarded nor punished
        }

        return max(0, min(100, score))
    }

    private func meanSpeed(in track: Track, from t0: TimeInterval, to t1: TimeInterval) -> Double {
        let a = max(0, min(track.duration, t0))
        let b = max(0, min(track.duration, t1))
        guard b > a else { return track.speed(atElapsed: max(a, b)) }
        return (track.distance(atElapsed: b) - track.distance(atElapsed: a)) / (b - a)
    }
}

// MARK: - Summary

extension ManeuverSummary {
    public init(maneuvers: [Maneuver]) {
        guard !maneuvers.isEmpty else { self = .empty; return }

        let gybes = maneuvers.filter { $0.kind == .gybe }
        let tacks = maneuvers.filter { $0.kind == .tack }
        let carves = maneuvers.filter { $0.kind == .carve }

        func dryRate(_ group: [Maneuver]) -> Double? {
            let known = group.filter { $0.stayedOnFoil != nil }
            guard !known.isEmpty else { return nil }
            return Double(known.filter(\.isDry).count) / Double(known.count)
        }

        var byTack: [Tack: Int] = [:]
        var scoreSum: [Tack: Double] = [:]
        for m in maneuvers {
            guard let t = m.exitTack else { continue }
            byTack[t, default: 0] += 1
            scoreSum[t, default: 0] += m.score
        }
        var scoreByTack: [Tack: Double] = [:]
        for (tack, count) in byTack where count > 0 {
            scoreByTack[tack] = (scoreSum[tack] ?? 0) / Double(count)
        }

        self.init(
            total: maneuvers.count,
            gybes: gybes.count,
            tacks: tacks.count,
            carves: carves.count,
            dryGybeRate: dryRate(gybes),
            dryTackRate: dryRate(tacks),
            meanSpeedLoss: maneuvers.reduce(0) { $0 + $1.speedLoss } / Double(maneuvers.count),
            bestScore: maneuvers.map(\.score).max() ?? 0,
            meanScore: maneuvers.reduce(0) { $0 + $1.score } / Double(maneuvers.count),
            byExitTack: byTack,
            scoreByExitTack: scoreByTack,
            fastest: maneuvers.max { $0.minimumSpeed < $1.minimumSpeed },
            best: maneuvers.max { $0.score < $1.score }
        )
    }
}
