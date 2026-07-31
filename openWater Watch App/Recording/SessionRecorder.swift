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
        engine.checkForRecoverableSession()
    }

    /// Warm the receiver up before recording, so the first fixes of a session
    /// are not the worst ones.
    func warmUpSensors() {
        location.warmUp()
    }

    // MARK: - Control

    func start(sport: Sport) {
        guard engine.state == .idle else { return }
        routeLocations.removeAll()

        let startDate = Date()
        engine.start(sport: sport, at: startDate)

        do {
            try workout.start(sport: sport, startDate: startDate)
        } catch {
            // No Health authorization costs heart rate and the Health entry,
            // not the track.
            Self.logger.error("workout session failed to start: \(error.localizedDescription)")
        }

        motion.start()
        location.start()

        // Water Lock stops spray triggering taps, and ejects water from the
        // speaker afterwards. On the water it is not optional.
        WKInterfaceDevice.current().enableWaterLock()
        WKInterfaceDevice.current().play(.start)
    }

    func pause() {
        guard engine.state == .recording else { return }
        engine.pause()
        location.stop()
        motion.stop()
        workout.pause()
        WKInterfaceDevice.current().play(.stop)
    }

    func resume() {
        guard engine.state == .paused else { return }
        engine.resume()
        location.start()
        motion.start()
        workout.resume()
        WKInterfaceDevice.current().play(.start)
    }

    @discardableResult
    func finish() async -> Session? {
        location.stop()
        motion.stop()

        let end = Date()
        await workout.finish(endDate: end, route: routeLocations)

        let session = engine.finish(at: end)
        if session != nil { WKInterfaceDevice.current().play(.success) }
        return session
    }

    func discard() {
        location.stop()
        motion.stop()
        workout.discard()
        engine.discard()
        routeLocations.removeAll()
    }

    func recover(_ candidate: RecordingEngine.RecoverableSession) -> Session? {
        engine.recover(candidate)
    }

    func dismissRecovery() {
        engine.dismissRecovery()
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
