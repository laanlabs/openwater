import OpenWaterCore
import SwiftData
import SwiftUI

@main
struct openWaterApp: App {

    private let container: ModelContainer
    @State private var library: SessionLibrary
    @State private var sync: PhoneSyncClient
    @State private var settings = AppSettings()
    @State private var recorder = PhoneRecorder()
    @State private var countdown = RaceCountdown()
    @State private var spotGuide = SpotGuideStore()
    @State private var routeNamer: RouteNamer

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: StoredSession.self)
        } catch {
            // A store that will not open is almost always a schema mismatch
            // during development. Falling back to memory keeps the app usable
            // and makes the problem visible instead of crashing on launch.
            container = try! ModelContainer(
                for: StoredSession.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        self.container = container

        let library = SessionLibrary(context: container.mainContext)
        _library = State(initialValue: library)
        _sync = State(initialValue: PhoneSyncClient(library: library))

        // Shares the one guide store rather than opening a second copy of the
        // spot database purely to name two coordinates.
        let guide = SpotGuideStore()
        _spotGuide = State(initialValue: guide)
        _routeNamer = State(initialValue: RouteNamer(guide: guide))
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
                .task {
                    library.applyLaunchArgumentsIfNeeded()
                    library.purgeExpiredTrash()
                    #if DEBUG
                    // The test set, so a debug build always has the sessions
                    // the expectation pages describe. No-op once they are in,
                    // and absent entirely from a release build.
                    DevSeed.loadIfNeeded(into: library)
                    #endif
                    sync.activate()
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

    /// Per-sport adjustments to the detection defaults.
    ///
    /// Keyed by sport, and only sports the rider has actually changed appear —
    /// so a default that improves later still reaches everyone who never
    /// touched it.
    var sportOverrides: [Sport: SportThresholds.Overrides] { didSet { persist() } }

    private let defaults = UserDefaults.standard

    init() {
        let speed = defaults.string(forKey: "speedUnit").flatMap(SpeedUnit.init(rawValue:)) ?? .knots
        let distance = defaults.string(forKey: "distanceUnit").flatMap(DistanceUnit.init(rawValue:)) ?? .metric
        units = UnitPreferences(speed: speed, distance: distance)
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
        defaults.set(customDistances, forKey: "customDistances")
        defaults.set(customDurations, forKey: "customDurations")
        defaults.set(mapStyle.rawValue, forKey: "mapStyle")
        defaults.set(lastSport.rawValue, forKey: "lastSport")
        defaults.set(autoPauseWhileRecording, forKey: "autoPauseWhileRecording")
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
