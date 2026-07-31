// CoreMotion's headers import on macOS but `CMMotionManager` itself is marked
// unavailable there, so `canImport` is not a strong enough guard — the package
// builds for macOS to run its tests, and would fail on the API rather than the
// import. Gate on the platforms that actually have device motion.
#if os(iOS) || os(watchOS)
import CoreMotion
import Foundation
import os

/// Supplies the motion channels that GPS cannot: whether the board is flying,
/// whether the rider is pumping, and whether they just landed a jump.
///
/// The key quantity is the **standard deviation of user acceleration along
/// gravity** over a one-second window. CoreMotion's `userAcceleration` already
/// has gravity removed, so what is left is what the water and the rider are
/// doing to the board:
///
/// - slamming through chop → SD of several m/s²;
/// - flying on a foil → SD well under 1 m/s²;
/// - pumping → a strong periodic component around 1 Hz, so a raised SD *without*
///   the high-frequency content of chop;
/// - airborne → SD near zero on every axis, then a hard spike on landing.
///
/// Sampling at 10 Hz is a deliberate compromise: enough to resolve a 1–2 Hz pump
/// cycle comfortably (well above Nyquist) while costing a fraction of what 50 Hz
/// would in battery over a three-hour session.
@MainActor
@Observable
public final class MotionProvider {

    nonisolated private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "Motion")

    /// One second of aggregated motion, aligned to the GPS fix rate.
    public struct Sample {
        public var verticalAccelSD: Double
        public var verticalAccelPeak: Double
        /// Roll about the fore-aft axis, degrees. Wrist-mounted, so this is
        /// suggestive rather than a measurement of the board.
        public var roll: Double?
        public var pitch: Double?
        /// Estimated pump/stroke cadence in cycles per minute, or `nil` when the
        /// signal is not periodic enough to claim one.
        public var cadence: Double?
    }

    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    /// Rolling window of vertical acceleration, one second long at 10 Hz.
    private var window: [Double] = []
    private var attitudeRoll: Double?
    private var attitudePitch: Double?

    /// Longer window for the cadence estimate — a 1 Hz pump needs several
    /// seconds of history before a period can be claimed with a straight face.
    private var cadenceWindow: [Double] = []
    private let cadenceWindowSize = 80   // 8 s at 10 Hz

    public private(set) var isRunning = false

    /// False on configurations without device motion. The UI says so rather
    /// than silently presenting speed-only flight detection as the real thing.
    public private(set) var isAvailable: Bool

    /// The most recent aggregate, refreshed continuously.
    public private(set) var latest = Sample(verticalAccelSD: 0, verticalAccelPeak: 0)

    public init() {
        isAvailable = manager.isDeviceMotionAvailable
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    // MARK: - Control

    public func start() {
        guard manager.isDeviceMotionAvailable, !isRunning else {
            if !manager.isDeviceMotionAvailable {
                Self.logger.notice("device motion unavailable; foil and jump detection will be speed-only")
            }
            return
        }
        isRunning = true
        manager.deviceMotionUpdateInterval = 1.0 / 10.0
        manager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: queue
        ) { [weak self] motion, error in
            guard let motion else {
                if let error { Self.logger.error("motion error: \(error.localizedDescription)") }
                return
            }
            // Project user acceleration onto the gravity vector to get the
            // component that is genuinely vertical, whatever way the wrist is
            // turned. Using raw z would make the answer depend on arm position.
            let g = motion.gravity
            let a = motion.userAcceleration
            let magnitude = sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
            let vertical = magnitude > 0
                ? (a.x * g.x + a.y * g.y + a.z * g.z) / magnitude
                : a.z
            // CoreMotion reports in g; the analysis layer works in m/s².
            let metresPerSecondSquared = vertical * 9.80665
            let roll = motion.attitude.roll * 180 / .pi
            let pitch = motion.attitude.pitch * 180 / .pi

            Task { @MainActor [weak self] in
                self?.ingest(vertical: metresPerSecondSquared, roll: roll, pitch: pitch)
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopDeviceMotionUpdates()
        window.removeAll()
        cadenceWindow.removeAll()
    }

    // MARK: - Aggregation

    private func ingest(vertical: Double, roll: Double, pitch: Double) {
        window.append(vertical)
        if window.count > 10 { window.removeFirst(window.count - 10) }

        cadenceWindow.append(vertical)
        if cadenceWindow.count > cadenceWindowSize {
            cadenceWindow.removeFirst(cadenceWindow.count - cadenceWindowSize)
        }

        attitudeRoll = roll
        attitudePitch = pitch

        guard !window.isEmpty else { return }
        let mean = window.reduce(0, +) / Double(window.count)
        let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window.count)

        latest = Sample(
            verticalAccelSD: sqrt(variance),
            verticalAccelPeak: window.map(abs).max() ?? 0,
            roll: roll,
            pitch: pitch,
            cadence: estimateCadence()
        )
    }

    /// Cadence by autocorrelation of the vertical acceleration.
    ///
    /// Autocorrelation rather than an FFT because the window is short, the band
    /// of interest is narrow, and a handful of lags is far cheaper than a
    /// transform — which matters when this runs every 100 ms for three hours.
    ///
    /// Returns `nil` unless the peak is strong enough to be a real rhythm, so a
    /// rider who is not pumping gets no number rather than a made-up one.
    private func estimateCadence() -> Double? {
        guard cadenceWindow.count >= cadenceWindowSize else { return nil }

        let mean = cadenceWindow.reduce(0, +) / Double(cadenceWindow.count)
        let signal = cadenceWindow.map { $0 - mean }
        let energy = signal.reduce(0) { $0 + $1 * $1 }
        guard energy > 0.5 else { return nil }   // essentially still

        // 0.4–3.0 Hz at 10 Hz sampling → lags of 3 to 25 samples.
        let minLag = 3, maxLag = 25
        var bestLag = 0
        var bestValue = 0.0
        for lag in minLag...maxLag {
            var sum = 0.0
            for i in 0..<(signal.count - lag) { sum += signal[i] * signal[i + lag] }
            let normalised = sum / energy
            if normalised > bestValue {
                bestValue = normalised
                bestLag = lag
            }
        }

        guard bestValue > 0.35, bestLag > 0 else { return nil }
        let periodSeconds = Double(bestLag) / 10.0
        return 60.0 / periodSeconds
    }
}

#endif
