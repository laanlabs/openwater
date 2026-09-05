import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// Everything about the point under the crosshairs, on one screen — and a way
/// into the three things that need a graph rather than a number.
///
/// The map's headline pill answers "is it on?" in three characters, which is
/// the whole job of a television at seven in the morning. This is the screen
/// for the second question, and it is the phone's conditions sheet reduced to
/// what a room can read: the wind now, the twelve hours after it, one summary
/// line each for the sea and the tide, the instruments actually reporting, and
/// the model behind all of it.
///
/// **Why the summary rows push.** A long-range chart is the one thing on this
/// screen that genuinely needs the whole display: five days of six models is
/// not a row, and squeezing it into one would produce a sparkline nobody can
/// read from a sofa. So each subject gets a line here carrying its headline
/// number — which is all most mornings need — and a press opens the graph.
///
/// Deliberately still not the phone's thirty sections. The phone is in the
/// room, and everything omitted here is on it.
struct ConditionsScreen: View {

    /// The point the map's dot was sitting on when this was opened. Fixed for
    /// the life of the screen — the map is not moving behind it, and a readout
    /// that drifted would be answering about somewhere else.
    let here: Geo.Coordinate
    /// What the map's own control bar calls this place.
    let placeName: String
    /// The starred spot this is a report *for*, when it is one.
    ///
    /// The favourites board used to push a thinner screen of its own — the
    /// same wind and stations, but none of the long-range charts, the rain
    /// chance or the model picker. There is no reason a saved spot deserves
    /// less than a point on the map, so the board pushes this instead and
    /// passes its spot, which anchors the camera search on the spot's own
    /// region rather than on whichever one is nearest a bare coordinate.
    var spot: GuideSpot?
    /// Opened from the favourites board rather than from the map.
    ///
    /// Decides whether the report offers a way *to* the map. From the map's
    /// own "Conditions here" the offer would point at the screen directly
    /// behind this one; from the board it is the one thing a rider cannot
    /// otherwise do without moving the pin — look at the wash over a spot
    /// they have starred.
    var openedFromBoard = false

    @Environment(SpotGuideStore.self) private var guide
    @Environment(TVLocation.self) private var location
    @Environment(\.dismiss) private var dismiss

    /// Where in the stack we are, so Menu can be answered explicitly — see
    /// `body`. A bound path rather than plain `NavigationLink` destinations
    /// because the answer to "what does Back do" depends on it.
    @State private var path: [Detail] = []

    /// The model, shared with the phone through `UserDefaults` under the same
    /// key. A household that picked ECMWF on the beach gets ECMWF in the
    /// kitchen, and the wash, the pins and this screen all move together.
    @AppStorage("spots.forecastModel") private var modelRaw = ForecastModel.automatic.rawValue

    @State private var wind: WindReading?
    @State private var weather: SpotWeather?
    @State private var ahead: [WindForecastHour] = []
    @State private var stations: [FreeStation] = []
    @State private var measured: [String: StationObservation] = [:]
    @State private var surf: SurfConditions?
    /// Fetched here as well as on the weather screen, for one number: the
    /// chance of rain. `SpotWeather` carries a code and a temperature and no
    /// probability at all, and "will it rain on me" is the second question
    /// anybody asks after "is it windy" — too important to be a press away.
    @State private var forecast = WeatherDetail()
    @State private var tide: TideCurve?
    /// Only to decide whether the current row is worth offering — the screen
    /// behind it fetches its own, in full.
    @State private var current: CurrentsOutlook?
    @State private var isLoading = true

    /// The fetch finished and came back empty-handed.
    ///
    /// Kept apart from `wind == nil` because the two mean opposite things to
    /// a rider. Open-Meteo covers every coordinate this app can show, ocean
    /// included, so "no model wind for this point" was almost never true —
    /// it was a dropped request wearing a confident sentence. A failure is
    /// now said as a failure, with a way to try again.
    @State private var didFail = false
    @State private var cams: [SpotGuideStore.GuideResource] = []

    /// So the page opens on its own headline rather than wherever the focus
    /// engine happens to find something pressable.
    @Namespace private var page

    /// The subjects that earn a screen of their own.
    private enum Detail: Hashable { case wind, waves, tide, weather, current, cameras }

    private var model: ForecastModel {
        ForecastModel(rawValue: modelRaw) ?? .automatic
    }

    /// How far out a spot's cameras reach. Sixty kilometres, as the board's
    /// report always had it: a spot is a launch, and the cameras a rider
    /// checks before driving to one are along its own stretch of coast, not
    /// the eighty the cameras tab sweeps for a whole area.
    private static let cameraRadius: Double = 60_000

    /// The guide's nearest launch, when there is one close enough to be what
    /// somebody means by "here". Ten kilometres: past that the name would be
    /// a different beach, and a wrong name on a television is worse than no
    /// name, because nobody can tap it to find out.
    private var nearest: (spot: GuideSpot, metres: Double)? {
        guard let spot = guide.nearestSpot(to: here) else { return nil }
        let metres = Geo.distance(here, .init(latitude: spot.latitude,
                                              longitude: spot.longitude))
        return metres < 10_000 ? (spot, metres) : nil
    }

    /// What the caller called this place beats what happens to be near it.
    ///
    /// This was the other way round, and it renamed things. A pin a rider
    /// dropped and called "Montauk, NY" came up under the name of whatever
    /// downwind run sat within ten kilometres of it — so pressing your own
    /// pin opened somebody else's spot, as far as the screen was concerned.
    /// The nearest launch is still the answer when nobody supplied a name,
    /// which is the map's crosshair sitting on an unnamed patch of water.
    private var title: String {
        if !placeName.isEmpty { return placeName }
        return nearest?.spot.name ?? "This point"
    }

    /// Degrees to three places with hemispheres spelled out, which is what a
    /// rider reads back to somebody over the phone. Not a `Format` helper:
    /// nothing else in the app prints a bare coordinate, and inventing a
    /// shared one for a single caption is how a units module fills up.
    private var coordinateLabel: String {
        String(format: "%.3f°%@ %.3f°%@",
               abs(here.latitude), here.latitude >= 0 ? "N" : "S",
               abs(here.longitude), here.longitude >= 0 ? "E" : "W")
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // Every block is a focus stop, and that is what makes this
                // scroll at all. A tvOS `ScrollView` has no touch to drag: it
                // moves only to keep the focused thing on screen, so a column
                // of read-only text is a column that cannot be reached.
                VStack(alignment: .leading, spacing: 44) {
                    ScrollStop { header }
                        .prefersDefaultFocus(in: page)
                    if !ahead.isEmpty { ScrollStop { ForecastStrip(hours: ahead) } }
                    detailRows
                    // Not wrapped: `MeasuredStations` puts a stop on each of
                    // its own rows, which is what lets a long list be walked
                    // rather than jumped over.
                    if !reportingStations.isEmpty {
                        MeasuredStations(rows: reportingStations)
                    }
                    aroundHere
                    modelPicker
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 60)
            }
            .focusScope(page)
            .background(Color.black.ignoresSafeArea())
            // White on the black this screen paints, stated rather than
            // inherited. `.primary` follows the system appearance, and on a
            // television set to Light that is black — black text on a black
            // background, which is exactly how this was reported.
            // `.secondary` and `.tertiary` resolve against this, so they
            // come right with it.
            .foregroundStyle(.white)
            .menuBackHint()
            .navigationDestination(for: Detail.self) { detail in
                switch detail {
                case .wind:  WindOutlookScreen(here: here, placeName: title)
                case .waves: WaveDetailScreen(here: here, placeName: title)
                case .tide:  TideDetailScreen(here: here, placeName: title)
                case .weather: WeatherDetailScreen(here: here, placeName: title)
                case .current: CurrentFlowScreen(here: here, placeName: title)
                case .cameras: SpotCamerasScreen(cams: cams, placeName: title)
                }
            }
        }
        // Menu, answered here and only here.
        //
        // A `NavigationStack` inside a `fullScreenCover` does not divide this
        // button sensibly with the cover, and both halves were wrong in turn.
        // Left to itself the stack swallowed Menu at the root and the screen
        // would not close. Declining at depth — handing the stack the press
        // by passing nil — did not give the stack the press either: it fell
        // through to the cover, so one press from a subpage went all the way
        // back to the map.
        //
        // So the stack's own handling is not relied on at all. One press, one
        // level: pop if there is anywhere to pop to, otherwise close.
        .onExitCommand {
            if path.isEmpty { dismiss() } else { path.removeLast() }
        }
        // Keyed on the model: picking a new one re-asks for every number on
        // this screen rather than leaving yesterday's alongside a new label.
        .task(id: modelRaw) { await load() }
        .task(id: isLoading) {
            // The capture seam; see `TVScreenshotRoute`.
            if TVScreenshotRoute.requested == .windOutlook, !isLoading, path.isEmpty {
                path.append(.wind)
            }
        }
    }

    private func load() async {
        isLoading = true
        didFail = false
        defer { isLoading = false }
        async let air = guide.weather(at: here)
        async let blowing = guide.currentWind(at: here)
        async let outlook = guide.forecast(latitude: here.latitude, longitude: here.longitude)
        async let free = FreeStations.near(here, limit: 8, radius: 40_000)
        // The sea and the tide are summary lines here and whole screens one
        // press away; both are cheap enough to have ready before the press.
        async let sea = OpenMeteo.surf(at: here)
        async let water = Tides.curve(at: here)
        async let sky = OpenMeteo.detail(at: here)
        async let running = Currents.outlook(at: here)
        weather = await air
        wind = await blowing
        // The hourly series is the same model asked a different way, so when
        // the current call drops and the outlook lands, hour zero is a real
        // answer rather than a guess — and it keeps the header honest with
        // the bars directly beneath it, which would otherwise be showing
        // wind on a screen that claims there is none.
        ahead = await outlook
        stations = await free
        if wind == nil, let first = ahead.first {
            wind = WindReading(from: first)
        }
        // Only a genuine, uncancelled empty answer is worth reporting. A
        // cancelled task means the rider left, and drawing an error on the
        // way out is noise.
        didFail = wind == nil && !Task.isCancelled
        surf = await sea
        tide = await water
        forecast = await sky
        current = await running
        // The cameras around this point, for every caller. They were fetched
        // only when a spot was passed, which left a pin's report — and the
        // map's — with no cameras at all for water that has plenty. A spot
        // still anchors the search on its own region; a bare coordinate
        // borrows the nearest one, which is what the cameras tab does.
        let around = if let spot {
            await guide.nearbyResources(to: spot, radius: Self.cameraRadius)
        } else {
            await guide.nearbyResources(near: here, radius: Self.cameraRadius)
        }
        // Playable first, then nearest — the cameras tab's order, because the
        // point of a camera on this screen is watching it on this screen.
        cams = around
            .filter { $0.kind == .camera }
            .sorted {
                if ($0.playback != nil) != ($1.playback != nil) { return $0.playback != nil }
                return $0.metres < $1.metres
            }

        // Readings come after the list, the way the phone's sheet does it:
        // each one is its own request, and the names are useful before the
        // numbers land.
        await withTaskGroup(of: (String, StationObservation?).self) { group in
            for station in stations {
                group.addTask { (station.id, await FreeStations.latest(for: station)) }
            }
            for await (id, observation) in group {
                if let observation { measured[id] = observation }
            }
        }
    }

    /// Only stations that actually answered, with a reading recent enough to
    /// mean anything — the map rules' first and loudest one. A number on a
    /// television is read from further away than a number on a phone, and
    /// there is no tapping it to find out where it came from.
    private var reportingStations: [(FreeStation, StationObservation)] {
        stations.compactMap { station in
            guard let observation = measured[station.id],
                  observation.reports, !observation.isStale
            else { return nil }
            return (station, observation)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 62, weight: .bold))
                .lineLimit(2)
            HStack(spacing: 20) {
                if let nearest {
                    Text("\(Format.distance(nearest.metres, unit: UnitPreferences.forThisDevice.distance)) from the pin")
                }
                Text(coordinateLabel)
            }
            .font(.system(size: 24))
            .foregroundStyle(.secondary)

            if let wind {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 40))
                        .rotationEffect(.degrees(wind.directionDeg + 180))
                    Text("\(Int(wind.speedKn.rounded()))")
                        .font(.system(size: 130, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("kn \(wind.cardinal)")
                            .font(.system(size: 34, weight: .semibold))
                        if let gust = wind.gustKn {
                            Text("gusting \(Int(gust.rounded()))")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let weather {
                        HStack(spacing: 12) {
                            Image(systemName: weather.symbol)
                                .font(.system(size: 40))
                                .foregroundStyle(weather.tint)
                            Text(Format.temperature(weather.temperatureC,
                                                    unit: UnitPreferences.forThisDevice.temperatureUnit))
                                .font(.system(size: 44, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(.leading, 30)
                    }
                    if let chance = rainChance {
                        HStack(spacing: 10) {
                            Image(systemName: "drop.fill")
                                .font(.system(size: 32))
                            Text("\(Int(chance.rounded()))%")
                                .font(.system(size: 44, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        // Blue only once it is worth a coat. Tinted at every
                        // value it would read as a warning about a dry day.
                        .foregroundStyle(chance >= 40 ? Color.blue : Color.secondary)
                        .padding(.leading, 24)
                    }
                }
                .foregroundStyle(wind.isFiring ? Color.accentColor : Color.white)
                // Said plainly, once, the way the phone's card says it: this
                // is a model, and the measured numbers are further down.
                Text("Forecast model, not an anemometer.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .padding(.vertical, 40)
            } else if didFail {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Couldn't reach the forecast")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("The model covers this point — the request didn't land.")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await load() } }
                        .font(.system(size: 26))
                }
                .padding(.vertical, 24)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .padding(.vertical, 40)
            }
        }
    }

    /// The three subjects with a graph behind them.
    ///
    /// Each row carries its own headline, so a rider who only wanted to know
    /// whether the tide is coming in never has to press anything.
    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("THE LONG VIEW")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            NavigationLink(value: Detail.wind) {
                DetailRow(symbol: "wind", title: "Wind, five days",
                          value: windSummary,
                          detail: "Every model, side by side")
            }
            .buttonStyle(.plain)

            NavigationLink(value: Detail.waves) {
                DetailRow(symbol: "water.waves", title: "Waves and swell",
                          value: waveSummary,
                          detail: surf == nil ? "No marine model here" : "Height, period and where it is from")
            }
            .buttonStyle(.plain)
            .disabled(surf == nil)

            NavigationLink(value: Detail.tide) {
                DetailRow(symbol: "arrow.up.and.down.circle", title: "Tide",
                          value: tideSummary,
                          detail: tideSource)
            }
            .buttonStyle(.plain)
            .disabled(tide?.isEmpty ?? true)

            // Only where there is water that runs. Inland and on a coast the
            // ocean model has no cell for, an empty current screen would be a
            // row that promises something and shows nothing.
            if let current, !current.isEmpty {
                NavigationLink(value: Detail.current) {
                    DetailRow(symbol: "water.waves.and.arrow.trianglehead.up",
                              title: "Current",
                              value: currentSummary,
                              detail: "Which way the water runs, and when it turns")
                }
                .buttonStyle(.plain)
            }

            NavigationLink(value: Detail.weather) {
                DetailRow(symbol: "cloud.sun", title: "Weather",
                          value: weatherSummary,
                          detail: "Chance of rain, temperature, the week")
            }
            .buttonStyle(.plain)
        }
    }

    /// What is around this point rather than above it: the cameras, and the
    /// map itself.
    ///
    /// Its own block rather than two more rows under "the long view". Those
    /// rows are forecasts with a graph behind them; these are places to go.
    /// The map row is only offered from the board — see `openedFromBoard`.
    private var aroundHere: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AROUND HERE")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            NavigationLink(value: Detail.cameras) {
                DetailRow(symbol: "video", title: "Cameras",
                          value: cameraSummary,
                          detail: cameraDetail)
            }
            .buttonStyle(.plain)
            .disabled(cams.isEmpty)

            if openedFromBoard {
                Button(action: seeOnTheMap) {
                    DetailRow(symbol: "map", title: "See it on the map",
                              value: "",
                              detail: "The wind map, centred here. Your pin stays where it is.")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Counted, and honest about how many of them this box can actually show.
    private var cameraSummary: String {
        guard !cams.isEmpty else { return isLoading ? "…" : "0" }
        return "\(cams.count)"
    }

    private var cameraDetail: String {
        guard !cams.isEmpty else {
            return isLoading ? "Looking…" : "No cameras near here"
        }
        let playable = cams.filter { $0.playback != nil }.count
        return switch playable {
        case 0: "All hand off to your phone"
        case cams.count: "All play on this Apple TV"
        default: "\(playable) play on this Apple TV, the rest hand off to your phone"
        }
    }

    /// Close the report and put the wind map on this point.
    ///
    /// Through `lookAt`, not `choose`: this is a look, and the pin — where
    /// the cameras tab counts from, where the next launch opens — is not
    /// moved by looking. The map's own "set the pin here" is a press away if
    /// the rider decides they want that. The ask is queued; the board hands
    /// it on once this cover has gone — see `TVLocation.lookAt`.
    private func seeOnTheMap() {
        location.lookAt(here, named: title)
        dismiss()
    }

    /// Set and rate, in the arrows' own convention — *toward*.
    private var currentSummary: String {
        guard let hour = current?.hour(at: nil), let speed = hour.speedKn else { return "—" }
        guard let set = hour.directionDeg else { return String(format: "%.1f kn", speed) }
        return String(format: "%.1f kn %@", speed, Format.cardinal(set))
    }

    /// The rain chance leads, because it is the one thing on the weather row
    /// that changes a plan. A temperature never stopped anybody going.
    private var weatherSummary: String {
        let degrees = weather.map {
            Format.temperature($0.temperatureC,
                               unit: UnitPreferences.forThisDevice.temperatureUnit)
        }
        guard let chance = rainChance else { return degrees ?? "—" }
        let rain = "\(Int(chance.rounded()))% rain"
        return degrees.map { "\(rain) · \($0)" } ?? rain
    }

    /// The chance of rain for the hour we are in.
    ///
    /// The nearest hour rather than the day's maximum: a forty per cent
    /// afternoon and a forty per cent chance right now are different facts,
    /// and this screen is about right now. The day's shape is one press away
    /// on the weather screen.
    private var rainChance: Double? {
        let now = Date()
        return forecast.hours
            .filter { $0.at >= now.addingTimeInterval(-3600) }
            .min { abs($0.at.timeIntervalSince(now)) < abs($1.at.timeIntervalSince(now)) }?
            .precipitationChance
    }

    private var windSummary: String {
        guard let wind else { return "—" }
        return "\(Int(wind.speedKn.rounded())) kn now"
    }

    private var waveSummary: String {
        guard let surf, let height = surf.waveHeightM else { return "—" }
        let unit = UnitPreferences.forThisDevice.distance
        if let period = surf.wavePeriodS {
            return "\(Format.height(height, unit: unit)) at \(Int(period.rounded())) s"
        }
        return Format.height(height, unit: unit)
    }

    /// Rising or falling is the half of "1.1 m" that actually matters — a
    /// metre on the way up is a different beach from a metre on the way down.
    private var tideSummary: String {
        guard let tide, !tide.isEmpty, let now = tide.now else { return "—" }
        let unit = UnitPreferences.forThisDevice.distance
        let state = tide.isRising == true ? "rising" : (tide.isRising == false ? "falling" : "")
        return state.isEmpty
        ? Format.height(now.metres, unit: unit)
        : "\(Format.height(now.metres, unit: unit)), \(state)"
    }

    /// Named, because the two sources do not share a datum and a rider who
    /// knows the difference wants to know which one this is.
    private var tideSource: String {
        guard let tide, !tide.isEmpty else { return "No tide model here" }
        return switch tide.source {
        case .station(let name, _): "\(name) — NOAA predictions"
        case .model: "Marine model, mean sea level"
        }
    }

    /// Which model is answering, and the chance to change it.
    ///
    /// On the phone this is buried in a layers menu, because the phone has
    /// somewhere to bury it. Here it is the last block on the only screen that
    /// shows a forecast, which is roughly the right prominence: the models
    /// disagree near a coast by more than the difference between a session and
    /// a drive home, and a rider who has learned which one reads their water
    /// should be able to say so from the sofa.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FORECAST MODEL")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ForEach(ForecastModel.allCases) { option in
                        Button { choose(option) } label: {
                            ModelChip(model: option, isOn: option == model)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    /// Every cached number came from the old model, so they all go — the same
    /// thing the phone's picker does. The map behind this screen re-asks on
    /// its own key when it comes back.
    private func choose(_ option: ForecastModel) {
        guard option != model else { return }
        modelRaw = option.rawValue
        guide.forgetWind()
    }
}

// MARK: - One way in

/// A subject, its headline, and the promise of a graph.
///
/// The value is on the row rather than only behind it because most mornings
/// end here: "1.4 m, rising" is the whole answer, and making somebody press
/// through to a chart to read six characters is the kind of thing a phone can
/// get away with and a television cannot.
private struct DetailRow: View {

    let symbol: String
    let title: String
    let value: String
    let detail: String

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 28) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 32, weight: .medium))
                Text(detail)
                    .font(.system(size: 22))
                    .opacity(0.65)
            }
            Spacer(minLength: 40)
            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.system(size: 26, weight: .semibold))
                .opacity(isEnabled ? 0.5 : 0.15)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .foregroundStyle(isFocused ? Color.black : (isEnabled ? Color.white : Color.white.opacity(0.35)))
        .background(isFocused ? Color.white : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 20))
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// One model to pick from, saying what it actually is.
///
/// The resolution line is not decoration. "Global, 25 km" against "1 km over
/// the Nordics" is the entire basis on which somebody chooses, and a list of
/// bare acronyms asks a rider to already know.
private struct ModelChip: View {

    let model: ForecastModel
    let isOn: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                }
                Text(model.name)
                    .font(.system(size: 28, weight: .semibold))
            }
            Text(model.detail)
                .font(.system(size: 20))
                .opacity(0.7)
        }
        .frame(width: 320, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .foregroundStyle(isFocused ? Color.black : (isOn ? Color.accentColor : Color.white))
        .background(isFocused ? Color.white : Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 18))
    }
}
