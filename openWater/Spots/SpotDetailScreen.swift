import MapKit
import OpenWaterCore
import SwiftUI

/// One spot, in the order a rider decides: live conditions above the fold,
/// then how to launch and what will hurt you, then everything else.
///
/// "Record here" is the whole point of having the guide inside the app rather
/// than in Safari — the page that told you it's on is one tap from the screen
/// that records the session.
struct SpotDetailScreen: View {

    let spot: GuideSpot

    @Environment(SpotGuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight
    @Environment(\.openURL) private var openURL

    @State private var forecast: [WindForecastHour] = []
    @State private var links: [SpotGuideStore.SpotLink] = []
    @State private var isChoosingMapApp = false
    @State private var isSuggesting = false
    @State private var isShowingConditions = false

    private var reading: WindReading? { guide.wind[spot.spotId] }
    private var weather: SpotWeather? { guide.weatherReading(for: spot) }
    private var isFavorite: Bool { guide.favoriteIds.contains(spot.spotId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero

                VStack(alignment: .leading, spacing: 7) {
                    Text(spot.name)
                        .font(.title2.weight(.bold))
                    HStack(spacing: 8) {
                        Text(spot.where_)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            isChoosingMapApp = true
                        } label: {
                            Image(systemName: "map")
                                .font(.subheadline)
                                .foregroundStyle(.tint)
                        }
                        .accessibilityLabel("Open in Maps")
                    }
                    chips
                }
                .padding(.horizontal, 16)

                windCard
                    .padding(.horizontal, 16)

                linksCard
                    .padding(.horizontal, 16)

                conditionsCard
                    .padding(.horizontal, 16)

                Button {
                    isSuggesting = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "camera.badge.ellipsis")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Improve this spot")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Add photos, fix conditions, link a cam or meter — goes to review.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                miniMap
                    .padding(.horizontal, 16)

                Button {
                    isChoosingMapApp = true
                } label: {
                    Label("Directions", systemImage: "car")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                resourcesFooter
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
            .padding(.bottom, tabBarHeight)
        }
        .background(Color(.systemGroupedBackground))
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    guide.toggleFavorite(spot.spotId)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                ShareLink(item: webURL) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $isSuggesting) {
            SuggestSpotView(mode: .correction(spot))
        }
        .sheet(isPresented: $isShowingConditions) {
            NearbyConditionsSheet(spot: spot)
        }
        .confirmationDialog("Open in", isPresented: $isChoosingMapApp, titleVisibility: .visible) {
            Button("Apple Maps") { openInAppleMaps() }
            Button("Google Maps") { openInGoogleMaps() }
        }
        .task {
            await guide.refreshWind(for: [spot])
            async let hours = guide.forecast(for: spot)
            async let resources = guide.links(for: spot)
            async let sky = guide.weather(for: spot)
            (forecast, links, _) = await (hours, resources, sky)
        }
    }

    /// The spot's page on the website — the share payload, and the "full
    /// guide" link, because the site carries the resources the app trims.
    private var webURL: URL {
        let slug = (spot.slug ?? "").replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        let tail = (spot.spotId + (slug.isEmpty ? "" : "-\(slug)")).lowercased()
        return URL(string: "https://openwaterapp.com/spots/\(tail)")!
    }

    // MARK: Pieces

    private var hero: some View {
        Group {
            if let url = spot.imageURL.flatMap(URL.init) {
                VStack(alignment: .leading, spacing: 4) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(.systemGray5)
                    }
                    .frame(height: 230)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    if let credit = spot.imageCredit {
                        Text(credit)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                    }
                }
            } else {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: spot.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                ))) {
                    Marker(spot.name, coordinate: spot.coordinate)
                }
                .frame(height: 230)
                .allowsHitTesting(false)
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(spot.activities, id: \.self) { activity in
                    chip(activity, accent: true)
                }
                if let level = spot.experienceLevel {
                    chip(String(level.prefix(30)), accent: false)
                }
                if let season = spot.bestSeason {
                    chip(String(season.prefix(20)), accent: false)
                }
            }
        }
    }

    private func chip(_ label: String, accent: Bool) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                accent ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }

    /// Live wind and the next 12 hours. Model data, and it says so — the
    /// difference between a forecast grid and an anemometer on the beach is
    /// exactly the kind of thing this app refuses to blur.
    /// The whole card opens the conditions, not just the weather glyph.
    ///
    /// A model estimate is the weakest reading on the page, so the useful
    /// next move from it is always "show me something better" — the free
    /// stations, the guide's meters, the cams. Making a 40-point symbol the
    /// only way through to them hid the most-wanted action behind the
    /// smallest target on the screen.
    private var windCard: some View {
        Button {
            isShowingConditions = true
        } label: {
            windCardBody
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens nearby stations, tides, surf and cameras")
    }

    private var windCardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(reading == nil ? "WIND" : "WIND · MODEL ESTIMATE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    if let reading {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(Int(reading.speedKn.rounded()))")
                                .font(.system(size: 38, weight: .heavy, design: .rounded))
                                .foregroundStyle(reading.isFiring ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            Text("kn \(reading.cardinal)\(reading.gustKn.map { " · gusts \(Int($0.rounded()))" } ?? "")")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // Shaped like the wind reading it becomes, so the
                        // card does not resize under the rider's thumb the
                        // moment the forecast lands.
                        LoadingPlaceholder(height: 22, width: 90)
                            .padding(.top, 6)
                    }
                }
                Spacer()
                if let reading {
                    Image(systemName: "arrow.down")
                        .font(.title3.weight(.semibold))
                        .rotationEffect(.degrees(reading.directionDeg))
                        .foregroundStyle(.secondary)
                }
                weatherButton
            }

            if !forecast.isEmpty {
                VStack(spacing: 4) {
                    let peak = max(forecast.map(\.speedKn).max() ?? 1, 1)
                    ZStack(alignment: .bottom) {
                        ChartGrid(peak: peak)
                        HStack(alignment: .bottom, spacing: 5) {
                            ForEach(forecast) { hour in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(hour.speedKn >= 15 ? AnyShapeStyle(.tint)
                                          : AnyShapeStyle(Color.accentColor.opacity(0.3)))
                                    .frame(height: max(4, 44 * hour.speedKn / peak))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: 44, alignment: .bottom)
                    HStack {
                        Text("now")
                        Spacer()
                        if let middle = forecast[safe: forecast.count / 2] {
                            Text(middle.date.formatted(.dateTime.hour()))
                        }
                        Spacer()
                        if let last = forecast.last {
                            Text(last.date.formatted(.dateTime.hour()))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    /// The sky, and the way into every other source.
    ///
    /// A model estimate is the weakest reading there is, and until now it was
    /// the only one the page offered without scrolling to the links. This
    /// says what the weather is doing — the half of "conditions" the wind
    /// number leaves out — and, tapped, opens the sources that can do better:
    /// the free NOAA stations, the guide's meters, the cams.
    private var weatherButton: some View {
        // Not a Button any more: it sits inside one. A nested button steals
        // the tap from the card around it, so the same action would only fire
        // from part of the area it appears to cover.
        Group {
            VStack(spacing: 1) {
                if let weather {
                    Image(systemName: weather.symbol)
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(weather.tint)
                    Text(Format.temperature(weather.temperatureC,
                                             unit: settings.units.temperatureUnit,
                                             includeSymbol: false))
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "cloud.sun")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("more")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 46)
            .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Weather and nearby stations")
    }

    @ViewBuilder
    private var conditionsCard: some View {
        let rows: [(String, String, Bool)] = [
            ("Best wind", spot.bestWinds, false),
            ("Season", spot.bestSeason, false),
            ("Water", spot.waterState, false),
            ("Hazards", spot.hazards, true),
            ("Parking", spot.parking, false),
        ].compactMap { label, value, warns in value.map { (label, $0, warns) } }

        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(row.2 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(linkified(row.1))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var miniMap: some View {
        if spot.imageURL != nil {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: spot.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
            ))) {
                Marker(spot.name, coordinate: spot.coordinate)
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .allowsHitTesting(false)
        }
    }

    /// Every outbound link in one card: the iKitesurf meter, the Surfline
    /// forecast, the tide chart, the cams, the local guides. Riders already
    /// have their forecast apps; the job here is not to replace them but to
    /// stop the five-app scavenger hunt before a session.
    @ViewBuilder
    private var linksCard: some View {
        let forecasts = links.filter { $0.kind != .guide }
        let guides = links.filter { $0.kind == .guide }
        if !forecasts.isEmpty {
            linkSection("FORECASTS, TIDES & CAMS", items: forecasts)
        }
        if !guides.isEmpty {
            linkSection("GUIDES", items: guides)
                .padding(.top, 4)
        }
    }

    private func linkSection(_ title: String, items: [SpotGuideStore.SpotLink]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)

                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, link in
                        // Button + openURL rather than `Link`, which tints the
                        // whole label orange over the children's own styles.
                        Button {
                            openURL(link.url)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: link.kind.symbol)
                                    .font(.subheadline)
                                    .foregroundStyle(.tint)
                                    .frame(width: 30, height: 30)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(link.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(link.kind.label) · \(link.providerLabel)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
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
                        if index < items.count - 1 {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var resourcesFooter: some View {
        HStack {
            Spacer()
            Link("Full guide on openwaterapp.com", destination: webURL)
                .font(.caption.weight(.semibold))
            Spacer()
        }
    }

    private var resourceLine: String {
        var parts: [String] = []
        if spot.windStationCount > 0 { parts.append("\(spot.windStationCount) wind meter\(spot.windStationCount == 1 ? "" : "s")") }
        if spot.cameraCount > 0 { parts.append("\(spot.cameraCount) webcam\(spot.cameraCount == 1 ? "" : "s")") }
        if spot.tideCount > 0 { parts.append("\(spot.tideCount) tide station\(spot.tideCount == 1 ? "" : "s")") }
        if spot.guideCount + spot.surfCount > 0 { parts.append("\(spot.guideCount + spot.surfCount) guides") }
        return parts.joined(separator: " · ")
    }

    /// Condition prose with any embedded URLs made tappable — the guide's
    /// hazards and parking notes routinely end in "see https://…", and a URL
    /// you can read but not tap is a small insult on a phone.
    private func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, url.scheme?.hasPrefix("http") == true,
                  let swiftRange = Range(match.range, in: text),
                  let attributedRange = attributed.range(of: String(text[swiftRange]))
            else { continue }
            attributed[attributedRange].link = url
            attributed[attributedRange].underlineStyle = .single
        }
        return attributed
    }

    private func openInAppleMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: spot.coordinate))
        item.name = spot.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func openInGoogleMaps() {
        // The guide's own link when it has one — it often points at the exact
        // parking lot rather than a pin in the water.
        if let curated = spot.googleMapsURL.flatMap(URL.init) {
            openURL(curated)
        } else {
            let query = String(format: "%.5f,%.5f", spot.latitude, spot.longitude)
            openURL(URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(query)")!)
        }
    }
}

// MARK: - Destination guide

/// A trip-planning view: the region's spots on one map, list below, wind on
/// every row so "where should we go tomorrow" answers itself.
struct DestinationScreen: View {

    let region: GuideRegion
    let onOpenSpot: (GuideSpot) -> Void

    @Environment(SpotGuideStore.self) private var guide
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var sortByWind = false

    private var spots: [GuideSpot] {
        let members = region.type == "country"
            ? guide.spots(inCountry: region)
            : guide.spots(inDestination: region)
        guard sortByWind else { return members }
        return members.sorted {
            (guide.wind[$0.spotId]?.speedKn ?? -1) > (guide.wind[$1.spotId]?.speedKn ?? -1)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                regionMap

                VStack(alignment: .leading, spacing: 4) {
                    Text(region.type == "destination" ? "Destination guide" : "Country")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(region.name)
                        .font(.title.weight(.bold))
                    Text("\(spots.count) spots")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)

                if let blurb = region.description {
                    Text(blurb)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                Toggle(isOn: $sortByWind) {
                    Text("Sort by wind")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    ForEach(spots) { spot in
                        Button { onOpenSpot(spot) } label: {
                            HStack(spacing: 12) {
                                if guide.favoriteIds.contains(spot.spotId) {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(spot.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(rowSubtitle(spot))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if let reading = guide.wind[spot.spotId] {
                                    (Text("\(Int(reading.speedKn.rounded()))")
                                        .font(.subheadline.weight(.bold))
                                     + Text("kn").font(.caption2))
                                        .foregroundStyle(reading.isFiring ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if spot.id != spots.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 16)
            }
            .padding(.bottom, tabBarHeight + 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(region.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: region.id) {
            await guide.refreshWind(for: spots)
        }
    }

    private func rowSubtitle(_ spot: GuideSpot) -> String {
        var parts: [String] = []
        if let admin = spot.adminRegion { parts.append(admin) }
        else if let country = spot.country { parts.append(country) }
        var resources: [String] = []
        if spot.windStationCount > 0 { resources.append("wind") }
        if spot.cameraCount > 0 { resources.append("cams") }
        if spot.guideCount > 0 { resources.append("guides") }
        if spot.tideCount > 0 { resources.append("tides") }
        parts.append(contentsOf: resources)
        return parts.joined(separator: " · ")
    }

    private var regionMap: some View {
        Map(initialPosition: .automatic) {
            ForEach(spots.prefix(60)) { spot in
                Marker(spot.name, coordinate: spot.coordinate)
            }
        }
        .frame(height: 220)
        .allowsHitTesting(false)
    }
}
