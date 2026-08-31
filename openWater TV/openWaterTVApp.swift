import OpenWaterSpots
import SwiftUI

/// openWater on a television.
///
/// The phone is for the beach and the watch is for the water. This one is for
/// the kitchen at seven in the morning, before anybody has found their phone:
/// it answers "is it on?" from across a room, and then lets somebody look at
/// the water through a camera while the kettle boils.
///
/// So it is three screens and no more. There is no session recording here —
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

/// The three tabs, favourites first.
///
/// tvOS puts the tab bar at the top and gives it focus when the screen opens,
/// which suits a lean-back app: the first thing the remote can do is move
/// between the three questions, and pressing down enters the one you landed on.
struct RootView: View {

    var body: some View {
        TabView {
            FavoritesBoard()
                .tabItem { Label("Wind", systemImage: "wind") }
            WindMapScreen()
                .tabItem { Label("Map", systemImage: "map") }
            CamerasScreen()
                .tabItem { Label("Cameras", systemImage: "video") }
        }
    }
}
