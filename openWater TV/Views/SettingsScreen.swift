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
                    Toggle(isOn: $playsYouTube) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Play YouTube cameras here")
                                .font(.system(size: 32, weight: .medium))
                            Text("Off: a YouTube camera shows a code to open on your phone.")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Cameras")
                } footer: {
                    // The whole argument, on the screen where the decision is
                    // made. A switch this consequential explaining itself in a
                    // release note nobody reads is not an explanation.
                    Text("""
                        Most cameras in the guide are YouTube live streams, and no app but \
                        YouTube's own is meant to play those on an Apple TV — there is no \
                        embeddable player, the way there is on a phone.

                        Turning this on makes openWater ask YouTube's internal service for \
                        the stream directly, presenting itself as one of YouTube's own \
                        clients. It works today for live cameras. It is against YouTube's \
                        terms of service, it may stop working without warning when they \
                        change that service, and a camera that fails falls back to the code \
                        for your phone.
                        """)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }

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
