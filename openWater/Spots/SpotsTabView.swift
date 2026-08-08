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
    @State private var panelDrag: CGFloat = 0
    @State private var disciplineFilter: String?
    @State private var firingOnly = false
    @State private var pickingNewSpot = false
    @State private var addingSpot: NewSpotRequest?

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
        .task { await guide.load() }
        .task(id: windRefreshKey) {
            await guide.refreshWind(for: pinSpots + nearbySpots.prefix(20) + guide.favorites)
        }
    }

    /// Wind is refetched when the viewport moves to new spots, not per frame.
    private var windRefreshKey: String {
        pinSpots.prefix(8).map(\.spotId).joined(separator: ",")
    }

    // MARK: - Map

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
        return Map(position: $camera) {
            UserAnnotation()
            ForEach(pinSpots) { spot in
                Annotation("", coordinate: spot.coordinate, anchor: .bottom) {
                    Button { path.append(.spot(spot)) } label: {
                        WindPin(reading: readings[spot.spotId])
                            .contentShape(Rectangle())
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
                    Spacer()
                    squareButton("magnifyingglass", showsBadge: hasActiveFilter) {
                        withAnimation(.snappy) { controlsExpanded = true }
                    }
                    addSpotMenu
                    squareButton("location.fill") {
                        withAnimation(.snappy) { camera = .userLocation(fallback: .automatic) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Adding a spot from the map, which is where a rider is already looking
    /// when they notice one is missing. Two ways in, because the guide gets
    /// both kinds of gap: the launch you are standing on, and the one across
    /// the bay you can point at but have never driven to.
    private var addSpotMenu: some View {
        Menu {
            Button {
                addingSpot = NewSpotRequest(place: hereOrCentre)
            } label: {
                Label("Add a spot here", systemImage: "location.fill")
            }
            Button {
                pickingNewSpot = true
            } label: {
                Label("Pick the spot on the map", systemImage: "mappin.and.ellipse")
            }
        } label: {
            squareLabel("plus")
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

    private func height(for detent: PanelDetent, in size: CGSize) -> CGFloat {
        max(collapsedHeight, size.height * detent.fraction)
    }

    private func panel(in size: CGSize) -> some View {
        let resting = height(for: panelDetent, in: size)
        let live = min(height(for: .full, in: size),
                       max(collapsedHeight, resting - panelDrag))
        return VStack(spacing: 0) {
            grabBar(in: size)

            Picker("Mode", selection: $panelMode) {
                ForEach(PanelMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // At the short detents the list has nothing to scroll, so the
            // whole panel drags — which is what a thumb landing anywhere on
            // it expects. Once it is tall enough to scroll, only the grab bar
            // drags, or the two gestures fight.
            panelContent
                .gesture(dragGesture(in: size), isEnabled: isCompact)
        }
        .frame(height: live, alignment: .top)
        .frame(maxWidth: .infinity)
        .clipped()
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.14), radius: 15, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// The one part of the panel that drags.
    ///
    /// It used to be the whole panel, which is why the list underneath fought
    /// the sheet for every swipe. A grab bar the width of the panel is the
    /// same target every map app uses, and it leaves the list free to scroll.
    /// The chevron beside it does the same job without a gesture at all —
    /// which is the point, since a drag you have to discover is not a control.
    private func grabBar(in size: CGSize) -> some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .padding(.top, 4)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Button {
                    withAnimation(.snappy) {
                        panelDetent = panelDetent == .minimized ? .half : .minimized
                    }
                } label: {
                    Image(systemName: panelDetent == .minimized ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 28)
                        .background(Color(.systemGray5), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
                .accessibilityLabel(panelDetent == .minimized ? "Expand nearby" : "Minimize nearby")
            }
            .onTapGesture {
                withAnimation(.snappy) {
                    panelDetent = panelDetent == .minimized ? .half : .minimized
                }
            }
            .gesture(dragGesture(in: size))
    }

    /// Drag to the nearest snap point, thrown rather than dropped — the
    /// projected end of the flick decides, so a fast flick down minimizes
    /// from full without stopping at every detent on the way.
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { panelDrag = $0.translation.height }
            .onEnded { value in
                let projected = height(for: panelDetent, in: size)
                    - value.predictedEndTranslation.height
                let nearest = PanelDetent.allCases.min {
                    abs(height(for: $0, in: size) - projected)
                        < abs(height(for: $1, in: size) - projected)
                } ?? .peek
                withAnimation(.snappy) {
                    panelDetent = nearest
                    panelDrag = 0
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
        ForEach(nearbySpots.prefix(30)) { spot in
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

// MARK: - Pieces

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

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.systemGray5)
                }
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: "water.waves")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
