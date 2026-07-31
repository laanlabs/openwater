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

    private let defaults = UserDefaults.standard

    init() {
        let speed = defaults.string(forKey: "speedUnit").flatMap(SpeedUnit.init(rawValue:)) ?? .knots
        let distance = defaults.string(forKey: "distanceUnit").flatMap(DistanceUnit.init(rawValue:)) ?? .metric
        units = UnitPreferences(speed: speed, distance: distance)
        lastSport = defaults.string(forKey: "lastSport").flatMap(Sport.init(rawValue:)) ?? .wingfoil
        keepScreenBright = defaults.bool(forKey: "keepScreenBright")
        autoPause = defaults.bool(forKey: "autoPause")
        recordHaptics = defaults.object(forKey: "recordHaptics") as? Bool ?? true
    }

    private func persist() {
        defaults.set(units.speed.rawValue, forKey: "speedUnit")
        defaults.set(units.distance.rawValue, forKey: "distanceUnit")
        defaults.set(lastSport.rawValue, forKey: "lastSport")
        defaults.set(keepScreenBright, forKey: "keepScreenBright")
        defaults.set(autoPause, forKey: "autoPause")
        defaults.set(recordHaptics, forKey: "recordHaptics")
    }
}
