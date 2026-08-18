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
    @Environment(RouteStore.self) private var routeStore
    @Environment(\.floatingTabBarHeight) private var tabBarHeight
    @Environment(\.openURL) private var openURL

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var path: [SpotsRoute] = []
    @State private var isSearching = false
    @State private var controlsExpanded = false
    @State private var disciplineFilter: String?
    @State private var firingOnly = false
    @State private var pickingNewSpot = false
    @State private var addingSpot: NewSpotRequest?
    @State private var addingPrivateSpot: NewPrivateSpotRequest?
    @State private var selectedPrivateSpot: PrivateSpot?
    @State private var renamingSpot: PrivateSpot?
    @State private var editingFacingSpot: PrivateSpot?
    @State private var renameText = ""
    /// Wind for the private spots, fetched ad hoc — they have no spotId, so
    /// the guide's per-spot wind dictionary cannot carry them.
    @State private var privateWind: [UUID: WindReading] = [:]
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

    enum PanelMode: String, CaseIterable {
        case nearby = "Nearby", favorites = "Favorites", destinations = "Destinations"
    }

    @State private var panelMode: PanelMode = .nearby

    /// The sheet's height is the tab's decision now: inspecting a route
    /// raises it to half, closing drops it back to peek.
    @State private var panelDetent: SheetDetent = .peek

    /// Route drawing and inspection; nil is the map as it always was.
    @State private var routeMode: RouteMode?

    /// The colour wash, off by default and remembered — a field drawn
    /// under this map's own pins: the flow map's wind, or the ocean
    /// model's current.
    @AppStorage("spots.washLayer") private var washLayerRaw = WashLayer.off.rawValue
    @State private var windWash = WindWashModel()

    /// The hardware layers: the guide's wind meters and cams, and NDBC's
    /// buoys, as pins around the browsed water. Remembered like the wash.
    /// On by default — the guide's pins are the page — but a rider reading
    /// the wash wants the field, not a hundred capsules over it.
    @AppStorage("spots.layer.spots") private var showSpots = true
    @AppStorage("spots.layer.windStations") private var showWindStations = false
    @AppStorage("spots.layer.cameras") private var showCameras = false
    @AppStorage("spots.layer.buoys") private var showBuoys = false
    @State private var resourcePins: [SpotGuideStore.GuideResource] = []
    @State private var buoyPins: [Buoy] = []
    @State private var watchingCam: SpotGuideStore.GuideResource?

    private var washLayer: WashLayer {
        WashLayer(rawValue: washLayerRaw) ?? .off
    }

    /// The inspected route's forecast — shared by panel and map so both
    /// speak about the same estimate.
    @State private var routeWeather = RouteWeatherModel()

    /// What the map draws for the inspected route at the scrubbed instant.
    /// Held as state and refreshed by key, never computed per body pass —
    /// the pins-as-state rule, applied to chords and arrows that would
    /// otherwise rebuild on every frame of a panel drag.
    struct RouteMapDisplay {
        struct Segment: Identifiable {
            let id: Int
            let a: CLLocationCoordinate2D
            let b: CLLocationCoordinate2D
            let tint: Color
        }
        struct Arrow: Identifiable {
            let id: Int
            let at: CLLocationCoordinate2D
            let deg: Double
        }
        var segments: [Segment] = []
        var arrows: [Arrow] = []
        var marker: CLLocationCoordinate2D?
    }
    @State private var routeDisplay = RouteMapDisplay()

    /// A drawn line waiting for a name.
    struct SaveRouteRequest: Identifiable {
        let draft: [Geo.Coordinate]
        let routeId: UUID?
        let id = UUID()
    }
    @State private var savingRoute: SaveRouteRequest?
    @State private var renamingRoute: PlannedRoute?
    @State private var renameRouteText = ""
    @State private var isEditingFavorites = false
    /// The camera's centre *right now*, tracked continuously — but only
    /// while a route is being drawn. `visibleRegion` settles on `.onEnd`,
    /// and a rider taps Add point faster than a glide decays; a point
    /// dropped from the settled region lands where the crosshairs were,
    /// not where they are.
    @State private var editingCentre: CLLocationCoordinate2D?

    /// The map's own clock: nil is now, anything else is the hour every pin
    /// and both washes are answering for. Deliberately not persisted — a
    /// map that reopened on yesterday's scrub would be lying about the
    /// wind. A route's slider takes the clock over while it is open, so
    /// this control hides rather than argue with it.
    @State private var mapScrub: Date?
    @State private var isShowingTimeControl = false
    /// The scrubbed hour came back empty for the centre point — shown as a
    /// dash rather than an endless shimmer.
    @State private var centreHourMissing = false

    /// Which model answers for wind, app-wide. Stored rather than passed
    /// because every wind URL in the app reads it at build time; this copy
    /// exists so the views redraw and the fetches re-key when it changes.
    @AppStorage("spots.forecastModel") private var forecastModelRaw = ForecastModel.automatic.rawValue
    @State private var isPickingModel = false

    /// A request to add a spot: either at a place picked on the map, or `nil`
    /// for "here", which lets the form use the live fix as it always has.
    struct NewSpotRequest: Identifiable {
        let place: PickedPlace?
        let id = UUID()
    }

    /// A request to save a private spot, pinned to a coordinate at the
    /// moment the menu was tapped so a wandering fix cannot move it.
    struct NewPrivateSpotRequest: Identifiable {
        let coordinate: Geo.Coordinate
        let id = UUID()
    }

    enum SpotsRoute: Hashable {
        case spot(GuideSpot)
        case region(GuideRegion)
        case buoy(Buoy)
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    map
                        .ignoresSafeArea()

                    panel(in: geometry.size)
                }
                .overlay(alignment: .top) {
                    if case .editing(let draft, let routeId) = routeMode {
                        RouteEditChrome(
                            draftCount: draft.count,
                            onUndo: {
                                var trimmed = draft
                                trimmed.removeLast()
                                withAnimation(.snappy) {
                                    routeMode = .editing(draft: trimmed, routeId: routeId)
                                }
                            },
                            onCancel: {
                                withAnimation(.snappy) {
                                    routeMode = nil
                                    panelDetent = .peek
                                }
                            },
                            onSave: {
                                savingRoute = SaveRouteRequest(draft: draft, routeId: routeId)
                            }
                        )
                    } else {
                        floatingControls
                    }
                }
                .overlay(alignment: .bottom) {
                    // The one way points are laid down: pan until the
                    // crosshairs sit on the water, then this button. In
                    // thumb range on purpose — it is the whole gesture.
                    if case .editing(let draft, _) = routeMode {
                        Button(action: addDraftPointAtCentre) {
                            Label(draft.isEmpty ? "Add start" : "Add point",
                                  systemImage: "plus")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .frame(height: 46)
                                .background(.tint, in: Capsule())
                                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        // Above the minimized panel's picker row, not on it.
                        .padding(.bottom, 116)
                    }
                }
                .overlay(alignment: .bottom) {
                    if routeMode == nil, !isSearching,
                       panelDetent == .peek || panelDetent == .minimized {
                        bottomCorners
                            .padding(.horizontal, 16)
                            .padding(.bottom,
                                     panelHeight(in: geometry.size, detent: panelDetent) + 12)
                    }
                }
                .overlay {
                    if isSearching {
                        SpotSearchOverlay(isPresented: $isSearching, biasRegion: visibleRegion) { route in
                            isSearching = false
                            path.append(route)
                        } onPlace: { place in
                            isSearching = false
                            // A place is a camera move: the map goes there and
                            // the centre pin samples it — the same pipeline as
                            // a drag, with no new fetch code at all.
                            withAnimation(.snappy) {
                                camera = .region(MKCoordinateRegion(
                                    center: CLLocationCoordinate2D(latitude: place.latitude,
                                                                   longitude: place.longitude),
                                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                                ))
                            }
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
                case .buoy(let buoy):
                    BuoyPinScreen(buoy: buoy, from: localCoordinate ?? buoy.coordinate)
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
        .sheet(item: $addingPrivateSpot) { request in
            AddPrivateSpotSheet(coordinate: request.coordinate)
        }
        .fullScreenSheet(item: $selectedPrivateSpot) { spot in
            // A private spot has no guide page, so its tap opens the same
            // full conditions sheet the centre pin uses, beach facing along.
            NearbyConditionsSheet(title: spot.name, coordinate: spot.coordinate,
                                  shoreFacingDeg: spot.shoreFacingDeg)
        }
        .fullScreenCover(item: $watchingCam) { cam in
            CamViewerSheet(name: cam.displayName, url: cam.url)
        }
        .sheet(item: $editingFacingSpot) { spot in
            ShoreFacingSheet(spot: spot)
        }
        .alert("Rename spot", isPresented: isRenamingSpot, presenting: renamingSpot) { spot in
            TextField("Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { guide.renamePrivateSpot(spot.id, to: trimmed) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $savingRoute) { request in
            RouteSaveSheet(
                draft: request.draft,
                editing: request.routeId.flatMap { id in routeStore.routes.first { $0.id == id } }
            ) { route in
                commitRoute(route)
            }
        }
        .alert("Rename route", isPresented: isRenamingRoute, presenting: renamingRoute) { route in
            TextField("Name", text: $renameRouteText)
            Button("Save") {
                let trimmed = renameRouteText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { routeStore.rename(route.id, to: trimmed) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isEditingFavorites) {
            FavoritesEditor()
        }
        .sheet(isPresented: $isPickingModel) {
            ForecastModelSheet(selection: $forecastModelRaw)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $sharingLocation) {
            ShareLocationSheet()
        }
        .sheet(isPresented: $isGivingFeedback) {
            AppFeedbackSheet(screen: "Spots")
        }
        .fullScreenSheet(isPresented: $isShowingConditions) {
            if let here = localCoordinate {
                NearbyConditionsSheet(title: conditionsTitle, coordinate: here)
            }
        }
        .onAppear {
            isBreathing = true
            // The tab that leads with the weather where you are cannot wait
            // for another screen to have asked. Authorization only — the
            // pages in ContentView stay alive once visited, so a warm-up
            // with no matching disappear would run the GPS forever; the
            // map's own UserAnnotation takes it from here.
            recorder.location.requestAuthorization()
            // A handoff may predate this page existing at all — the seam,
            // not the notification, is what survives that.
            consumeRouteHandoff()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWaterOpenRoute)) { _ in
            consumeRouteHandoff()
        }
        .onChange(of: spotsKey, initial: true) { _, _ in refreshSpotLists() }
        .onChange(of: routeDisplayKey, initial: true) { _, _ in refreshRouteDisplay() }
        .task(id: localWeatherKey) {
            guard let here = localCoordinate else { return }
            // The old point's answer must not flash on the new point while
            // the refetch is in flight — the pin shimmers instead.
            localWind = nil
            localWeather = nil
            async let air = guide.weather(at: here)
            async let blowing = guide.currentWind(at: here)
            (localWeather, localWind) = await (air, blowing)
        }
        .task { await guide.load() }
        .onChange(of: forecastModelRaw) { _, _ in
            // Every cached number came from the old model; the wash refetches
            // on the map's own settle rule, and the pins' live readings are
            // re-asked by the key below carrying the model with it.
            guide.forgetWind()
            if washLayer != .off, let region = visibleRegion {
                windWash.clear()
                windWash.viewSettled(on: region, layer: washLayer)
            }
        }
        .task(id: windRefreshKey) {
            await guide.refreshWind(for: pins + nearby.prefix(20) + guide.favorites)
        }
        // Hourly series, fetched only once the clock leaves now — a rider
        // who never scrubs never pays for this.
        .task(id: scrubbedSpotsKey) {
            guard mapScrub != nil else { return }
            await guide.refreshWindHours(for: pins + nearby.prefix(20) + guide.favorites)
        }
        .task(id: scrubbedCentreKey) {
            centreHourMissing = false
            guard mapScrub != nil, let here = localCoordinate else { return }
            await guide.refreshWindHours(at: here)
            // The request is done. If there is still nothing for this hour,
            // the pill must stop implying that something is on its way —
            // some models are thin at some points, and a shimmer that never
            // ends is indistinguishable from a broken app.
            centreHourMissing = guide.reading(
                for: SpotGuideStore.windKey(for: here), at: mapScrub) == nil
        }
        .task(id: hardwareLayersKey) {
            guard showWindStations || showCameras || showBuoys,
                  let here = localCoordinate else {
                resourcePins = []
                buoyPins = []
                return
            }
            if showWindStations || showCameras {
                let resources = await guide.nearbyResources(near: here, radius: 60_000)
                // Capped: a dense coast can carry hundreds of meters and
                // cams, and a map of nothing but hardware stops being a map.
                resourcePins = Array(resources.filter {
                    ($0.kind == .wind && showWindStations) ||
                    ($0.kind == .camera && showCameras)
                }.prefix(80))
            } else {
                resourcePins = []
            }
            buoyPins = showBuoys ? await DataBuoyCenter.buoys(near: here, limit: 25) : []
        }
        .task(id: privateWindKey) {
            for spot in guide.privateSpots where privateWind[spot.id] == nil {
                privateWind[spot.id] = await guide.currentWind(at: spot.coordinate)
            }
        }
    }

    private var isRenamingRoute: Binding<Bool> {
        Binding(get: { renamingRoute != nil },
                set: { if !$0 { renamingRoute = nil } })
    }

    /// The alert modifier wants a Boolean; the spot being renamed is the truth.
    private var isRenamingSpot: Binding<Bool> {
        Binding(get: { renamingSpot != nil },
                set: { if !$0 { renamingSpot = nil } })
    }

    private var privateWindKey: String {
        guide.privateSpots.map(\.id.uuidString).joined(separator: ",")
    }

    /// Wind is refetched when the viewport moves to new spots, not per frame.
    /// The list's head rides in the key beside the pins'. Zoomed into a
    /// street there are no pins at all, and a key made only of pins never
    /// changes there — so the rows below sat blank, waiting for a pin to
    /// appear before the live fetch would fire. Refires are cheap:
    /// `refreshWind` drops every spot still inside its TTL.
    private var windRefreshKey: String {
        (pins.prefix(8).map(\.spotId) + nearby.prefix(8).map(\.spotId))
            .joined(separator: ",") + "|" + forecastModelRaw
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
        return "\(region)|\(here)|\(disciplineFilter ?? "")|\(firingOnly)|\(showSpots)|\(guide.spots.count)|\(firingOnly ? guide.wind.count : 0)"
    }

    private func refreshSpotLists() {
        pins = pinSpots
        nearby = Array(nearbySpots.prefix(30))
    }

    /// The spots worth pins right now: inside the viewport, nearest to its
    /// centre first, capped so MapKit is drawing dozens and not a thousand.
    /// Empty when the layer is toggled off — which also spares the wind
    /// refresh for pins nobody can see.
    private var pinSpots: [GuideSpot] {
        guard showSpots, let region = visibleRegion else { return [] }
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
                guard let reading = guide.reading(for: spot.spotId, at: mapScrub),
                      reading.isFiring else { return false }
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
        // Resolved through the map's clock: `guide.wind` at now, the
        // spot's own hourly row at any other hour.
        let readings = scrubbedReadings
        // Hoisted for the same reason as the wind dictionary: reads inside
        // the map content builder register no observation dependency.
        let washCells = washLayer == .off ? [] : windWash.cells
        let washField = washLayer == .off ? nil : windWash.field
        return MapReader { proxy in
            Map(position: $camera) {
            // The wash goes first: map content draws in order, and the
            // field belongs under every pin, handle and marker.
            ForEach(washCells) { cell in
                // The stroke is the fill's own colour: it papers over the
                // antialiased hairline between neighbouring quads, which
                // the saturated wash would otherwise show as a faint grid.
                MapPolygon(coordinates: cell.coordinates)
                    .foregroundStyle(cell.color)
                    .stroke(cell.color, lineWidth: 1)
            }
            UserAnnotation()
            // Pins step aside while a route is drawn: the map is a canvas
            // there, and a pin under the finger would steal the tap.
            if routeMode?.isEditing != true {
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

                ForEach(guide.privateSpots) { spot in
                    Annotation("", coordinate: spot.clCoordinate, anchor: .bottom) {
                        Button { selectedPrivateSpot = spot } label: {
                            PrivateSpotPin()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }

                // The hardware layers. A camera plays in the app, a buoy
                // opens its own page, a wind station is an outbound link —
                // each pin does what its row in the conditions sheet does.
                ForEach(resourcePins) { resource in
                    Annotation("", coordinate: resource.coordinate.clCoordinate, anchor: .center) {
                        Button {
                            if resource.kind == .camera { watchingCam = resource }
                            else { openURL(resource.url) }
                        } label: {
                            HardwarePin(kind: resource.kind)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(buoyPins) { buoy in
                    Annotation("", coordinate: buoy.coordinate.clCoordinate, anchor: .center) {
                        Button { path.append(.buoy(buoy)) } label: {
                            HardwarePin(kind: nil)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
            }

            if let mode = routeMode {
                let line = mode.waypoints.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                if line.count >= 2 {
                    MapPolyline(coordinates: line)
                        .stroke(.tint, style: StrokeStyle(
                            lineWidth: 4, lineCap: .round,
                            dash: mode.isEditing ? [7, 7] : []))
                }
                if case .editing(let draft, _) = mode {
                    ForEach(draft.indices, id: \.self) { index in
                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: draft[index].latitude, longitude: draft[index].longitude)) {
                            RouteHandle(isEnd: index == 0 || index == draft.count - 1)
                                .gesture(
                                    DragGesture(coordinateSpace: .global)
                                        .onChanged { value in
                                            guard let moved = proxy.convert(value.location, from: .global)
                                            else { return }
                                            moveDraftPoint(index, to: Geo.Coordinate(
                                                latitude: moved.latitude, longitude: moved.longitude))
                                        }
                                        .onEnded { _ in snapDraftPoint(index) }
                                )
                        }
                        .annotationTitles(.hidden)
                    }
                    if draft.count >= 2 {
                        ForEach(0..<(draft.count - 1), id: \.self) { leg in
                            Annotation("", coordinate: legMidpoint(draft[leg], draft[leg + 1])) {
                                Button { insertDraftPoint(after: leg) } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundStyle(.white)
                                        .frame(width: 18, height: 18)
                                        .background(Color.primary.opacity(0.6), in: Circle())
                                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                }
                                .buttonStyle(.plain)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                } else if line.count >= 2 {
                    Annotation("", coordinate: line.first!) {
                        RouteHandle(isEnd: true).allowsHitTesting(false)
                    }
                    .annotationTitles(.hidden)
                    Annotation("", coordinate: line.last!) {
                        RouteHandle(isEnd: true).allowsHitTesting(false)
                    }
                    .annotationTitles(.hidden)

                    // Alignment chords over the line: green runs, orange
                    // reaches, red work — recolored as the hour scrubs.
                    ForEach(routeDisplay.segments) { segment in
                        MapPolyline(coordinates: [segment.a, segment.b])
                            .stroke(segment.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                    ForEach(routeDisplay.arrows) { arrow in
                        Annotation("", coordinate: arrow.at) {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 10, weight: .heavy))
                                .rotationEffect(.degrees(arrow.deg + 180))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.primary.opacity(0.7), in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .allowsHitTesting(false)
                        }
                        .annotationTitles(.hidden)
                    }
                    if let marker = routeDisplay.marker {
                        Annotation("", coordinate: marker) {
                            Image(systemName: "figure.surfing")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(.tint, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                                .allowsHitTesting(false)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
        }
        // While a wash is up, the standard map goes muted — Apple's grey
        // mutedStandard voice — so its parkland greens stop arguing with
        // the field's colours; the wash owns the palette, the chart keeps
        // the shapes. The rider's own style returns the moment the wash
        // is off, and hybrid/satellite are left as chosen — emphasis is
        // a standard-style idea. (A saturation/contrast mute stack over
        // the whole map was tried and backed out: it composites over the
        // map's own content, so the pins drained grey with the basemap.)
        .mapStyle(washLayer != .off && settings.mapStyle == .standard
                  ? .standard(elevation: .flat, emphasis: .muted,
                              pointsOfInterest: .excludingAll, showsTraffic: false)
                  : settings.mapStyle.mapStyle)
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            windWash.viewSettled(on: context.region, layer: washLayer)
        }
        .onMapCameraChange(frequency: .continuous) { context in
            // Live centre for the crosshairs (see `editingCentre`). The
            // guard keeps ordinary pans from churning state every frame;
            // the single nil write on exit stops a stale centre from
            // outliving the session it was tracked for.
            if routeMode?.isEditing == true {
                editingCentre = context.region.center
            } else if editingCentre != nil {
                editingCentre = nil
            }
        }
        // The living streaks over the wash: the reference apps' particle
        // animation, streaming with the field. See WashParticleLayer for
        // why this is an overlay and not map content.
        .overlay {
            if let washField {
                WashParticleLayer(field: washField, proxy: proxy)
            }
        }
        // The centre pin: pinned to the glass, never a map annotation. As an
        // annotation it would join MapKit's diffing — the strobe class of bug
        // the pins-as-state comment above exists to prevent — and its
        // coordinate would need chasing after every camera move. On the
        // glass, the map slides and the pin stays, which is the interaction.
        .overlay {
            // Hidden while a route is up — two readouts about two different
            // points is how a map lies.
            if !isSearching, routeMode == nil {
                CentrePinReadout(reading: scrubbedLocalWind,
                                 isUnavailable: mapScrub != nil && centreHourMissing) {
                    isShowingConditions = true
                }
            }
            // Route drawing aims with the glass, not the finger: the
            // crosshairs sit at the camera's centre, the map is dragged
            // underneath, and Add point drops the waypoint exactly there —
            // no stray touches on the canvas.
            if routeMode?.isEditing == true {
                RouteCrosshair()
            }
        }
        }
    }

    // MARK: - Route editing

    /// The Add point button's whole job: the waypoint lands where the
    /// crosshairs are — the settled camera centre — snapped like a tap
    /// used to be before the crosshairs replaced it.
    private func addDraftPointAtCentre() {
        guard case .editing(var draft, let routeId) = routeMode,
              let centre = editingCentre ?? visibleRegion?.center else { return }
        draft.append(snapped(Geo.Coordinate(latitude: centre.latitude,
                                            longitude: centre.longitude)))
        withAnimation(.snappy) { routeMode = .editing(draft: draft, routeId: routeId) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// A point becomes the spot it nearly is: within 800 m the waypoint
    /// lands exactly on the guide spot, so the route's ends carry real
    /// names into the save sheet.
    private func snapped(_ point: Geo.Coordinate) -> Geo.Coordinate {
        guard let spot = guide.nearestSpot(to: point) else { return point }
        let there = Geo.Coordinate(latitude: spot.latitude, longitude: spot.longitude)
        return Geo.distance(point, there) < 800 ? there : point
    }

    private func moveDraftPoint(_ index: Int, to point: Geo.Coordinate) {
        guard case .editing(var draft, let routeId) = routeMode,
              draft.indices.contains(index) else { return }
        draft[index] = point
        routeMode = .editing(draft: draft, routeId: routeId)
    }

    /// Dropping a handle near a spot snaps it, same as placing one.
    private func snapDraftPoint(_ index: Int) {
        guard case .editing(let draft, _) = routeMode,
              draft.indices.contains(index) else { return }
        moveDraftPoint(index, to: snapped(draft[index]))
    }

    private func insertDraftPoint(after leg: Int) {
        guard case .editing(var draft, let routeId) = routeMode,
              draft.indices.contains(leg), draft.indices.contains(leg + 1) else { return }
        let mid = legMidpoint(draft[leg], draft[leg + 1])
        draft.insert(Geo.Coordinate(latitude: mid.latitude, longitude: mid.longitude),
                     at: leg + 1)
        withAnimation(.snappy) { routeMode = .editing(draft: draft, routeId: routeId) }
    }

    private func legMidpoint(_ a: Geo.Coordinate, _ b: Geo.Coordinate) -> CLLocationCoordinate2D {
        let mid = Geo.destination(from: a, bearing: Geo.bearing(from: a, to: b),
                                  distance: Geo.distance(a, b) / 2)
        return CLLocationCoordinate2D(latitude: mid.latitude, longitude: mid.longitude)
    }

    /// When the route display must be rebuilt: a new grid, a new scrubbed
    /// hour (bucketed to five minutes for the "now" case), a new departure
    /// or speed. Everything else — panel drags above all — re-reads the
    /// same state.
    private var routeDisplayKey: String {
        guard case .inspecting(let route) = routeMode else { return "off" }
        let stamp = routeWeather.grid?.stamp.uuidString ?? "loading"
        // Fifteen seconds of scrubbed time per step, so the run slider's
        // dot glides rather than hopping five minutes at a time; a refresh
        // is a dozen samples of arithmetic, cheap enough to spend freely.
        let bucket = Int(routeWeather.instant.timeIntervalSince1970 / 15)
        return "\(route.id)|\(stamp)|\(bucket)|\(routeWeather.departure.timeIntervalSince1970)|\(routeWeather.speedKn)"
    }

    private func refreshRouteDisplay() {
        // The wash rides the same scrubbed instant as the dot: while a
        // route is open, the panel's slider is the whole map's clock.
        // scrub(to:) is a no-op until the thumb crosses an hour, so the
        // fifteen-second ticks this refresh runs on cost nothing.
        if case .inspecting = routeMode {
            windWash.scrub(to: routeWeather.instant)
        } else {
            windWash.scrub(to: nil)
        }
        guard case .inspecting(let route) = routeMode,
              let grid = routeWeather.grid, !grid.isEmpty else {
            routeDisplay = RouteMapDisplay()
            return
        }
        let instant = routeWeather.instant
        var display = RouteMapDisplay()

        let samples = grid.samples
        for index in 0..<max(0, samples.count - 1) {
            let midDistance = (samples[index].distance + samples[index + 1].distance) / 2
            let tint: Color
            if let wind = grid.wind(atDistance: midDistance, time: instant) {
                let off = Solar.runAlignment(bearing: samples[index].legBearing,
                                             windFrom: wind.directionDeg)
                tint = off <= 15 ? .green : off <= 30 ? .orange : .red
            } else {
                tint = .gray
            }
            display.segments.append(.init(id: index,
                                          a: clCoordinate(samples[index].coordinate),
                                          b: clCoordinate(samples[index + 1].coordinate),
                                          tint: tint))
        }
        for index in samples.indices where index.isMultiple(of: 2) && index > 0 && index < samples.count - 1 {
            if let wind = grid.wind(atDistance: samples[index].distance, time: instant) {
                display.arrows.append(.init(id: index,
                                            at: clCoordinate(samples[index].coordinate),
                                            deg: wind.directionDeg))
            }
        }
        display.marker = routeWeather.progress(for: route).position(at: instant)
            .map(clCoordinate)
        routeDisplay = display
    }

    private func clCoordinate(_ point: Geo.Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private func commitRoute(_ route: PlannedRoute) {
        if routeStore.routes.contains(where: { $0.id == route.id }) {
            routeStore.update(route)
        } else {
            routeStore.add(route)
        }
        inspectRoute(route)
    }

    /// What another tab asked this map to do, done exactly once.
    ///
    /// The doing waits a breath, whichever way it arrived: from `onAppear`
    /// the page is mid-first-layout and the map does not exist yet, and
    /// from the notification the tab switch lands in the same runloop turn
    /// — either way a camera position set that early is quietly dropped,
    /// which left the panel showing Oregon over a map still parked on
    /// Montauk. The seam is claimed *before* the wait, so a second ask
    /// cannot double-run.
    private func consumeRouteHandoff() {
        guard RouteHandoff.pending != nil || RouteHandoff.startPlanning else { return }
        let route = RouteHandoff.pending
        RouteHandoff.pending = nil
        RouteHandoff.startPlanning = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if let route {
                inspectRoute(route)
            } else {
                withAnimation(.snappy) {
                    routeMode = .editing(draft: [], routeId: nil)
                    panelDetent = .minimized
                }
            }
        }
    }

    private func inspectRoute(_ route: PlannedRoute) {
        withAnimation(.snappy) {
            routeMode = .inspecting(route)
            panelDetent = .half
            // The panel takes the lower half, so the camera sits south of
            // the route's centre — the line rides the visible upper part.
            // The shift is sized against what the screen will actually
            // show, not the route's own latitude span: a portrait screen
            // fitting an east–west run is zoomed out by the *longitude*
            // span, and a shift keyed to the (tiny) latitude delta left
            // the whole line parked under the panel.
            var region = boundingRegion(of: route.waypoints)
            region.span.latitudeDelta *= 1.6
            region.span.longitudeDelta *= 1.6
            let effectiveLatSpan = max(
                region.span.latitudeDelta,
                region.span.longitudeDelta * cos(region.center.latitude * .pi / 180) * 2.0
            )
            region.center.latitude -= effectiveLatSpan * 0.28
            camera = .region(region)
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
                            Text("Search spots, cams, places")
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
                    // The weather chip lived in this corner for a year; it
                    // moved to the bottom right to become the conditions
                    // door, and the clock took the empty seat.
                    timeButton
                    Spacer()
                    washToggle
                    squareButton("magnifyingglass", showsBadge: hasActiveFilter) {
                        withAnimation(.snappy) { controlsExpanded = true }
                    }
                    moreMenu
                    squareButton("location.fill") {
                        withAnimation(.snappy) { camera = .userLocation(fallback: .automatic) }
                    }
                }
                if isShowingTimeControl, routeMode == nil {
                    timeSlider
                }
                if let caption = washLayer.caption {
                    // The doctrine's line, map-sized: colours are a model,
                    // they are about now — or about a slider's hour, and
                    // then the clock says which — and the model has a name
                    // the rider can change by tapping it.
                    Button { isPickingModel = true } label: {
                        HStack(spacing: 4) {
                            Text("\(caption) · \(windWash.scrubLabel ?? "now")")
                            if washLayer == .wind {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(washLayer != .wind)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: The map's clock

    /// The clock in the corner. Lit while the map is answering for another
    /// hour, and wearing that hour, so a scrubbed map can never be mistaken
    /// for a live one at a glance.
    private var timeButton: some View {
        Button {
            withAnimation(.snappy) { isShowingTimeControl.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.body.weight(.semibold))
                if let label = scrubButtonLabel {
                    Text(label)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(mapScrub == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, mapScrub == nil ? 0 : 12)
            .frame(minWidth: 44, minHeight: 44)
            .background(mapScrub == nil ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.tint),
                        in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mapScrub == nil
                            ? "Show the time slider"
                            : "Showing \(scrubButtonLabel ?? ""). Show the time slider")
    }

    /// The slider itself: whole hours from six behind now to three days
    /// ahead — the window the hourly fetches actually buy. Every pin and
    /// both washes answer for the hour under the thumb.
    private var timeSlider: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text(scrubHeadline)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Spacer(minLength: 0)
                if mapScrub != nil {
                    Button("Now") { setScrub(hoursFromNow: 0) }
                        .font(.subheadline.weight(.semibold))
                }
                Button {
                    withAnimation(.snappy) { isShowingTimeControl = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide the time slider")
            }
            Slider(value: scrubHoursBinding,
                   in: Double(-SpotGuideStore.scrubPastHours)...Double(SpotGuideStore.scrubForecastHours),
                   step: 1)
            HStack {
                Text("−\(SpotGuideStore.scrubPastHours)h")
                Spacer()
                Text("now")
                    // Now sits where it falls on the track, not at the
                    // middle: six hours behind against seventy-two ahead.
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Text("+3d")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
    }

    /// Every pin's reading for the hour the map is holding. Built once per
    /// body pass for the map-content builder's sake — a lookup inside that
    /// builder registers no observation dependency — and it reads
    /// `windHours`, so a landing fetch redraws the pins.
    private var scrubbedReadings: [String: WindReading] {
        guard mapScrub != nil else { return guide.wind }
        var out: [String: WindReading] = [:]
        for spot in pins {
            if let reading = guide.reading(for: spot.spotId, at: mapScrub) {
                out[spot.spotId] = reading
            }
        }
        return out
    }

    /// The centre pill's reading for the hour the map holds. Nil while the
    /// series is still coming, which the pill already draws as "on its
    /// way" — better than a number belonging to a different hour.
    private var scrubbedLocalWind: WindReading? {
        guard let mapScrub, let here = localCoordinate else { return localWind }
        return guide.reading(for: SpotGuideStore.windKey(for: here), at: mapScrub)
    }

    /// Refetch the hourly series when the pinned set changes — never when
    /// the thumb moves, since one fetch already covers the whole window.
    /// The model belongs in here beside the coordinate: picking a new one
    /// forgets every cached wind, and a key that did not mention the model
    /// never changed — so the centre pill sat shimmering at a series that
    /// had been thrown away and would never be asked for again.
    private var scrubbedCentreKey: String {
        "\(mapScrub != nil)|\(forecastModelRaw)|\(localWeatherKey)"
    }

    private var scrubbedSpotsKey: String {
        "\(mapScrub != nil)|\(forecastModelRaw)|\(pins.map(\.spotId).joined(separator: ","))"
    }

    /// Whole hours off now — the slider's own units, rounded so the thumb
    /// lands on hours the model actually published.
    private var scrubHoursBinding: Binding<Double> {
        Binding(
            get: {
                guard let mapScrub else { return 0 }
                return (mapScrub.timeIntervalSinceNow / 3600).rounded()
            },
            set: { setScrub(hoursFromNow: Int($0.rounded())) }
        )
    }

    private func setScrub(hoursFromNow hours: Int) {
        // Zero means now, and now means nil: the live `current=` reading is
        // a better answer for this hour than the hourly forecast of it.
        let instant: Date? = hours == 0
            ? nil
            : Calendar.current.date(bySetting: .minute, value: 0,
                                    of: Date().addingTimeInterval(Double(hours) * 3600))
                ?? Date().addingTimeInterval(Double(hours) * 3600)
        mapScrub = instant
        windWash.scrub(to: instant)
    }

    /// The button's own label: nothing at now, else the hour it is holding.
    private var scrubButtonLabel: String? {
        guard let mapScrub else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(mapScrub) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: mapScrub)
    }

    /// The slider's headline: the full day and hour, or "Now".
    private var scrubHeadline: String {
        guard let mapScrub else { return "Now" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(mapScrub)
            ? "'Today' HH:mm" : "EEE d MMM · HH:mm"
        return formatter.string(from: mapScrub)
    }

    /// The layers menu: the colour wash (one at a time) and the hardware
    /// pins (any of them). Lit when anything is on, so a dressed map never
    /// has to be explained by memory; a menu rather than a cycle button,
    /// because "which one is this" should never take three taps to answer.
    private var washToggle: some View {
        Menu {
            Picker("Map wash", selection: Binding(
                get: { washLayerRaw },
                set: { raw in
                    washLayerRaw = raw
                    let layer = WashLayer(rawValue: raw) ?? .off
                    if layer == .off {
                        windWash.clear()
                    } else if let region = visibleRegion {
                        windWash.viewSettled(on: region, layer: layer)
                    }
                }
            )) {
                Label("No wash", systemImage: "square.slash").tag(WashLayer.off.rawValue)
                Label("Wind", systemImage: "wind").tag(WashLayer.wind.rawValue)
                Label("Current", systemImage: "water.waves").tag(WashLayer.currents.rawValue)
            }
            Section("On the map") {
                Toggle(isOn: $showSpots) {
                    Label("Spots", systemImage: "mappin.and.ellipse")
                }
                Toggle(isOn: $showWindStations) {
                    Label("Wind stations", systemImage: "gauge.with.needle")
                }
                Toggle(isOn: $showCameras) {
                    Label("Cameras", systemImage: "video")
                }
                Toggle(isOn: $showBuoys) {
                    Label("Buoys", systemImage: "dot.radiowaves.up.forward")
                }
            }
        } label: {
            // Hidden spots are as much a dressed map as a wash — the lit
            // button is the reminder that the map is not in its default suit.
            let isDressed = washLayer != .off || showWindStations || showCameras || showBuoys
                || !showSpots
            Image(systemName: "square.3.layers.3d")
                .font(.body.weight(.semibold))
                .foregroundStyle(isDressed ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 44, height: 44)
                .background(isDressed ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial),
                            in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map layers")
    }

    /// The conditions door, wearing the weather.
    ///
    /// The centre pin's pill owns the wind; this button carries the other
    /// half — sky and temperature — and names the action: one tap into
    /// every station, cam and forecast around the pin. It reads wherever
    /// the pin points, so browsing Maui from the sofa shows Maui's
    /// weather rather than the weather outside. Bottom-right on purpose —
    /// the one door the thumb should never have to travel for.
    private var conditionsCorner: some View {
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
                // While the map is holding another hour, this corner is the
                // one thing still speaking for now — the sky and the
                // temperature are observed-ish current conditions, not a
                // scrubbed forecast — so it says so. The flow map's own
                // marker, borrowed: orange, small, unmissable.
                if mapScrub != nil {
                    Text("now")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                }
                // The expand glyph instead of a word: the sky and the
                // number are the invitation, this says *more lives here*
                // without spelling it.
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mapScrub == nil
                            ? "Weather at the pin, and nearby stations"
                            : "Weather at the pin right now, and nearby stations")
    }

    /// The thumb corners over the map: on the right, the conditions door;
    /// on the left, the guide page of whatever spot the map is parked on —
    /// named, so "full detail" says full detail *of what* — and nothing at
    /// all when it is parked on open water. Shown only while the panel
    /// sits low; a raised panel owns the screen.
    private var bottomCorners: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if let spot = centredSpot {
                Button { path.append(.spot(spot)) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "book.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text(spot.name)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .frame(maxWidth: 230)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open the full guide for \(spot.name)")
            }
            Spacer(minLength: 8)
            conditionsCorner
        }
    }

    /// The guide spot the map is parked on, if any — within the same 800 m
    /// the route editor snaps by. Derived from the settled centre rather
    /// than remembered from a tap, so it works however the rider got
    /// there: a row, a search pick, or panning by hand.
    private var centredSpot: GuideSpot? {
        guard let centre = visibleRegion?.center else { return nil }
        let here = Geo.Coordinate(latitude: centre.latitude, longitude: centre.longitude)
        guard let spot = guide.nearestSpot(to: here),
              Geo.distance(here, Geo.Coordinate(latitude: spot.latitude,
                                                longitude: spot.longitude)) < 800
        else { return nil }
        return spot
    }

    /// A row is a camera move, never a push — the place-search grammar,
    /// extended to the guide's own rows. The map parks on the spot, the
    /// centre pin samples it, and the bottom corners offer the depth.
    private func focus(on coordinate: CLLocationCoordinate2D) {
        withAnimation(.snappy) {
            panelDetent = .peek
            camera = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
        }
    }

    /// SpotsSheet's own height formula, mirrored so the corners sit just
    /// above the panel at either low detent.
    private func panelHeight(in size: CGSize, detent: SheetDetent) -> CGFloat {
        max(tabBarHeight + 84, size.height * detent.fraction)
    }

    /// Where "here" is: the centre pin — whatever the map is looking at —
    /// with the fix standing in only until the first camera change lands.
    private var localCoordinate: Geo.Coordinate? {
        mapCentre ?? recorder.location.lastCoordinate
    }

    /// "Here" while the pin stands about where the rider does; "there" once
    /// the map has been dragged somewhere else.
    private var conditionsTitle: String {
        guard let fix = recorder.location.lastCoordinate, let centre = mapCentre,
              Geo.distance(fix, centre) < 2000 else { return "Conditions there" }
        return "Conditions here"
    }

    /// Rounded to about a kilometre so panning the map does not refetch on
    /// every frame — the weather does not change across a city block.
    private var localWeatherKey: String {
        guard let here = localCoordinate else { return "" }
        return String(format: "%.2f,%.2f", here.latitude, here.longitude)
    }

    /// Coarser than the weather key — the pins reach tens of kilometres
    /// out, so a refetch every ~10 km of panning keeps up with the view.
    private var hardwareLayersKey: String {
        guard showWindStations || showCameras || showBuoys,
              let here = localCoordinate else { return "" }
        return "\(showWindStations)|\(showCameras)|\(showBuoys)|"
            + String(format: "%.1f,%.1f", here.latitude, here.longitude)
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
                Label("Add a public spot here", systemImage: "plus.circle")
            }
            Button {
                pickingNewSpot = true
            } label: {
                Label("Pick the spot on the map", systemImage: "mappin.and.ellipse")
            }
            Divider()
            // The other kind of spot: no submission, no review — saved on the
            // phone, listed with the favorites. "Here" means what the centre
            // pin means: the point under the pin.
            Button {
                if let here = localCoordinate {
                    addingPrivateSpot = NewPrivateSpotRequest(coordinate: here)
                }
            } label: {
                Label("Add a private spot here", systemImage: "star.circle")
            }
            Divider()
            // Point-to-point planning: draw the run, save it, read the
            // wind along it. Starting at the pin seeds the first waypoint
            // with the same "here" everything else on this screen means.
            Button {
                withAnimation(.snappy) {
                    routeMode = .editing(draft: [], routeId: nil)
                    panelDetent = .minimized
                }
            } label: {
                Label("Plan a route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            Button {
                if let here = localCoordinate {
                    withAnimation(.snappy) {
                        routeMode = .editing(draft: [snapped(here)], routeId: nil)
                        panelDetent = .minimized
                    }
                }
            } label: {
                Label("Start a route at the pin", systemImage: "mappin.and.ellipse")
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

    /// The panel is being rebuilt from nothing, one measured step at a time,
    /// after three fixes to the old one each moved the flicker without
    /// killing it. Each phase adds exactly one moving part and goes to a
    /// real phone before the next. `SpotsSheet` is the rebuild.
    private func panel(in size: CGSize) -> some View {
        SpotsSheet(size: size, detent: $panelDetent) {
            if case .inspecting(let route) = routeMode {
                HStack(spacing: 10) {
                    Text(route.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.snappy) {
                            routeMode = .editing(draft: route.waypoints, routeId: route.id)
                            panelDetent = .minimized
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(Color(.systemGray5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit the route's line")
                    Button {
                        withAnimation(.snappy) {
                            routeMode = nil
                            panelDetent = .peek
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(Color(.systemGray5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close route")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            } else {
                Picker("Mode", selection: $panelMode) {
                    ForEach(PanelMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        } content: {
            if case .inspecting(let route) = routeMode {
                RoutePanel(route: route, weather: routeWeather)
            } else if guide.spots.isEmpty {
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
                switch panelMode {
                case .nearby: nearbyList
                case .favorites: favoritesList
                case .destinations: destinationsList
                }
            }
        }
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
            // A row is a camera move: the map parks on the spot, and the
            // bottom corners offer conditions and the guide page. Pins
            // still push directly — tapping the map means "open that";
            // tapping a row means "show me where".
            Button { focus(on: spot.coordinate) } label: {
                SpotRow(spot: spot, reading: guide.reading(for: spot.spotId, at: mapScrub),
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
        if favorites.isEmpty && guide.privateSpots.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "star")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No favorites yet")
                    .font(.subheadline.weight(.medium))
                Text("Star a spot and it lives here with live wind, so \"is it on?\" is one glance. Private spots you save from the map land here too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)
        } else {
            // One door to arranging the whole tab: reorder, delete, all
            // three sections in one editable list.
            HStack {
                Spacer()
                Button("Edit") { isEditingFavorites = true }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
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
            // One list, no type headers — a route sits wherever the rider
            // dragged it between two spots. The kind shows in the glyph,
            // and PRIVATE in the badge, not in a section.
            ForEach(guide.favoriteItems(routes: routeStore.routes)) { item in
                switch item {
                case .spot(let spot):
                    // A camera move, like every row — the corners take it
                    // from there.
                    Button { focus(on: spot.coordinate) } label: {
                        SavedLineRow(icon: "star.fill", name: spot.name,
                                     reading: guide.reading(for: spot.spotId, at: mapScrub))
                    }
                    .buttonStyle(.plain)
                case .route(let route):
                    Button { inspectRoute(route) } label: {
                        SavedLineRow(icon: "point.topleft.down.to.point.bottomright.curvepath",
                                     name: route.name,
                                     detail: Format.distance(route.path.totalDistance,
                                                             unit: settings.units.distance))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameRouteText = route.name
                            renamingRoute = route
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            withAnimation(.snappy) {
                                routeMode = .editing(draft: route.waypoints, routeId: route.id)
                                panelDetent = .minimized
                                camera = .region(boundingRegion(of: route.waypoints))
                            }
                        } label: {
                            Label("Edit the line", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                        Button(role: .destructive) {
                            routeStore.remove(route.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                case .privateSpot(let spot):
                    // The same camera move; the spot's own star pin sits
                    // under the centre pin then, and tapping it opens the
                    // facing-aware conditions sheet. The corner label is
                    // reserved for guide spots.
                    Button { focus(on: spot.clCoordinate) } label: {
                        SavedLineRow(icon: "star.fill", name: spot.name,
                                     reading: privateWind[spot.id], isPrivate: true)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameText = spot.name
                            renamingSpot = spot
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            editingFacingSpot = spot
                        } label: {
                            Label("Beach facing…", systemImage: "location.north.line")
                        }
                        Button(role: .destructive) {
                            guide.removePrivateSpot(spot.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                Divider().padding(.leading, 54)
            }
        }
    }

    private func distanceFrom(_ coordinate: Geo.Coordinate) -> Double? {
        guard let here = recorder.location.lastCoordinate else { return nil }
        return Geo.distance(here, coordinate)
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

// MARK: - Pieces

/// The point a rider held a finger on.
///
/// Deliberately unlike `WindPin`: those are places in the guide, this is a
/// scratch mark that goes away when they are done with it.
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

/// A hardware pin — a wind meter, a cam, a buoy. Smaller and rounder than
/// the spot pins, because the stations dress the map; they never compete
/// with the spots standing on it.
struct HardwarePin: View {
    /// The guide resource's kind, or nil for an NDBC buoy.
    let kind: SpotGuideStore.SpotLink.Kind?

    private var symbol: String { kind?.symbol ?? "dot.radiowaves.up.forward" }
    private var tint: Color {
        switch kind {
        case .wind: .teal
        case .camera: .indigo
        default: .orange
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(tint, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
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

/// One saved thing, one line: a glyph, the name, and — when it has wind —
/// the arrow and the number. The tab's whole promise is that glance, so
/// the row carries nothing else. The arrow points downwind, the same
/// streamline convention as every arrow on the map.
struct SavedLineRow: View {
    let icon: String
    let name: String
    var reading: WindReading? = nil
    /// Trailing text for rows with no wind of their own (a route's length).
    var detail: String? = nil
    var isPrivate: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(name)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if isPrivate {
                // The BEST chips' navy-on-wash, and never the thing that
                // truncates — the name gives way, the badge does not.
                Text("PRIVATE")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.harbourNavy)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.tintWash, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if let reading {
                HStack(spacing: 5) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 11, weight: .heavy))
                        .rotationEffect(.degrees(reading.directionDeg + 180))
                    Text("\(Int(reading.speedKn.rounded()))")
                        .font(.callout.weight(.bold))
                        .monospacedDigit()
                    + Text(" kn")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(reading.isFiring ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            } else if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// The whole favorites tab as one editable list: drag to reorder — across
/// kinds, a route lands happily between two spots — and swipe (or tap the
/// minus) to delete. Edit mode is on from the first frame; the sheet *is*
/// the edit button's promise.
struct FavoritesEditor: View {
    @Environment(SpotGuideStore.self) private var guide
    @Environment(RouteStore.self) private var routeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(guide.favoriteItems(routes: routeStore.routes)) { item in
                    editorRow(for: item)
                }
                .onMove {
                    guide.moveFavoriteItems(routes: routeStore.routes,
                                            fromOffsets: $0, toOffset: $1)
                }
                .onDelete { offsets in
                    // Deletion goes home to whichever store owns the row.
                    let items = guide.favoriteItems(routes: routeStore.routes)
                    for item in offsets.compactMap({ items[safe: $0] }) {
                        switch item {
                        case .spot(let spot): guide.removeFavorite(spot.spotId)
                        case .route(let route): routeStore.remove(route.id)
                        case .privateSpot(let spot): guide.removePrivateSpot(spot.id)
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func editorRow(for item: FavoriteItem) -> some View {
        let (icon, name, isPrivate): (String, String, Bool) = switch item {
        case .spot(let spot): ("star.fill", spot.name, false)
        case .route(let route): ("point.topleft.down.to.point.bottomright.curvepath", route.name, false)
        case .privateSpot(let spot): ("star.fill", spot.name, true)
        }
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if isPrivate {
                Text("PRIVATE")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.harbourNavy)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.tintWash, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
            }
        }
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
///
/// Four sections of result, in rank order: destinations, curated spots, the
/// guide's webcams, and — from Apple's geocoder — map areas, so a bay the
/// guide has never heard of is still reachable. A cam plays right here over
/// the search; a map area never enters the navigation path — it comes back
/// through `onPlace` and becomes a camera move.
struct SpotSearchOverlay: View {

    @Binding var isPresented: Bool
    /// What the map is looking at, handed to the place completer as its
    /// bias — without it Apple leans hard toward the US.
    var biasRegion: MKCoordinateRegion?
    let onOpen: (SpotsTabView.SpotsRoute) -> Void
    let onPlace: (PlaceResult) -> Void

    @Environment(SpotGuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var placeSearch = PlaceSearchModel()
    /// The guide's meters, cams and surf pages around the map, fetched the
    /// first time a query is worth answering and held for the overlay's
    /// life — the store caches per country, so this is one query ever.
    @State private var resources: [SpotGuideStore.GuideResource] = []
    /// A cam tapped in the results, playing over the search.
    @State private var watchingCam: SpotGuideStore.GuideResource?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search spots, cams, places", text: $query)
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
        .onAppear {
            focused = true
            placeSearch.bias(to: biasRegion)
        }
        .onChange(of: query) { _, text in placeSearch.query = text }
        .task(id: query.count >= 2) {
            guard query.count >= 2, resources.isEmpty,
                  let centre = biasRegion?.center else { return }
            // An unstructured Task, deliberately: a keystroke that drops the
            // query below two characters cancels this .task, and a cancelled
            // fetch would let the store cache a half-empty answer for the
            // whole country. The fetch runs to the end either way.
            resources = await Task {
                await guide.nearbyResources(
                    near: Geo.Coordinate(latitude: centre.latitude,
                                         longitude: centre.longitude),
                    radius: 750_000
                )
            }.value
        }
        .fullScreenCover(item: $watchingCam) { cam in
            CamViewerSheet(name: cam.displayName, url: cam.url)
        }
    }

    /// Prefix hits first — someone typing "Vie" wants Viento, not every
    /// spot whose description mentions the Soviets — then the substring
    /// catches, alphabetically.
    private var matches: [GuideSpot] {
        let needle = query.lowercased()
        return guide.spots.filter {
            $0.name.lowercased().contains(needle) ||
            $0.where_.lowercased().contains(needle)
        }
        .sorted { a, b in
            let ap = a.name.lowercased().hasPrefix(needle)
            let bp = b.name.lowercased().hasPrefix(needle)
            if ap != bp { return ap }
            return a.name < b.name
        }
    }

    private var regionMatches: [GuideRegion] {
        let needle = query.lowercased()
        return (guide.destinations + guide.countries).filter {
            $0.name.lowercased().contains(needle)
        }
    }

    /// The guide's webcams whose name says the query — nearest first, which
    /// the store's ranking already did. Two characters before anything
    /// matches, same bar as the geocoder.
    private var cameraMatches: [SpotGuideStore.GuideResource] {
        let needle = query.lowercased()
        guard needle.count >= 2 else { return [] }
        return resources.filter {
            $0.kind == .camera &&
            ($0.displayName.lowercased().contains(needle) ||
             $0.name.lowercased().contains(needle))
        }
    }

    /// Surfline's answer shape, and the right one: not one ranked pile but a
    /// section per kind of thing — a spot is a page, a cam is a picture, a
    /// map area is a camera move — so the rider picks the kind first.
    @ViewBuilder
    private var results: some View {
        if !regionMatches.isEmpty {
            section("Destinations") {
                ForEach(regionMatches.prefix(3)) { regionRow($0) }
            }
        }
        if !matches.isEmpty {
            section("Spots") {
                ForEach(matches.prefix(12)) { spotRow($0) }
            }
        }
        if !cameraMatches.isEmpty {
            section("Cameras") {
                ForEach(cameraMatches.prefix(8)) { camRow($0) }
            }
        }
        if !placeSearch.completions.isEmpty {
            section("Map area") {
                ForEach(placeSearch.completions.prefix(6)) { placeRow($0) }
            }
        }
        if matches.isEmpty && regionMatches.isEmpty && cameraMatches.isEmpty
            && placeSearch.completions.isEmpty {
            Text("Nothing matches \"\(query)\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    /// Rows sit tight under their header; the outer stack's spacing
    /// separates only the sections.
    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(title)
            rows()
        }
    }

    private func regionRow(_ region: GuideRegion) -> some View {
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

    private func spotRow(_ spot: GuideSpot) -> some View {
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

    /// A cam plays where it was found: full screen over the search, and
    /// closing it lands back on these results — no map move, no panel.
    private func camRow(_ cam: SpotGuideStore.GuideResource) -> some View {
        Button { watchingCam = cam } label: {
            HStack(spacing: 12) {
                Image(systemName: "video.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .frame(width: 32, height: 32)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(cam.displayName)
                        .font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(Format.distance(cam.metres, unit: settings.units.distance)) away\(cam.providerLabel.isEmpty ? "" : " · \(cam.providerLabel)")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.rectangle").font(.subheadline).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func placeRow(_ completion: PlaceSearchModel.Completion) -> some View {
        Button {
            Task {
                if let place = await placeSearch.resolve(completion) {
                    onPlace(place)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(completion.title)
                        .font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "location").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
