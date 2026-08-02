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

    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sports) { sport in
                        SportCard(sport: sport) {
                            start(sport)
                        }
                    }

                    gpsStatus
                        .padding(.top, 2)

                    Button {
                        showingSettings = true
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
            // Leaving the chooser — for the live screen or for the wrist going
            // down — gives the receiver back. Only a recording session holds it.
            .onDisappear { recorder.stopWarmUp() }
            .sheet(isPresented: $showingSettings) {
                NavigationStack { WatchSettingsView() }
            }
        }
    }

    /// The sport last used first, then the rest.
    ///
    /// Picking the activity *is* starting the session — there is no separate
    /// start button, because on a beach in a wetsuit the shortest path from
    /// cold to recording is one tap, and a rider who does the same thing every
    /// session finds it at the top every time.
    private var sports: [Sport] {
        let recordable = Sport.recordable
        guard let index = recordable.firstIndex(of: settings.lastSport) else { return recordable }
        var ordered = recordable
        ordered.remove(at: index)
        ordered.insert(settings.lastSport, at: 0)
        return ordered
    }

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

    private func start(_ sport: Sport) {
        settings.lastSport = sport
        recorder.autoPauseEnabled = settings.autoPause
        recorder.start(sport: sport)
    }
}

/// One activity, sized to be hit without looking.
struct SportCard: View {

    let sport: Sport
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: sport.symbolName)
                    .font(.system(size: 22))
                    .frame(width: 30)
                Text(sport.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

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
