// Same guard as `MotionProvider`: CoreMotion's headers import on macOS but
// `CMAltimeter` is marked unavailable there, and the package builds for macOS
// to run its tests. Gate on the platforms that actually have a barometer.
#if os(iOS) || os(watchOS)
import CoreMotion
import Foundation
import os

/// Height above where the session started, from the watch's barometer.
///
/// **Why this sensor and not the receiver.** Jump height is the one number on
/// the analysis screen that GPS cannot supply. Measured on a wingfoil session
/// whose rider counted about fifteen jumps between three and ten feet: the
/// receiver's altitude reported a *largest* excursion of 1.27 m, called its own
/// vertical accuracy 3 m, and compressed most jumps into a single sample — at
/// which point a jump and a receiver glitch look identical. Reading that
/// channel finds the jumps but understates every one of them by a factor of
/// two or three, which is worse than a number people can trust.
///
/// A barometer has none of those failings. It resolves to roughly a tenth of a
/// metre, it reports on its own schedule rather than waiting for a fix, and it
/// works with the sky behind a cloud, a sail, or a wave. Every watch openWater
/// runs on has one.
///
/// **Relative, deliberately.** `CMAltimeter` reports height against wherever it
/// was started, and that is the right frame: a jump is measured against the
/// water a second earlier, not against sea level. It also means no pressure
/// reference is needed. Weather moves the baseline over hours and the analysis
/// takes a local baseline anyway, so the drift never reaches the measurement.
@MainActor
@Observable
public final class BarometerProvider {

    nonisolated private static let logger = Logger(subsystem: "com.laan.labs.openWater",
                                                   category: "Barometer")

    /// Metres above the point where `start()` was called, or nil before the
    /// first reading — and on any device with no barometer, forever.
    public private(set) var relativeAltitude: Double?

    /// The highest reading since the last time a fix took one.
    ///
    /// The apex of a jump is a moment, and the track is written when the
    /// *receiver* has something to say — so sampling the barometer at that
    /// instant throws away whatever happened between fixes, which on a jump
    /// lasting a second is most of it. Holding the peak instead means the top
    /// of the jump survives even when no fix landed near it.
    ///
    /// Ordinary riding raises this a few centimetres over the instantaneous
    /// value, which the analysis absorbs: its baseline is a local median, so a
    /// small constant bias moves the baseline and the apex together.
    public private(set) var peakSinceRead: Double?

    /// The same again from `startAbsoluteAltitudeUpdates`, the newer API.
    ///
    /// Measured on a wrist, the relative API handed over a new value every
    /// three seconds on average — 53 in 162 s — which cannot time a jump that
    /// lasts one. Nobody documents the absolute API's schedule either, so both
    /// are recorded side by side and one arm-raise session says which, if
    /// either, is fast enough. Metres above sea level rather than above the
    /// start; the analysis takes a local baseline, so the frame does not
    /// matter, only the clock.
    public private(set) var absoluteAltitude: Double?
    public private(set) var absolutePeakSinceRead: Double?

    public private(set) var isRunning = false

    /// Whether this device can answer at all. False in the simulator, which is
    /// why jump heights cannot be checked there.
    public var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    public init() {}

    public func start() {
        guard !isRunning else { return }
        guard isAvailable else {
            Self.logger.notice("no barometer on this device; jump height will be unavailable")
            return
        }
        isRunning = true
        relativeAltitude = nil
        peakSinceRead = nil
        absoluteAltitude = nil
        absolutePeakSinceRead = nil
        // Same `@Sendable` hazard as `MotionProvider`: the handler is imported
        // without Sendable, so a closure written inside this `@MainActor` class
        // would inherit main-actor isolation and then be called on the queue
        // below — which traps on a real device and never in the simulator,
        // where the sensor does not exist and the handler is never installed.
        altimeter.startRelativeAltitudeUpdates(to: queue) { @Sendable [weak self] data, error in
            guard let data else {
                if let error { Self.logger.error("altimeter: \(error.localizedDescription)") }
                return
            }
            let metres = data.relativeAltitude.doubleValue
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Said once, so a rider testing this on a wrist can see in
                // the console that readings are arriving at all — the one
                // thing the simulator can never show.
                if self.relativeAltitude == nil {
                    Self.logger.notice("barometer live: first reading \(metres, format: .fixed(precision: 2)) m")
                }
                self.relativeAltitude = metres
                self.peakSinceRead = max(self.peakSinceRead ?? metres, metres)
            }
        }

        if #available(iOS 15, watchOS 8, *), CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: queue) { @Sendable [weak self] data, error in
                guard let data else {
                    if let error { Self.logger.error("absolute altimeter: \(error.localizedDescription)") }
                    return
                }
                let metres = data.altitude
                let accuracy = data.accuracy
                let precision = data.precision
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.absoluteAltitude == nil {
                        Self.logger.notice("absolute altimeter live: first reading \(metres, format: .fixed(precision: 2)) m, accuracy \(accuracy, format: .fixed(precision: 2)), precision \(precision, format: .fixed(precision: 2))")
                    }
                    self.absoluteAltitude = metres
                    self.absolutePeakSinceRead = max(self.absolutePeakSinceRead ?? metres, metres)
                }
            }
        } else {
            Self.logger.notice("absolute altimeter not available on this device")
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        altimeter.stopRelativeAltitudeUpdates()
        if #available(iOS 15, watchOS 8, *) { altimeter.stopAbsoluteAltitudeUpdates() }
        relativeAltitude = nil
        peakSinceRead = nil
        absoluteAltitude = nil
        absolutePeakSinceRead = nil
    }

    /// The absolute API's highest reading since this was last called.
    public func takeAbsolutePeak() -> Double? {
        defer { absolutePeakSinceRead = absoluteAltitude }
        return absolutePeakSinceRead
    }

    /// The highest reading since this was last called, and start again.
    public func takePeak() -> Double? {
        defer { peakSinceRead = relativeAltitude }
        return peakSinceRead
    }
}

#endif
