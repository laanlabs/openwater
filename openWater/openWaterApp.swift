import OpenWaterCore
import OpenWaterSpots
import SwiftData
import SwiftUI
import os

@main
struct openWaterApp: App {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "App")

    private let container: ModelContainer
    @State private var library: SessionLibrary
    @State private var sync: PhoneSyncClient
    @State private var settings = AppSettings()
    @State private var recorder = PhoneRecorder()
    @State private var countdown = RaceCountdown()
    @State private var spotGuide: SpotGuideStore
    @State private var routeNamer: RouteNamer
    @State private var plannedRoutes: RouteStore

    @Environment(\.scenePhase) private var scenePhase

    /// Portrait is the app's shape; a map on its side is the one exception.
    /// UIKit asks the delegate, not the Info.plist, once the plist has locked
    /// the phone to portrait — see `OrientationGate`.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let container: ModelContainer
        var ephemeral = false
        do {
            container = try ModelContainer(for: StoredSession.self)
        } catch {
            // A store that will not open is a schema mismatch during
            // development, or — on a rider's phone — a full disk or a damaged
            // file. Falling back to memory keeps the app usable instead of
            // crashing on launch, but it must not be silent: every session
            // looks deleted, and anything recorded now would vanish at the
            // next launch. The library carries the flag so the list can say
            // so and the recorder can keep its crash logs.
            Self.logger.error("session store would not open: \(error.localizedDescription)")
            ephemeral = true
            container = try! ModelContainer(
                for: StoredSession.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        self.container = container

        let library = SessionLibrary(context: container.mainContext, isEphemeral: ephemeral)
        _library = State(initialValue: library)
        let sync = PhoneSyncClient(library: library)
        _sync = State(initialValue: sync)
        // Activated here, at launch, not from the scene. iOS relaunches the
        // app in the background to hand it a file the watch sent while the
        // phone was asleep, and a scene that never becomes active is not a
        // reliable place to have set the delegate by then.
        sync.activate()

        // Shares the one guide store rather than opening a second copy of the
        // spot database purely to name two coordinates.
        let guide = SpotGuideStore()
        _spotGuide = State(initialValue: guide)
        _routeNamer = State(initialValue: RouteNamer(guide: guide))
        _plannedRoutes = State(initialValue: RouteStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(sync)
                .environment(settings)
                .environment(recorder)
                .environment(countdown)
                .environment(spotGuide)
                .environment(routeNamer)
                .environment(plannedRoutes)
                .task {
                    library.applyLaunchArgumentsIfNeeded()
                    library.purgeExpiredTrash()
                    #if DEBUG
                    // The test set, so a debug build always has the sessions
                    // the expectation pages describe. No-op once they are in,
                    // and absent entirely from a release build.
                    DevSeed.loadIfNeeded(into: library)
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    // Leaving the foreground: push buffered fixes to disk, and
                    // hand back the receiver unless a session is actually being
                    // recorded. A termination in the background is silent, so
                    // flushing here bounds the loss to seconds rather than the
                    // whole session.
                    if phase != .active { recorder.enteredBackground() }
                }
        }
        .modelContainer(container)
    }
}

/// Phone-side preferences.
@MainActor
@Observable
final class AppSettings {

    var units: UnitPreferences { didSet { persist() } }

    /// Extra windows the rider has added — the "max speed over X km" they
    /// actually care about, on top of the standard categories.
    var customDistances: [Double] { didSet { persist() } }
    var customDurations: [Double] { didSet { persist() } }

    /// Privacy defaults applied when sharing.
    var sharingPrivacy: PrivacySettings { didSet { persist() } }

    /// Map style, shared by the session map, the full-screen map and replay so
    /// a rider sets it once rather than per screen.
    var mapStyle: MapStyleOption { didSet { persist() } }

    /// Sport pre-selected when recording, so a rider who does the same thing
    /// every session is one tap from starting.
    var lastSport: Sport { didSet { persist() } }

    /// Auto-pause when stationary. Off by default — a mistimed pause corrupts
    /// the averages people care about.
    var autoPauseWhileRecording: Bool { didSet { persist() } }

    /// Everything the rider owns, offered when tagging a session.
    var quiver: [GearItem] = [] { didSet { persist() } }

    /// Show every live page on the watch, rather than the two that are usable
    /// with wet hands. Mirrors the same preference on the watch; whichever was
    /// changed more recently wins, so this is stamped when it is set here.
    var watchExtendedDisplay: Bool {
        didSet {
            watchExtendedDisplayChangedAt = Date()
            persist()
        }
    }

    private(set) var watchExtendedDisplayChangedAt: Date

    /// Per-sport adjustments to the detection defaults.
    ///
    /// Keyed by sport, and only sports the rider has actually changed appear —
    /// so a default that improves later still reaches everyone who never
    /// touched it.
    var sportOverrides: [Sport: SportThresholds.Overrides] { didSet { persist() } }

    private let defaults = UserDefaults.standard

    init() {
        // A first launch takes its units from the phone. Somebody in Texas
        // should not have to convert every reading in their head before the
        // app is usable, and the device already knows the answer. Anything
        // they change afterwards wins, because the stored value is read back
        // in preference to the default.
        let device = UnitPreferences.forThisDevice
        let speed = defaults.string(forKey: "speedUnit")
            .flatMap(SpeedUnit.init(rawValue:)) ?? device.speed
        let distance = defaults.string(forKey: "distanceUnit")
            .flatMap(DistanceUnit.init(rawValue:)) ?? device.distance
        let temperature = defaults.string(forKey: "temperatureUnit")
            .flatMap(TemperatureUnit.init(rawValue:)) ?? device.temperatureUnit
        units = UnitPreferences(speed: speed, distance: distance, temperature: temperature)
        quiver = (defaults.data(forKey: "quiver"))
            .flatMap { try? JSONDecoder().decode([GearItem].self, from: $0) } ?? []
        customDistances = defaults.array(forKey: "customDistances") as? [Double] ?? []
        customDurations = defaults.array(forKey: "customDurations") as? [Double] ?? []
        sharingPrivacy = defaults.data(forKey: "sharingPrivacy")
            .flatMap { try? JSONDecoder().decode(PrivacySettings.self, from: $0) }
            ?? .sharing
        mapStyle = defaults.string(forKey: "mapStyle").flatMap(MapStyleOption.init(rawValue:)) ?? .standard
        lastSport = defaults.string(forKey: "lastSport").flatMap(Sport.init(rawValue:)) ?? .wingfoil
        autoPauseWhileRecording = defaults.bool(forKey: "autoPauseWhileRecording")
        watchExtendedDisplay = defaults.bool(forKey: "watchExtendedDisplay")
        watchExtendedDisplayChangedAt =
            defaults.object(forKey: "watchExtendedDisplayChangedAt") as? Date ?? .distantPast
        sportOverrides = defaults.data(forKey: "sportOverrides")
            .flatMap { try? JSONDecoder().decode([Sport: SportThresholds.Overrides].self, from: $0) }
            ?? [:]
    }

    /// What this sport's detection actually uses, defaults plus any changes.
    func thresholds(for sport: Sport) -> SportThresholds {
        sportOverrides[sport]?.applied(to: sport.thresholds) ?? sport.thresholds
    }

    func overrides(for sport: Sport) -> SportThresholds.Overrides? {
        guard let o = sportOverrides[sport], !o.isEmpty else { return nil }
        return o
    }

    /// Every category to evaluate: the standards plus whatever the rider added.
    var categories: [SpeedCategory] {
        var all = SpeedCategory.standard
        all += customDistances.sorted().map { SpeedCategory.distance(metres: $0) }
        all += customDurations.sorted().map { SpeedCategory.time(seconds: $0) }
        return all
    }

    private func persist() {
        defaults.set(units.speed.rawValue, forKey: "speedUnit")
        defaults.set(units.distance.rawValue, forKey: "distanceUnit")
        defaults.set(units.temperatureUnit.rawValue, forKey: "temperatureUnit")
        defaults.set(customDistances, forKey: "customDistances")
        defaults.set(customDurations, forKey: "customDurations")
        defaults.set(mapStyle.rawValue, forKey: "mapStyle")
        defaults.set(lastSport.rawValue, forKey: "lastSport")
        defaults.set(autoPauseWhileRecording, forKey: "autoPauseWhileRecording")
        defaults.set(watchExtendedDisplay, forKey: "watchExtendedDisplay")
        defaults.set(watchExtendedDisplayChangedAt, forKey: "watchExtendedDisplayChangedAt")
        if let data = try? JSONEncoder().encode(sharingPrivacy) {
            defaults.set(data, forKey: "sharingPrivacy")
        }
        if let data = try? JSONEncoder().encode(sportOverrides) {
            defaults.set(data, forKey: "sportOverrides")
        }
        if let data = try? JSONEncoder().encode(quiver) {
            defaults.set(data, forKey: "quiver")
        }
    }
}
