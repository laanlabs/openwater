import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The few things this television lets you change.
///
/// There is deliberately almost nothing here. A lean-back app that needs
/// configuring has already lost, and everything the phone lets a rider set —
/// units, map style, private spots — either has no meaning on a television or
/// belongs on the screen it affects, the way the forecast model sits on the
/// conditions screen rather than in a drawer.
///
/// What is here is the one switch that changes what the app *is* rather than
/// how it looks, and it is off until somebody says otherwise.
struct SettingsScreen: View {

    @Environment(TVLocation.self) private var location

    @AppStorage(TVSettings.playsYouTubeKey) private var playsYouTube = false
    @AppStorage(TVSettings.debugHUDKey) private var showsDebugHUD = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $showsDebugHUD) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Show debug overlay")
                                .font(.system(size: 32, weight: .medium))
                            Text("A corner button with live memory and frame rate, for diagnosing a slow screen.")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Diagnostics")
                }

                Section("Location") {
                    LabeledContent {
                        Text(location.name.isEmpty ? "Not set" : location.name)
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("The coast this app is about")
                            .font(.system(size: 30))
                    }
                    Text("Change it on the Map tab.")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }

                // Last, and quiet. This used to lead the screen with several
                // paragraphs about how it works, which put the most technical
                // thing in the app in front of every rider who came here to
                // check which coast they were on. It is a preference about
                // playback, so it reads as one and sits where the rarely
                // touched settings sit.
                Section {
                    Toggle(isOn: $playsYouTube) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Improved streaming")
                                .font(.system(size: 26))
                            Text("Play more cameras on this Apple TV. Off: a code opens the camera on your phone.")
                                .font(.system(size: 19))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// The defaults this app reads from more than one screen.
///
/// A named key rather than a string repeated in three files: the cameras grid,
/// the card that decides what pressing it does, and the switch itself all have
/// to agree, and a typo in any of them is a feature that silently never turns
/// on.
enum TVSettings {
    static let playsYouTubeKey = "tv.youtube.play"
    static let debugHUDKey = "tv.debug.hud"

    /// Read from outside a view — `CamCard` needs it during a button action,
    /// not only while drawing.
    static var playsYouTube: Bool {
        UserDefaults.standard.bool(forKey: playsYouTubeKey)
    }
}
