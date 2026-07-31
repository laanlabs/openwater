import Foundation

/// A one-dimensional Kalman filter over speed.
///
/// Why not a moving average: a boxcar or exponential average clips real peaks,
/// and peaks are the entire point of this app. A Kalman filter weights each new
/// measurement by how good the receiver says that measurement is
/// (`speedAccuracy`), so a confident 22 m/s fix moves the estimate almost all
/// the way there while an uncertain one barely nudges it. Noise gets smoothed;
/// genuine peaks survive.
///
/// State is `[speed, acceleration]` with a constant-acceleration model, which
/// matters because a foil accelerating out of a gybe is not a step change.
public struct KalmanSpeedFilter: Sendable {

    /// Process noise: how much the rider's acceleration is expected to change
    /// between samples, m/s³. Higher tracks aggressive changes but smooths less.
    public var processNoise: Double

    /// Used when the receiver gives no `speedAccuracy`, m/s.
    ///
    /// This value matters more than it looks, because most imported files have
    /// no accuracy channel at all — GPX and TCX have nowhere to put one. Set it
    /// too low and the filter treats every sample as gospel, so GPS noise
    /// becomes a personal best; too high and it smooths away the real peaks the
    /// whole app exists to find.
    ///
    /// 0.5 m/s is roughly what a modern multi-band receiver actually achieves on
    /// Doppler speed, so it is the honest default for "a device reported a
    /// speed but did not say how sure it was".
    public var defaultMeasurementNoise: Double

    /// Floor on measurement noise so an over-confident receiver cannot make the
    /// filter blindly trust a single spike.
    public var minimumMeasurementNoise: Double

    // State: speed and acceleration.
    private var x: (v: Double, a: Double) = (0, 0)
    // Covariance, symmetric 2×2 stored as p00, p01, p11.
    private var p: (p00: Double, p01: Double, p11: Double) = (100, 0, 100)
    private var initialized = false

    public init(
        processNoise: Double = 0.8,
        defaultMeasurementNoise: Double = 0.5,
        minimumMeasurementNoise: Double = 0.15
    ) {
        self.processNoise = processNoise
        self.defaultMeasurementNoise = defaultMeasurementNoise
        self.minimumMeasurementNoise = minimumMeasurementNoise
    }

    /// Feed one measurement and get the filtered speed.
    ///
    /// - Parameters:
    ///   - measurement: observed speed, m/s.
    ///   - accuracy: receiver's speed accuracy in m/s, or `nil`/negative if unknown.
    ///   - dt: seconds since the previous call.
    public mutating func update(measurement: Double, accuracy: Double?, dt: TimeInterval) -> Double {
        guard measurement.isFinite else { return max(0, x.v) }

        if !initialized {
            x = (measurement, 0)
            p = (1, 0, 1)
            initialized = true
            return measurement
        }

        let dt = max(1e-3, min(dt, 10))   // a huge gap should not blow up the covariance

        // --- Predict: v' = v + a·dt, a' = a
        x.v += x.a * dt
        x.a = x.a

        // P = F·P·Fᵀ + Q, with F = [[1, dt], [0, 1]]
        let p00 = p.p00 + dt * (2 * p.p01 + dt * p.p11)
        let p01 = p.p01 + dt * p.p11
        let p11 = p.p11
        // Continuous white-noise-acceleration model.
        let q = processNoise * processNoise
        p = (
            p00: p00 + q * dt * dt * dt / 3,
            p01: p01 + q * dt * dt / 2,
            p11: p11 + q * dt
        )

        // --- Update with H = [1, 0]
        var r = (accuracy.map { $0 >= 0 ? $0 : defaultMeasurementNoise }) ?? defaultMeasurementNoise
        r = max(r, minimumMeasurementNoise)
        let s = p.p00 + r * r
        guard s > 0 else { return max(0, x.v) }

        let k0 = p.p00 / s
        let k1 = p.p01 / s
        let residual = measurement - x.v

        x.v += k0 * residual
        x.a += k1 * residual

        let np00 = (1 - k0) * p.p00
        let np01 = (1 - k0) * p.p01
        let np11 = p.p11 - k1 * p.p01
        p = (np00, np01, np11)

        return max(0, x.v)
    }

    public mutating func reset() {
        initialized = false
        x = (0, 0)
        p = (100, 0, 100)
    }
}
