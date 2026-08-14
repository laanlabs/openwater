import CoreLocation
import SwiftUI
import WeatherKit

/// Whether Apple's weather service is answering, and what it said if not.
///
/// The conditions strip on the Record tab hides itself when the service is
/// unavailable, which is right for a rider mid-session and useless for working
/// out why there is no wind reading. WeatherKit can fail for at least four
/// unrelated reasons — the capability missing from the App ID, a provisioning
/// profile predating it, no network, or the service simply refusing the app's
/// token — and every one of them looks identical from the outside: nothing.
///
/// So the reason lives here, in Settings, where somebody looking for it can
/// find it and quote it, rather than only in a log that needs a Mac and a cable.
struct WeatherStatusView: View {

    @State private var check: Check = .idle

    enum Check: Equatable {
        case idle
        case checking
        case working(windSpeed: Double, place: String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            status
            // The mark and legal link stay put whatever the service says.
            // This section is about Apple Weather either way — and attribution
            // that only appears when the service happens to answer is
            // invisible to exactly the reviewer who came looking for it.
            AppleWeatherAttribution(showsLegalLabel: true, prefix: "Weather data provided by")
                .font(.caption)
        }
        // Runs itself rather than waiting to be asked. Somebody opening
        // Settings after finding no wind reading has already asked the
        // question; making them find a button to ask it again is one step too
        // many, and the call is a few hundred bytes against a monthly
        // allowance of half a million.
        .task {
            if check == .idle { await runCheck() }
        }
    }

    @ViewBuilder
    private var status: some View {
        Group {
            switch check {
            case .idle:
                // Shown only in the instant before the automatic check starts.
                Button("Check weather service") { Task { await runCheck() } }

            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }

            case .working(let windSpeed, let place):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Weather service is working", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(place): wind \(String(format: "%.1f", windSpeed * 1.94384)) kn")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .failed(let reason):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Weather service unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Try again") { Task { await runCheck() } }
                        .font(.caption)
                }
            }
        }
    }

    /// A fixed, known coordinate rather than the rider's own.
    ///
    /// This question is about the service, not about here — and asking about a
    /// place the rider is standing would make a diagnostic tool the one thing
    /// in Settings that needs location permission.
    private func runCheck() async {
        check = .checking
        let hoodRiver = CLLocation(latitude: 45.7087, longitude: -121.5215)
        do {
            let weather = try await WeatherService.shared.weather(for: hoodRiver, including: .current)
            check = .working(
                windSpeed: weather.wind.speed.converted(to: .metersPerSecond).value,
                place: "Hood River"
            )
        } catch {
            check = .failed(String(describing: error))
        }
    }
}
