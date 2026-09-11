import OpenWaterCore
import SwiftUI
import WatchKit

@main
struct openWaterWatchApp: App {

    @State private var recorder = SessionRecorder()
    @State private var settings = WatchSettings()
    @State private var sync = WatchSyncClient()

    @Environment(\.scenePhase) private var scenePhase

    /// Water Lock is asked for once per launch, not once per activation.
    ///
    /// Only an attempt made while the app is genuinely frontmost counts —
    /// `enableWaterLock()` is ignored otherwise and says nothing about it, so a
    /// try from a scene that had not yet become active would burn the one
    /// chance and leave the wrist unlocked.
    @State private var hasLockedForLaunch = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(recorder)
                .environment(settings)
                .environment(sync)
                .task {
                    await recorder.prepare()
                    sync.activate()

                    // Screenshot capture: begin a real session so the live
                    // screens have genuine data. No-op without the argument.
                    if WatchScreenshotRoute.shouldAutoStart {
                        recorder.start(sport: WatchScreenshotRoute.sport ?? settings.lastSport)
                    }
                    // The phone owns the record book, so the watch asks for it
                    // at launch. Without it a live "personal best" alert would
                    // only ever mean "best so far today", which is not the same
                    // thing and would cheapen the haptic.
                    sync.requestBests { bests in
                        recorder.allTimeBests = bests
                    }
                    // The phone can carry this preference too. It only lands
                    // if the phone's change is newer than the one made here,
                    // so a switch flipped on the wrist is not undone by a
                    // context the phone queued before it.
                    sync.onExtendedDisplay = { value, changedAt in
                        settings.applyPushedExtendedDisplay(value, changedAt: changedAt)
                    }
                    sync.onStartWaterLocked = { value, changedAt in
                        settings.applyPushedStartWaterLocked(value, changedAt: changedAt)
                    }
                    sync.recordingHeartRate = {
                        (recorder.state != .idle, recorder.workout.heartRate)
                    }

                    // The scene is usually still becoming active when this
                    // runs, in which case the phase change below does it.
                    lockForLaunch(phase: scenePhase)
                }
                .onChange(of: scenePhase) { _, phase in
                    lockForLaunch(phase: phase)
                }
        }
    }

    /// Come up already locked, so the first thing the water touches is a screen
    /// that ignores it.
    ///
    /// The app is opened with a wet wrist, from a board, in spray — and until
    /// the rider has picked a sport there is no session holding Water Lock for
    /// them. That gap is where a stray drop finds the crown, the app leaves the
    /// screen, and a session that was about to be recorded never is.
    ///
    /// The cost is honest: touch does nothing until the rider turns the Digital
    /// Crown to unlock. That is one deliberate gesture against an accidental
    /// one, which is the trade this screen wants — but riders who disagree turn
    /// it off in Settings.
    private func lockForLaunch(phase: ScenePhase) {
        guard !hasLockedForLaunch, phase == .active else { return }
        hasLockedForLaunch = true
        // A capture run drives the app by taps; locking would end the run.
        guard settings.startWaterLocked, !WatchScreenshotRoute.shouldAutoStart else { return }

        // Best effort, and honestly so. watchOS grants Water Lock only during
        // an active workout or location session; before a sport is tapped the
        // only candidate is the GPS warm-up the start screen runs, and whether
        // the system counts that is not documented. So this asks over ten
        // seconds, checking each time, and the session's own lock — engaged
        // the moment the workout is running — is the one that is guaranteed.
        Task { @MainActor in
            await WaterLock.engage(after: [0.5, 1, 2, 3, 4])
        }
    }
}

/// User preferences that live on the watch.
///
/// Deliberately a small, independent store rather than a mirror of the phone's
/// settings: the watch must be fully usable by someone who has never opened the
/// phone app, or even installed it.
@MainActor
@Observable
final class WatchSettings {

    var units: UnitPreferences {
        didSet { persist() }
    }

    var lastSport: Sport {
        didSet { persist() }
    }

    /// Keep the screen at full brightness rather than dimming to always-on.
    /// Costs battery; some riders want it anyway.
    var keepScreenBright: Bool {
        didSet { persist() }
    }

    var autoPause: Bool {
        didSet { persist() }
    }

    /// Haptic when a personal best falls.
    var recordHaptics: Bool {
        didSet { persist() }
    }

    /// Show every live page rather than the two that matter with wet hands.
    ///
    /// Off by default. Seven pages is a lot to swipe past on a wrist that is
    /// cold, wet and moving, and the two a rider actually needs mid-session are
    /// the controls and the big number — the rest are for reading afterwards,
    /// or for people who genuinely want them.
    ///
    /// Set on the wrist, this also stamps `extendedDisplayChangedAt`, which is
    /// what lets a change made here survive a later push from the phone.
    var extendedDisplay: Bool {
        didSet {
            extendedDisplayChangedAt = Date()
            persist()
        }
    }

    /// Engage Water Lock as soon as the app opens, before a session exists.
    ///
    /// On by default. Everything about this app happens on water, and the few
    /// seconds between opening it and picking a sport are the only ones where
    /// nothing is guarding the screen.
    ///
    /// Stamped when set here, like `extendedDisplay`, so a change made on the
    /// wrist survives a later push from the phone.
    var startWaterLocked: Bool {
        didSet {
            startWaterLockedChangedAt = Date()
            persist()
        }
    }

    /// When this watch last set `startWaterLocked` itself.
    private(set) var startWaterLockedChangedAt: Date

    /// When this watch last set `extendedDisplay` itself.
    ///
    /// The phone can push the same preference, and the two can disagree — a
    /// rider who flips it on the wrist mid-session must not have it flipped
    /// back by an application context the phone queued an hour ago. Both sides
    /// carry a stamp and the newer one wins, so "wins" is about which change is
    /// more recent rather than which device it came from.
    private(set) var extendedDisplayChangedAt: Date

    private let defaults = UserDefaults.standard

    init() {
        let speed = defaults.string(forKey: "speedUnit").flatMap(SpeedUnit.init(rawValue:)) ?? .knots
        let distance = defaults.string(forKey: "distanceUnit").flatMap(DistanceUnit.init(rawValue:)) ?? .metric
        units = UnitPreferences(speed: speed, distance: distance)
        lastSport = defaults.string(forKey: "lastSport").flatMap(Sport.init(rawValue:)) ?? .wingfoil
        keepScreenBright = defaults.bool(forKey: "keepScreenBright")
        autoPause = defaults.bool(forKey: "autoPause")
        recordHaptics = defaults.object(forKey: "recordHaptics") as? Bool ?? true
        extendedDisplay = defaults.bool(forKey: "extendedDisplay")
        extendedDisplayChangedAt =
            defaults.object(forKey: "extendedDisplayChangedAt") as? Date ?? .distantPast
        // Defaults on, so `bool(forKey:)` and its false-when-absent is the
        // wrong reader for it.
        startWaterLocked = defaults.object(forKey: "startWaterLocked") as? Bool ?? true
        startWaterLockedChangedAt =
            defaults.object(forKey: "startWaterLockedChangedAt") as? Date ?? .distantPast
    }

    /// Take the phone's value, if its change is newer than this watch's own.
    ///
    /// Returns whether it was applied, so the caller can tell "ignored because
    /// stale" from "nothing to do".
    @discardableResult
    func applyPushedExtendedDisplay(_ value: Bool, changedAt: Date) -> Bool {
        guard SyncedPreference.accepts(incoming: changedAt,
                                       over: extendedDisplayChangedAt) else { return false }
        extendedDisplay = value
        // `extendedDisplay` stamped *now* on the way through its setter, which
        // would make this watch look like the most recent author of a change it
        // merely accepted. Carry the phone's stamp instead, so a third device —
        // or the phone again — still compares against the real edit time.
        extendedDisplayChangedAt = changedAt
        persist()
        return true
    }

    /// Take the phone's value, if its change is newer than this watch's own.
    @discardableResult
    func applyPushedStartWaterLocked(_ value: Bool, changedAt: Date) -> Bool {
        guard SyncedPreference.accepts(incoming: changedAt,
                                       over: startWaterLockedChangedAt) else { return false }
        startWaterLocked = value
        // Carry the phone's stamp rather than the one the setter just wrote,
        // for the same reason `applyPushedExtendedDisplay` does.
        startWaterLockedChangedAt = changedAt
        persist()
        return true
    }

    private func persist() {
        defaults.set(units.speed.rawValue, forKey: "speedUnit")
        defaults.set(units.distance.rawValue, forKey: "distanceUnit")
        defaults.set(lastSport.rawValue, forKey: "lastSport")
        defaults.set(keepScreenBright, forKey: "keepScreenBright")
        defaults.set(autoPause, forKey: "autoPause")
        defaults.set(recordHaptics, forKey: "recordHaptics")
        defaults.set(extendedDisplay, forKey: "extendedDisplay")
        defaults.set(extendedDisplayChangedAt, forKey: "extendedDisplayChangedAt")
        defaults.set(startWaterLocked, forKey: "startWaterLocked")
        defaults.set(startWaterLockedChangedAt, forKey: "startWaterLockedChangedAt")
    }
}
