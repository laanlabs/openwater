import CoreLocation
import Foundation
import OpenWaterCore
import SwiftUI
import UIKit
import os

/// Records a session on the phone.
///
/// A thin shell over the same `RecordingEngine` the watch uses, so a session
/// recorded on a phone and one recorded on a wrist go through identical
/// filtering, identical window maths and identical detection. That matters:
/// personal bests have to be comparable across whichever device happened to be
/// to hand.
///
/// The differences from the watch are all platform, not analysis:
///
/// - **Staying alive.** watchOS needs an `HKWorkoutSession`; iOS just needs the
///   `location` background mode and `allowsBackgroundLocationUpdates`, which
///   `LocationProvider` already sets.
/// - **The screen.** A phone in a pocket or on a mast is not being read, so the
///   idle timer is disabled only while recording and restored afterwards —
///   leaving it off would flatten the battery on a device that is not even
///   being looked at.
/// - **Haptics** come from `UIFeedbackGenerator` rather than `WKInterfaceDevice`.
@MainActor
@Observable
final class PhoneRecorder {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "PhoneRecorder")

    let engine: RecordingEngine
    let location = LocationProvider()
    let motion = MotionProvider()
    let barometer = BarometerProvider()

    var state: RecordingEngine.State { engine.state }
    var metrics: LiveMetrics { engine.metrics }
    var sport: Sport { engine.sport }
    var recordsHit: [LiveRecord] { engine.recordsHit }
    var recoverable: RecordingEngine.RecoverableSession? { engine.recoverable }

    /// The track so far, reduced for drawing, in one piece per stretch the
    /// receiver was reporting — see `Track.drawableGap`.
    ///
    /// A three-hour session is ten thousand fixes and the live map redraws on
    /// every one of them; at a few hundred points the line looks identical and
    /// the redraw is free. Uniform sampling, because this is about the shape.
    var trackPieces: [[CLLocationCoordinate2D]] {
        engine.recordedPoints.polylinePieces(budget: 400)
    }

    /// Optional name and spot set before starting, carried into the session.
    var title: String? {
        get { engine.title }
        set { engine.title = newValue }
    }

    var spotName: String? {
        get { engine.spotName }
        set { engine.spotName = newValue }
    }

    var wind: Wind? {
        get { engine.wind }
        set { engine.wind = newValue }
    }

    var swellHeight: Double? {
        get { engine.swellHeight }
        set { engine.swellHeight = newValue }
    }

    var swellDirection: Double? {
        get { engine.swellDirection }
        set { engine.swellDirection = newValue }
    }

    var allTimeBests: [SpeedCategory: Double] {
        get { engine.allTimeBests }
        set { engine.allTimeBests = newValue }
    }

    var autoPauseEnabled: Bool {
        get { engine.autoPauseEnabled }
        set { engine.autoPauseEnabled = newValue }
    }

    private let notificationHaptics = UINotificationFeedbackGenerator()
    private let impactHaptics = UIImpactFeedbackGenerator(style: .medium)

    init() {
        engine = RecordingEngine(
            deviceModel: UIDevice.current.model,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )

        location.onFix = { [weak self] point in
            self?.ingest(point)
        }
        engine.onRecord = { [weak self] _ in
            self?.notificationHaptics.notificationOccurred(.success)
        }
        engine.onAutoPause = { [weak self] in
            self?.impactHaptics.impactOccurred()
        }
        engine.onAutoResume = { [weak self] in
            self?.impactHaptics.impactOccurred()
        }
    }

    // MARK: - Setup

    /// - Parameter isAlreadySaved: whether the library holds this session, so
    ///   a log left behind by a save that landed is cleaned up, not offered.
    func prepare(isAlreadySaved: (UUID) -> Bool = { _ in false }) async {
        location.requestAuthorization()
        await engine.checkForRecoverableSession(isAlreadySaved: isAlreadySaved)
    }

    /// Warm the receiver so the first fixes are not the worst ones.
    ///
    /// Foreground only — see `LocationProvider.warmUp()`. Paired with
    /// `stopWarmUp()`, which every caller must make on the way out.
    func warmUpSensors() {
        location.warmUp()
    }

    /// Give the receiver back when nobody is looking at it. A session in
    /// progress is untouched.
    func stopWarmUp() {
        location.endWarmUp()
    }

    // MARK: - Control

    func start(sport: Sport) {
        guard engine.state == .idle else { return }

        // Before the receiver is asked for anything, so the first fixes of the
        // session already come at the rate this sport needs.
        location.configure(for: sport)
        engine.start(sport: sport)
        motion.start()
        barometer.start()
        location.start()

        // Only while actually recording — a phone strapped to a mast is not
        // being read, and an always-on screen is the fastest way to end a
        // session early.
        UIApplication.shared.isIdleTimerDisabled = true
        // And the other half of keeping the screen on: a screen that is on
        // in a wetsuit pocket is a screen being tapped by the wetsuit. The
        // proximity sensor is what iOS uses to blank the display against a
        // cheek on a call, and it does the same against a chest — the screen
        // goes dark and ignores touches until the phone comes out again. A
        // rider lost seventy-one minutes of a session to Pause and Resume
        // taps nobody made.
        UIDevice.current.isProximityMonitoringEnabled = true

        notificationHaptics.prepare()
        impactHaptics.prepare()
        impactHaptics.impactOccurred()
    }

    /// Stop the clock. The receiver and the motion sensors stay on.
    ///
    /// They used to stop here, which made a pause the one thing in the app
    /// that threw fixes away for good. Now the engine keeps every fix that
    /// arrives while paused and cuts the stretch from the session when it is
    /// built — see `RecordedPause` — so a pause costs the rider nothing but a
    /// visit to Trim if it was not meant. The price is the receiver running
    /// through a break on the beach, which is the price the trim model has
    /// always been happy to pay.
    func pause() {
        guard engine.state == .recording else { return }
        engine.pause(cause: .rider)
        impactHaptics.impactOccurred()
    }

    func resume() {
        guard engine.state == .paused else { return }
        engine.resume()
        impactHaptics.impactOccurred()
    }

    /// End the session, saving it before the crash log is released.
    ///
    /// `save` writes the session into the library and says whether it landed;
    /// the engine keeps the log until it does, so a failed write leaves the
    /// session recoverable rather than gone.
    @discardableResult
    func finish(save: (Session) -> Bool) async -> Session? {
        if location.silentRestarts > 0 {
            engine.noteIssue(
                "The receiver stopped reporting \(location.silentRestarts == 1 ? "once" : "\(location.silentRestarts) times") and was restarted after a minute of silence each time."
            )
        }
        location.stop()
        motion.stop()
        barometer.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isProximityMonitoringEnabled = false

        let session = await engine.finish(save: save)
        if session != nil { notificationHaptics.notificationOccurred(.success) }
        return session
    }

    func discard() {
        location.stop()
        motion.stop()
        barometer.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isProximityMonitoringEnabled = false
        engine.discard()
    }

    func recover(_ candidate: RecordingEngine.RecoverableSession,
                 save: (Session) -> Bool) async -> Session? {
        await engine.recover(candidate, save: save)
    }

    func dismissRecovery() async {
        await engine.dismissRecovery()
    }

    /// Push everything to disk. Called when the app is backgrounded, so a
    /// termination while recording loses seconds rather than the session.
    func flush() {
        engine.flush()
    }

    /// The app left the foreground.
    ///
    /// Recording carries on — that is what the background mode is for. Anything
    /// else gives the receiver up: a warm-up left running was the reason the
    /// blue location pill stayed lit, and the battery kept draining, for an app
    /// that was not recording a thing.
    func enteredBackground() {
        flush()
        if engine.state == .idle { location.endWarmUp() }
    }

    // MARK: - Ingest

    private func ingest(_ raw: TrackPoint) {
        var point = raw
        if motion.isRunning {
            point.verticalAccelSD = motion.latest.verticalAccelSD
            point.verticalAccelPeak = motion.latest.verticalAccelPeak
            point.verticalAccelSamples = motion.takeSamples()
            point.cadence = motion.latest.cadence
        }
        // Same as the watch: the highest reading since the last fix, so a
        // jump's apex between fixes is kept. Recorded for the comparison that
        // will decide whether the barometer is trusted; not yet read by the
        // detector — see `JumpDetector.trustsBarometer`. A phone in a vest
        // pocket rides the same jump the board does.
        point.baroAltitude = barometer.takePeak()
        point.absoluteAltitude = barometer.takeAbsolutePeak()
        engine.ingest(point)
    }
}
