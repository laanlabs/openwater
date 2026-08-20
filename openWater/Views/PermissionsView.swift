import CoreLocation
import OpenWaterCore
import SwiftUI
import UIKit

/// What the app was allowed to do, and how to change your mind.
///
/// Every permission this app needs is asked for once, in the middle of doing
/// something else — location while a rider is trying to start a session, Health
/// on the watch at the first tap of Start — and iOS never asks twice. A tap on
/// the wrong button at that moment costs a feature silently and for ever: the
/// track that will not record, the heart rate that never appears. Riders then
/// have no way to find out what they refused, because a refused permission
/// looks exactly like a feature the app does not have.
///
/// So this page states each one, says what it is for, says what the answer
/// currently is, and offers the only two moves that exist — ask, if the
/// question has never been put, and open Settings, if it has.
struct PermissionsView: View {

    @Environment(PhoneSyncClient.self) private var sync
    @State private var permissions = PermissionsCheck()

    var body: some View {
        List {
            Section {
                row(
                    title: "Location",
                    detail: permissions.locationDetail,
                    symbol: "location.fill",
                    tone: permissions.locationTone,
                    action: permissions.locationAction
                )
            } header: {
                Text("Recording")
            } footer: {
                Text("A session is a GPS track — without location there is nothing to record. openWater asks only for While Using, and keeps recording with the screen off because a session is an active workout, not a background app.")
                    .font(.subheadline)
            }

            Section {
                row(
                    title: "Precise location",
                    detail: permissions.accuracyDetail,
                    symbol: "scope",
                    tone: permissions.accuracyTone,
                    action: permissions.accuracy == .fullAccuracy ? nil : .openSettings
                )
            } footer: {
                Text("Approximate location is a few kilometres wide. It is fine for a weather forecast and useless for a speed — a track built from it would be a scribble with nonsense numbers on it.")
                    .font(.subheadline)
            }

            Section {
                Button {
                    sync.checkHeartRate()
                } label: {
                    HStack(spacing: 10) {
                        icon("heart.fill", tone: heartTone)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Heart rate on the watch")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(sync.isCheckingHeartRate ? "Asking the watch…" : "Tap to check")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if sync.isCheckingHeartRate { ProgressView() }
                    }
                }
                .disabled(sync.isCheckingHeartRate)

                if let message = sync.heartRateMessage {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(heartTone == .good ? AnyShapeStyle(.primary)
                                                            : AnyShapeStyle(Color.orange))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The steps, in the size a person reads instructions at.
                //
                // These lived in a Form footer — caption-sized grey text under
                // a grey background — which is where an app puts something it
                // does not really expect anybody to act on. Heart rate is the
                // single most asked-for thing the watch does, and the path to
                // it is four taps that nobody can guess: it is not in this
                // app's settings, and it is not in the Watch app either.
                howToEnableHeartRate
            } header: {
                Text("Apple Watch")
            } footer: {
                // The honest asymmetry: this phone has no HealthKit at all, so
                // it cannot read the answer — only the watch can, and only by
                // asking its own store for a sample.
                Text("Heart rate is read on the watch, so only the watch can answer — the check above asks it directly.")
                    .font(.subheadline)
            }

            Section {
                Label("Motion sensors need no permission", systemImage: "figure.wave")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Jumps, pumps and time on foil are read from the accelerometer on whichever device is recording. Neither iPhone nor Apple Watch asks for that, so there is nothing here to switch on — and nothing you can have turned off by accident.")
                    .font(.subheadline)
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Permissions")
        .onAppear { permissions.refresh() }
    }

    /// Where the switch actually is, spelled out.
    ///
    /// Numbered because it is a route rather than a fact, and at body size
    /// because a rider is going to read it while holding the phone in the
    /// other hand and tapping along.
    private var howToEnableHeartRate: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("How to turn it on", systemImage: "heart.text.square")
                .font(.headline)

            step(1, "Open the **Health** app on this iPhone")
            step(2, "Tap your **profile picture**, top right")
            step(3, "Under Privacy, tap **Apps**, then **openWater**")
            step(4, "Turn on **Heart Rate** — or Turn On All")

            Text("watchOS asks once and never again, so this is the only way back. It applies to your next session, not the ones already recorded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heartTone: Tone {
        guard let message = sync.heartRateMessage else { return .unknown }
        return message.hasPrefix("Heart rate is on") ? .good : .bad
    }

    // MARK: - Pieces

    enum Tone {
        case good, bad, unknown

        var colour: Color {
            switch self {
            case .good: .green
            case .bad: .orange
            case .unknown: .secondary
            }
        }
    }

    /// The only two moves iOS actually offers.
    enum Action {
        case ask, openSettings

        var title: String {
            switch self {
            case .ask: "Ask"
            case .openSettings: "Open Settings"
            }
        }
    }

    private func icon(_ symbol: String, tone: Tone) -> some View {
        Image(systemName: symbol)
            .font(.subheadline)
            .foregroundStyle(tone.colour)
            .frame(width: 26)
    }

    @ViewBuilder
    private func row(title: String, detail: String, symbol: String,
                     tone: Tone, action: Action?) -> some View {
        HStack(spacing: 10) {
            icon(symbol, tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(tone == .good ? AnyShapeStyle(.secondary)
                                                   : AnyShapeStyle(tone.colour))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action.title) {
                    switch action {
                    case .ask: permissions.request()
                    case .openSettings: PermissionsCheck.openSettings()
                    }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        }
    }
}

// MARK: - The answers

/// Reads the app's own permission state, and offers the two moves that exist.
///
/// Its own `CLLocationManager` on purpose: authorization is a property of the
/// app rather than of a manager, so asking here cannot disturb the one that is
/// recording — and this page has to work when nothing is recording at all.
@MainActor
@Observable
final class PermissionsCheck: NSObject {

    private let manager = CLLocationManager()

    private(set) var status: CLAuthorizationStatus = .notDetermined
    private(set) var accuracy: CLAccuracyAuthorization = .fullAccuracy

    override init() {
        super.init()
        manager.delegate = self
        refresh()
    }

    func refresh() {
        status = manager.authorizationStatus
        accuracy = manager.accuracyAuthorization
    }

    /// Only ever useful once. iOS shows the prompt for `notDetermined` and
    /// silently does nothing afterwards, which is why every other state offers
    /// Settings instead of a button that would appear to do nothing.
    func request() {
        manager.requestWhenInUseAuthorization()
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: What to say about it

    var locationDetail: String {
        switch status {
        case .notDetermined: "Not asked yet — sessions cannot record until it is"
        case .denied: "Denied — sessions cannot record"
        case .restricted: "Restricted by this device's policy"
        case .authorizedWhenInUse: "While Using — this is what openWater asks for"
        case .authorizedAlways: "Always — more than openWater needs, and fine"
        @unknown default: "Unknown"
        }
    }

    var locationTone: PermissionsView.Tone {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: .good
        case .notDetermined: .unknown
        default: .bad
        }
    }

    var locationAction: PermissionsView.Action? {
        switch status {
        case .notDetermined: .ask
        case .denied, .restricted: .openSettings
        default: nil
        }
    }

    var accuracyDetail: String {
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return "Waiting on location itself"
        }
        return accuracy == .fullAccuracy
            ? "On — speeds and distances are measured properly"
            : "Off — approximate location cannot measure a track"
    }

    var accuracyTone: PermissionsView.Tone {
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return .unknown }
        return accuracy == .fullAccuracy ? .good : .bad
    }

    /// Whether anything on this page wants attention, for the badge on the
    /// row that opens it — the point being that a rider should not have to
    /// come looking.
    var needsAttention: Bool {
        locationTone == .bad || accuracyTone == .bad
    }
}

extension PermissionsCheck: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        Task { @MainActor in
            self.status = status
            self.accuracy = accuracy
        }
    }
}
