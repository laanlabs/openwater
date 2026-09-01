import OpenWaterSpots
import SwiftUI

/// openWater on a television.
///
/// The phone is for the beach and the watch is for the water. This one is for
/// the kitchen at seven in the morning, before anybody has found their phone:
/// it answers "is it on?" from across a room, and then lets somebody look at
/// the water through a camera while the kettle boils.
///
/// So it is three screens and a settings tab. There is no session recording —
/// an Apple TV goes nowhere — no tides, no currents, no route drawing. What
/// the phone does with a fingertip on a map, this does with four arrow keys
/// and a Select button, which is the whole constraint the design answers to.
@main
struct openWaterTVApp: App {

    @State private var guide = SpotGuideStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(guide)
                .task { await guide.load() }
        }
    }
}

/// The tabs, the map first.
///
/// The order is the order the questions get asked. A television turned on in
/// the morning is asked "what is the wind doing out there" before it is asked
/// anything about a list somebody curated once, so the wind map leads, the
/// cameras of that same water come next, and the starred spots — the tab that
/// needs setting up before it says anything — comes after them.
///
/// Settings is last and is a tab rather than a button buried at the bottom of
/// the favourites board, which is where it started. On a television the tab
/// bar *is* the menu: a screen that is not on it is a screen somebody has to
/// be told about, and a switch nobody can find is a switch that does not
/// exist.
///
/// tvOS puts the tab bar at the top and gives it focus when the screen opens,
/// which suits a lean-back app: the first thing the remote can do is move
/// between the three questions, and pressing down enters the one you landed on.
struct RootView: View {

    /// Where this box thinks it is, and what the map is looking at. Owned up
    /// here because three tabs are about the same patch of water: the map
    /// opens on it, the camera list counts its distances from it, and radar
    /// inherits its whole rectangle — zoom included. A rider who pans to
    /// Montauk and presses across should not have to find Montauk twice.
    @State private var location = TVLocation()

    @State private var tab = Tab.map

    enum Tab: Hashable { case map, cameras, radar, favorites, settings }

    var body: some View {
        TabView(selection: $tab) {
            // The map is told whether it is the tab on screen: its wash and
            // its comets are worth carrying only while somebody is looking at
            // them, which is the phone's rule and matters more here.
            WindMapScreen(isActive: tab == .map)
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)
            CamerasScreen()
                .tabItem { Label("Cameras", systemImage: "video") }
                .tag(Tab.cameras)
            // Radar sits beside the cameras rather than beside the map,
            // because it answers the same kind of question they do — what is
            // actually happening out there right now — where the map is about
            // what the models think will.
            RadarScreen()
                .tabItem { Label("Radar", systemImage: "cloud.rain") }
                .tag(Tab.radar)
            FavoritesBoard()
                .tabItem { Label("Favourites", systemImage: "star") }
                .tag(Tab.favorites)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .environment(location)
        // Dark, always, whatever the television is set to.
        //
        // Reported from a real Apple TV in Light appearance: half the app was
        // unreadable. This design is dark by construction — black detail
        // screens, white-on-dark map chrome, translucent capsules over a
        // muted basemap — and in Light every semantic colour flipped
        // underneath it. `.primary` turned black on a black background,
        // `.thinMaterial` came up pale under white text, and the control bar
        // read as empty.
        //
        // The screens below are also explicit about their own colours now, so
        // this is the belt rather than the only thing holding it up. But a
        // lean-back app that is dark everywhere it draws should say so once,
        // at the top, rather than defending itself on every label.
        .preferredColorScheme(.dark)
    }
}
