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

    let title: String
    let coordinate: Geo.Coordinate
    /// The guide spot this is about, when it is about one. A spot supplies the
    /// region the resource query is scoped to; a bare coordinate borrows the
    /// nearest spot's.
    var spot: GuideSpot?
    /// Which way the beach faces, when the spot knows — turns the surf
    /// tab's offshore/onshore from a swell-relative proxy into the real
    /// thing.
    var shoreFacingDeg: Double?

    init(spot: GuideSpot) {
        self.title = spot.name
        self.coordinate = Geo.Coordinate(latitude: spot.latitude, longitude: spot.longitude)
        self.spot = spot
        self.shoreFacingDeg = spot.shoreFacingDeg
    }

    init(title: String, coordinate: Geo.Coordinate, shoreFacingDeg: Double? = nil) {
        self.title = title
        self.coordinate = coordinate
        self.shoreFacingDeg = shoreFacingDeg
    }

    @Environment(SpotGuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var tab: Tab = .conditions
    @State private var stations: [FreeStation] = []
    /// Every name the registry knows for an instrument — url and gov-id
    /// keys, each mapping to the one registry row they all are.
    @State private var registryAliases: [String: String] = [:]
    @State private var resources: [SpotGuideStore.GuideResource] = []
    @State private var reading: WindReading?
    @State private var weather: SpotWeather?
    @State private var alerts: [WeatherAlert] = []
    @State private var tides: [TideStation] = []
    @State private var buoys: [Buoy] = []
    @State private var surfOutlook = SurfOutlook()
    @State private var outlook = WindOutlook(hours: [], models: [])
    @State private var waves: [WaveHour] = []
    @State private var full = WeatherDetail()
    @State private var surf: SurfConditions?
    @State private var tide = TideCurve(points: [])
    /// The models minus what the nearest anemometer just disagreed by.
    @State private var nowcast: NowcastAdjustment?
    /// Quarter-hour wind, only where a rapid-update model natively has it.
    @State private var nearTerm = NearTermWind(times: [], speedsKn: [], gustsKn: [], directions: [])
    /// The nearest buoy's measured swell split, when one resolves it.
    @State private var measuredSwell: MeasuredSwell?
    /// Four wave models side by side, for the agreement sentence and the
    /// compare screen behind it.
    @State private var swellModels = SwellOutlook(hours: [], models: [])
    /// The wave model minus what the nearest wave buoy just disagreed by.
    @State private var swellNowcast: SwellNowcastAdjustment?
    /// The next two hours of rain — radar while it reaches, hourly after.
    @State private var minuteRain = MinuteRain()
    /// What this week normally does here, to read the forecast against.
    @State private var typicalWeek = TypicalWeek()
    /// And the half of that Apple does not publish — wind, from the archive.
    @State private var typicalWind = TypicalWind()
    @State private var isSearching = true

    /// How far out to look. Persisted, because a rider in a thin part of the
    /// guide widens it once and means it for every spot after that.
    @AppStorage("spots.conditionsRadiusKm") private var radiusKm: Double = 40

    /// Everything is fetched once at `maxRadius` and filtered on the way to
    /// the screen, so dragging the slider costs nothing and never re-hits an
    /// API. Only the widening beyond this would need a refetch, and this is
    /// further than anybody drives for a session.
    private static let maxRadius: Double = 250_000

    private var radius: Double { radiusKm * 1000 }

    private func within(_ items: [SpotGuideStore.GuideResource]) -> [SpotGuideStore.GuideResource] {
        items.filter { $0.metres <= radius }
    }

    enum Tab: String, CaseIterable {
        case conditions = "Weather", water = "Tide", currents = "Current", surf = "Waves", cams = "Cams"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    alertBanner
                    picker
                    radiusSlider
                    switch tab {
                    case .conditions: conditionsTab
                    case .water: tideTab
                    case .currents: CurrentFlowView(coordinate: coordinate)
                    case .surf: surfTab
                    case .cams: camsTab
                    }
                }
                .padding(16)
                // Full screen on an iPad, the cards keep a column instead of
                // stretching a forecast label a foot from its number. Inside
                // the pin below, so the scroll content still measures exactly
                // the viewport and the no-sideways-pan guarantee holds.
                .frame(maxWidth: 700)
                // Pinned to the viewport's width. A vertical scroll view
                // whose content measures even a point wider becomes
                // horizontally draggable, and one over-wide child anywhere
                // in four tabs is all it takes — this makes the sideways
                // pan impossible rather than hunting the child.
                .containerRelativeFrame(.horizontal)
            }
            .background(Color.deepSurface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Nearby conditions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .fullScreenCover(item: $watchingCam) { cam in
            CamViewerSheet(name: cam.displayName, url: cam.url)
        }
        .task(id: taskKey) { await search() }
    }

    private var picker: some View {
        Picker("Section", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    /// How far to look.
    ///
    /// Forty kilometres is right at a well-covered coast and useless in the
    /// places the guide is thin — a rider in rural Oregon or anywhere outside
    /// the app's strongest regions wants to know what is an hour away, not
    /// what is next door. Everything is already fetched wide, so this only
    /// decides how much of it to show.
    private var radiusLabel: String {
        switch settings.units.distance {
        case .imperial: "\(Int((radius / DistanceUnit.metresPerStatuteMile).rounded())) mi"
        case .nautical: "\(Int((radius / DistanceUnit.metresPerNauticalMile).rounded())) NM"
        case .metric: "\(Int(radiusKm)) km"
        }
    }

    private var radiusSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Within")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $radiusKm, in: 10...250, step: 10)
                // Whole units. `Format.distance` carries two decimals, which
                // is right for a session's distance and reads as a bug on a
                // slider that only stops at multiples of ten.
                Text(radiusLabel)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
            Text("Stations, cams and forecasts within this far. Widen it where the guide is thin.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Wind & weather

    @ViewBuilder
    private var conditionsTab: some View {
        modelCard

        // Rain coming sits directly under the readings, above the radar link:
        // "is it about to rain on me" and "show me the rain" are the same
        // thought a second apart, and the nowcast answers it in words before
        // the map has to be read. A dry window says so further down, under
        // the wind — see `dryRainCard`.
        if minuteRain.isWorthShowing {
            MinuteRainCard(rain: minuteRain)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: minuteRain.isEmpty)
        }

        NavigationLink {
            RadarScreen(centre: coordinate, title: "Radar · \(title)")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cloud.rain.fill")
                    .font(.subheadline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Radar")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("NOAA reflectivity over the map")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        NavigationLink {
            FlowMapScreen(title: title, coordinate: coordinate)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wind")
                    .font(.subheadline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.teal)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Flow map")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("The wind as arrows over the water, next 24 hours")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        windAheadCard

        // The dry half of the nowcast, below the wind rather than above it.
        // "No rain in the next six hours" is worth being able to check and
        // never worth the seat directly under the readings — a card that
        // spends the best place on the sheet saying nothing is one a rider
        // stops reading before the day it matters.
        if !minuteRain.isWorthShowing {
            MinuteRainCard(rain: minuteRain)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: minuteRain.isEmpty)
        }

        // Under the week's forecast, because that is what it is for: the
        // normals are the scale the numbers above are read against, and they
        // mean nothing on their own.
        TypicalWeekCard(typical: typicalWeek, wind: typicalWind,
                        forecast: full.days, timeZone: full.timeZone)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: typicalWeek.isEmpty)
            .animation(.easeInOut(duration: 0.25), value: typicalWind.isEmpty)

        section("REAL STATIONS NEARBY, FREE", trailing: {
            mapLink("Wind stations", places: stationPlaces, search: searchStations)
        }) {
            let shown = stations.filter { $0.metres <= radius }
            if shown.isEmpty {
                note(isSearching
                     ? "Looking for public stations…"
                     : stations.isEmpty
                       ? "No free public stations here. NOAA's network is United States only — outside it the model above and the meters below are what there is."
                       : "Nearest free station is \(Format.distance(stations[0].metres, unit: settings.units.distance)) away. Widen the search above to reach it.")
            } else {
                card {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, station in
                        stationRow(station)
                        if index < shown.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                note("NOAA airfield, road and marine sensors. Free to read, no account. They are wherever NOAA put them, not at the launch — check the distance before you trust one.")
            }
        }

        let meters = dedupedMeters(within(resources.filter { $0.kind == .wind }))
        section("WIND METERS IN THE GUIDE", trailing: {
            mapLink("Wind stations", places: stationPlaces, search: searchStations)
        }) {
            if meters.isEmpty {
                note(isSearching ? "Looking…" : "No wind meters this close in the guide. Widen the search, or add one from Improve this spot.")
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

    // MARK: Places on a map

    /// Every wind sensor around this point — NOAA's free network and the
    /// guide's meters, which are usually the paid networks — as one set of
    /// pins. Together on purpose: "is there a station close enough to
    /// believe" is one question, and the answer should not depend on which
    /// list the station happened to be filed under.
    private var stationPlaces: [PlacesMapScreen.Place] {
        stationPlaces(free: stations.filter { $0.metres <= radius },
                      meters: dedupedMeters(within(resources.filter { $0.kind == .wind })))
    }

    /// One instrument, one row — however many names the guide holds for it.
    ///
    /// The same sensor arrives twice three ways. A free station's row already
    /// carries the meter's URL as a provider link (the registry absorb). The
    /// meter's NOAA URL names a station or buoy this sheet is already
    /// rendering live. Or the guide itself holds per-provider rows — Montauk
    /// sits in `windStations` as a CO-OPS row, an NWS row and an NDBC row,
    /// three documents metres apart for one anemometer, and the registry's
    /// one-document rule cannot stop a writer from regressing. Presentation
    /// can: rows arrive nearest-first, and the first of each instrument wins.
    ///
    /// Deduped against what is *shown*, deliberately: when a sensor is down
    /// and its live row dropped, the guide's link is the only door left to
    /// it, and one copy stays.
    private func dedupedMeters(
        _ meters: [SpotGuideStore.GuideResource]
    ) -> [SpotGuideStore.GuideResource] {
        var seen = Set<String>()
        for station in stations {
            seen.insert("gov:\(station.id.lowercased())")
            seen.insert("url:\(station.url.absoluteString.lowercased())")
            for link in station.links {
                seen.insert("url:\(link.url.absoluteString.lowercased())")
            }
            if let row = registryAliases["gov:\(station.id.lowercased())"] {
                seen.insert("reg:\(row)")
            }
        }
        for buoy in buoys {
            seen.insert("gov:\(buoy.id.lowercased())")
            seen.insert("url:\(buoy.url.absoluteString.lowercased())")
        }

        var kept: [SpotGuideStore.GuideResource] = []
        for meter in meters {
            var keys = ["url:\(meter.url.absoluteString.lowercased())"]
            if let id = Self.govStationId(in: meter.url) { keys.append("gov:\(id)") }
            // The registry is the alias table nothing else can be: only it
            // knows that CO-OPS 8510560 and NDBC mtkn6 are one anemometer.
            for key in keys {
                if let row = registryAliases[key] { keys.append("reg:\(row)") }
            }
            // Two rows with one name a stone's throw apart are one sensor
            // whatever their URLs say — compared directly rather than by
            // grid cell, so nothing depends on where a boundary falls.
            let isDuplicate = keys.contains(where: seen.contains) || kept.contains {
                $0.name.caseInsensitiveCompare(meter.name) == .orderedSame &&
                Geo.distance($0.coordinate, meter.coordinate) < 250
            }
            // A duplicate's keys still count: they are aliases of the row
            // that won, and the next alias should match through them —
            // Montauk's NWS row falls to its CO-OPS twin by name, and its
            // gov id is what then catches the NDBC row's third name.
            seen.formUnion(keys)
            guard !isDuplicate else { continue }
            kept.append(meter)
        }
        return kept
    }

    /// The registry, flattened into a lookup: every gov id and provider URL
    /// a row carries maps to that row's document id, so any two of a
    /// sensor's names resolve to the same key.
    private static func registryAliasMap() async -> [String: String] {
        var aliases: [String: String] = [:]
        for row in await WindStationRegistry.crossLinks().values {
            for id in row.govIds { aliases["gov:\(id.lowercased())"] = row.id }
            for link in row.links {
                aliases["url:\(link.url.absoluteString.lowercased())"] = row.id
            }
        }
        return aliases
    }

    /// The government station id a NOAA URL names, when it names one — the
    /// key that recognises an NDBC station page and an api.weather.gov row
    /// as the same piece of hardware.
    private static func govStationId(in url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("ndbc.noaa.gov"),
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "station" })?.value,
           !id.isEmpty {
            return id.lowercased()
        }
        if host == "api.weather.gov" {
            let parts = url.pathComponents
            if let at = parts.firstIndex(of: "stations"), parts.count > at + 1 {
                return parts[at + 1].lowercased()
            }
        }
        return nil
    }

    private func stationPlaces(free: [FreeStation],
                               meters: [SpotGuideStore.GuideResource]) -> [PlacesMapScreen.Place] {
        let free = free.map { station in
            PlacesMapScreen.Place(
                id: "nws-\(station.id)",
                name: station.name,
                subtitle: [near(station.metres), "free NOAA station",
                           station.observation?.windKn.map { "\(Int($0.rounded())) kn now" }]
                    .compactMap { $0 }.joined(separator: " · "),
                coordinate: station.coordinate,
                symbol: "antenna.radiowaves.left.and.right",
                pinText: station.observation?.windKn.map { "\(Int($0.rounded()))kn" },
                url: station.url
            )
        }
        let meters = meters.map { meter in
            PlacesMapScreen.Place(
                id: meter.id,
                name: meter.displayName,
                subtitle: "\(bearingAndDistance(meter)) · \(meter.providerLabel), from the guide",
                coordinate: meter.coordinate,
                symbol: "gauge.with.needle",
                tint: .orange,
                url: meter.url
            )
        }
        return free + meters
    }

    /// NOAA's tide stations and the guide's tide charts, one map.
    private var tidePlaces: [PlacesMapScreen.Place] {
        tidePlaces(noaa: tides.filter { $0.metres <= radius },
                   charts: within(resources.filter { $0.kind == .tide }))
    }

    private func tidePlaces(noaa: [TideStation],
                            charts: [SpotGuideStore.GuideResource]) -> [PlacesMapScreen.Place] {
        let noaa = noaa.map { station in
            PlacesMapScreen.Place(
                id: "noaa-\(station.id)",
                name: station.name,
                subtitle: "\(near(station.metres)) · NOAA harmonic predictions",
                coordinate: station.coordinate,
                symbol: "arrow.up.and.down",
                url: station.url
            )
        }
        let charts = charts.map { chart in
            PlacesMapScreen.Place(
                id: chart.id,
                name: chart.displayName,
                subtitle: "\(bearingAndDistance(chart)) · \(chart.providerLabel), from the guide",
                coordinate: chart.coordinate,
                symbol: "chart.xyaxis.line",
                tint: .orange,
                url: chart.url
            )
        }
        return noaa + charts
    }

    /// The guide's surf pages for this stretch of coast.
    private var surfPlaces: [PlacesMapScreen.Place] {
        surfPlaces(from: within(resources.filter { $0.kind == .surf }))
    }

    private func surfPlaces(from pages: [SpotGuideStore.GuideResource]) -> [PlacesMapScreen.Place] {
        pages.map { page in
            PlacesMapScreen.Place(
                id: page.id,
                name: page.displayName,
                subtitle: "\(bearingAndDistance(page)) · \(page.providerLabel), from the guide",
                coordinate: page.coordinate,
                symbol: "figure.surfing",
                tint: .orange,
                url: page.url
            )
        }
    }

    /// The guide's cams, pinned where they point — and watched in the app.
    private var camPlaces: [PlacesMapScreen.Place] {
        camPlaces(from: within(resources.filter { $0.kind == .camera }))
    }

    private func camPlaces(from cams: [SpotGuideStore.GuideResource]) -> [PlacesMapScreen.Place] {
        cams.map { cam in
            PlacesMapScreen.Place(
                id: cam.id,
                name: cam.displayName,
                subtitle: "\(bearingAndDistance(cam)) · \(cam.providerLabel), from the guide",
                coordinate: cam.coordinate,
                symbol: "video.fill",
                tint: .orange,
                url: cam.url,
                watchInApp: true
            )
        }
    }

    // MARK: - Search this area

    // The maps open on what was fetched around this sheet's own point. When
    // the rider pans to the next bay, these repeat the relevant fetch around
    // wherever the map is looking — the same sources, a new centre. The
    // radius slider deliberately does not gate these: a rider who has panned
    // three bays over has already said the slider's answer is not the one
    // they want.

    private func searchStations(near centre: Geo.Coordinate) async -> [PlacesMapScreen.Place] {
        async let guided = guide.nearbyResources(near: centre, radius: Self.maxRadius)
        var free = await FreeStations.near(centre, limit: 15, radius: Self.maxRadius)
        // The same fill the sheet does: a station is only worth a pin if it
        // is reporting, and the reading is what the pin wears.
        await withTaskGroup(of: (String, StationObservation?).self) { group in
            for station in free {
                group.addTask { (station.id, await FreeStations.latest(for: station)) }
            }
            for await (id, observation) in group {
                guard let at = free.firstIndex(where: { $0.id == id }) else { continue }
                free[at].observation = observation
            }
        }
        free.removeAll { $0.observation == nil }
        return await stationPlaces(free: free, meters: dedupedMeters(guided.filter { $0.kind == .wind }))
    }

    private func searchTides(near centre: Geo.Coordinate) async -> [PlacesMapScreen.Place] {
        async let noaa = TidesAndCurrents.stations(near: centre)
        async let guided = guide.nearbyResources(near: centre, radius: Self.maxRadius)
        return await tidePlaces(noaa: noaa, charts: guided.filter { $0.kind == .tide })
    }

    private func searchSurf(near centre: Geo.Coordinate) async -> [PlacesMapScreen.Place] {
        surfPlaces(from: await guide.nearbyResources(near: centre, radius: Self.maxRadius)
            .filter { $0.kind == .surf })
    }

    private func searchCams(near centre: Geo.Coordinate) async -> [PlacesMapScreen.Place] {
        camPlaces(from: await guide.nearbyResources(near: centre, radius: Self.maxRadius)
            .filter { $0.kind == .camera })
    }

    private func searchBuoys(near centre: Geo.Coordinate) async -> [Buoy] {
        var found = await DataBuoyCenter.buoys(near: centre, limit: 14, radius: Self.maxRadius)
        await withTaskGroup(of: (String, BuoyReading?).self) { group in
            for buoy in found {
                group.addTask { (buoy.id, await DataBuoyCenter.latest(for: buoy.id)) }
            }
            for await (id, reading) in group {
                guard let at = found.firstIndex(where: { $0.id == id }) else { continue }
                found[at].reading = reading
            }
        }
        // Reporting ones only, but no prefix(3) here — three is a list's
        // budget, and a map has room for every buoy that answers.
        return found.filter { $0.reading != nil }
    }

    /// The little map beside a section title, when the section has places
    /// worth seeing on one.
    @ViewBuilder
    private func mapLink(_ title: String, places: [PlacesMapScreen.Place],
                         search: ((Geo.Coordinate) async -> [PlacesMapScreen.Place])? = nil) -> some View {
        if !places.isEmpty {
            NavigationLink {
                PlacesMapScreen(title: title, places: places, from: coordinate, search: search)
            } label: {
                Label("Map", systemImage: "map")
                    .font(.caption2.weight(.semibold))
            }
        }
    }

    /// The estimate the spot page leads with, repeated here with its
    /// provenance spelled out — this sheet exists to rank sources, so the
    /// weakest one has to say what it is.
    private var modelCard: some View {
        NavigationLink {
            CurrentConditionsScreen(title: title, coordinate: coordinate,
                                    detail: full, station: stations.first)
        } label: {
            modelCardBody
        }
        .buttonStyle(.plain)
    }

    private var modelCardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MODEL ESTIMATE, HERE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("All readings")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .center, spacing: 14) {
                if let weather = weather {
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
                    .transition(.opacity)
                } else {
                    VStack(spacing: 4) {
                        LoadingPlaceholder(height: 30, width: 30, corner: 8)
                        LoadingPlaceholder(height: 18, width: 34, corner: 5)
                    }
                    .frame(width: 58)
                    .transition(.opacity)
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
                        // Shaped like the line that is coming — a big number
                        // and its cardinal. What used to sit here was four
                        // stacked 58-point bars, nearly three hundred points
                        // of shimmer where forty were about to land, so the
                        // card collapsed the moment the reading did and took
                        // everything below it up the screen.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            LoadingPlaceholder(height: 30, width: 52, corner: 8)
                            LoadingPlaceholder(height: 17, width: 120, corner: 5)
                        }
                        .padding(.vertical, 3)
                        .transition(.opacity)
                    }
                    if let weather = weather {
                        Text(weather.label + (weather.apparentC.map { ", feels \(Int($0.rounded()))°" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    } else {
                        LoadingPlaceholder(height: 12, width: 150, corner: 4)
                            .padding(.top, 2)
                            .transition(.opacity)
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
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        .animation(.easeInOut(duration: 0.25), value: reading == nil)
        .animation(.easeInOut(duration: 0.25), value: weather == nil)
    }

    /// The wind ahead: one strip, quarter-hour while a rapid-update model
    /// still has it and hourly after, with the models' own argument about
    /// it underneath.
    ///
    /// This was two cards — six hours at fifteen-minute grain, then a day
    /// at hourly — which drew the same wind twice at two scales and asked
    /// the rider to join them up in their head. One scrolling strip says it
    /// once, in the map's own colours, with the numbers written on it.
    @ViewBuilder
    private var windAheadCard: some View {
        let track = WindTrack.make(nearTerm: nearTerm, outlook: ahead)
        Group {
            if !track.isEmpty {
                NavigationLink {
                    ForecastScreen(title: title, coordinate: coordinate, detail: full,
                                   outlook: ahead, waves: waves)
                } label: {
                    windAheadBody(track)
                }
                .buttonStyle(.plain)
            } else if isSearching {
                windAheadPlaceholder
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: track.isEmpty)
    }

    /// The strip's own shape, held while the forecast is in flight.
    ///
    /// This card is a quarter of the tab's height and used to render as
    /// nothing at all until the run landed, so the stations, the meters and
    /// everything under them started high and were shoved down the screen
    /// mid-read. Holding the space costs nothing and the wind fades into it.
    ///
    /// Only while the search is actually running: a point with no forecast
    /// at all — the marine grid has holes — must end up with no card rather
    /// than a shimmer that never resolves.
    private var windAheadPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LoadingPlaceholder(height: 11, width: 132, corner: 4)
                Spacer(minLength: 0)
                LoadingPlaceholder(height: 11, width: 70, corner: 4)
            }
            HStack(alignment: .top, spacing: 6) {
                LoadingPlaceholder(height: 152, width: 34, corner: 8)
                LoadingPlaceholder(height: 152, corner: 8)
            }
            LoadingPlaceholder(height: 11, corner: 4)
            LoadingPlaceholder(height: 11, width: 210, corner: 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel("Loading the wind forecast")
    }

    /// The window the cards speak for. The raw `outlook` keeps its head
    /// start — the nowcast needs the hour a station's reading was taken in.
    ///
    /// Two days rather than one: a strip that stops at this hour tomorrow
    /// cannot answer "is it worth going out after work tomorrow", which is
    /// the question a rider opens this card with the evening before. The
    /// strip scrolls, so the extra day costs width rather than legibility,
    /// and it is one more calendar day on a request already being made.
    private var ahead: WindOutlook { outlook.nextHours(48) }

    private func windAheadBody(_ track: WindTrack) -> some View {
        let agreement = ahead.agreement

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WIND, NEXT 48 HOURS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Disagreement warns from the icon; the words stay in a
                // colour that can be read.
                if ahead.spreadKn >= 8 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                }
                Text(agreement.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ahead.spreadKn < 8 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            WindTrackChart(track: track, skySymbol: skySymbol(at:))

            if let age = ahead.staleAge {
                Label {
                    Text("No network right now — this is the model from \(Format.duration(age)) ago, not a fresh run.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.harbourNavy)
            }

            Text(agreement.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A real anemometer against the models — the one line on this
            // card that is measured rather than modelled, which is exactly
            // why it gets to talk back to the chart above it. The alert
            // lives in the icon, never the type: orange words on the blue
            // wash were unreadable, and a sentence a rider must actually
            // read should not wear the warning colour.
            if let nowcast {
                Label {
                    Text(nowcast.line)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: abs(nowcast.deltaKn) < 1.5
                          ? "gauge.with.needle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(abs(nowcast.deltaKn) < 1.5
                                         ? AnyShapeStyle(Color.harbourNavy)
                                         : AnyShapeStyle(Color.orange))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.harbourNavy)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tintWash, in: RoundedRectangle(cornerRadius: 12))
            }

            Text(trackSource(track))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Where the strip's two halves come from, said once. The fine half
    /// only exists where a rapid-update model natively resolves this water,
    /// so the sentence has to change rather than promise it everywhere.
    private func trackSource(_ track: WindTrack) -> String {
        let models = "the hourly average of \(ahead.models.count) global models"
        guard track.handover != nil else {
            return "Scroll for the day ahead — \(models). Tap for each of them, the hour by hour, and the week."
        }
        return "Scroll for the day ahead. The narrow bars are quarter-hour steps from a rapid-update model — HRRR, ICON-D2 or AROME, wherever one of them resolves this water — then \(models). Tap for each model, the hour by hour, and the week."
    }

    /// The sky over one moment of the forecast, from the full detail the
    /// sheet already fetched — sun, cloud, rain, each in its own colours so
    /// the row reads at a glance.
    private func skySymbol(at date: Date) -> String? {
        skyCode(at: date).map { SpotWeather.symbol(for: $0, isDay: isDaylight(date)) }
    }

    /// The WMO code for the hour nearest a moment, when the detail knows it.
    private func skyCode(at date: Date) -> Int? {
        full.hours
            .min { abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date)) }
            .flatMap { abs($0.at.timeIntervalSince(date)) <= 3600 ? $0.code : nil }
    }

    /// Sun or moon variants, decided by the day's own sunrise and sunset
    /// when the forecast carries them, by a plain 7-to-7 otherwise.
    private func isDaylight(_ date: Date) -> Bool {
        if let day = full.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }),
           let sunrise = day.sunrise, let sunset = day.sunset {
            return date >= sunrise && date <= sunset
        }
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 7 && hour < 19
    }

    /// Sea state ahead, where there is any sea.
    @ViewBuilder
    private var waveCard: some View {
        if !waves.isEmpty {
            let peak = max(waves.compactMap(\.heightM).max() ?? 1, 0.3)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("WAVES, NEXT 24 HOURS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let now = waves.first {
                        Text(String(format: "%.1f m", now.heightM ?? 0)
                             + (now.periodS.map { " @ \(Int($0.rounded()))s" } ?? ""))
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                    }
                }

                ZStack(alignment: .bottom) {
                    // Metres, and small ones — half-metre rules, and no
                    // "firing" line because there is no such threshold here.
                    ChartGrid(peak: peak, step: peak > 3 ? 1 : 0.5, unit: "m", highlight: nil)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(waves) { hour in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.teal.opacity(0.5))
                                .frame(height: max(2, 50 * (hour.heightM ?? 0) / peak))
                                .frame(maxWidth: .infinity, alignment: .bottom)
                        }
                    }
                }
                .frame(height: 50, alignment: .bottom)

                Text("Open-Meteo's marine model — significant wave height, worldwide and free. A forecast, not a buoy.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
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
        // The registry's second door: the tap stays on the free NOAA page,
        // and a rider who pays for the network this sensor is also on gets
        // their app one press deeper.
        .contextMenu {
            ForEach(station.links, id: \.self) { link in
                Button {
                    openURL(link.url)
                } label: {
                    Label("Open in \(link.label)", systemImage: "arrow.up.forward.app")
                }
            }
        }
    }

    /// Distance first, then whatever the station is actually saying — and
    /// when it last said it, because a dead sensor reading 0 kn looks exactly
    /// like a calm day.
    /// "0 m" is technically true and reads like a bug. A resource pinned at
    /// the launch itself should say so.
    private func near(_ metres: Double) -> String {
        metres < 100 ? "at this spot" : Format.distance(metres, unit: settings.units.distance)
    }

    /// "3.7 mi WNW", or just "at this spot" when a bearing would be noise.
    private func bearingAndDistance(_ resource: SpotGuideStore.GuideResource) -> String {
        guard resource.metres >= 100 else { return near(resource.metres) }
        return "\(near(resource.metres)) \(Format.cardinal(resource.bearing))"
    }

    private func stationSubtitle(_ station: FreeStation) -> String {
        var parts = [near(station.metres)]
        if let observation = station.observation {
            if let direction = observation.directionDeg {
                parts.append(Format.cardinal(direction))
            }
            if let temperature = observation.temperatureC {
                parts.append(Format.temperature(temperature, unit: settings.units.temperatureUnit))
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
        // So the second door is discoverable without knowing about the
        // long-press: the context menu is where it opens from.
        for link in station.links { parts.append("also on \(link.label)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Water

    /// Tide and sea state — measured, not modelled.
    ///
    /// Both of these matter more here than in most weather apps. A downwinder
    /// against an ebb is a different run from the same one on a flood, and
    /// water temperature decides what a rider puts on, which in a lot of the
    /// places this app is used is a safety question rather than a comfort one.

    @ViewBuilder
    private var tideTab: some View {
        if !tide.isEmpty {
            // A push rather than a full-screen cover, and into a screen of
            // cards rather than a bare chart — the same door the wind card
            // opens, so "tap the chart for the detail" means one thing on
            // this sheet.
            NavigationLink {
                TideScreen(curve: tide, title: title)
            } label: {
                VStack(alignment: .trailing, spacing: 4) {
                    // Two days on the card, ten behind the chevron. The card
                    // is a glance — the shape of today and tomorrow, with
                    // every turn labelled — and the whole run drawn into it
                    // would be a scribble under a pile of overlapping times.
                    TideChart(curve: tide.window(hours: 48))
                    HStack(spacing: 3) {
                        Text("Hour by hour")
                            .font(.caption2.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
        } else if isSearching {
            note("Reading the tide…")
        }

        section("TIDE STATIONS", trailing: {
            mapLink("Tide stations", places: tidePlaces, search: searchTides)
        }) {
            let shownTides = tides.filter { $0.metres <= radius }
            if shownTides.isEmpty {
                note(isSearching
                     ? "Looking for tide stations…"
                     : "No NOAA tide station within reach. Their harmonic predictions are United States only — the curve above is the worldwide model, and stands in everywhere else.")
            } else {
                card {
                    ForEach(Array(shownTides.enumerated()), id: \.element.id) { index, station in
                        tideRow(station)
                        if index < shownTides.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                note("NOAA CO-OPS predictions, heights above MLLW. Predicted, not measured — wind and pressure move real water levels around the forecast.")
            }
        }

        let tideLinks = within(resources.filter { $0.kind == .tide })
        if !tideLinks.isEmpty {
            section("TIDE CHARTS IN THE GUIDE") {
                card {
                    ForEach(Array(tideLinks.enumerated()), id: \.element.id) { index, link in
                        resourceRow(link)
                        if index < tideLinks.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
            }
        }
    }

    /// Everything about waves: what is running now, what is forecast, the
    /// buoys measuring it, and the surf pages for this stretch of coast.
    @ViewBuilder
    private var surfTab: some View {
        if let surf {
            SurfCard(surf: surf, windDirectionDeg: reading?.directionDeg)

            // The opinion, under the facts it was formed from.
            SurfRatingCard(rating: SurfRating.rate(
                trains: [surf.primarySwell, surf.secondarySwell].compactMap { $0?.core },
                shore: shoreFacingDeg.map { ShoreGeometry(waterFacingDeg: $0) },
                windKn: reading?.speedKn,
                windFromDeg: reading?.directionDeg))
        }

        if let measuredSwell {
            MeasuredSwellCard(measured: measuredSwell)
        }

        // A real wave sensor against the model — the one sentence here
        // that is measured, which is why it gets to talk back to the
        // forecast below it. Same rule as the wind nowcast: the warning
        // colour goes on the icon, the words stay legible.
        if let swellNowcast {
            Label {
                Text(swellNowcast.line(unit: settings.units.distance))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: abs(swellNowcast.deltaM) < 0.15
                      ? "water.waves" : "exclamationmark.triangle.fill")
                    .foregroundStyle(abs(swellNowcast.deltaM) < 0.15
                                     ? AnyShapeStyle(Color.harbourNavy)
                                     : AnyShapeStyle(Color.orange))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.harbourNavy)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tintWash, in: RoundedRectangle(cornerRadius: 12))
        }

        if let age = surf?.staleAge ?? surfOutlook.staleAge {
            Label {
                Text("No network right now — this is the wave model from \(Format.duration(age)) ago, not a fresh run.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "wifi.slash")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.harbourNavy)
        }

        waveCard

        if !surfOutlook.isEmpty {
            section("NEXT FEW DAYS") {
                card {
                    SurfOverviewStrip(outlook: surfOutlook)
                }
            }
        }

        // One sentence of error bar: how far apart four agencies' wave
        // models sit here, with the full comparison a tap away.
        if !swellModels.isEmpty {
            NavigationLink {
                SwellCompareScreen(title: title, coordinate: coordinate)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(swellModels.agreement.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(swellModels.agreement.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }

        // The multi-day view, which is the question a surf tab is really
        // being asked: not "what is it doing" but "when should I go".
        NavigationLink {
            SurfForecastScreen(coordinate: coordinate, title: title,
                               shoreFacingDeg: shoreFacingDeg, initial: surfOutlook)
        } label: {
            HStack {
                Label("Multi-day forecast", systemImage: "calendar")
                    .font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.deepCard,
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)

        let mappableBuoys = buoys.filter { $0.metres <= radius }
        section("BUOYS", trailing: {
            if !mappableBuoys.isEmpty {
                NavigationLink {
                    BuoyMapScreen(buoys: mappableBuoys, from: coordinate, search: searchBuoys)
                } label: {
                    Label("Map", systemImage: "map")
                        .font(.caption2.weight(.semibold))
                }
            }
        }) {
            let shownBuoys = mappableBuoys
            if shownBuoys.isEmpty {
                note(isSearching
                     ? "Looking for buoys…"
                     : buoys.isEmpty
                       ? "No NOAA buoy reporting nearby. Waves and water temperature come from NDBC, which is United States coastal — and its sensors go down often enough that a quiet stretch of coast is normal."
                       : "Nearest reporting buoy is \(Format.distance(buoys[0].metres, unit: settings.units.distance)) away. Widen the search above to reach it.")
            } else {
                card {
                    ForEach(Array(shownBuoys.enumerated()), id: \.element.id) { index, buoy in
                        buoyRow(buoy)
                        if index < shownBuoys.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                note("NOAA's National Data Buoy Center. Wave height, period and water temperature, measured on the water.")
            }
        }

        let allSurfLinks = resources.filter { $0.kind == .surf }
        let surfLinks = within(allSurfLinks)
        section("SURF FORECASTS IN THE GUIDE", trailing: {
            mapLink("Surf pages", places: surfPlaces, search: searchSurf)
        }) {
            if surfLinks.isEmpty {
                // Say how far the nearest one is rather than only that there
                // is none in range — "none this close" and "none at all" are
                // different answers, and the slider fixes exactly one of them.
                note(isSearching
                     ? "Looking…"
                     : allSurfLinks.isEmpty
                       ? "No surf or marine forecast pages for this stretch of coast in the guide yet."
                       : "Nearest surf page is \(Format.distance(allSurfLinks[0].metres, unit: settings.units.distance)) away. Widen the search above to reach it.")
            } else {
                card {
                    ForEach(Array(surfLinks.enumerated()), id: \.element.id) { index, link in
                        resourceRow(link)
                        if index < surfLinks.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
            }
        }
    }

    private func tideRow(_ station: TideStation) -> some View {
        Button {
            openURL(station.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "water.waves.and.arrow.trianglehead.up")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(tideSubtitle(station))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let next = station.next {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(next.isHigh ? "HIGH" : "LOW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(next.isHigh ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(next.at.formatted(date: .omitted, time: .shortened))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
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

    /// Distance, then the whole day's turns — a rider planning a downwinder
    /// wants the shape of the tide, not only the next event.
    private func tideSubtitle(_ station: TideStation) -> String {
        var parts = [near(station.metres)]
        if station.events.isEmpty {
            parts.append("no predictions")
        } else {
            parts.append(station.events.map {
                "\($0.isHigh ? "H" : "L") \($0.at.formatted(date: .omitted, time: .shortened))"
            }.joined(separator: "  "))
        }
        return parts.joined(separator: " · ")
    }

    private func buoyRow(_ buoy: Buoy) -> some View {
        // To the buoy's own page rather than straight out to NDBC. Leaving
        // the app was the only thing a rider could do with a buoy, which is a
        // strange end for the one reading here that is actually measured.
        NavigationLink {
            BuoyDetailScreen(buoy: buoy, from: coordinate)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(buoy.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(buoySubtitle(buoy))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let water = buoy.reading?.waterTempC {
                    Text("\(Int(water.rounded()))°")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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

    private func buoySubtitle(_ buoy: Buoy) -> String {
        var parts = [near(buoy.metres)]
        if let reading = buoy.reading {
            if let wave = reading.waveHeightM {
                parts.append(String(format: "%.1f m", wave)
                             + (reading.dominantPeriodS.map { " @ \(Int($0))s" } ?? ""))
            }
            if let wind = reading.windKn { parts.append("\(Int(wind.rounded())) kn") }
            if let at = reading.at {
                parts.append(at.formatted(date: .omitted, time: .shortened))
            }
        } else {
            parts.append("no recent reading")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Alerts

    /// Above everything, on every tab.
    ///
    /// A Small Craft Advisory is not a detail to find under a heading — it is
    /// the answer to the question the whole screen exists for, and it should
    /// not be possible to miss it by being on the wrong tab.
    @ViewBuilder
    private var alertBanner: some View {
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(alerts.prefix(3)) { alert in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: alert.isSevere ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(alert.isSevere ? Color.orange : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.event)
                                .font(.subheadline.weight(.semibold))
                            Text(alert.headline ?? "In force now")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Text("National Weather Service, in force at this point.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Cams and surf

    /// The cam a rider is watching right now, inside the app.
    @State private var watchingCam: SpotGuideStore.GuideResource?

    @ViewBuilder
    private var camsTab: some View {
        section("CAMS IN THE GUIDE", trailing: {
            mapLink("Cams", places: camPlaces, search: searchCams)
        }) {
            list(of: .camera, empty: "No webcams this close in the guide. Widen the search to look further.")
        }
    }

    @ViewBuilder
    private func list(of kind: SpotGuideStore.SpotLink.Kind, empty: String) -> some View {
        let items = within(resources.filter { $0.kind == kind })
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
            // Cams stay in the app — YouTube embeds play right here, and
            // everything else gets the in-app browser. The rest of the
            // resources are reference pages, and those still hand off.
            if resource.kind == .camera {
                watchingCam = resource
            } else {
                openURL(resource.url)
            }
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
                        // Which way, not only how far. Eleven map links from
                        // one provider all carry the same name; the bank of
                        // the river they point at is what separates them.
                        Text("\(bearingAndDistance(resource)) · \(resource.providerLabel)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        accessBadge(resource.access)
                    }
                }
                Spacer(minLength: 0)
                // A cam plays here; everything else leaves for its page —
                // and the trailing icon says which before the tap.
                Image(systemName: resource.kind == .camera ? "play.rectangle" : "arrow.up.forward")
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
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    /// A section with a control beside its title — a map, usually, for the
    /// rows that are places rather than numbers.
    private func section<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 2)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
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
    private var taskKey: String {
        spot?.spotId ?? String(format: "@%.3f,%.3f", coordinate.latitude, coordinate.longitude)
    }

    // A spot goes through the spot-keyed calls so it shares the cache the spot
    // page has usually already filled; a bare coordinate takes the coordinate
    // ones. Written out rather than folded into `map`, which cannot carry an
    // `async` closure.

    private func findResources(_ here: Geo.Coordinate) async -> [SpotGuideStore.GuideResource] {
        if let spot { return await guide.nearbyResources(to: spot, radius: Self.maxRadius) }
        return await guide.nearbyResources(near: here, radius: Self.maxRadius)
    }

    private func findWeather(_ here: Geo.Coordinate) async -> SpotWeather? {
        if let spot { return await guide.weather(for: spot) }
        return await guide.weather(at: here)
    }

    private func findWind(_ here: Geo.Coordinate) async -> WindReading? {
        if let spot, let known = guide.wind[spot.spotId] { return known }
        return await guide.currentWind(at: here)
    }

    private func search() async {
        isSearching = true
        let here = coordinate

        async let nearby = findResources(here)
        async let aliases = Self.registryAliasMap()
        async let found = FreeStations.near(here, limit: 15, radius: Self.maxRadius)
        async let air = findWeather(here)
        async let blowing = findWind(here)
        async let warnings = NationalWeatherService.alerts(at: here)
        async let tideList = TidesAndCurrents.stations(near: here)
        async let buoyList = DataBuoyCenter.buoys(near: here, limit: 14, radius: Self.maxRadius)
        // Three calendar days: the card draws 48 hours from this hour, and
        // the run opens at local midnight — so an evening rider has most of
        // day one already behind them and needs the third to reach the end.
        async let ahead = OpenMeteo.outlook(at: here, days: 3)
        async let sea = OpenMeteo.waves(at: here)
        async let everything = OpenMeteo.detail(at: here)
        async let sea2 = OpenMeteo.surf(at: here)
        async let water = Tides.curve(at: here)
        (resources, stations, weather, reading) = await (nearby, found, air, blowing)
        registryAliases = await aliases
        (alerts, tides, buoys) = await (warnings, tideList, buoyList)
        (outlook, waves, full) = await (ahead, sea, everything)
        (surf, tide) = await (sea2, water)
        isSearching = false

        // The multi-day outlook is two more calls, so it lands after the tab
        // is usable rather than holding it blank — the strip appears when it
        // arrives, in space the rest of the tab is not occupying.
        //
        // The three normals-and-nowcast calls ride in the same wave, and the
        // Apple pair for a stronger reason: they are the only calls on this
        // sheet that can fail for something the rider cannot fix — no
        // entitlement, no Apple service in this country. Nothing above them
        // may wait on that.
        async let quarterly = OpenMeteo.nearTerm(at: here)
        async let waveAgencies = OpenMeteo.swellOutlook(at: here)
        async let radarMinutes = AppleWeather.minuteRain(at: here)
        // Keyed to the spot's own midnight, which the detail run above has
        // already resolved — the normals only line up with the forecast they
        // are drawn against if both weeks start on the same day.
        async let normals = AppleWeather.typicalWeek(at: here, timeZone: full.timeZone)
        async let windNormals = OpenMeteo.typicalWind(at: here, timeZone: full.timeZone)
        surfOutlook = await OpenMeteo.surfOutlook(at: here)
            .applyingShoreFacing(shoreFacingDeg)
        nearTerm = await quarterly
        swellModels = await waveAgencies
        minuteRain = await radarMinutes
        typicalWeek = await normals
        typicalWind = await windNormals

        // Predictions and buoy rows come second, for the same reason station
        // readings do: the lists are useful the moment they exist, and half a
        // dozen sequential fetches would hold the whole tab blank.
        await withTaskGroup(of: (String, [TideEvent]).self) { group in
            for station in tides {
                group.addTask { (station.id, await TidesAndCurrents.today(for: station.id)) }
            }
            for await (id, events) in group {
                guard let at = tides.firstIndex(where: { $0.id == id }) else { continue }
                tides[at].events = events
            }
        }
        await withTaskGroup(of: (String, BuoyReading?).self) { group in
            for buoy in buoys {
                group.addTask { (buoy.id, await DataBuoyCenter.latest(for: buoy.id)) }
            }
            for await (id, reading) in group {
                guard let at = buoys.firstIndex(where: { $0.id == id }) else { continue }
                buoys[at].reading = reading
            }
        }
        // Keep the nearest few that are actually reporting. Asking for more
        // than we show is the point: a buoy whose sensors are down should not
        // cost the list a slot.
        buoys = Array(buoys.filter { $0.reading != nil }.prefix(3))

        // The measured swell split, from the nearest buoy whose .spec file
        // resolves one. In order of distance because the question is "what
        // is the sea here doing", and a fresher reading further away does
        // not answer it better.
        measuredSwell = nil
        for buoy in buoys {
            guard let spectral = await DataBuoyCenter.spectral(for: buoy.id),
                  Date().timeIntervalSince(spectral.at) < 2 * 3600,
                  spectral.swell != nil || spectral.windWave != nil
            else { continue }
            measuredSwell = MeasuredSwell(buoy: buoy, reading: spectral)
            break
        }

        await withTaskGroup(of: (String, StationObservation?).self) { group in
            for station in stations {
                group.addTask { (station.id, await FreeStations.latest(for: station)) }
            }
            for await (id, observation) in group {
                guard let index = stations.firstIndex(where: { $0.id == id }) else { continue }
                stations[index].observation = observation
            }
        }

        // A station with nothing to say is noise on a list whose whole point
        // is live readings — but only drop it once every reading is back.
        stations.removeAll { $0.observation == nil }

        // With every reading home, the freshest nearby anemometer gets to
        // correct the models' next few hours. Last on purpose: it needs the
        // outlook and the observations both, and it is a sentence, not a
        // card the sheet should wait for.
        nowcast = NowcastAdjustment.make(outlook: outlook, stations: stations, buoys: buoys)
        // And the wave buoy gets the same say over the wave model.
        swellNowcast = SwellNowcastAdjustment.make(outlook: surfOutlook, buoys: buoys)
    }
}
