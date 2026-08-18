import MapKit
import OpenWaterCore
import SwiftUI

// MARK: - What is selected

/// The thing the detail panel is about: a curated spot, or just a place.
///
/// The distinction decides almost nothing here — every fetch is
/// coordinate-first — but it decides the title, and it keeps the door to
/// the full guide page, which only a spot has.
enum SpotSelection: Equatable {
    case spot(GuideSpot)
    case place(PlaceResult)
    case privateSpot(PrivateSpot)

    var title: String {
        switch self {
        case .spot(let spot): spot.name
        case .place(let place): place.name
        case .privateSpot(let spot): spot.name
        }
    }

    var coordinate: Geo.Coordinate {
        switch self {
        case .spot(let spot): Geo.Coordinate(latitude: spot.latitude, longitude: spot.longitude)
        case .place(let place): place.coordinate
        case .privateSpot(let spot): spot.coordinate
        }
    }

    var guideSpot: GuideSpot? {
        if case .spot(let spot) = self { return spot }
        return nil
    }

    /// A private spot may know which way its beach faces; the full
    /// conditions sheet uses that for shore-aware surf.
    var shoreFacingDeg: Double? {
        if case .privateSpot(let spot) = self { return spot.shoreFacingDeg }
        return nil
    }

    /// The fetch key: a spot keeps its id so the caches it already warmed
    /// stay warm; anything else is its rounded coordinate, the `taskKey`
    /// rule.
    var key: String {
        switch self {
        case .spot(let spot): spot.spotId
        case .place(let place): String(format: "@%.3f,%.3f", place.latitude, place.longitude)
        case .privateSpot(let spot): "private:\(spot.id)"
        }
    }
}

/// The five doors of the detail panel.
enum ConditionsTab: String, CaseIterable {
    case weather = "Weather"
    case currents = "Currents"
    case tides = "Tides"
    case waves = "Waves"
    case cams = "Cams"
}

// MARK: - The panel

/// The Orca-style compact conditions panel: map above, five tabs below,
/// one shared hour cursor.
///
/// Deliberately *not* a transplant of `NearbyConditionsSheet`'s tab bodies
/// — those are full-screen, radius-scoped station lists that would be wrong
/// at a third of the screen. This panel is charts and value rows sized for
/// the sheet's half detent, and the full sheet stays one "More detail" tap
/// away on every tab.
struct SpotConditionsPanel: View {

    let selection: SpotSelection
    let tab: ConditionsTab

    @Environment(SpotGuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings

    // Fetched once per selection and held as plain state: panel drags
    // re-read these arrays, they never recompute — the pins-as-state
    // lesson applied to charts.
    @State private var outlook = WindOutlook(hours: [], models: [])
    @State private var detail = WeatherDetail()
    @State private var currents = CurrentsOutlook(hours: [], source: .model)
    @State private var tide = TideCurve(points: [])
    @State private var waves: [WaveHour] = []
    @State private var cams: [SpotGuideStore.GuideResource] = []
    @State private var tideStation: TideStation?
    @State private var isLoading = true

    /// The shared cursor: one instant, every tab. Nil is "now".
    @State private var scrub: Date?

    private struct WatchingCam: Identifiable {
        let id = UUID()
        let name: String
        let url: URL
    }
    @State private var watchingCam: WatchingCam?
    @State private var showingMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch tab {
            case .weather: weatherTab
            case .currents: currentsTab
            case .tides: tidesTab
            case .waves: wavesTab
            case .cams: camsTab
            }

            if tab != .cams {
                Button {
                    showingMore = true
                } label: {
                    HStack {
                        Text("More detail")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .task(id: selection.key) {
            isLoading = true
            scrub = nil
            let here = selection.coordinate
            async let wind = OpenMeteo.outlook(at: here, days: 2)
            async let sky = OpenMeteo.detail(at: here)
            async let water = Currents.outlook(at: here)
            async let sea = Tides.curve(at: here)
            async let swell = OpenMeteo.waves(at: here, hours: 48)
            async let resources = guide.nearbyResources(near: here, radius: 40_000)
            async let stations = TidesAndCurrents.stations(near: here, limit: 1)
            (outlook, detail, currents, tide, waves) = await (wind, sky, water, sea, swell)
            cams = await resources.filter { $0.kind == .camera }
            if let nearest = await stations.first {
                var station = nearest
                station.events = await TidesAndCurrents.today(for: station.id)
                tideStation = station
            } else {
                tideStation = nil
            }
            isLoading = false
        }
        .fullScreenCover(item: $watchingCam) { cam in
            CamViewerSheet(name: cam.name, url: cam.url)
        }
        .fullScreenSheet(isPresented: $showingMore) {
            if let spot = selection.guideSpot {
                NearbyConditionsSheet(spot: spot)
            } else {
                NearbyConditionsSheet(title: selection.title,
                                      coordinate: selection.coordinate,
                                      shoreFacingDeg: selection.shoreFacingDeg)
            }
        }
    }

    // MARK: Weather (wind + rain)

    private var weatherTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading, outlook.hours.isEmpty {
                LoadingPlaceholder(height: 96)
            } else if outlook.hours.isEmpty {
                emptyNote("No wind forecast came back here.")
            } else {
                let speeds = outlook.consensus
                let gusts = outlook.consensusGusts
                let voters = Set(outlook.models.filter { !$0.isComposite }.map(\.id))
                let directions = outlook.blendDirections(of: voters)
                let peak = max(18, (gusts.compactMap { $0 }.max() ?? 0) * 1.15)

                chartBars(values: speeds, caps: gusts, peak: peak, tint: barTint(for:))
                DirectionTicksRow(directions: directions)
                if detail.hours.contains(where: { ($0.precipitationMm ?? 0) > 0 }) {
                    rainRow
                }
                HourScrubber(hours: outlook.hours, timeZone: outlook.timeZone, selection: $scrub)

                let index = scrubIndex(in: outlook.hours)
                valueRow("Speed", speeds[safe: index].flatMap { $0 }.map { "\(Int($0.rounded())) kn" })
                valueRow("Gusts", gusts[safe: index].flatMap { $0 }.map { "\(Int($0.rounded())) kn" })
                valueRow("Direction", directions[safe: index].flatMap { $0 }.map(Format.cardinal))
                valueRow("Rain", rainValue(at: scrubDate(in: outlook.hours, index: index)))

                provenance(outlook.staleAge == nil
                           ? "Blend of \(voters.count) independent models — Open-Meteo, modeled, not observed."
                           : "Blend of \(voters.count) independent models — Open-Meteo, modeled. Offline: \(age(outlook.staleAge)) old.")
            }
        }
    }

    /// The rain strip under the wind bars: probability as depth of tint,
    /// amount as the number worth printing.
    private var rainRow: some View {
        HStack(spacing: 0) {
            ForEach(alignedHours(detail.hours, to: outlook.hours), id: \.at) { hour in
                Rectangle()
                    .fill(Color.accentColor.opacity(rainOpacity(hour)))
                    .frame(maxWidth: .infinity)
                    .frame(height: 6)
            }
        }
        .clipShape(Capsule())
    }

    // MARK: Currents

    private var currentsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading, currents.hours.isEmpty, currents.events.isEmpty {
                LoadingPlaceholder(height: 96)
            } else if currents.isEmpty {
                if case .model = currents.source {
                    emptyNote("No current model here. Open-Meteo's ocean model covers open water — this point has no marine cell.")
                } else {
                    emptyNote("The nearest current station answered with nothing.")
                }
            } else {
                if !currents.hours.isEmpty {
                    let speeds = currents.hours.map(\.speedKn)
                    // The reference grammar, top to bottom: the set's
                    // arrows first — the flip across slack is the story —
                    // then the bars wearing the strength ramp, then the
                    // numbers under their own columns. Arrows drawn as-is:
                    // currents point TOWARD, the one row where the wind
                    // habit of +180 would flip a river.
                    DirectionTicksRow(directions: currents.hours.map(\.directionDeg),
                                      pointsToward: true, size: 13)
                    let peak = max(1.5, (speeds.compactMap { $0 }.max() ?? 0) * 1.2)
                    chartBars(values: speeds, caps: [], peak: peak) {
                        CurrentPalette.color(for: $0)
                    }
                    ValueTicksRow(values: speeds)
                    HourScrubber(hours: currents.hours.map(\.at), timeZone: currents.timeZone, selection: $scrub)

                    let index = scrubIndex(in: currents.hours.map(\.at))
                    valueRow("Speed", currents.hours[safe: index]?.speedKn.map { String(format: "%.1f kn", $0) } ?? nil)
                    valueRow("Sets", currents.hours[safe: index]?.directionDeg.flatMap { $0 }.map(Format.cardinal))
                }

                if !currents.events.isEmpty {
                    eventChips
                }

                switch currents.source {
                case .station(let station):
                    provenance("NOAA CO-OPS predictions · \(station.name) · \(Format.distance(station.metres, unit: settings.units.distance)) away · predicted from harmonics, not measured.",
                               link: station.url)
                case .model:
                    provenance("Open-Meteo ocean model · modeled, not observed · CC-BY 4.0.")
                }
            }
        }
    }

    /// The turns of the water: max flood, slack, max ebb, in order.
    private var eventChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(currents.events.filter { $0.at > Date().addingTimeInterval(-3600) }.prefix(8)) { event in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(eventLabel(event.kind))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(eventTint(event.kind))
                        Text(shortTime(event.at, zone: currents.timeZone))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        + Text(event.speedKn.map { String(format: " · %.1f kn", $0) } ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: Tides

    private var tidesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading, tide.isEmpty {
                LoadingPlaceholder(height: 120)
            } else if tide.isEmpty, tideStation == nil {
                emptyNote("No sea level here — this point has no marine cell.")
            } else {
                if !tide.isEmpty {
                    TideChart(curve: tide)
                }
                // The NOAA station is a separate authority in a separate
                // box — MSL curve above, MLLW turns here, never blended.
                if let station = tideStation, let next = station.next {
                    HStack(spacing: 10) {
                        Image(systemName: next.isHigh ? "arrow.up.to.line" : "arrow.down.to.line")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(next.isHigh ? "High" : "Low") \(shortTime(next.at, zone: nil)) · \(Format.height(next.metres, unit: settings.units.distance))")
                                .font(.subheadline.weight(.semibold))
                            Text("\(station.name) · \(Format.distance(station.metres, unit: settings.units.distance)) · NOAA CO-OPS, MLLW — the authority on times")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Link(destination: station.url) {
                            Image(systemName: "arrow.up.forward")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: Waves

    private var wavesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading, waves.isEmpty {
                LoadingPlaceholder(height: 96)
            } else if waves.isEmpty {
                emptyNote("No wave model here — this point has no marine cell.")
            } else {
                let heights = waves.map(\.heightM)
                let peak = max(1.0, (heights.compactMap { $0 }.max() ?? 0) * 1.25)
                chartBars(values: heights, caps: [], peak: peak) { _ in Color.foam }
                // Wave direction is stated FROM, like wind — drawn +180.
                DirectionTicksRow(directions: waves.map(\.directionDeg))
                HourScrubber(hours: waves.map(\.at), timeZone: detail.timeZone, selection: $scrub)

                let index = scrubIndex(in: waves.map(\.at))
                valueRow("Height", waves[safe: index]?.heightM.map { Format.height($0, unit: settings.units.distance) } ?? nil)
                valueRow("Period", waves[safe: index]?.periodS.map { String(format: "%.0f s", $0) } ?? nil)
                valueRow("Swell", waves[safe: index]?.swellM.map { Format.height($0, unit: settings.units.distance) } ?? nil)

                provenance("Open-Meteo marine model · modeled, not observed · CC-BY 4.0.")
            }
        }
    }

    // MARK: Cams

    private var camsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading, cams.isEmpty {
                LoadingPlaceholder(height: 60)
            } else if cams.isEmpty {
                emptyNote("No webcams in the guide this close.")
            } else {
                ForEach(0..<cams.count, id: \.self) { index in
                    let cam = cams[index]
                    Button {
                        watchingCam = WatchingCam(name: cam.displayName, url: cam.url)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "video.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .frame(width: 32, height: 32)
                                .background(Color(.secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cam.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(Format.distance(cam.metres, unit: settings.units.distance)) away\(cam.providerLabel.isEmpty ? "" : " · \(cam.providerLabel)")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.rectangle")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < cams.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    // MARK: Shared pieces

    /// Equal-column bars with optional gust caps, on a ChartGrid backdrop.
    private func chartBars(values: [Double?], caps: [Double?], peak: Double,
                           tint: @escaping (Double) -> Color) -> some View {
        ZStack(alignment: .bottom) {
            ChartGrid(peak: peak)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(values.indices, id: \.self) { index in
                    let value = values[index] ?? 0
                    VStack(spacing: 1) {
                        if let cap = caps[safe: index] ?? nil, cap > value {
                            Spacer(minLength: 0)
                            Capsule()
                                .fill(tint(value).opacity(0.35))
                                .frame(height: max(2, 88 * (cap - value) / peak))
                        } else {
                            Spacer(minLength: 0)
                        }
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(tint(value))
                            .frame(height: max(2, 88 * value / peak))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 96)
    }

    private func barTint(for knots: Double) -> Color {
        knots >= 15 ? .accentColor : Color.chartBar.opacity(0.75)
    }

    private func valueRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func provenance(_ text: String, link: URL? = nil) -> some View {
        Group {
            if let link {
                Link(destination: link) {
                    Text(text).multilineTextAlignment(.leading)
                }
            } else {
                Text(text)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
    }

    // MARK: Cursor resolution

    /// Each tab resolves the shared instant against its own axis.
    private func scrubIndex(in hours: [Date]) -> Int {
        let instant = scrub ?? Date()
        guard !hours.isEmpty else { return 0 }
        var best = 0
        var bestGap = TimeInterval.greatestFiniteMagnitude
        for (index, hour) in hours.enumerated() {
            let gap = abs(hour.timeIntervalSince(instant))
            if gap < bestGap { best = index; bestGap = gap }
        }
        return best
    }

    private func scrubDate(in hours: [Date], index: Int) -> Date? {
        hours[safe: index]
    }

    private func rainValue(at instant: Date?) -> String? {
        guard let instant,
              let hour = detail.hours.min(by: {
                  abs($0.at.timeIntervalSince(instant)) < abs($1.at.timeIntervalSince(instant))
              })
        else { return nil }
        let chance = hour.precipitationChance.map { "\(Int($0))%" }
        let amount = (hour.precipitationMm ?? 0) > 0 ? String(format: "%.1f mm", hour.precipitationMm ?? 0) : nil
        return [chance, amount].compactMap { $0 }.joined(separator: " · ").isEmpty
            ? nil : [chance, amount].compactMap { $0 }.joined(separator: " · ")
    }

    /// The detail hours clipped to the wind chart's own axis, so the rain
    /// strip's columns line up under the wind bars.
    private func alignedHours(_ hours: [WeatherDetail.Hour], to axis: [Date]) -> [WeatherDetail.Hour] {
        guard let first = axis.first, let last = axis.last else { return [] }
        return hours.filter { $0.at >= first && $0.at <= last }
    }

    private func rainOpacity(_ hour: WeatherDetail.Hour) -> Double {
        guard let chance = hour.precipitationChance, chance > 5 else { return 0.06 }
        return 0.1 + 0.75 * (chance / 100)
    }

    private func eventLabel(_ kind: CurrentsOutlook.Event.Kind) -> String {
        switch kind {
        case .maxFlood: "MAX FLOOD"
        case .maxEbb: "MAX EBB"
        case .slack: "SLACK"
        }
    }

    private func eventTint(_ kind: CurrentsOutlook.Event.Kind) -> Color {
        switch kind {
        case .maxFlood: .accentColor
        case .maxEbb: .orange
        case .slack: .secondary
        }
    }

    private func age(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        return Format.duration(seconds)
    }

    private func shortTime(_ date: Date, zone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone ?? .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
