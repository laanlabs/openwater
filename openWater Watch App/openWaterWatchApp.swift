import OpenWaterCore
import SwiftUI

@main
struct openWaterWatchApp: App {

    @State private var recorder = SessionRecorder()
    @State private var settings = WatchSettings()
    @State private var sync = WatchSyncClient()

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
                }
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

    private func persist() {
        defaults.set(units.speed.rawValue, forKey: "speedUnit")
        defaults.set(units.distance.rawValue, forKey: "distanceUnit")
        defaults.set(lastSport.rawValue, forKey: "lastSport")
        defaults.set(keepScreenBright, forKey: "keepScreenBright")
        defaults.set(autoPause, forKey: "autoPause")
        defaults.set(recordHaptics, forKey: "recordHaptics")
        defaults.set(extendedDisplay, forKey: "extendedDisplay")
        defaults.set(extendedDisplayChangedAt, forKey: "extendedDisplayChangedAt")
    }
}
