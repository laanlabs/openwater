import OpenWaterCore
import SwiftUI

/// The pre-session screen: pick a sport, check the GPS, go.
///
/// Designed to be one tap from cold. Somebody standing on a beach in a wetsuit
/// with cold hands should not have to navigate anything, so the last sport used
/// is pre-selected and the start button is the largest thing on screen.
struct StartView: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings
    @Environment(WatchSyncClient.self) private var sync

    @State private var showingSportPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    startButton
                    sportButton
                    gpsStatus
                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    if sync.pendingTransfers > 0 || !sync.queuedSessions.isEmpty {
                        pendingBadge
                    }
                }
                .padding(.horizontal, 2)
            }
            .navigationTitle("openWater")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { recorder.warmUpSensors() }
            .sheet(isPresented: $showingSportPicker) {
                SportPickerView(selection: Binding(
                    get: { settings.lastSport },
                    set: { settings.lastSport = $0 }
                ))
            }
        }
    }

    // MARK: - Pieces

    private var startButton: some View {
        Button {
            recorder.autoPauseEnabled = settings.autoPause
            recorder.start(sport: settings.lastSport)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "record.circle")
                    .font(.system(size: 30))
                Text("Start")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .tint(.green)
    }

    private var sportButton: some View {
        Button {
            showingSportPicker = true
        } label: {
            HStack {
                Image(systemName: settings.lastSport.symbolName)
                Text(settings.lastSport.displayName)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
    }

    /// GPS state, shown plainly rather than hidden.
    ///
    /// Starting before the receiver has settled is the single most common way to
    /// ruin a session's numbers, so the state is surfaced up front instead of
    /// being something a rider discovers afterwards.
    private var gpsStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: gpsSymbol)
                .foregroundStyle(gpsColour)
            Text(gpsLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var gpsSymbol: String {
        switch recorder.location.authorization {
        case .denied, .restricted: "location.slash"
        default: recorder.location.hasFix ? "location.fill" : "location"
        }
    }

    private var gpsColour: Color {
        switch recorder.location.authorization {
        case .denied, .restricted:
            return .red
        default:
            if !recorder.location.hasFix { return .orange }
            let accuracy = recorder.location.latestAccuracy
            return accuracy >= 0 && accuracy <= 10 ? .green : .orange
        }
    }

    private var gpsLabel: String {
        switch recorder.location.authorization {
        case .denied, .restricted:
            return "Location off — enable in Settings"
        case .notDetermined:
            return "Waiting for permission"
        default:
            guard recorder.location.hasFix else { return "Finding satellites…" }
            let accuracy = recorder.location.latestAccuracy
            return accuracy >= 0
                ? String(format: "GPS ±%.0f m", accuracy)
                : "GPS ready"
        }
    }

    private var pendingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.circle")
            Text("\(sync.queuedSessions.count) waiting for iPhone")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// Sport picker. Wind sports first, because that is what this app is for.
struct SportPickerView: View {

    @Binding var selection: Sport
    @Environment(\.dismiss) private var dismiss

    private let ordered: [Sport] = [
        .wingfoil, .parawing, .downwindSUP, .prone,
        .windfoil, .windsurf, .kitefoil, .kitesurf,
        .sail, .sup, .kayak, .efoil, .tow, .other,
    ]

    var body: some View {
        List {
            ForEach(ordered) { sport in
                Button {
                    selection = sport
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: sport.symbolName)
                            .frame(width: 20)
                        Text(sport.displayName)
                        Spacer(minLength: 0)
                        if sport == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Sport")
    }
}

struct WatchSettingsView: View {

    @Environment(WatchSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        List {
            Section("Units") {
                Picker("Speed", selection: $settings.units.speed) {
                    ForEach(SpeedUnit.allCases, id: \.self) { unit in
                        Text(unit.symbol).tag(unit)
                    }
                }
                Picker("Distance", selection: $settings.units.distance) {
                    Text("km").tag(DistanceUnit.metric)
                    Text("NM").tag(DistanceUnit.nautical)
                    Text("mi").tag(DistanceUnit.imperial)
                }
            }
            Section("Recording") {
                Toggle("Auto-pause", isOn: $settings.autoPause)
                Toggle("Record haptics", isOn: $settings.recordHaptics)
                Toggle("Keep screen bright", isOn: $settings.keepScreenBright)
            }
            Section {
                Text("Auto-pause stops the clock when you stop moving. It is off by default because a mistimed pause distorts your session averages.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
