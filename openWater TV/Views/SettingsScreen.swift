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
/// how it looks — off until somebody says otherwise — and the two units a
/// household actually disagrees about. Units lead: they are the setting a
/// rider comes here for, and the one that is wrong for somebody in every
/// household that watches this in more than one language of wind.
struct SettingsScreen: View {

    @Environment(TVLocation.self) private var location
    @Environment(TVUnits.self) private var units

    @AppStorage(TVSettings.playsYouTubeKey) private var playsYouTube = false
    @AppStorage(TVSettings.debugHUDKey) private var showsDebugHUD = false
    @AppStorage(TVSettings.cameraRadiusKey) private var cameraRadiusKm = TVSettings.defaultCameraRadiusKm

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Segmented, because a television picker that pushes a
                    // list is three presses and a page for a two-way choice.
                    // The titles are rows of their own: a segmented picker
                    // on tvOS draws its segments and drops its label, so a
                    // label passed the ordinary way was never seen.
                    @Bindable var units = units
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Wind speed")
                            .font(.system(size: 32, weight: .medium))
                        Picker("Wind speed", selection: $units.speed) {
                            ForEach(TVUnits.speeds, id: \.self) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("Knots are what the sport measures in. The map's colours and the firing line stay the same whichever you pick.")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Temperature")
                            .font(.system(size: 32, weight: .medium))
                        Picker("Temperature", selection: $units.temperature) {
                            ForEach(TemperatureUnit.allCases) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Units")
                }

                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Search radius")
                            .font(.system(size: 32, weight: .medium))
                        Picker("Search radius", selection: $cameraRadiusKm) {
                            ForEach(TVSettings.cameraRadiusChoicesKm, id: \.self) { km in
                                Text(TVSettings.cameraRadiusLabel(km, unit: units.preferences.distance)).tag(km)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("How far around the pin the Cameras tab and a spot's camera list look. Wider finds more, further away.")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Cameras")
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
                    // Worded as the diagnostic it is, beside the other one:
                    // this resolves an embedded player's own HLS manifest and
                    // plays it directly, which is a thing to switch on when
                    // tracing why a camera will not play, not a promise about
                    // playback. It used to be its own section at the foot of
                    // the screen, under a friendlier name.
                    Toggle(isOn: $playsYouTube) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Stream debugging")
                                .font(.system(size: 32, weight: .medium))
                            Text("Resolve embedded players' HLS manifests directly. Off by default.")
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

    /// How far around the pin the cameras are gathered, in kilometres.
    ///
    /// Eighty was the fixed number, and it is the right default for a coast:
    /// a television is not standing on the beach, so the question is which
    /// cameras are on this stretch of water, not which one is under your
    /// feet. It is a choice now because it was wrong in both directions for
    /// somebody — a city rider whose nearest surf is an hour away wants the
    /// net wider, and a rider on a crowded coast wants fewer, closer cards.
    static let cameraRadiusKey = "tv.cameras.radiusKm"
    static let cameraRadiusChoicesKm = [25, 50, 80, 150]
    static let defaultCameraRadiusKm = 80

    /// The radius in metres, for code that fetches rather than draws.
    static var cameraRadiusMetres: Double {
        let stored = UserDefaults.standard.integer(forKey: cameraRadiusKey)
        return Double(stored > 0 ? stored : defaultCameraRadiusKm) * 1000
    }

    /// "80 km", "50 mi" or "43 NM" — whole numbers, because these are
    /// choices, not measurements, and "49.71 mi" is a measurement.
    static func cameraRadiusLabel(_ km: Int, unit: DistanceUnit) -> String {
        let metres = Double(km) * 1000
        switch unit {
        case .metric: return "\(km) km"
        case .imperial: return "\(Int((metres / DistanceUnit.metresPerStatuteMile).rounded())) mi"
        case .nautical: return "\(Int((metres / DistanceUnit.metresPerNauticalMile).rounded())) NM"
        }
    }

    /// Read from outside a view — `CamCard` needs it during a button action,
    /// not only while drawing.
    static var playsYouTube: Bool {
        UserDefaults.standard.bool(forKey: playsYouTubeKey)
    }
}
