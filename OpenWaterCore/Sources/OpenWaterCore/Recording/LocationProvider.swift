import CoreLocation
import Foundation
import os

/// Wraps `CLLocationManager` and hands out fixes as `TrackPoint`s.
///
/// Two settings do most of the work here:
///
/// - `desiredAccuracy = .bestForNavigation` keeps the receiver in its
///   highest-rate mode, which is what supplies the Doppler speed the whole app
///   depends on. Anything less and `CLLocation.speed` starts arriving as −1.
/// - `distanceFilter = .none` means every fix is delivered rather than only
///   those a certain distance apart. A distance filter would silently destroy
///   the uniform sampling the window metrics assume.
///
/// The receiver runs in exactly two modes, and the difference between them is
/// the whole of this class's contract:
///
/// - **Recording** (`start()` … `stop()`) holds background updates, because a
///   session has to survive the screen locking and the phone going in a pocket.
/// - **Warming up** (`warmUp()` … `endWarmUp()`) is foreground-only and
///   time-limited. It exists so the accuracy shown on the pre-session screen is
///   real, which nobody reads from another app.
///
/// Nothing else may hold the receiver. Background GPS is a promise that a
/// session is being written down.
@MainActor
@Observable
public final class LocationProvider: NSObject {

    nonisolated private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "Location")

    private let manager = CLLocationManager()

    /// Called for each accepted fix.
    public var onFix: ((TrackPoint) -> Void)?

    public private(set) var authorization: CLAuthorizationStatus = .notDetermined
    public private(set) var latestAccuracy: Double = -1
    public private(set) var isRunning = false

    /// Whether background updates are currently held.
    ///
    /// Mirrors what was last set on the manager, so the state can be asserted
    /// and reported rather than only inferred from a battery graph.
    public private(set) var usesBackgroundUpdates = false

    /// True once at least one fix has arrived with usable accuracy — the signal
    /// the UI uses to say "ready" rather than letting a rider start recording
    /// while the receiver is still cold.
    public private(set) var hasFix = false

    /// Most recent position, whether or not a session is recording.
    ///
    /// Used by anything that needs to know roughly where the rider is before
    /// they start — the map, and the weather lookup.
    public private(set) var lastCoordinate: Geo.Coordinate?

    /// Most recent Doppler speed, m/s, updated on every fix — recording or
    /// not, so a live speed readout works without starting a session. `-1`
    /// until the receiver reports one.
    public private(set) var lastSpeed: Double = -1

    /// Whether the host app declares the `location` background mode.
    nonisolated static let declaresBackgroundLocationMode: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }()

    /// Exposed so the UI can warn that a session will stop when backgrounded,
    /// rather than letting a rider discover it after a three-hour downwinder.
    public nonisolated var supportsBackgroundRecording: Bool {
        Self.declaresBackgroundLocationMode
    }

    public override init() {
        super.init()
        manager.delegate = self
        apply(.init(accuracy: .navigation, activity: .otherNavigation))

        // The single most important line here.
        //
        // `pausesLocationUpdatesAutomatically` defaults to **true**. When iOS
        // decides the device has stopped moving it pauses the location stream
        // and calls `locationManagerDidPauseLocationUpdates` — and it is under
        // no obligation to ever resume. For a walking app that saves battery;
        // for this one it silently ends the recording, and the rider finds out
        // hours later that their session stops twenty minutes in.
        //
        // It misfires constantly on the water: sitting on the board between
        // runs, drifting, or waiting for a gust all look like "stationary" to a
        // heuristic tuned for someone who parked the car. Auto-pause is
        // something openWater decides for itself, from speed, with a threshold
        // the rider can see — not something CoreLocation does behind its back.
        #if os(iOS)
        manager.pausesLocationUpdatesAutomatically = false
        #endif
        // Background updates are *not* switched on here. See `start()`.
        if !Self.declaresBackgroundLocationMode {
            Self.logger.error(
                "Info.plist does not list \"location\" in UIBackgroundModes — recording will stop when the app is backgrounded."
            )
        }
        #if os(iOS)
        // The blue pill in the status bar, for whenever background updates are
        // actually on. Not optional in spirit: an app holding GPS in the
        // background while the rider is in Messages should say so, and it
        // doubles as the rider's own confirmation that the session is running.
        manager.showsBackgroundLocationIndicator = true
        #endif
        authorization = manager.authorizationStatus
    }

    // MARK: - Control

    /// Drive the receiver the way this sport needs it.
    ///
    /// Called before every session rather than once at launch: a rider who does
    /// a downwinder in the morning and a paddle in the evening should get the
    /// right trade-off for each, and the wrong one persisting from the last
    /// session is exactly the kind of thing nobody would ever notice was
    /// happening.
    public func configure(for sport: Sport) {
        apply(sport.locationProfile)
    }

    private func apply(_ profile: SportThresholds.LocationProfile) {
        switch profile.accuracy {
        case .navigation:
            // The mode that keeps Doppler speed coming. Anything less and
            // `CLLocation.speed` starts arriving as −1, which the whole app
            // depends on.
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        case .best:
            manager.desiredAccuracy = kCLLocationAccuracyBest
        }

        // A distance filter would silently destroy the even sampling every
        // window metric assumes, so it is off unless a profile asks otherwise —
        // and none of them do.
        manager.distanceFilter = profile.distanceFilter ?? kCLDistanceFilterNone

        switch profile.activity {
        case .otherNavigation: manager.activityType = .otherNavigation
        case .fitness: manager.activityType = .fitness
        }
    }

    public func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Start delivering fixes to `onFix`.
    ///
    /// This is the only thing that turns on background updates, and `stop()` is
    /// the only thing that turns them off. That pairing is the whole point: the
    /// permission used to be granted once at launch and never withdrawn, so the
    /// warm-up stream — started merely by opening the Record tab — kept the
    /// receiver alive in the background indefinitely, with the blue pill
    /// showing and the battery draining, for an app that was not recording
    /// anything. Background GPS is a promise that a session is being written
    /// down; holding it at any other time is taking something for nothing.
    public func start() {
        guard !isRunning else { return }
        endWarmUp(stoppingReceiver: false)
        isRunning = true
        if Self.declaresBackgroundLocationMode {
            manager.allowsBackgroundLocationUpdates = true
            usesBackgroundUpdates = true
        }
        manager.startUpdatingLocation()
        Self.logger.info("location updates started (background: \(self.usesBackgroundUpdates))")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.allowsBackgroundLocationUpdates = false
        usesBackgroundUpdates = false
        manager.stopUpdatingLocation()
        Self.logger.info("location updates stopped")
    }

    /// How long a warm-up runs before giving up on its own.
    ///
    /// Long enough to cover rigging up and reading the accuracy off the Record
    /// screen; short enough that an app left open on that screen does not hold
    /// the receiver all afternoon.
    public static let warmUpDuration: TimeInterval = 180

    private var warmUpTask: Task<Void, Never>?
    private var isWarmingUp = false

    /// Warm the receiver up before recording begins, so the first fixes of a
    /// session are not the worst ones.
    ///
    /// Foreground only, and time-limited. It exists to make the GPS readout on
    /// the pre-session screen honest, which is a foreground concern by
    /// definition — nobody is reading it from another app.
    public func warmUp() {
        guard !isRunning else { return }
        manager.allowsBackgroundLocationUpdates = false
        usesBackgroundUpdates = false
        isWarmingUp = true
        manager.startUpdatingLocation()
        Self.logger.info("warm-up started (foreground only)")

        warmUpTask?.cancel()
        warmUpTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.warmUpDuration))
            guard !Task.isCancelled else { return }
            self?.endWarmUp()
        }
    }

    /// Give up the receiver if it is only warming up.
    ///
    /// Called when the pre-session screen goes away and when the app leaves the
    /// foreground. A recording in progress is untouched.
    public func endWarmUp() {
        endWarmUp(stoppingReceiver: true)
    }

    private func endWarmUp(stoppingReceiver: Bool) {
        warmUpTask?.cancel()
        warmUpTask = nil
        guard isWarmingUp else { return }
        isWarmingUp = false
        if stoppingReceiver, !isRunning {
            manager.stopUpdatingLocation()
            Self.logger.info("warm-up ended")
        }
    }

    /// Kick the stream back into life after the system stopped it.
    func restart() {
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }
}

extension LocationProvider: CLLocationManagerDelegate {

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        Task { @MainActor in
            self.authorization = status
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let points = locations.map(TrackPoint.init(location:))
        let accuracies = locations.map(\.horizontalAccuracy)
        Task { @MainActor in
            if let last = accuracies.last {
                self.latestAccuracy = last
                if last >= 0, last < 30 { self.hasFix = true }
            }
            if let last = points.last, last.hasValidPosition {
                self.lastCoordinate = last.coordinate
            }
            if let speed = points.last?.speed, speed >= 0 {
                self.lastSpeed = speed
            }
            guard self.isRunning else { return }
            for point in points { self.onFix?(point) }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Self.logger.error("location failure: \(error.localizedDescription)")
    }

    #if os(iOS)
    /// iOS decided to pause the location stream.
    ///
    /// With `pausesLocationUpdatesAutomatically = false` this should never
    /// arrive, but it is the failure that silently ends a recording with no way
    /// for the rider to notice, so it is worth handling rather than trusting the
    /// flag. Restarting costs nothing if it never fires and saves the session if
    /// it does.
    public nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Self.logger.error("CoreLocation paused location updates — restarting")
        Task { @MainActor in
            // Restart through our own reference rather than the one handed to
            // the callback, which is isolated to the delegate's context.
            guard self.isRunning else { return }
            self.restart()
        }
    }

    public nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Self.logger.info("CoreLocation resumed location updates")
    }
    #endif
}

extension TrackPoint {
    /// Bridge a `CLLocation` into the platform-free model.
    ///
    /// The accuracy fields are carried across verbatim, negatives and all: a
    /// negative value is CoreLocation's way of saying "this channel is invalid",
    /// and flattening that to zero would tell the analysis layer the fix was
    /// perfect.
    public init(location: CLLocation) {
        self.init(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.courseAccuracy >= 0 ? location.course : nil,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speedAccuracy: location.speedAccuracy
        )
    }
}
