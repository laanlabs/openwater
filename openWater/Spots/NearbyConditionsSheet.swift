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

    init(spot: GuideSpot) {
        self.title = spot.name
        self.coordinate = Geo.Coordinate(latitude: spot.latitude, longitude: spot.longitude)
        self.spot = spot
    }

    init(title: String, coordinate: Geo.Coordinate) {
        self.title = title
        self.coordinate = coordinate
    }

    @Environment(SpotGuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var tab: Tab = .conditions
    @State private var stations: [FreeStation] = []
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
        case conditions = "Weather", water = "Tide", surf = "Surf", cams = "Cams"
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
                    case .surf: surfTab
                    case .cams: list(of: .camera, empty: "No webcams this close in the guide. Widen the search to look further.")
                    }
                }
                .padding(16)
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
        .fullScreenCover(isPresented: $isShowingTideFullScreen) {
            TideFullScreen(curve: tide, title: title)
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

        nearTermCard

        outlookCard

        section("REAL STATIONS NEARBY, FREE") {
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

        let meters = within(resources.filter { $0.kind == .wind })
        section("WIND METERS IN THE GUIDE") {
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
                        VStack(spacing: 12) {
                            ForEach(0..<4, id: \.self) { _ in
                                LoadingPlaceholder(height: 58, corner: 12)
                            }
                        }
                        .padding(.horizontal)
                    }
                    if let weather = weather {
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
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    /// The next 24 hours, and how much the models argue about them.
    ///
    /// Drawn as one bar per hour at the consensus, with a whisker showing the
    /// range across models — so the eye reads the shape of the day first and
    /// the confidence second, which is the order a rider thinks in.
    @ViewBuilder
    private var outlookCard: some View {
        if !outlook.isEmpty {
            NavigationLink {
                ForecastScreen(title: title, coordinate: coordinate, detail: full, outlook: outlook, waves: waves)
            } label: {
                outlookCardBody
            }
            .buttonStyle(.plain)
        }
    }

    /// The next six hours at quarter-hour grain — only where HRRR, ICON-D2
    /// or AROME natively resolve it, which is the whole point of showing it:
    /// this is the card that can see a sea breeze switch on inside an hour,
    /// and pretending to that grain from interpolated hourly data would be
    /// the false precision the rest of the sheet is against.
    @ViewBuilder
    private var nearTermCard: some View {
        if !nearTerm.isEmpty {
            // Gusts set the scale, not the means — the caps have to fit
            // under the same grid the bars use.
            let peak = max((nearTerm.speedsKn + nearTerm.gustsKn).compactMap { $0 }.max() ?? 1, 1)
            NavigationLink {
                ForecastScreen(title: title, coordinate: coordinate, detail: full,
                               outlook: outlook, waves: waves)
            } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("NEXT SIX HOURS · EVERY 15 MIN")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let gust = nearTerm.peakGustKn {
                        Text("gusts to \(Int(gust.rounded())) kn")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Grid above the bars, the way the comps draw it — the caps
                // reach high enough that labels behind them would vanish.
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(nearTerm.times.indices, id: \.self) { step in
                            GustBar(meanKn: (nearTerm.speedsKn[safe: step] ?? nil) ?? 0,
                                    gustKn: nearTerm.gustsKn[safe: step] ?? nil,
                                    peak: peak, height: 54, cornerRadius: 1.5)
                        }
                    }
                    ChartGrid(peak: peak)
                }
                .frame(height: 54, alignment: .bottom)

                // On the hour, under the four bars it speaks for: the wind's
                // arrow, and the sky it blows under.
                HStack(spacing: 2) {
                    ForEach(nearTerm.times.indices, id: \.self) { step in
                        Group {
                            if step % 4 == 0,
                               let direction = nearTerm.directions[safe: step] ?? nil {
                                VStack(spacing: 4) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .rotationEffect(.degrees(direction))
                                        .foregroundStyle(.secondary)
                                    skyIcon(at: nearTerm.times[step])
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                HStack {
                    Text("now")
                    Spacer()
                    if let middle = nearTerm.times[safe: nearTerm.times.count / 2] {
                        Text(middle.formatted(.dateTime.hour().minute()))
                    }
                    Spacer()
                    if let last = nearTerm.times.last {
                        Text(last.formatted(.dateTime.hour().minute()))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text("Quarter-hour steps straight from a rapid-update model — HRRR over North America, ICON-D2 and AROME over Europe. This card only exists where one of them actually resolves this water.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
        }
    }

    /// The sky over one moment of the forecast, from the full detail the
    /// sheet already fetched — sun, cloud, rain, each in its own colours so
    /// the row reads at a glance.
    @ViewBuilder
    private func skyIcon(at date: Date) -> some View {
        if let code = skyCode(at: date) {
            Image(systemName: SpotWeather.symbol(for: code, isDay: isDaylight(date)))
                .font(.system(size: 11))
                .symbolRenderingMode(.multicolor)
        }
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

    @ViewBuilder
    private var outlookCardBody: some View {
        if !outlook.isEmpty {
            let consensus = outlook.consensus
            let gusts = outlook.consensusGusts
            let peak = max((consensus + gusts).compactMap { $0 }.max() ?? 1, 1)
            let agreement = outlook.agreement

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("NEXT 24 HOURS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(agreement.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(outlook.spreadKn < 8 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.orange))
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Consensus only. The first version drew a whisker above every
                // bar for the spread between models, which was accurate and
                // unreadable — twenty-four thin spikes over twenty-four bars.
                // The disagreement is now one sentence below, and the per-model
                // lines live on the detail screen where there is room for them.
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(outlook.hours.indices, id: \.self) { hour in
                            GustBar(meanKn: (consensus[safe: hour] ?? nil) ?? 0,
                                    gustKn: gusts[safe: hour] ?? nil,
                                    peak: peak, height: 62, cornerRadius: 2)
                        }
                    }
                    ChartGrid(peak: peak)
                }
                .frame(height: 62, alignment: .bottom)

                // Under the bars, every third hour: the wind's arrow and the
                // sky's icon. Speed decides whether you go, direction decides
                // whether the spot works at all, and the sky is the context
                // both sit in — sea breezes live and die by the sun.
                // Independent models only, matching the consensus above.
                let directions = outlook.blendDirections(
                    of: Set(outlook.models.filter { !$0.isComposite }.map(\.id)))
                HStack(spacing: 3) {
                    ForEach(outlook.hours.indices, id: \.self) { hour in
                        Group {
                            if hour % 3 == 0, let direction = directions[safe: hour] ?? nil {
                                VStack(spacing: 4) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .rotationEffect(.degrees(direction))
                                        .foregroundStyle(.secondary)
                                    skyIcon(at: outlook.hours[hour])
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                HStack {
                    Text("now")
                    Spacer()
                    if let middle = outlook.hours[safe: outlook.hours.count / 2] {
                        Text(middle.formatted(.dateTime.hour()))
                    }
                    Spacer()
                    if let last = outlook.hours.last {
                        Text(last.formatted(.dateTime.hour()))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if let age = outlook.staleAge {
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

                // A real anemometer against the models — the one line on
                // this card that is measured rather than modelled, which is
                // exactly why it gets to talk back to the chart above it.
                if let nowcast {
                    Label {
                        Text(nowcast.line)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "gauge.with.needle")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(abs(nowcast.deltaKn) < 1.5 ? AnyShapeStyle(Color.harbourNavy)
                                     : AnyShapeStyle(Color.orange))
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tintWash, in: RoundedRectangle(cornerRadius: 12))
                }

                Text("Average of \(outlook.models.count) global models — tap for each of them, the hour by hour, and the week.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
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
        return parts.joined(separator: " · ")
    }

    // MARK: Water

    /// Tide and sea state — measured, not modelled.
    ///
    /// Both of these matter more here than in most weather apps. A downwinder
    /// against an ebb is a different run from the same one on a flood, and
    /// water temperature decides what a rider puts on, which in a lot of the
    /// places this app is used is a safety question rather than a comfort one.
    @State private var isShowingTideFullScreen = false

    @ViewBuilder
    private var tideTab: some View {
        if !tide.isEmpty {
            Button {
                isShowingTideFullScreen = true
            } label: {
                VStack(alignment: .trailing, spacing: 4) {
                    TideChart(curve: tide)
                    Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
        } else if isSearching {
            note("Reading the tide…")
        }

        section("TIDE STATIONS") {
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
        }

        waveCard

        if !surfOutlook.isEmpty {
            section("NEXT FEW DAYS") {
                card {
                    SurfOverviewStrip(outlook: surfOutlook)
                }
            }
        }

        // The multi-day view, which is the question a surf tab is really
        // being asked: not "what is it doing" but "when should I go".
        NavigationLink {
            SurfForecastScreen(coordinate: coordinate, title: title)
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
                    BuoyMapScreen(buoys: mappableBuoys, from: coordinate)
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
        section("SURF FORECASTS IN THE GUIDE") {
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
        async let found = NationalWeatherService.stations(near: here, limit: 15)
        async let air = findWeather(here)
        async let blowing = findWind(here)
        async let warnings = NationalWeatherService.alerts(at: here)
        async let tideList = TidesAndCurrents.stations(near: here)
        async let buoyList = DataBuoyCenter.buoys(near: here, limit: 14, radius: Self.maxRadius)
        async let ahead = OpenMeteo.outlook(at: here)
        async let sea = OpenMeteo.waves(at: here)
        async let everything = OpenMeteo.detail(at: here)
        async let sea2 = OpenMeteo.surf(at: here)
        async let water = OpenMeteo.tide(at: here)
        (resources, stations, weather, reading) = await (nearby, found, air, blowing)
        (alerts, tides, buoys) = await (warnings, tideList, buoyList)
        (outlook, waves, full) = await (ahead, sea, everything)
        (surf, tide) = await (sea2, water)
        isSearching = false

        // The multi-day outlook is two more calls, so it lands after the tab
        // is usable rather than holding it blank — the strip appears when it
        // arrives, in space the rest of the tab is not occupying.
        async let quarterly = OpenMeteo.nearTerm(at: here)
        surfOutlook = await OpenMeteo.surfOutlook(at: here)
        nearTerm = await quarterly

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

        // With every reading home, the freshest nearby anemometer gets to
        // correct the models' next few hours. Last on purpose: it needs the
        // outlook and the observations both, and it is a sentence, not a
        // card the sheet should wait for.
        nowcast = NowcastAdjustment.make(outlook: outlook, stations: stations, buoys: buoys)
    }
}

/// One forecast bar: solid to the mean, with a Foam cap up to the gust.
///
/// The cap is the headroom that knocks you over, so it gets its own colour
/// on top of the bar rather than the old scheme of paling the whole bar —
/// which flattened a gusty 8 kn and a steady 8 kn into the same picture.
struct GustBar: View {

    let meanKn: Double
    let gustKn: Double?
    /// The chart's full-scale value — the caller must fold gusts into it,
    /// or the caps overflow the frame.
    let peak: Double
    let height: Double
    let cornerRadius: Double

    var body: some View {
        VStack(spacing: 0) {
            if let gustKn, gustKn > meanKn {
                UnevenRoundedRectangle(topLeadingRadius: cornerRadius,
                                       topTrailingRadius: cornerRadius)
                    .fill(Color.foam)
                    .frame(height: height * (gustKn - meanKn) / peak)
            }
            Rectangle()
                .fill(Color.chartBar)
                .frame(height: max(2, height * meanKn / peak))
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
    }
}
