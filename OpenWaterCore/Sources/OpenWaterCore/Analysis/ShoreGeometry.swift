import Foundation

/// Which way a spot faces the water, and what that makes of a direction.
///
/// The one number that turns a forecast direction into a sentence about a
/// beach. "Wind from 270°" says nothing; "straight offshore" decides a
/// session. The same bearing gates swell: energy arriving from behind a
/// beach's back does not break on it, however big the model says it is.
///
/// Deliberately one bearing and one width rather than a full exposure
/// polygon — this is the per-spot datum a rider can set with one drag, and
/// the research guide's advice is to start exactly here and earn anything
/// fancier from observations.
public struct ShoreGeometry: Hashable, Sendable, Codable {

    /// Degrees true from the beach out toward open water — the direction a
    /// rider faces standing on the sand looking at the sea.
    public var waterFacingDeg: Double

    /// Half-width of the swell window, degrees. Energy from within this
    /// far of the facing arrives cleanly; beyond it the taper begins.
    /// Seventy-five degrees suits an open beach; a wrapped cove deserves
    /// less, a point that bends swell around itself more.
    public var exposureHalfWidthDeg: Double

    public init(waterFacingDeg: Double, exposureHalfWidthDeg: Double = 75) {
        self.waterFacingDeg = Geo.normalizeDegrees(waterFacingDeg)
        self.exposureHalfWidthDeg = exposureHalfWidthDeg
    }

    public enum WindRelation: String, Sendable {
        case offshore
        case crossShore = "cross-shore"
        case onshore
    }

    /// Wind against the shore — the real offshore/onshore, not the
    /// wind-versus-swell proxy.
    ///
    /// Wind *from* within 45° of the facing is coming off the water:
    /// onshore. From within 45° of the reciprocal it is coming off the
    /// land: offshore, the groomer. Everything between is cross-shore.
    public func windRelation(windFromDeg: Double) -> WindRelation {
        let separation = Geo.angleSeparation(windFromDeg, waterFacingDeg)
        if separation < 45 { return .onshore }
        if separation > 135 { return .offshore }
        return .crossShore
    }

    /// How much of a swell train this facing lets through, 0–1.
    ///
    /// One inside the window, tapering smoothly to zero over the next 45°
    /// — a hard edge would flip a forecast on a one-degree wobble. Long
    /// period widens the window, up to 15° at sixteen seconds: refraction
    /// bends long swell around corners that block short chop, and the
    /// widening is the same stated heuristic scale as
    /// `SwellMath.faceHeightRange`.
    public func exposure(swellFromDeg: Double, periodS: Double? = nil) -> Double {
        let period = periodS ?? SwellMath.assumedPeriodS
        let widening = 15 * min(1, max(0, (period - 10) / 6))
        let window = exposureHalfWidthDeg + widening
        let taper = 45.0

        let separation = Geo.angleSeparation(swellFromDeg, waterFacingDeg)
        if separation <= window { return 1 }
        if separation >= window + taper { return 0 }
        return 0.5 * (1 + cos(.pi * (separation - window) / taper))
    }
}
