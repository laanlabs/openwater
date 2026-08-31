import CoreLocation
import OpenWaterSpots
import SwiftUI
import WeatherKit

/// Everything the app asks about the weather, and who answers it.
///
/// A rider who wants to know where a number came from should be able to find
/// out without reading the source, and the sources genuinely differ in kind:
/// a model grid, a machine-learning nowcast, a real anemometer on an airfield,
/// a buoy in the water. Which one said it changes how much it is worth.
///
/// It lives at the bottom of Settings because it is a reference rather than a
/// control — nothing here changes what the app does.
struct WeatherSourcesView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            source(
                "Open-Meteo",
                "Nearly all of it: wind, gusts, temperature and sky wherever you point the map. "
                + "The five global models on the compare screen and the GEFS ensemble behind the odds. "
                + "Quarter-hour rapid-update runs — HRRR, ICON-D2, AROME — where they reach. "
                + "Waves and swell, the ocean-current field under the wash, and the ERA5 archive "
                + "behind what a week here normally does. Free and worldwide, no account."
            )

            apple

            source(
                "NOAA · National Weather Service",
                "The free public stations and their live readings, the radar reflectivity over the "
                + "map, and the watches and warnings. United States only — which is why the station "
                + "list is empty everywhere else, and the model above is what there is."
            )

            source(
                "NOAA · Tides and Currents",
                "Tide stations, their predictions, and the curve on the Tide tab."
            )

            source(
                "NOAA · National Data Buoy Center",
                "Buoy readings — wave height, period and sea temperature. Measured rather than "
                + "modelled, which is why a buoy outranks a model wherever one is close enough."
            )

            source(
                "Natural Earth",
                "The 1:10m shoreline that ships inside the app. Not weather, but it is what the "
                + "current wash is masked to, so the map knows land from water with no network at all."
            )
        }
        // Every control in this block answers for its own rectangle. A Form
        // row hands its whole width to a single control, and with a Link in
        // the row the Link is the one that takes it — so every tap here, the
        // error text included, opened Apple's legal page, and the button could
        // not be pressed at all. This has to sit on the whole block rather
        // than on the button: styling the button alone leaves the Link holding
        // the row, which was measured, not assumed.
        .buttonStyle(.borderless)
    }

    /// Apple's share, named part by part.
    ///
    /// Apple supplies two things nothing free can — a radar-derived nowcast
    /// and published climate normals — plus the observed wind a saved session
    /// is scored against. The trademark and the legal link ride with them:
    /// WeatherKit's terms ask for both wherever its data is shown, and this is
    /// where the app says it.
    private var apple: some View {
        VStack(alignment: .leading, spacing: 6) {
            source(
                "Apple Weather",
                "The rain nowcast on the conditions sheet — machine learning over live radar, which "
                + "is how it can name the minute. The temperature and rain normals a forecast week "
                + "is read against. And the observed wind offered for a saved session, the \"Use "
                + "recorded conditions\" button: a model on a roughly 2 km grid rather than an "
                + "anemometer on the beach, which is why it is offered rather than applied."
            )
            WeatherStatusView()
        }
    }

    private func source(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The " Weather" mark, its legal link, and a way to ask whether the
/// service is actually answering.
///
/// WeatherKit can fail for at least four unrelated reasons — the capability
/// missing from the App ID, a provisioning profile predating it, no network,
/// or the service simply refusing the app's token — and every one of them
/// looks identical from the outside: nothing. So the reason can be asked for
/// here, in Settings, where somebody looking for it can find it and quote it,
/// rather than only in a log that needs a Mac and a cable.
///
/// Asked for, not run on sight. The check used to fire whenever Settings
/// opened, which spent a request on the overwhelming majority of visits that
/// were not about the weather at all — and put a live network call behind a
/// screen full of switches. The button is one tap for the rare visit that
/// wants it.
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
            HStack(spacing: 10) {
                // No prefix: the credit directly above already says whose
                // data this is, and the row has to leave room for the check
                // beside it.
                AppleWeatherAttribution(showsLegalLabel: true)
                    .font(.caption)
                Spacer(minLength: 8)
                trigger
            }
            detail
        }
    }

    /// The ask, and what it is doing while it answers.
    @ViewBuilder
    private var trigger: some View {
        switch check {
        case .idle:
            Button("Verify") { Task { await runCheck() } }
                .font(.caption)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .working, .failed:
            Button("Check again") { Task { await runCheck() } }
                .font(.caption)
        }
    }

    /// What it said, once it has said anything.
    @ViewBuilder
    private var detail: some View {
        switch check {
        case .idle, .checking:
            EmptyView()

        case .working(let windSpeed, let place):
            Label("Answering — \(place), wind \(String(format: "%.1f", windSpeed * 1.94384)) kn",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 3) {
                Label("Weather service unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                // Selectable, because the useful thing to do with it is paste
                // it somewhere — a bug report, a search, a provisioning profile.
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
