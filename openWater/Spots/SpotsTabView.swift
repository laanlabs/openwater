import CoreLocation
import MapKit
import OpenWaterCore
import SwiftUI

/// The Spots tab: a persistent map with live wind on the pins, and one
/// draggable sheet carrying the three things riders check daily — what's
/// nearby, their favorites, and the destination guides.
///
/// The sheet is hand-built rather than `.sheet` because the design (and any
/// map app worth copying) keeps the tab bar floating *above* the panel and the
/// map alive behind it; a system sheet would cover both and dismiss on tab
/// switches. Three snap points: a peek, half, and nearly-full.
struct SpotsTabView: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(PhoneRecorder.self) private var recorder
    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var path: [SpotsRoute] = []
    @State private var isSearching = false
    @State private var controlsExpanded = false
    @State private var panelMode: PanelMode = .nearby
    @State private var panelDetent: PanelDetent = .peek
    @State private var disciplineFilter: String?
    @State private var firingOnly = false
    @State private var pickingNewSpot = false
    @State private var addingSpot: NewSpotRequest?
    @State private var sharingLocation = false
    @State private var isGivingFeedback = false
    @State private var isShowingConditions = false
    @State private var localWeather: SpotWeather?
    /// Drives the chip's fade while the weather is in flight.
    @State private var isBreathing = false
    @State private var localWind: WindReading?

    /// The two spot lists, worked out when something they depend on moves
    /// rather than every time the body runs.
    ///
    /// Both are a filter and a distance sort over the whole guide — a
    /// thousand-odd haversines each. As computed properties they were paid for
    /// on every body evaluation, and the body runs on every frame of a panel
    /// drag, which is what made the map's pins strobe: fifty annotations
    /// rebuilt from a freshly sorted array sixty times a second. Held as
    /// state, a drag re-reads the same array and MapKit has nothing to diff.
    @State private var pins: [GuideSpot] = []
    @State private var nearby: [GuideSpot] = []

    /// A point the rider chose by holding a finger on the map.
    ///
    /// The chip has always followed the GPS, which is right when you are
    /// standing at the launch and useless when you are on the sofa deciding
    /// where to drive. Long-press anywhere and everything — the weather, the
    /// wind, the conditions sheet — is about that point instead.
    @State private var pickedPoint: Geo.Coordinate?

    enum PanelMode: String, CaseIterable {
        case nearby = "Nearby", favorites = "Favorites", destinations = "Destinations"
    }

    /// Four snap points, not three. The old floor was 30% of the screen, so
    /// "get out of my way" was not a thing the panel could do — dragging it
    /// down just sprang it back, which is what "the nearby tab doesn't slide
    /// down" meant. `.minimized` is the header alone: the mode switch stays
    /// reachable and the map gets everything else.
    enum PanelDetent: CaseIterable {
        case minimized, peek, half, full
        /// Zero means "as small as the header allows" — resolved in points,
        /// because the header does not scale with the screen.
        var fraction: CGFloat {
            switch self {
            case .minimized: 0
            case .peek: 0.32
            case .half: 0.58
            case .full: 0.92
            }
        }
    }

    /// A request to add a spot: either at a place picked on the map, or `nil`
    /// for "here", which lets the form use the live fix as it always has.
    struct NewSpotRequest: Identifiable {
        let place: PickedPlace?
        let id = UUID()
    }

    enum SpotsRoute: Hashable {
        case spot(GuideSpot)
        case region(GuideRegion)
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    map
                        .ignoresSafeArea()

                    panel(in: geometry.size)
                }
                .overlay(alignment: .top) { floatingControls }
                .overlay {
                    if isSearching {
                        SpotSearchOverlay(isPresented: $isSearching) { route in
                            isSearching = false
                            path.append(route)
                        }
                    }
                }
            }
            .navigationDestination(for: SpotsRoute.self) { route in
                switch route {
                case .spot(let spot):
                    SpotDetailScreen(spot: spot)
                case .region(let region):
                    DestinationScreen(region: region) { path.append(.spot($0)) }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $pickingNewSpot) {
            LocationPickerSheet(title: "Where is the spot?", initial: mapCentre) { place in
                addingSpot = NewSpotRequest(place: place)
            }
        }
        .sheet(item: $addingSpot) { request in
            SuggestSpotView(mode: .newSpot(request.place))
        }
        .sheet(isPresented: $sharingLocation) {
            ShareLocationSheet()
        }
        .sheet(isPresented: $isGivingFeedback) {
            AppFeedbackSheet(screen: "Spots")
        }
        .sheet(isPresented: $isShowingConditions) {
            if let here = localCoordinate {
                NearbyConditionsSheet(title: pickedPoint == nil ? "Conditions here" : "Conditions there",
                                      coordinate: here)
            }
        }
        .onAppear { isBreathing = true }
        .onChange(of: spotsKey, initial: true) { _, _ in refreshSpotLists() }
        .task(id: localWeatherKey) {
            guard let here = localCoordinate else { return }
            async let air = guide.weather(at: here)
            async let blowing = guide.currentWind(at: here)
            (localWeather, localWind) = await (air, blowing)
        }
        .task { await guide.load() }
        .task(id: windRefreshKey) {
            await guide.refreshWind(for: pins + nearby.prefix(20) + guide.favorites)
        }
    }

    /// Wind is refetched when the viewport moves to new spots, not per frame.
    private var windRefreshKey: String {
        pins.prefix(8).map(\.spotId).joined(separator: ",")
    }

    // MARK: - Map

    /// What the two lists depend on. Anything not in here cannot change them,
    /// which is the whole point — a panel drag is not in here.
    ///
    /// The viewport is rounded to about a hundred metres: a map settles on a
    /// region whose span differs in the twelfth decimal place between frames,
    /// and an exact key would recompute on every one of them.
    private var spotsKey: String {
        let region = visibleRegion.map {
            String(format: "%.3f,%.3f,%.3f",
                   $0.center.latitude, $0.center.longitude, $0.span.latitudeDelta)
        } ?? "-"
        let here = recorder.location.lastCoordinate.map {
            String(format: "%.3f,%.3f", $0.latitude, $0.longitude)
        } ?? "-"
        // The wind count moves as readings land, and `firingOnly` reads them.
        return "\(region)|\(here)|\(disciplineFilter ?? "")|\(firingOnly)|\(guide.spots.count)|\(firingOnly ? guide.wind.count : 0)"
    }

    private func refreshSpotLists() {
        pins = pinSpots
        nearby = Array(nearbySpots.prefix(30))
    }

    /// The spots worth pins right now: inside the viewport, nearest to its
    /// centre first, capped so MapKit is drawing dozens and not a thousand.
    private var pinSpots: [GuideSpot] {
        guard let region = visibleRegion else { return [] }
        let halfLat = region.span.latitudeDelta / 2 * 1.2
        let halfLon = region.span.longitudeDelta / 2 * 1.2
        let centre = region.center
        return filtered(guide.spots)
            .filter { spot in
                abs(spot.latitude - centre.latitude) < halfLat &&
                abs(spot.longitude - centre.longitude) < halfLon
            }
            .sorted {
                distance($0.coordinate, from: centre) < distance($1.coordinate, from: centre)
            }
            .prefix(50)
            .map { $0 }
    }

    private func filtered(_ spots: [GuideSpot]) -> [GuideSpot] {
        spots.filter { spot in
            if let discipline = disciplineFilter, spot.preferredActivity != discipline { return false }
            if firingOnly {
                guard let reading = guide.wind[spot.spotId], reading.isFiring else { return false }
            }
            return true
        }
    }

    private func distance(_ a: CLLocationCoordinate2D, from b: CLLocationCoordinate2D) -> Double {
        Geo.distance(.init(latitude: a.latitude, longitude: a.longitude),
                     .init(latitude: b.latitude, longitude: b.longitude))
    }

    private var map: some View {
        // Read the wind dictionary *here*, during body evaluation. The map
        // content builder's closures run outside SwiftUI's observation scope,
        // so a lookup inside them registers no dependency — the pins were
        // stuck as dots while the list rows two inches below showed the
        // readings. Capturing the dictionary up front both registers the
        // dependency and hands the closures a stable copy.
        let readings = guide.wind
        return MapReader { proxy in
            Map(position: $camera) {
            UserAnnotation()
            ForEach(pins) { spot in
                Annotation("", coordinate: spot.coordinate, anchor: .bottom) {
                    Button { path.append(.spot(spot)) } label: {
                        WindPin(reading: readings[spot.spotId])
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }

            if let picked = pickedPoint {
                Annotation("", coordinate: .init(latitude: picked.latitude,
                                                 longitude: picked.longitude),
                           anchor: .bottom) {
                    Button { isShowingConditions = true } label: {
                        PickedPointPin()
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(settings.mapStyle.mapStyle)
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        // A long press rather than a tap: a tap on a map is how you dismiss
        // things and hit pins, and stealing it would make the map feel broken.
        .gesture(
            LongPressGesture(minimumDuration: 0.4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onEnded { value in
                    guard case .second(true, let drag?) = value,
                          let coordinate = proxy.convert(drag.location, from: .local)
                    else { return }
                    withAnimation(.snappy) {
                        pickedPoint = Geo.Coordinate(latitude: coordinate.latitude,
                                                     longitude: coordinate.longitude)
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
        )
        }
    }

    // MARK: - Floating chrome

    /// Collapsed by default — the map is the point, and a permanent search
    /// bar plus a chip row was a hat brim across the top of it. One icon
    /// expands into the bar and the filters; a dot on the icon says a filter
    /// is quietly shaping what the map shows, because a hidden active filter
    /// is how "where did all the spots go" tickets get written.
    private var floatingControls: some View {
        VStack(spacing: 10) {
            if controlsExpanded {
                HStack(spacing: 10) {
                    Button { isSearching = true } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            Text("Search spots, places")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
                    }
                    .buttonStyle(.plain)

                    squareButton("xmark") {
                        withAnimation(.snappy) { controlsExpanded = false }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(majorDisciplines, id: \.self) { discipline in
                            chip(shortLabel(discipline), isOn: disciplineFilter == discipline) {
                                disciplineFilter = disciplineFilter == discipline ? nil : discipline
                            }
                        }
                        chip("15kn+", isOn: firingOnly) { firingOnly.toggle() }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    weatherChip
                    Spacer()
                    squareButton("magnifyingglass", showsBadge: hasActiveFilter) {
                        withAnimation(.snappy) { controlsExpanded = true }
                    }
                    moreMenu
                    squareButton("location.fill") {
                        withAnimation(.snappy) { camera = .userLocation(fallback: .automatic) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// What it is doing where the rider is standing.
    ///
    /// The map answers "where can I go" and said nothing at all about now.
    /// This is the other half: sky and temperature for the rider's own
    /// position — not a spot, just wherever they are — and the way into every
    /// station, cam and forecast around them.
    ///
    /// It follows the fix when there is one and the map centre when there is
    /// not, so browsing Maui from the sofa shows Maui's weather rather than
    /// the weather outside.
    private var weatherChip: some View {
        Button {
            isShowingConditions = true
        } label: {
            HStack(spacing: 6) {
                if let weather = localWeather {
                    Image(systemName: weather.symbol)
                        .font(.subheadline)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(weather.tint)
                    Text(Format.temperature(weather.temperatureC,
                                             unit: settings.units.temperatureUnit,
                                             includeSymbol: false))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                } else {
                    // Breathing rather than spinning. This chip is a corner of
                    // a map somebody is panning, and a spinner in the corner of
                    // a map reads as something being wrong; a symbol that
                    // fades says "on its way" and gets out of the way.
                    Image(systemName: "cloud.sun")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .opacity(isBreathing ? 0.35 : 1)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                   value: isBreathing)
                    LoadingPlaceholder(height: 13, width: 26, corner: 4)
                }
                if let reading = localWind {
                    Text("\(Int(reading.speedKn.rounded()))kn")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(reading.isFiring ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                }
                if localWeather == nil, localWind != nil {
                    LoadingPlaceholder(height: 13, width: 22, corner: 4)
                }
                if pickedPoint != nil {
                    Divider().frame(height: 18)
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.snappy) { pickedPoint = nil }
                        }
                        .accessibilityLabel("Back to my location")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pickedPoint == nil
                            ? "Weather here, and nearby stations"
                            : "Weather at the point you picked")
    }

    /// Where "here" is: the rider, or what they are looking at.
    private var localCoordinate: Geo.Coordinate? {
        pickedPoint ?? recorder.location.lastCoordinate ?? mapCentre
    }

    /// Rounded to about a kilometre so panning the map does not refetch on
    /// every frame — the weather does not change across a city block.
    private var localWeatherKey: String {
        guard let here = localCoordinate else { return "" }
        return String(format: "%.2f,%.2f", here.latitude, here.longitude)
    }

    /// What else a rider does while looking at this map.
    ///
    /// Adding a spot is here because the map is where you are already looking
    /// when you notice one is missing, and it takes two forms: the launch you
    /// are standing on, and the one across the bay you can point at but have
    /// never driven to. Sharing a pin is here for the same reason — it is
    /// wanted at the end of a run, with this screen open, not two tabs away
    /// in Tools.
    private var moreMenu: some View {
        Menu {
            Button {
                addingSpot = NewSpotRequest(place: hereOrCentre)
            } label: {
                Label("Add a spot here", systemImage: "plus.circle")
            }
            Button {
                pickingNewSpot = true
            } label: {
                Label("Pick the spot on the map", systemImage: "mappin.and.ellipse")
            }
            Divider()
            Button {
                sharingLocation = true
            } label: {
                Label("Share my position", systemImage: "square.and.arrow.up")
            }
            Divider()
            // This tab hides its navigation bar, so the bug button every other
            // screen carries in the toolbar has nowhere to go. It lives here
            // rather than as a fifth floating control: the map is the point of
            // the screen, and a permanent extra button over it is exactly the
            // hat brim the controls were collapsed to avoid.
            Button {
                isGivingFeedback = true
            } label: {
                Label("Feedback about this screen", systemImage: "ladybug")
            }
        } label: {
            squareLabel("ellipsis")
        }
    }

    /// The rider's own fix when there is one — `nil` lets the form keep
    /// following it as it settles — otherwise whatever the map is centred on.
    private var hereOrCentre: PickedPlace? {
        if recorder.location.lastCoordinate != nil { return nil }
        guard let centre = mapCentre else { return nil }
        return PickedPlace(name: "", coordinate: centre)
    }

    private var mapCentre: Geo.Coordinate? {
        visibleRegion.map {
            Geo.Coordinate(latitude: $0.center.latitude, longitude: $0.center.longitude)
        }
    }

    private var hasActiveFilter: Bool { disciplineFilter != nil || firingOnly }

    private func squareButton(_ symbol: String, showsBadge: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            squareLabel(symbol, showsBadge: showsBadge)
        }
        .buttonStyle(.plain)
    }

    private func squareLabel(_ symbol: String, showsBadge: Bool = false) -> some View {
        Image(systemName: symbol)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
            .overlay(alignment: .topTrailing) {
                if showsBadge {
                    Circle()
                        .fill(.tint)
                        .frame(width: 9, height: 9)
                        .offset(x: -5, y: 5)
                }
            }
    }

    /// The disciplines that earn a chip — same rule as the website: only ones
    /// with a real population, so the row stays scannable.
    private var majorDisciplines: [String] {
        var counts: [String: Int] = [:]
        for spot in guide.spots {
            if let d = spot.preferredActivity { counts[d, default: 0] += 1 }
        }
        return counts.filter { $0.value >= 5 }
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map(\.key)
    }

    private func shortLabel(_ discipline: String) -> String {
        discipline
            .replacingOccurrences(of: " Foiling", with: "")
            .replacingOccurrences(of: "Foiling", with: "Foil")
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(
                    isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial),
                    in: Capsule()
                )
                .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Panel

    /// The header's own height: the grab bar plus the mode switch. This is
    /// what `.minimized` resolves to, plus room for the tab bar that floats
    /// over the panel — without that the switch would sit behind it.
    private var collapsedHeight: CGFloat { 76 + tabBarHeight }

    /// The panel, with its own drag.
    ///
    /// The live drag offset lives inside `SpotsPanel` rather than here, and
    /// that is the fix for the flicker: as state on this view it invalidated
    /// the whole body — map included — on every touch-move, so a slow drag up
    /// or down tore down and rebuilt fifty map annotations sixty times a
    /// second. Only the panel's own height changes during a drag, so only the
    /// panel needs to know about it.
    private func panel(in size: CGSize) -> some View {
        SpotsPanel(detent: $panelDetent, size: size, collapsedHeight: collapsedHeight) {
            VStack(spacing: 0) {
                Picker("Mode", selection: $panelMode) {
                    ForEach(PanelMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                panelContent
            }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        if guide.spots.isEmpty {
            VStack(spacing: 8) {
                if guide.isLoading {
                    ProgressView()
                    Text("Loading the spot guide…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = guide.loadError {
                    Text("Couldn't load the spot guide.")
                        .font(.subheadline)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch panelMode {
                    case .nearby: nearbyList
                    case .favorites: favoritesList
                    case .destinations: destinationsList
                    }
                }
                .padding(.bottom, tabBarHeight + 12)
            }
            .scrollDisabled(isCompact)
        }
    }

    private var isCompact: Bool {
        panelDetent == .peek || panelDetent == .minimized
    }

    // MARK: Nearby

    /// Sorted by distance from the rider — or from the map centre when the
    /// app has no fix, which is also what makes browsing a faraway region
    /// from the sofa work the way you'd hope.
    private var nearbySpots: [GuideSpot] {
        let origin: CLLocationCoordinate2D
        if let here = recorder.location.lastCoordinate {
            origin = CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude)
        } else if let region = visibleRegion {
            origin = region.center
        } else {
            return filtered(guide.spots)
        }
        return filtered(guide.spots)
            .sorted { distance($0.coordinate, from: origin) < distance($1.coordinate, from: origin) }
    }

    private var nearbyList: some View {
        ForEach(nearby) { spot in
            Button { path.append(.spot(spot)) } label: {
                SpotRow(spot: spot, reading: guide.wind[spot.spotId],
                        distanceMetres: distanceFromHere(spot), units: settings.units)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 74)
        }
    }

    private func distanceFromHere(_ spot: GuideSpot) -> Double? {
        guard let here = recorder.location.lastCoordinate else { return nil }
        return Geo.distance(here, .init(latitude: spot.latitude, longitude: spot.longitude))
    }

    // MARK: Favorites

    @ViewBuilder
    private var favoritesList: some View {
        let favorites = guide.favorites
        if favorites.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "star")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No favorites yet")
                    .font(.subheadline.weight(.medium))
                Text("Star a spot and it lives here with live wind, so \"is it on?\" is one glance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)
        } else {
            let firing = favorites.filter { guide.wind[$0.spotId]?.isFiring == true }
            if !firing.isEmpty {
                HStack(spacing: 12) {
                    Text("\(firing.count)")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.tint, in: Circle())
                    Text("\(firing.count == 1 ? "1 favorite is" : "\(firing.count) favorites are") firing right now — \(firing.map(\.name).joined(separator: ", ")).")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            ForEach(favorites) { spot in
                Button { path.append(.spot(spot)) } label: {
                    FavoriteCard(spot: spot, reading: guide.wind[spot.spotId],
                                 distanceMetres: distanceFromHere(spot), units: settings.units)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: Destinations

    private var destinationsList: some View {
        ForEach(guide.destinations) { region in
            Button { path.append(.region(region)) } label: {
                HStack(spacing: 12) {
                    Text("\(region.spotCount)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(region.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let blurb = region.description {
                            Text(blurb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 68)
        }
    }
}

// MARK: - The panel

/// The draggable sheet over the spots map, and the only thing that knows how
/// far the thumb has moved.
///
/// It is its own view for exactly one reason: a live drag is sixty or a
/// hundred and twenty state writes a second, and every one of them invalidates
/// the body that owns the state. When that body also built the map, the drag
/// cost a full rebuild of every annotation on it — which is what a rider saw
/// as the panel flickering. Here, the writes land on a view whose body is a
/// frame height and a `VStack`, and the map never hears about them.
private struct SpotsPanel<Content: View>: View {

    @Binding var detent: SpotsTabView.PanelDetent
    let size: CGSize
    let collapsedHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var drag: CGFloat = 0

    private func height(for detent: SpotsTabView.PanelDetent) -> CGFloat {
        max(collapsedHeight, size.height * detent.fraction)
    }

    /// At the short detents the list has nothing to scroll, so the whole panel
    /// drags — which is what a thumb landing anywhere on it expects. Once it
    /// is tall enough to scroll, only the grab bar drags, or the two gestures
    /// fight.
    private var isCompact: Bool {
        detent == .peek || detent == .minimized
    }

    /// The panel slides. It does not grow and shrink.
    ///
    /// That distinction is the whole difference between a drag that glides and
    /// one that flickers. Driving the height from the drag re-proposes a new
    /// size to the `ScrollView` inside on every frame, so its `LazyVStack`
    /// recomputes which rows fit and builds and tears down the ones at the
    /// boundary — sixty times a second. A row built from scratch starts its
    /// thumbnail loading again from the grey placeholder, which is what a
    /// rider sees as the list glitching under their thumb.
    ///
    /// So the content is laid out once at its tallest, and the drag moves it
    /// with `offset`. Offsetting is a draw-time transform: nothing is
    /// re-proposed, no row is rebuilt, and whatever hangs below the bottom of
    /// the screen is simply not on screen.
    var body: some View {
        let full = height(for: .full)
        let resting = height(for: detent)
        let live = min(full, max(collapsedHeight, resting - drag))
        VStack(spacing: 0) {
            grabBar
            content
                // The panel is laid out at its tallest but only `resting` of
                // it is on screen, so without this the last rows of the list
                // sit in the part that is below the bottom edge and no amount
                // of scrolling can reach them. Keyed to the detent, not to the
                // drag, so it changes once on release rather than per frame.
                .contentMargins(.bottom, full - resting, for: .scrollContent)
                .gesture(dragGesture, isEnabled: isCompact)
        }
        .frame(height: full, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.14), radius: 15, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
        .offset(y: full - live)
    }

    /// The one part of the panel that drags.
    ///
    /// It used to be the whole panel, which is why the list underneath fought
    /// the sheet for every swipe. A grab bar the width of the panel is the
    /// same target every map app uses, and it leaves the list free to scroll.
    /// The chevron beside it does the same job without a gesture at all —
    /// which is the point, since a drag you have to discover is not a control.
    private var grabBar: some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .padding(.top, 4)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Button { toggle() } label: {
                    Image(systemName: detent == .minimized ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 28)
                        .background(Color(.systemGray5), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
                .accessibilityLabel(detent == .minimized ? "Expand nearby" : "Minimize nearby")
            }
            .onTapGesture { toggle() }
            .gesture(dragGesture)
    }

    private func toggle() {
        withAnimation(.snappy) {
            detent = detent == .minimized ? .half : .minimized
        }
    }

    /// Drag to the nearest snap point, thrown rather than dropped — the
    /// projected end of the flick decides, so a fast flick down minimizes
    /// from full without stopping at every detent on the way.
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation.height }
            .onEnded { value in
                let projected = height(for: detent) - value.predictedEndTranslation.height
                let nearest = SpotsTabView.PanelDetent.allCases.min {
                    abs(height(for: $0) - projected) < abs(height(for: $1) - projected)
                } ?? .peek
                withAnimation(.snappy) {
                    detent = nearest
                    drag = 0
                }
            }
    }
}

// MARK: - Pieces

/// The point a rider held a finger on.
///
/// Deliberately unlike `WindPin`: those are places in the guide, this is a
/// scratch mark that goes away when they are done with it.
struct PickedPointPin: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "cloud.sun.fill")
                .font(.caption)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            Rectangle()
                .fill(Color.primary.opacity(0.85))
                .frame(width: 2, height: 8)
        }
    }
}

/// A map pin that answers "is it on?" before it answers "what is here?".
struct WindPin: View {
    let reading: WindReading?

    var body: some View {
        VStack(spacing: 0) {
            if let reading {
                HStack(spacing: 5) {
                    Text(reading.cardinal.prefix(1))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(reading.isFiring ? .white.opacity(0.28) : Color.accentColor, in: Circle())
                    Text("\(Int(reading.speedKn.rounded()))")
                        .font(.system(size: 13, weight: .bold))
                    + Text("kn")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.leading, 5)
                .padding(.trailing, 9)
                .foregroundStyle(reading.isFiring ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(
                    reading.isFiring ? AnyShapeStyle(.tint) : AnyShapeStyle(.background),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
            } else {
                Circle()
                    .fill(.tint)
                    .stroke(.white, lineWidth: 2.5)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            }
            if reading != nil {
                Rectangle()
                    .fill(.background)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(45))
                    .offset(y: -6)
            }
        }
    }
}

/// A row in the Nearby list: name, distance and discipline, wind on the right.
struct SpotRow: View {
    let spot: GuideSpot
    let reading: WindReading?
    let distanceMetres: Double?
    let units: UnitPreferences

    var body: some View {
        HStack(spacing: 12) {
            SpotThumb(url: spot.imageURL)

            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let reading {
                VStack(alignment: .trailing, spacing: 1) {
                    (Text("\(Int(reading.speedKn.rounded()))")
                        .font(.headline)
                     + Text("kn").font(.caption2.weight(.semibold)))
                        .foregroundStyle(reading.isFiring ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text("\(reading.cardinal)\(reading.gustKn.map { " · g\(Int($0.rounded()))" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let metres = distanceMetres {
            parts.append(Format.distance(metres, unit: units.distance))
        }
        if let activity = spot.preferredActivity { parts.append(activity) }
        if let level = spot.experienceLevel { parts.append(String(level.prefix(24))) }
        if parts.isEmpty, !spot.where_.isEmpty { parts.append(spot.where_) }
        return parts.joined(separator: " · ")
    }
}

/// The favorites dashboard card: wind leads, everything else supports.
struct FavoriteCard: View {
    let spot: GuideSpot
    let reading: WindReading?
    let distanceMetres: Double?
    let units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(spot.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(locationLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.tint, in: Circle())
            }

            HStack(spacing: 8) {
                statTile("Wind", reading.map { "\(Int($0.speedKn.rounded()))kn \($0.cardinal)" } ?? "—",
                         highlighted: reading?.isFiring == true)
                if let gust = reading?.gustKn {
                    statTile("Gusts", "\(Int(gust.rounded()))kn", highlighted: false)
                }
                if spot.cameraCount > 0 {
                    statTile("Cams", "\(spot.cameraCount)", highlighted: false)
                } else if spot.windStationCount > 0 {
                    statTile("Meters", "\(spot.windStationCount)", highlighted: false)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var locationLine: String {
        var parts: [String] = []
        if !spot.where_.isEmpty { parts.append(spot.where_) }
        if let metres = distanceMetres {
            parts.append(Format.distance(metres, unit: units.distance))
        }
        return parts.joined(separator: " · ")
    }

    private func statTile(_ label: String, _ value: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.bold))
                .foregroundStyle(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Small photo thumbnail with a graceful empty state.
struct SpotThumb: View {
    let url: String?
    var size: CGFloat = 46

    @State private var loaded: UIImage?

    private var parsed: URL? { url.flatMap { URL(string: $0) } }

    /// Read straight out of the cache during body evaluation, so a row that
    /// has been drawn once already draws with its picture on the very first
    /// frame rather than a frame of grey.
    private var image: UIImage? {
        loaded ?? parsed.flatMap { ThumbnailCache.shared.image(for: $0) }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(.systemGray5)
                    if parsed == nil {
                        Image(systemName: "water.waves")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            guard let parsed, ThumbnailCache.shared.image(for: parsed) == nil else { return }
            loaded = await ThumbnailCache.shared.load(parsed)
        }
    }
}

/// Thumbnails, kept in memory for as long as the app is running.
///
/// `AsyncImage` was doing this job and cannot: it holds its loading state in
/// the view, so every time SwiftUI rebuilds a row — a lazy stack recycling it,
/// a panel changing size, a list reordering — the picture restarts from the
/// placeholder. On a list of spots that reads as the whole thing flashing
/// grey, which is what a rider reported while dragging the panel.
///
/// `NSCache` rather than a dictionary, so this yields memory back under
/// pressure instead of growing until the guide is exhausted.
@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSURL, UIImage>()
    /// One request per URL, however many rows ask for it at once.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() { cache.countLimit = 300 }

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let running = inFlight[url] { return await running.value }

        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data)
            else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

// MARK: - Search overlay

/// Search covers the map, and the empty state does the work: destinations
/// first, then browse by country — the two ways someone plans a trip.
struct SpotSearchOverlay: View {

    @Binding var isPresented: Bool
    let onOpen: (SpotsTabView.SpotsRoute) -> Void

    @Environment(SpotGuideStore.self) private var guide
    @FocusState private var focused: Bool
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search spots, places", text: $query)
                        .focused($focused)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                Button("Cancel") { isPresented = false }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if !query.isEmpty {
                        results
                    } else {
                        destinationRail
                        countryChips
                    }
                }
                .padding(.bottom, 120)
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { focused = true }
    }

    private var matches: [GuideSpot] {
        let needle = query.lowercased()
        return guide.spots.filter {
            $0.name.lowercased().contains(needle) ||
            $0.where_.lowercased().contains(needle)
        }
    }

    private var regionMatches: [GuideRegion] {
        let needle = query.lowercased()
        return (guide.destinations + guide.countries).filter {
            $0.name.lowercased().contains(needle)
        }
    }

    @ViewBuilder
    private var results: some View {
        sectionHeader("Top results")
        ForEach(regionMatches.prefix(3)) { region in
            Button { onOpen(.region(region)) } label: {
                HStack(spacing: 12) {
                    Text("\(region.spotCount)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(region.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Text(region.type == "destination" ? "Destination guide · \(region.spotCount) spots"
                             : "\(region.spotCount) spots")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        ForEach(matches.prefix(20)) { spot in
            Button { onOpen(.spot(spot)) } label: {
                HStack(spacing: 12) {
                    SpotThumb(url: spot.imageURL, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(spot.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Text([spot.where_, spot.preferredActivity].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if matches.isEmpty && regionMatches.isEmpty {
            Text("Nothing matches \"\(query)\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var destinationRail: some View {
        sectionHeader("Destinations")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(guide.destinations.prefix(8)) { region in
                    Button { onOpen(.region(region)) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(region.name)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(region.spotCount) spots")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(width: 160, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var countryChips: some View {
        sectionHeader("Browse by country")
        FlowLayoutChips(regions: Array(guide.countries.prefix(24))) { onOpen(.region($0)) }
            .padding(.horizontal, 16)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
    }
}

/// Country chips that wrap, like the site's browse footer.
struct FlowLayoutChips: View {
    let regions: [GuideRegion]
    let onTap: (GuideRegion) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(regions) { region in
                Button { onTap(region) } label: {
                    HStack(spacing: 6) {
                        Text(region.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(region.spotCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal wrapping layout for the chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
