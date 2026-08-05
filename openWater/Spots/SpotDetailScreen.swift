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

    private var reading: WindReading? { guide.wind[spot.spotId] }
    private var isFavorite: Bool { guide.favoriteIds.contains(spot.spotId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero

                VStack(alignment: .leading, spacing: 7) {
                    Text(spot.name)
                        .font(.title2.weight(.bold))
                    Text("\(spot.where_) · \(String(format: "%.3f, %.3f", spot.latitude, spot.longitude))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    chips
                }
                .padding(.horizontal, 16)

                windCard
                    .padding(.horizontal, 16)

                HStack(spacing: 10) {
                    Button {
                        NotificationCenter.default.post(name: .openWaterSwitchToRecord, object: nil)
                    } label: {
                        Text("Record here")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button {
                        openDirections()
                    } label: {
                        Text("Directions")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)

                conditionsCard
                    .padding(.horizontal, 16)

                miniMap
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
        .task {
            await guide.refreshWind(for: [spot])
            forecast = await guide.forecast(for: spot)
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
    private var windCard: some View {
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
                        ProgressView()
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
            }

            if !forecast.isEmpty {
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(forecast) { hour in
                            let peak = max(forecast.map(\.speedKn).max() ?? 1, 1)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(hour.speedKn >= 15 ? AnyShapeStyle(.tint)
                                      : AnyShapeStyle(Color.accentColor.opacity(0.3)))
                                .frame(height: max(4, 44 * hour.speedKn / peak))
                                .frame(maxWidth: .infinity)
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
                        Text(row.1)
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

    @ViewBuilder
    private var resourcesFooter: some View {
        if spot.resourceCount > 0 {
            HStack(spacing: 10) {
                Text(resourceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Link("Full guide", destination: webURL)
                    .font(.caption.weight(.semibold))
            }
        } else {
            HStack {
                Spacer()
                Link("Full guide on openwaterapp.com", destination: webURL)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
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

    private func openDirections() {
        // The guide's own Google Maps link when it has one — it often points at
        // the exact parking lot rather than the beach — otherwise Apple Maps
        // at the launch coordinates.
        if let google = spot.googleMapsURL.flatMap(URL.init) {
            openURL(google)
        } else {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: spot.coordinate))
            item.name = spot.name
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
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
