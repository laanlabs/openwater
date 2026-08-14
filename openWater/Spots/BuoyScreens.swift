import MapKit
import OpenWaterCore
import SwiftUI

/// One buoy, in full.
///
/// The list can only afford a line each, which is enough to compare them and
/// not enough to decide whether to trust one. This says what it is
/// measuring, when it last said so, and — the part the list cannot show —
/// where it is moored. A buoy twelve kilometres away is a different reading
/// depending on whether it sits outside the bar or inside the bay.
struct BuoyDetailScreen: View {

    let buoy: Buoy
    let from: Geo.Coordinate

    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL

    private var units: UnitPreferences { settings.units }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                map
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if let reading = buoy.reading {
                    if let direction = reading.meanDirectionDeg {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                // Pointing the way the waves travel, which is
                                // how an arrow on a swell chart is read.
                                .rotationEffect(.degrees(direction + 180))
                                .foregroundStyle(.teal)
                            Text("Waves from \(Format.cardinal(direction))")
                                .font(.subheadline.weight(.semibold))
                        }
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 10) {
                        tile("Wave height", reading.waveHeightM.map {
                            Format.height($0, unit: units.distance)
                        })
                        tile("Dominant period", reading.dominantPeriodS.map {
                            "\(Int($0.rounded())) s"
                        })
                        tile("Mean direction", reading.meanDirectionDeg.map {
                            "\(Format.cardinal($0)) \(Int($0.rounded()))°"
                        })
                        tile("Water", reading.waterTempC.map {
                            Format.temperature($0, unit: units.temperatureUnit)
                        })
                        tile("Wind", reading.windKn.map {
                            Format.speed($0 / 1.94384, unit: units.speed, decimals: 0)
                        })
                    }

                    if let at = reading.at {
                        Text("Measured \(at.formatted(.relative(presentation: .named)))"
                             + " · \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("This station is listed but not reporting. NDBC sensors go down "
                         + "often enough that a silent buoy is normal rather than alarming.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button {
                    openURL(buoy.url)
                } label: {
                    Label("Open on NDBC", systemImage: "arrow.up.right.square")
                        .font(.callout.weight(.semibold))
                }

                Text("Station \(buoy.id) · \(Format.distance(buoy.metres, unit: units.distance)) away. "
                     + "Measured on the water by NOAA's National Data Buoy Center, not modelled.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(buoy.name)
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Buoy detail")
    }

    private var map: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: buoy.coordinate.clCoordinate,
            latitudinalMeters: max(4_000, buoy.metres * 2.6),
            longitudinalMeters: max(4_000, buoy.metres * 2.6)
        ))) {
            Annotation(buoy.name, coordinate: buoy.coordinate.clCoordinate) {
                BuoyPin()
            }
            Annotation("Here", coordinate: from.clCoordinate) {
                Circle()
                    .fill(.tint)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func tile(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Every nearby buoy at once.
///
/// Distances in a list are a poor way to choose between buoys, because the
/// nearest one is often on the wrong side of a headland. Seen on a map the
/// choice makes itself.
struct BuoyMapScreen: View {

    let buoys: [Buoy]
    let from: Geo.Coordinate
    /// Fetch the buoys around a new centre, once the rider pans away.
    var search: ((Geo.Coordinate) async -> [Buoy])? = nil

    @Environment(AppSettings.self) private var settings
    @State private var chosen: Buoy?
    /// What "Search this area" found, shown in place of the originals.
    @State private var refreshed: [Buoy]?

    /// The fetch dressed for the modifier: nil stays nil, so the button
    /// never appears on a map with nothing to refetch.
    private var areaSearch: ((Geo.Coordinate) async -> Void)? {
        guard let search else { return nil }
        return { centre in refreshed = await search(centre) }
    }

    var body: some View {
        Map {
            Annotation("Here", coordinate: from.clCoordinate) {
                Circle()
                    .fill(.tint)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            ForEach(refreshed ?? buoys) { buoy in
                Annotation(buoy.name, coordinate: buoy.coordinate.clCoordinate) {
                    Button { chosen = buoy } label: {
                        BuoyPin(waveHeightM: buoy.reading?.waveHeightM,
                                unit: settings.units.distance)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .searchThisArea(areaSearch)
        .navigationTitle("Buoys nearby")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Buoys nearby")
        .sheet(item: $chosen) { buoy in
            NavigationStack {
                BuoyDetailScreen(buoy: buoy, from: from)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// Any of the sheet's placed sources on one map.
///
/// The lists sort by distance, and distance is the wrong way to choose
/// between places — the nearest station is often behind a headland, the
/// second-nearest tide chart on the wrong bank of the inlet. Seen on a map
/// the choice makes itself, which is why the buoys earned one first; this
/// is the same screen for everything else that has a coordinate: wind
/// stations free and paid, tide stations, the guide's surf pages.
struct PlacesMapScreen: View {

    struct Place: Identifiable {
        let id: String
        let name: String
        /// The line under the name on the callout — distance, provider, a
        /// reading when there is one.
        let subtitle: String
        let coordinate: Geo.Coordinate
        /// The pin's symbol — the same one its list row wears.
        let symbol: String
        /// Free public sources wear the tint; guide sources (usually the
        /// paid networks) wear orange, so the two read apart at a glance.
        var tint: Color = .accentColor
        /// Short text on the pin itself, when a number earns the space.
        var pinText: String? = nil
        /// Where "Open" goes, when the place has a page.
        var url: URL? = nil
        /// Cams play inside the app rather than handing off to a browser
        /// or another app — see `CamViewerSheet`.
        var watchInApp: Bool = false
    }

    let title: String
    let places: [Place]
    let from: Geo.Coordinate
    /// Fetch this map's kind of places around a new centre, once the rider
    /// pans away from where the originals were gathered.
    var search: ((Geo.Coordinate) async -> [Place])? = nil

    @Environment(\.openURL) private var openURL
    @State private var chosen: Place?
    @State private var watching: Place?
    /// What "Search this area" found, shown in place of the originals.
    @State private var refreshed: [Place]?

    /// The fetch dressed for the modifier: nil stays nil, so the button
    /// never appears on a map with nothing to refetch.
    private var areaSearch: ((Geo.Coordinate) async -> Void)? {
        guard let search else { return nil }
        return { centre in refreshed = await search(centre) }
    }

    var body: some View {
        Map {
            Annotation("Here", coordinate: from.clCoordinate) {
                Circle()
                    .fill(.tint)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            ForEach(refreshed ?? places) { place in
                Annotation(place.name, coordinate: place.coordinate.clCoordinate) {
                    Button { chosen = place } label: {
                        PlacePin(symbol: place.symbol, text: place.pinText, tint: place.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .searchThisArea(areaSearch)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Places map")
        .sheet(item: $chosen) { place in
            VStack(alignment: .leading, spacing: 10) {
                Text(place.name)
                    .font(.headline)
                Text(place.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = place.url {
                    Button {
                        if place.watchInApp {
                            chosen = nil
                            watching = place
                        } else {
                            openURL(url)
                        }
                    } label: {
                        Label(place.watchInApp ? "Watch" : "Open",
                              systemImage: place.watchInApp ? "play.rectangle" : "arrow.up.right.square")
                            .font(.callout.weight(.semibold))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .presentationDetents([.height(170)])
        }
        .fullScreenCover(item: $watching) { place in
            if let url = place.url {
                CamViewerSheet(name: place.name, url: url)
            }
        }
    }
}

// MARK: - Search this area

/// The "redo the search where I'm looking" mechanic, shared by the maps
/// that show fetched places.
///
/// Every map here opens on results gathered around one point. The moment the
/// rider pans down the coast or zooms out past the fetch radius, the pins
/// stop describing what the screen shows — and nothing says so. The fix is
/// the one Maps taught everyone: a button appears once the view has
/// wandered, and tapping it repeats the search around wherever the map is
/// looking now.
private struct SearchThisArea: ViewModifier {

    /// Repeat the search around this centre and swap in what it finds.
    /// Nil disables the mechanic entirely — a caller with nothing sensible
    /// to refetch never shows the button.
    let perform: ((Geo.Coordinate) async -> Void)?

    /// The framing the current results were gathered for. Drift is measured
    /// against this, and it rebases every time a search runs. Nil until the
    /// camera first settles — the map decides its own opening frame, and
    /// that frame is the baseline, not the coordinate the pins came from.
    @State private var searched: MKCoordinateRegion?
    @State private var visible: MKCoordinateRegion?
    @State private var isOffered = false
    @State private var isSearching = false

    func body(content: Content) -> some View {
        content
            .onMapCameraChange(frequency: .onEnd) { context in
                visible = context.region
                guard let searched else {
                    searched = context.region
                    return
                }
                withAnimation(.snappy) {
                    isOffered = hasDrifted(from: searched, to: context.region)
                }
            }
            .overlay(alignment: .top) {
                if isOffered, perform != nil {
                    button
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }

    private var button: some View {
        Button {
            Task { await search() }
        } label: {
            HStack(spacing: 6) {
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                Text(isSearching ? "Searching…" : "Search this area")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color(.separator).opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isSearching)
    }

    /// Far enough that the results no longer describe the view: the centre
    /// has moved a quarter of the screen in either axis, or the zoom has
    /// changed by half. Measured in fractions of the *visible* span, so the
    /// same finger's travel means the same thing at every zoom.
    private func hasDrifted(from searched: MKCoordinateRegion,
                            to region: MKCoordinateRegion) -> Bool {
        let dLat = abs(region.center.latitude - searched.center.latitude)
        let dLon = abs(region.center.longitude - searched.center.longitude)
        if dLat > region.span.latitudeDelta * 0.25 || dLon > region.span.longitudeDelta * 0.25 {
            return true
        }
        let scale = region.span.latitudeDelta / searched.span.latitudeDelta
        return scale > 1.5 || scale < 0.66
    }

    private func search() async {
        guard let perform, let region = visible else { return }
        withAnimation(.snappy) { isSearching = true }
        // The same beat the wind setter holds: a fetch that answers within
        // a frame reads as a button that did nothing.
        let started = ContinuousClock.now
        await perform(Geo.Coordinate(latitude: region.center.latitude,
                                     longitude: region.center.longitude))
        let elapsed = started.duration(to: .now)
        if elapsed < .seconds(1) {
            try? await Task.sleep(for: .seconds(1) - elapsed)
        }
        withAnimation(.snappy) {
            searched = region
            isOffered = false
            isSearching = false
        }
    }
}

extension View {
    /// Offer a "Search this area" button over a `Map` once its camera has
    /// wandered from the view the current results were fetched for.
    func searchThisArea(_ perform: ((Geo.Coordinate) async -> Void)?) -> some View {
        modifier(SearchThisArea(perform: perform))
    }
}

/// A place on the map, wearing its kind's symbol and colour.
struct PlacePin: View {
    let symbol: String
    var text: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            if let text {
                Text(text)
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint, in: Capsule())
        .foregroundStyle(.white)
        .shadow(radius: 2)
    }
}

/// The measured swell split from a nearby buoy — the `.spec` file's answer,
/// paired with the buoy it came from so the card can say whose water it is.
struct MeasuredSwell {
    let buoy: Buoy
    let reading: NDBCSpectral.Reading
}

/// The one card on the surf tab that is measured rather than modelled.
///
/// It shows the same swell/wind-wave breakdown as the modelled card above
/// it, from a wave sensor on real water — which is exactly why the footer
/// must name the buoy and its distance. A buoy in deep water is not the
/// beach, and presenting its reading as the spot would trade one kind of
/// dishonesty for another.
struct MeasuredSwellCard: View {

    let measured: MeasuredSwell

    @Environment(AppSettings.self) private var settings
    private var units: UnitPreferences { settings.units }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("MEASURED SWELL")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let steepness = measured.reading.steepness {
                    Text(steepness.lowercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            if let swell = measured.reading.swell {
                row(swell, colour: .orange, label: "swell")
            }
            if let windWave = measured.reading.windWave {
                row(windWave, colour: .secondary, label: "wind wave")
            }
            if measured.reading.swell == nil, measured.reading.windWave == nil,
               let height = measured.reading.waveHeightM {
                // The buoy measured a sea but could not resolve the split.
                Text("\(Format.height(height, unit: units.distance)) combined — this buoy is not resolving the split right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(footer)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private func row(_ train: SwellTrain, colour: Color, label: String) -> some View {
        HStack(spacing: 10) {
            Text(Format.height(train.heightM, unit: units.distance))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .frame(width: 58, alignment: .leading)

            Text(train.periodS.map { "\(Int($0.rounded()))s" } ?? "—")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .leading)

            if let direction = train.directionFromDeg {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(direction + 180))
                    .foregroundStyle(colour)
                Text("\(Format.cardinal(direction)) \(Int(direction.rounded()))°")
                    .font(.subheadline.weight(.medium))
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var footer: String {
        var text = "Measured at \(measured.buoy.name), "
            + "\(Format.distance(measured.buoy.metres, unit: units.distance)) away — "
            + "a wave sensor on deep water, not the beach."
        if Date().timeIntervalSince(measured.reading.at) > 60 {
            text += " Read \(measured.reading.at.formatted(.relative(presentation: .named)))."
        }
        return text
    }
}

/// A buoy, with its wave height on it when it has one.
struct BuoyPin: View {
    var waveHeightM: Double?
    var unit: DistanceUnit = .metric

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "water.waves")
                    .font(.system(size: 10, weight: .bold))
                if let waveHeightM {
                    Text(Format.height(waveHeightM, unit: unit))
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.tint, in: Capsule())
            .foregroundStyle(.white)
            .shadow(radius: 2)
        }
    }
}
