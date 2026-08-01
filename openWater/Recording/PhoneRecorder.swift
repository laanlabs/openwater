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

    var state: RecordingEngine.State { engine.state }
    var metrics: LiveMetrics { engine.metrics }
    var sport: Sport { engine.sport }
    var recordsHit: [LiveRecord] { engine.recordsHit }
    var recoverable: RecordingEngine.RecoverableSession? { engine.recoverable }

    /// The track so far, reduced for drawing.
    ///
    /// A three-hour session is ten thousand fixes and the live map redraws on
    /// every one of them; at a few hundred points the line looks identical and
    /// the redraw is free. Uniform sampling, because this is about the shape.
    var trackCoordinates: [CLLocationCoordinate2D] {
        let points = engine.recordedPoints
        guard points.count > 1 else { return [] }
        let step = max(1, points.count / 400)
        var result = stride(from: 0, to: points.count, by: step)
            .filter { points[$0].hasValidPosition }
            .map { points[$0].clCoordinate }
        if let last = points.last, last.hasValidPosition { result.append(last.clCoordinate) }
        return result
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
    }

    // MARK: - Setup

    func prepare() {
        location.requestAuthorization()
        engine.checkForRecoverableSession()
    }

    /// Warm the receiver so the first fixes are not the worst ones.
    func warmUpSensors() {
        location.warmUp()
    }

    // MARK: - Control

    func start(sport: Sport) {
        guard engine.state == .idle else { return }

        // Before the receiver is asked for anything, so the first fixes of the
        // session already come at the rate this sport needs.
        location.configure(for: sport)
        engine.start(sport: sport)
        motion.start()
        location.start()

        // Only while actually recording — a phone strapped to a mast is not
        // being read, and an always-on screen is the fastest way to end a
        // session early.
        UIApplication.shared.isIdleTimerDisabled = true

        notificationHaptics.prepare()
        impactHaptics.prepare()
        impactHaptics.impactOccurred()
    }

    func pause() {
        guard engine.state == .recording else { return }
        engine.pause()
        location.stop()
        motion.stop()
        impactHaptics.impactOccurred()
    }

    func resume() {
        guard engine.state == .paused else { return }
        engine.resume()
        location.start()
        motion.start()
        impactHaptics.impactOccurred()
    }

    @discardableResult
    func finish() -> Session? {
        location.stop()
        motion.stop()
        UIApplication.shared.isIdleTimerDisabled = false

        let session = engine.finish()
        if session != nil { notificationHaptics.notificationOccurred(.success) }
        return session
    }

    func discard() {
        location.stop()
        motion.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        engine.discard()
    }

    func recover(_ candidate: RecordingEngine.RecoverableSession) -> Session? {
        engine.recover(candidate)
    }

    func dismissRecovery() {
        engine.dismissRecovery()
    }

    /// Push everything to disk. Called when the app is backgrounded, so a
    /// termination while recording loses seconds rather than the session.
    func flush() {
        engine.flush()
    }

    // MARK: - Ingest

    private func ingest(_ raw: TrackPoint) {
        var point = raw
        if motion.isRunning {
            point.verticalAccelSD = motion.latest.verticalAccelSD
            point.verticalAccelPeak = motion.latest.verticalAccelPeak
            point.cadence = motion.latest.cadence
        }
        engine.ingest(point)
    }
}
