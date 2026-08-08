import OpenWaterCore
import SwiftUI

/// Everything that can tell you what it is doing at this spot right now.
///
/// The spot page shows one number — a model estimate — because that is all
/// that is true everywhere. It is also the weakest kind of answer: a grid
/// forecast smoothed over a few kilometres, in a sport where the difference
/// between the river and the ridge is the whole session. Riders already know
/// this, which is why they check three apps before driving.
///
/// So this collects the better answers where they exist: real anemometers
/// NOAA runs for nothing, the meters and cams the guide has curated, and the
/// surf pages for the same stretch of coast. Sorted by distance, because the
/// question is never "is there a station" but "is there one close enough to
/// believe".
struct NearbyConditionsSheet: View {

    let spot: GuideSpot

    @Environment(SpotGuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var tab: Tab = .conditions
    @State private var stations: [FreeStation] = []
    @State private var resources: [SpotGuideStore.GuideResource] = []
    @State private var isSearching = true

    enum Tab: String, CaseIterable {
        case conditions = "Wind & weather", cams = "Cams", surf = "Surf"
    }

    private var reading: WindReading? { guide.wind[spot.spotId] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    picker
                    switch tab {
                    case .conditions: conditionsTab
                    case .cams: list(of: .camera, empty: "No webcams within 40 km in the guide.")
                    case .surf: list(of: .surf, empty: "No surf or marine forecasts within 40 km in the guide.")
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(spot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task(id: spot.spotId) { await search() }
    }

    private var picker: some View {
        Picker("Section", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Wind & weather

    @ViewBuilder
    private var conditionsTab: some View {
        modelCard

        section("REAL STATIONS NEARBY, FREE") {
            if stations.isEmpty {
                note(isSearching
                     ? "Looking for public stations…"
                     : "No free public stations here. NOAA's network is United States only — outside it the model above and the meters below are what there is.")
            } else {
                card {
                    ForEach(Array(stations.enumerated()), id: \.element.id) { index, station in
                        stationRow(station)
                        if index < stations.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                note("NOAA airfield, road and marine sensors. Free to read, no account. They are wherever NOAA put them, not at the launch — check the distance before you trust one.")
            }
        }

        let meters = resources.filter { $0.kind == .wind }
        section("WIND METERS IN THE GUIDE") {
            if meters.isEmpty {
                note(isSearching ? "Looking…" : "No wind meters within 40 km in the guide. If you know one, add it from Improve this spot.")
            } else {
                card {
                    ForEach(Array(meters.enumerated()), id: \.element.id) { index, meter in
                        resourceRow(meter)
                        if index < meters.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
            }
        }
    }

    /// The estimate the spot page leads with, repeated here with its
    /// provenance spelled out — this sheet exists to rank sources, so the
    /// weakest one has to say what it is.
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MODEL ESTIMATE, THIS SPOT")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 14) {
                if let weather = guide.weatherReading(for: spot) {
                    VStack(spacing: 2) {
                        Image(systemName: weather.symbol)
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(weather.tint)
                        Text("\(Int(weather.temperatureC.rounded()))°")
                            .font(.headline)
                            .monospacedDigit()
                    }
                    .frame(width: 58)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let reading {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(Int(reading.speedKn.rounded()))")
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .foregroundStyle(reading.isFiring ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            Text("kn \(reading.cardinal)\(reading.gustKn.map { " · gusts \(Int($0.rounded()))" } ?? "")")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                    }
                    if let weather = guide.weatherReading(for: spot) {
                        Text(weather.label + (weather.apparentC.map { ", feels \(Int($0.rounded()))°" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Text("Open-Meteo's forecast grid, free and worldwide. It is a model, not an anemometer — near a gorge or a headland it can be out by a lot.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func stationRow(_ station: FreeStation) -> some View {
        Button {
            openURL(station.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(stationSubtitle(station))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)

                if let wind = station.observation?.windKn {
                    (Text("\(Int(wind.rounded()))").font(.headline)
                     + Text("kn").font(.caption2.weight(.semibold)))
                        .foregroundStyle(wind >= 15 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                }
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Distance first, then whatever the station is actually saying — and
    /// when it last said it, because a dead sensor reading 0 kn looks exactly
    /// like a calm day.
    /// "0 m" is technically true and reads like a bug. A resource pinned at
    /// the launch itself should say so.
    private func near(_ metres: Double) -> String {
        metres < 100 ? "at this spot" : Format.distance(metres, unit: settings.units.distance)
    }

    private func stationSubtitle(_ station: FreeStation) -> String {
        var parts = [near(station.metres)]
        if let observation = station.observation {
            if let direction = observation.directionDeg {
                parts.append(Format.cardinal(direction))
            }
            if let temperature = observation.temperatureC {
                parts.append("\(Int(temperature.rounded()))°C")
            }
            if let summary = observation.summary { parts.append(summary) }
            if let at = observation.at {
                parts.append(observation.isStale
                             ? "last seen \(at.formatted(.relative(presentation: .named)))"
                             : at.formatted(date: .omitted, time: .shortened))
            }
        } else {
            parts.append("no recent reading")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Cams and surf

    @ViewBuilder
    private func list(of kind: SpotGuideStore.SpotLink.Kind, empty: String) -> some View {
        let items = resources.filter { $0.kind == kind }
        if items.isEmpty {
            note(isSearching ? "Looking…" : empty)
                .padding(.top, 4)
        } else {
            card {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    resourceRow(item)
                    if index < items.count - 1 { Divider().padding(.leading, 14) }
                }
            }
        }
    }

    private func resourceRow(_ resource: SpotGuideStore.GuideResource) -> some View {
        Button {
            openURL(resource.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: resource.kind.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(resource.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(near(resource.metres)) · \(resource.providerLabel)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        accessBadge(resource.access)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func accessBadge(_ access: SpotGuideStore.GuideResource.Access) -> some View {
        switch access {
        case .free:
            badge("free", tinted: false)
        case .account:
            badge("account", tinted: true)
        case .unknown:
            EmptyView()
        }
    }

    private func badge(_ text: String, tinted: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                tinted ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                       : AnyShapeStyle(Color(.systemGray5)),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }

    // MARK: Chrome

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    // MARK: Search

    /// The guide's resources and NOAA's stations in parallel, then each
    /// station's reading as it arrives.
    ///
    /// Readings come in a second pass rather than being awaited together: the
    /// list is useful the moment it exists, and eight sequential observation
    /// calls would hold the whole sheet blank for the slowest of them.
    private func search() async {
        isSearching = true
        let here = Geo.Coordinate(latitude: spot.latitude, longitude: spot.longitude)

        async let nearby = guide.nearbyResources(to: spot)
        async let found = NationalWeatherService.stations(near: here)
        (resources, stations) = await (nearby, found)
        isSearching = false

        await withTaskGroup(of: (String, StationObservation?).self) { group in
            for station in stations {
                group.addTask { (station.id, await NationalWeatherService.latest(for: station.id)) }
            }
            for await (id, observation) in group {
                guard let index = stations.firstIndex(where: { $0.id == id }) else { continue }
                stations[index].observation = observation
            }
        }

        // A station with nothing to say is noise on a list whose whole point
        // is live readings — but only drop it once every reading is back.
        stations.removeAll { $0.observation == nil }
    }
}
