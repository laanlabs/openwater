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

    /// Said once per session, in the failing API's own words, the moment the
    /// altimeter refuses — the same channel the workout uses. A session with
    /// no altimeter readings used to say only that it had none; the first one
    /// recorded on the water read every other sensor and left this one
    /// blank, and nothing on the session said whether the barometer was
    /// missing, refused, or never asked.
    public var onIssue: ((String) -> Void)?

    /// The altimeter's own error, if it gave one this session.
    public private(set) var lastError: String?

    /// Whether this device can answer at all. False in the simulator, which is
    /// why jump heights cannot be checked there.
    public var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    /// Motion & Fitness, which the altimeter needs and the accelerometer does
    /// not. That asymmetry is the trap: `CMMotionManager` fills the motion
    /// channel with no permission at all, so a session can carry every
    /// accelerometer sample and no altitude, and look like a sensor fault.
    public var isAuthorized: Bool {
        switch CMAltimeter.authorizationStatus() {
        case .authorized: true
        default: false
        }
    }

    /// The permission in words, for the session's account of itself.
    public var authorizationDescription: String {
        switch CMAltimeter.authorizationStatus() {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "never asked"
        @unknown default: "unknown"
        }
    }

    /// Ask for Motion & Fitness now, before a session, by starting the
    /// altimeter for one reading and stopping it.
    ///
    /// The prompt otherwise appears the first time a session starts the
    /// altimeter — which is the moment Water Lock takes the screen, on a
    /// wrist that is about to be under a wing. A prompt nobody can answer
    /// leaves the permission undetermined and the channel empty for the
    /// whole session. Asked at launch, it is answered on the beach.
    public func requestAccess() {
        Self.logger.notice("altimeter at launch: barometer \(self.isAvailable ? "present" : "absent"), Motion & Fitness \(self.authorizationDescription)")
        guard isAvailable, !isRunning,
              CMAltimeter.authorizationStatus() == .notDetermined else { return }
        Self.logger.notice("asking for Motion & Fitness so the altimeter can be read")
        let probe = CMAltimeter()
        self.probe = probe
        probe.startRelativeAltitudeUpdates(to: queue) { @Sendable [weak self] data, error in
            if let error { Self.logger.error("altimeter access: \(error.localizedDescription)") }
            if data != nil { Self.logger.notice("altimeter access granted") }
            Task { @MainActor [weak self] in
                self?.probe?.stopRelativeAltitudeUpdates()
                self?.probe = nil
            }
        }
    }

    /// The one-reading altimeter behind `requestAccess`, alive until it answers.
    private var probe: CMAltimeter?

    /// One instance per API, made fresh on every `start()`.
    ///
    /// Both were started on one `CMAltimeter` held for the life of the app,
    /// and on a wrist the two channels came and went independently: a
    /// session on 11 September carried the relative one and not the
    /// absolute; a desk run on 16 September carried the absolute at one a
    /// second and not the relative at all — the relative API only speaks
    /// when the pressure moves, and a desk does not. And one hour-long
    /// session on the water carried neither from its first fix, with the
    /// permission granted and the accelerometer running throughout. Nothing
    /// in this class reproduces that on a desk. So the instances are new
    /// each session rather than as old as the app, and `nudge` restarts
    /// them if they fall silent.
    private var altimeter: CMAltimeter?
    private var absoluteAltimeter: CMAltimeter?

    /// Readings this session, per API. On the session's own account when it
    /// ends with none, so the next silent hour says whether readings arrived
    /// and were lost or never arrived.
    public private(set) var relativeReadings = 0
    public private(set) var absoluteReadings = 0

    /// Times `nudge` restarted a silent altimeter this session.
    public private(set) var restarts = 0

    private var lastReadingAt: Date?
    private var startedAt: Date?

    /// How long the absolute altimeter may say nothing before it is
    /// restarted. Measured at one reading a second on a wrist.
    public var silenceTolerance: TimeInterval = 30
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    public init() {}

    public func start() {
        guard !isRunning else {
            Self.logger.notice("altimeter: start asked while already running")
            return
        }
        guard isAvailable else {
            Self.logger.notice("no barometer on this device; jump height will be unavailable")
            return
        }
        Self.logger.notice("altimeter: starting, Motion & Fitness \(self.authorizationDescription)")
        isRunning = true
        relativeAltitude = nil
        peakSinceRead = nil
        absoluteAltitude = nil
        absolutePeakSinceRead = nil
        lastError = nil
        relativeReadings = 0
        absoluteReadings = 0
        restarts = 0
        startedAt = Date()
        lastReadingAt = nil
        subscribe()
    }

    /// Install the handlers on fresh instances. `start` and `nudge` both come
    /// here; only `start` resets the session's counters.
    private func subscribe() {
        let altimeter = CMAltimeter()
        self.altimeter = altimeter
        switch CMAltimeter.authorizationStatus() {
        case .denied, .restricted:
            let status = authorizationDescription
            Self.logger.error("altimeter: Motion & Fitness \(status); no readings will arrive")
            onIssue?("Motion & Fitness access is \(status), so the altimeter could not be read and jump height comes from GPS. Settings ▸ Privacy & Security ▸ Motion & Fitness ▸ openWater.")
        case .notDetermined:
            // The prompt is about to appear, on a screen Water Lock is about
            // to take. `requestAccess` at launch is what keeps it from
            // landing here; if it does, `finish` says so.
            Self.logger.notice("altimeter: Motion & Fitness never asked; the prompt will show now")
        default:
            break
        }
        // Same `@Sendable` hazard as `MotionProvider`: the handler is imported
        // without Sendable, so a closure written inside this `@MainActor` class
        // would inherit main-actor isolation and then be called on the queue
        // below — which traps on a real device and never in the simulator,
        // where the sensor does not exist and the handler is never installed.
        altimeter.startRelativeAltitudeUpdates(to: queue) { @Sendable [weak self] data, error in
            guard let data else {
                if let error {
                    Self.logger.error("altimeter: \(error.localizedDescription)")
                    Task { @MainActor [weak self] in self?.note(error) }
                }
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
                self.relativeReadings += 1
                self.lastReadingAt = Date()
                if self.relativeReadings % 10 == 0 {
                    Self.logger.notice("barometer: \(self.relativeReadings) readings, now \(metres, format: .fixed(precision: 2)) m")
                }
            }
        }

        if #available(iOS 15, watchOS 8, *), CMAltimeter.isAbsoluteAltitudeAvailable() {
            let absoluteAltimeter = CMAltimeter()
            self.absoluteAltimeter = absoluteAltimeter
            absoluteAltimeter.startAbsoluteAltitudeUpdates(to: queue) { @Sendable [weak self] data, error in
                guard let data else {
                    if let error {
                        Self.logger.error("absolute altimeter: \(error.localizedDescription)")
                        Task { @MainActor [weak self] in self?.note(error) }
                    }
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
                    self.absoluteReadings += 1
                    self.lastReadingAt = Date()
                    if self.absoluteReadings % 10 == 0 {
                        Self.logger.notice("absolute altimeter: \(self.absoluteReadings) readings, now \(metres, format: .fixed(precision: 2)) m")
                    }
                }
            }
        } else {
            Self.logger.notice("absolute altimeter not available on this device")
        }
    }

    /// Restart the altimeter if it has said nothing for `silenceTolerance`.
    ///
    /// Called on every fix by the recorder. The one thing known about the
    /// silent hour is that a running subscription delivered nothing; a new
    /// subscription is the only remedy available from inside the app, and it
    /// costs nothing when the readings are arriving.
    public func nudge(now: Date = Date()) {
        guard isRunning, isAuthorized, let began = startedAt else { return }
        let since = now.timeIntervalSince(lastReadingAt ?? began)
        guard since > silenceTolerance else { return }
        restarts += 1
        Self.logger.error("altimeter silent for \(Int(since)) s; restarting (\(self.restarts) so far)")
        unsubscribe()
        startedAt = now
        lastReadingAt = nil
        subscribe()
    }

    private func unsubscribe() {
        altimeter?.stopRelativeAltitudeUpdates()
        if #available(iOS 15, watchOS 8, *) { absoluteAltimeter?.stopAbsoluteAltitudeUpdates() }
        altimeter = nil
        absoluteAltimeter = nil
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        unsubscribe()
        Self.logger.notice("altimeter stopped after \(self.relativeReadings) relative and \(self.absoluteReadings) absolute readings, \(self.restarts) restarts")
        startedAt = nil
        relativeAltitude = nil
        peakSinceRead = nil
        absoluteAltitude = nil
        absolutePeakSinceRead = nil
    }

    /// The altimeter's error, kept and said once. CoreMotion repeats an
    /// authorization error on every delivery it would have made.
    private func note(_ error: Error) {
        guard lastError == nil else { return }
        lastError = error.localizedDescription
        onIssue?("The altimeter refused: \(error.localizedDescription). Jump height comes from GPS for this session.")
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
