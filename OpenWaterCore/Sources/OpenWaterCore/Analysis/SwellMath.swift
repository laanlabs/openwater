import Foundation

/// One train of waves as a model or a buoy states it: significant height,
/// peak period, and the direction it comes *from*.
///
/// The sea is usually several of these stacked on top of each other — a
/// long-period groundswell from one storm, a shorter one from another, and
/// the chop the local wind is making right now. Everything that reasons
/// about surf should reason about trains, because a single combined height
/// hides exactly the distinction that decides whether it is worth paddling
/// out.
public struct SwellTrain: Hashable, Sendable, Codable {

    /// Significant height, metres — roughly the mean of the biggest third
    /// of waves in this train, not the biggest wave.
    public var heightM: Double

    /// Peak period, seconds. The energy's arrival rhythm, and the best
    /// single clue to how far this train travelled to get here.
    public var periodS: Double?

    /// Degrees true the waves come *from* — the meteorological convention
    /// every wave product uses, and the opposite of the way they travel.
    public var directionFromDeg: Double?

    public init(heightM: Double, periodS: Double? = nil, directionFromDeg: Double? = nil) {
        self.heightM = heightM
        self.periodS = periodS
        self.directionFromDeg = directionFromDeg
    }
}

/// The arithmetic of swell — the handful of conversions everything
/// surf-shaped must agree on, in one place with the reasoning attached.
public enum SwellMath {

    /// What a train's period counts as when the source did not report one.
    /// Six seconds — short, local, unglamorous — so an unknown period can
    /// never inflate a train's energy past a measured one.
    public static let assumedPeriodS: Double = 6

    /// The combined significant height of independent trains.
    ///
    /// Energies add; heights do not. Two 1 m trains make a 1.41 m sea, not
    /// a 2 m one — height is the square root of energy, so the sum happens
    /// under the root. Adding heights linearly is the single most common
    /// mistake in amateur surf arithmetic and overstates every crossed sea.
    public static func combinedHeight(_ trains: [SwellTrain]) -> Double {
        trains.reduce(0) { $0 + $1.heightM * $1.heightM }.squareRoot()
    }

    /// A train's energy-flux proxy: Hs² · Te.
    ///
    /// In deep water the energy a train delivers scales with the square of
    /// its height times its period — which is why 1 m at 15 s outworks
    /// 1.5 m at 6 s, and why anything ranking or weighting trains should
    /// use this rather than height alone. A relative measure for comparing
    /// trains, not joules.
    public static func energy(_ train: SwellTrain) -> Double {
        train.heightM * train.heightM * (train.periodS ?? assumedPeriodS)
    }

    /// The energy-weighted mean direction across trains, degrees from.
    ///
    /// Vector mean, so 350° and 10° neighbours average to north rather
    /// than to south, weighted by each train's energy so a groundswell
    /// out-votes the chop. `nil` when no train knows its direction or the
    /// vectors cancel — crossed seas of equal energy genuinely have no
    /// dominant direction, and saying so beats inventing one.
    public static func dominantDirection(_ trains: [SwellTrain]) -> Double? {
        var x = 0.0, y = 0.0
        for train in trains {
            guard let direction = train.directionFromDeg else { continue }
            let weight = energy(train)
            x += weight * sin(direction * .pi / 180)
            y += weight * cos(direction * .pi / 180)
        }
        guard x != 0 || y != 0 else { return nil }
        return Geo.normalizeDegrees(atan2(x, y) * 180 / .pi)
    }

    /// Offshore significant height as a breaking-face range, metres.
    ///
    /// There is no universal physical conversion from a deep-water grid
    /// point to the face a surfer sees — that depends on bathymetry this
    /// app does not have. This is *the* stated heuristic, used by every
    /// screen that says "surf": faces typically run 0.8–1.25× the offshore
    /// height at an ordinary beach break, and long-period swell shoals
    /// harder — it stands up taller when it finally feels the bottom — so
    /// past ten seconds the top of the range grows, capped at 1.5× at
    /// sixteen seconds and beyond. A range because the ocean varies wave
    /// to wave, and a single number would be false precision.
    public static func faceHeightRange(offshoreHs: Double,
                                       periodS: Double?) -> ClosedRange<Double> {
        let hs = max(0, offshoreHs)
        guard hs > 0 else { return 0...0 }
        let period = periodS ?? assumedPeriodS
        let shoaling = min(1, max(0, (period - 10) / 6))
        let upper = 1.25 + 0.25 * shoaling
        return (hs * 0.8)...(hs * upper)
    }
}
