import CoreLocation
import Foundation
import OpenWaterCore
import WatchKit
import os

/// The watch's recorder.
///
/// Everything that produces a *number* lives in `RecordingEngine`, shared with
/// the phone so the two can never disagree. What is left here is genuinely
/// watch-specific: the `HKWorkoutSession` that keeps the app alive with the
/// screen off, Water Lock, and haptics.
///
/// The workout session is not a nicety — it is the mechanism. A merely
/// backgrounded watch app stops receiving location within seconds of the wrist
/// dropping; one running an active workout keeps its sensors alive for hours.
@MainActor
@Observable
final class SessionRecorder {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "Recorder")

    let engine: RecordingEngine
    let location = LocationProvider()
    let motion = MotionProvider()
    let barometer = BarometerProvider()
    let workout = WorkoutController()

    /// Mirrors the engine so views can switch on it without reaching through.
    var state: RecordingEngine.State { engine.state }
    var metrics: LiveMetrics { engine.metrics }
    var sport: Sport { engine.sport }
    var recordsHit: [LiveRecord] { engine.recordsHit }
    var recoverable: RecordingEngine.RecoverableSession? { engine.recoverable }

    var wind: Wind? {
        get { engine.wind }
        set { engine.wind = newValue }
    }

    var allTimeBests: [SpeedCategory: Double] {
        get { engine.allTimeBests }
        set { engine.allTimeBests = newValue }
    }

    var autoPauseEnabled: Bool {
        get { engine.autoPauseEnabled }
        set { engine.autoPauseEnabled = newValue }
    }

    /// Whether personal-best haptics fire.
    var recordHaptics = true

    private var routeLocations: [CLLocation] = []

    init() {
        engine = RecordingEngine(
            deviceModel: WKInterfaceDevice.current().model,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )

        location.onFix = { [weak self] point in
            self?.ingest(point)
        }
        engine.onRecord = { [weak self] _ in
            // Nobody is reading their wrist at 25 knots, so a genuine all-time
            // best has to be felt rather than displayed.
            guard self?.recordHaptics == true else { return }
            WKInterfaceDevice.current().play(.notification)
        }
        engine.onAutoPause = {
            WKInterfaceDevice.current().play(.stop)
        }
    }

    func prepare() async {
        location.requestAuthorization()
        await workout.requestAuthorization()
        await engine.checkForRecoverableSession()
    }

    /// Warm the receiver up before recording, so the first fixes of a session
    /// are not the worst ones.
    func warmUpSensors() {
        location.warmUp()
    }

    /// Give the receiver back when the chooser goes away. A session in progress
    /// is untouched.
    func stopWarmUp() {
        location.endWarmUp()
    }

    // MARK: - Control

    func start(sport: Sport) {
        guard engine.state == .idle else { return }
        routeLocations.removeAll()

        // Before the receiver is asked for anything, so the first fixes of the
        // session already come at the rate this sport needs.
        location.configure(for: sport)

        let startDate = Date()
        engine.start(sport: sport, at: startDate)

        workout.onIssue = { [engine] text in engine.noteIssue(text) }
        // Water Lock, at the moment watchOS allows it. Asking here, before
        // the workout is active, was silently ignored on every session this
        // app has recorded — see `WaterLock`.
        workout.onRunning = {
            Task { @MainActor in
                let locked = await WaterLock.engage(after: [0, 0.5, 1.5, 3])
                if !locked {
                    Self.logger.error("water lock did not engage at session start")
                }
            }
        }
        do {
            try workout.start(sport: sport, startDate: startDate)
        } catch {
            // No Health authorization costs heart rate and the Health entry,
            // not the track — and it costs the sensors staying alive when the
            // wrist drops, which is the part a rider notices. Said on the
            // session, not just here.
            Self.logger.error("workout session failed to start: \(error.localizedDescription)")
            engine.noteIssue("The workout session could not start: \(error.localizedDescription). Without it there is no heart rate, and recording stops when the wrist drops.")
        }

        motion.start()
        barometer.start()
        location.start()

        // Water Lock is engaged from `workout.onRunning`, above — the only
        // moment watchOS will grant it. Asking here never worked.
        WKInterfaceDevice.current().play(.start)
    }

    func pause() {
        guard engine.state == .recording else { return }
        engine.pause()
        location.stop()
        motion.stop()
        // Left running through a pause would be wrong in the other direction:
        // the rider walks up the beach and the baseline moves with them.
        barometer.stop()
        workout.pause()
        WKInterfaceDevice.current().play(.stop)
    }

    func resume() {
        guard engine.state == .paused else { return }
        engine.resume()
        location.start()
        motion.start()
        barometer.start()
        workout.resume()
        WKInterfaceDevice.current().play(.start)
    }

    /// End the session, saving it before anything else is allowed to fail.
    ///
    /// `save` writes the session down and says whether it is safe; the engine
    /// keeps the crash log until it says yes.
    ///
    /// HealthKit is deliberately settled *afterwards*. Closing a workout and
    /// inserting its route is the slowest part of stopping and the part most
    /// able to fail or stall, and it was previously awaited before the session
    /// was built at all — so a wrist dropped at the wrong moment took the whole
    /// session with the Health entry. Losing the Health entry costs a duplicate
    /// row in Fitness. Losing the session costs the session.
    @discardableResult
    func finish(save: (Session) -> Bool) async -> Session? {
        location.stop()
        motion.stop()
        barometer.stop()

        let end = Date()
        let session = await engine.finish(at: end, save: save)

        await workout.finish(endDate: end, route: routeLocations)

        if session != nil { WKInterfaceDevice.current().play(.success) }
        return session
    }

    func discard() {
        location.stop()
        motion.stop()
        barometer.stop()
        workout.discard()
        engine.discard()
        routeLocations.removeAll()
    }

    func recover(_ candidate: RecordingEngine.RecoverableSession,
                 save: (Session) -> Bool) async -> Session? {
        await engine.recover(candidate, save: save)
    }

    func dismissRecovery() async {
        await engine.dismissRecovery()
    }

    // MARK: - Ingest

    /// Merge the motion and heart-rate channels onto the fix, so everything
    /// downstream sees one coherent sample per second.
    private func ingest(_ raw: TrackPoint) {
        var point = raw
        if motion.isRunning {
            point.verticalAccelSD = motion.latest.verticalAccelSD
            point.verticalAccelPeak = motion.latest.verticalAccelPeak
            point.cadence = motion.latest.cadence
        }
        // The *highest* reading since the last fix, not the reading at this
        // one. A jump's apex falls between fixes as often as on one, and the
        // barometer is sampling throughout — so asking it for the peak is free
        // and asking it for the instant throws the jump away.
        point.baroAltitude = barometer.takePeak()
        point.absoluteAltitude = barometer.takeAbsolutePeak()
        point.heartRate = workout.heartRate

        engine.ingest(point)

        if point.hasValidPosition, point.horizontalAccuracy >= 0, point.horizontalAccuracy < 50 {
            routeLocations.append(CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                ),
                altitude: point.altitude ?? 0,
                horizontalAccuracy: point.horizontalAccuracy,
                verticalAccuracy: point.verticalAccuracy ?? -1,
                course: point.course ?? -1,
                speed: point.speed ?? -1,
                timestamp: point.timestamp
            ))
        }
    }
}
