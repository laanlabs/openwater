import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The screen the app opens on: your water, with the wind painted on it.
///
/// This is the screen the big display earns, and it is the phone's Spots map
/// rather than a television's summary of it — the same `WindWashModel`, the
/// same 7×9 field bilinearly upsampled into `MapPolygon`s, the same palette,
/// the same comets streaming over it, and the same muted basemap underneath so
/// the chart's greens stop arguing with the field's colours. What differs is
/// the size and the input: three metres away, and four arrow keys.
///
/// **Where it opens.** An Apple TV has no receiver and cannot be carried
/// anywhere, so "here" is either the coarse network fix tvOS will hand over or
/// a place somebody typed once — see `TVLocation`. The map does not guess. A
/// box that cannot say where it is gets asked, rather than being dropped on a
/// coast nobody in the room sails.
///
/// **Driving it.** The remote has four directions, a Select, a Play/Pause and
/// a Menu, and the tab bar above already owns "up". So the map is not
/// permanently listening: focus sits on the control bar, and pressing *Pan &
/// zoom* hands the D-pad to the map until Menu gives it back. Inside that, the
/// four keys pan, Select zooms in, Play/Pause zooms out, and a legend on the
/// glass says so — because there is no other way for a television to explain
/// itself.
struct WindMapScreen: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(TVLocation.self) private var location
    @Environment(\.displayScale) private var displayScale

    /// Whether this tab is the one on screen. The field is only worth
    /// carrying while somebody is looking at it — the phone's rule, and it
    /// matters more here, because the comets run at display rate and the tab
    /// this app opens on is now this one.
    let isActive: Bool

    @State private var wash = WindWashModel()

    /// The wash, remembered. On by default: a wind map with the wind turned
    /// off is a chart, and this tab is not a chart.
    @AppStorage("tv.map.wind") private var showsWind = true

    /// Whether the meters wear their names. Off by default, and that is the
    /// right default: the numbers are the answer and the names are a lookup.
    /// Where instruments cluster — three airports around East Hampton — the
    /// name chips are wider than the capsules they belong to and write over
    /// each other, so the map reads worse for carrying them.
    @AppStorage("tv.map.meterNames") private var showsMeterNames = false

    /// Read here only so the map can notice it changing. The conditions
    /// screen owns the picker; every cached number on this one came from
    /// whichever model was selected when it was fetched.
    @AppStorage("spots.forecastModel") private var modelRaw = ForecastModel.automatic.rawValue

    @State private var camera: MapCameraPosition = .automatic
    /// What the map is actually showing, from its own settle callback — and
    /// written optimistically by the pan and zoom below so a second key press
    /// compounds instead of waiting a frame for the truth.
    @State private var visible: MKCoordinateRegion?
    @State private var mapWidth: CGFloat = 1920

    @State private var offsetHours = 0
    @State private var isDriving = false
    @State private var isSearching = false
    @State private var isShowingConditions = false
    @State private var isShowingOptions = false
    /// Set when the pin was just dropped from this map, so the camera move
    /// that follows does not also re-frame the map — see `placeKey`.
    @State private var justPinned = false

    /// The wind and the weather under the crosshairs. Held here rather than
    /// read from the store so the old point's answer cannot flash on the new
    /// one while a refetch is in the air.
    @State private var centreWind: WindReading?
    @State private var centreWeather: SpotWeather?
    /// Whether that fetch has finished. Kept apart from the readings because
    /// "on its way" and "the model has nothing here" are two different
    /// answers, and only one of them is a pulse.
    @State private var centreLoaded = false

    /// The in-flight centre request, so a settle can retire the one before it.
    @State private var centreTask: Task<Void, Never>?

    /// The anemometers around the view, and what they last said.
    ///
    /// These replaced the guide's own spots on this map. A starred launch
    /// wearing a *model* number is the same forecast the wash under it is
    /// already drawing, said twice — and the second saying looks like a
    /// measurement, which is the one thing `WIND_MAP_RULES` is most insistent
    /// it must not. A meter is the other half of the picture: what the air is
    /// actually doing, against what the model thinks it is doing.
    @State private var meters: [FreeStation] = []
    @State private var readings: [String: StationObservation] = [:]

    @FocusState private var focus: Control?

    /// The control bar as a focus scope, so "which button does Down land on"
    /// has an answer that is not geometry. See `controls`.
    @Namespace private var bar
    /// The options panel is its own focus scope: it has its own idea of which
    /// row "down" should land on, and sharing the bar's would make the two
    /// argue about it.
    @Namespace private var panel

    /// Everything on this screen the remote can land on. The map is in the
    /// list because driving it is a focus state like any other — that is what
    /// keeps the D-pad out of the tab bar's hands while a rider is panning.
    private enum Control: Hashable {
        case map, hourBack, hourForward, conditions, move, options, optWind, optNames, setPin, reset, locate, place
    }

    /// How far the clock will travel. The field carries seventy-two hours,
    /// but a television is not a planning tool — two days is the horizon
    /// somebody standing up decides a weekend on.
    private static let horizon = 48

    /// What the map opens at: about ninety kilometres across, which is one
    /// coastline's worth of afternoon rather than one launch.
    private static let openingSpan = 0.8
    /// How far in and out the remote may go. The floor is a harbour mouth;
    /// the ceiling is a continent, past which the wash is fetching a grid
    /// coarser than the weather it describes.
    private static let tightestSpan = 0.02
    private static let widestSpan = 30.0

    /// How far one press moves the map, as a fraction of what is on screen.
    ///
    /// A twelfth. It began at a third, which on a television is not panning
    /// but jumping: one press and the coast you were reading is off the edge,
    /// and finding it again takes two presses back and a guess. Small enough
    /// that a held-down key slides rather than teleports, and that four or
    /// five presses cross a bay — which is the gesture this is standing in
    /// for.
    private static let panStep = 0.08

    private var layer: WashLayer { showsWind ? .wind : .off }

    private var scrubbed: Date? {
        guard offsetHours != 0 else { return nil }
        return Calendar.current.date(byAdding: .hour, value: offsetHours, to: .now)
    }

    var body: some View {
        Group {
            if location.here != nil {
                mapScreen
            } else {
                NoPlaceYet(isTrying: !location.needsAPlace) { isSearching = true }
            }
        }
        .fullScreenCover(isPresented: $isSearching) {
            PlaceSearchScreen(near: visible)
        }
        .fullScreenCover(isPresented: $isShowingConditions) {
            if let here = centreCoordinate {
                ConditionsScreen(here: here, placeName: location.name)
            }
        }
        // Only when there is nothing to show. A rider who typed a place is
        // not asking to be prompted about Location Services every launch.
        .onAppear { if !location.isChosen { location.locate() } }
        // The capture seam; see `TVScreenshotRoute`. Held until the centre has
        // real numbers, so the report is photographed with a forecast in it
        // rather than mid-pulse.
        .task(id: centreLoaded) {
            guard centreLoaded,
                  let route = TVScreenshotRoute.requested,
                  route == .conditions || route == .windOutlook else { return }
            isShowingConditions = true
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active { wash.wake() } else { wash.sleep() }
        }
        // A place arriving — the first fix, or one typed in — is the only
        // thing that moves the camera without somebody pressing a key.
        .onChange(of: placeKey, initial: true) { _, _ in
            // A pin dropped from this map is already in frame; re-centring
            // would snap the zoom back and throw away the view the rider
            // just chose. Anything else — a fix arriving, a typed place — is
            // somewhere new and does move the camera.
            if justPinned { justPinned = false } else { recentre() }
        }
    }

    // MARK: - The screen

    private var mapScreen: some View {
        ZStack(alignment: .bottom) {
            // Only the map ignores the safe area. The bar below it must not:
            // a television overscans, and chrome pinned to the panel edge is
            // chrome half off the glass in somebody's living room.
            mapWithWash
                // The crosshairs ride *inside* the map's own frame, and are
                // expanded with it. Left on the ZStack they centred on the
                // safe-area rect instead — which a tab bar makes taller at
                // the top than the bottom — and the dot sat some forty points
                // below the coordinate it claims to be reading.
                .overlay(alignment: .center) {
                    CentreReadout(wind: scrubbedCentreWind,
                                  weather: centreWeather,
                                  isWaiting: isWaitingOnCentre)
                }
                .ignoresSafeArea()
            if isDriving {
                drivingSurface
                DrivingLegend()
                    .padding(.bottom, 60)
            } else {
                VStack(spacing: 18) {
                    if isShowingOptions { optionsPanel }
                    controls
                }
                .padding(.bottom, 50)
            }
        }
        .overlay(alignment: .topTrailing) { statusChip }
        // The tab bar goes away while the map has the D-pad.
        //
        // `onMoveCommand` hears an Up press, but hearing it does not stop
        // tvOS acting on it: the tab bar is a focusable thing directly above,
        // so Up moved focus there instead of panning north — reported exactly
        // that way. Nothing can out-argue the focus engine about a target
        // that exists, so while driving the target does not exist.
        .toolbar(isDriving ? .hidden : .visible, for: .tabBar)
        .task(id: centreKey) { await refreshCentre() }
        // The instruments around the view. One list request and a reading
        // each, on every settle — the readings are cached per station by
        // their own clients, so a pan inside the same patch costs little.
        .task(id: pinKey) {
            await refreshMeters()
        }
        // The centre's hourly series, fetched only once the clock leaves now:
        // a rider who never scrubs never pays for this. The meters are not
        // scrubbed at all — an anemometer has no future, and drawing one at
        // tomorrow's hour would be the model wearing an instrument's clothes.
        .task(id: scrubKey) {
            guard offsetHours != 0, let here = centreCoordinate else { return }
            await guide.refreshWindHours(at: here)
        }
        .task(id: offsetHours) {
            wash.scrub(to: scrubbed)
        }
        // Every cached number came from the old model. The pins and the
        // centre re-ask on their own keys, which carry the model; the wash
        // holds its own day and has to be told.
        .onChange(of: modelRaw) { _, _ in
            guide.forgetWind()
            guard layer != .off, let visible else { return }
            wash.clear()
            wash.viewSettled(on: visible, layer: layer,
                             widthPoints: mapWidth, displayScale: displayScale)
        }
        .onChange(of: showsWind) { _, _ in
            guard let visible else { return }
            if layer == .off {
                wash.clear()
            } else {
                wash.viewSettled(on: visible, layer: layer,
                                 widthPoints: mapWidth, displayScale: displayScale)
            }
        }
    }

    /// The centre moved far enough to be a different place: re-ask for its
    /// wind and its weather.
    /// Re-ask for the point under the crosshairs.
    ///
    /// The answer is checked against the crosshairs *again* on the way in.
    /// A map opens on MapKit's own default rectangle — the middle of the
    /// United States — and moves to the coast a moment later, so the first
    /// request is always for a field in Kansas and it is always still in the
    /// air when the real place arrives. Its answer used to land anyway, and
    /// the badge sat there reading 99°F and sunny over Block Island Sound
    /// while the report one press away said 70°F and cloud. Both were true;
    /// they were about different places.
    ///
    /// The freshness check is the fix rather than the trigger, because the
    /// trigger is the part that cannot be relied on: `.task(id:)` was
    /// observed on the device *not* restarting when the key changed under it
    /// — the map settled on Montauk, the key changed, and the Kansas task ran
    /// on to completion. So the settle now asks directly, and anything that
    /// comes back for somewhere the map has left is dropped.
    private func refreshCentre() async {
        guard let here = centreCoordinate else { return }
        centreLoaded = false
        centreWind = nil
        centreWeather = nil
        async let air = guide.weather(at: here)
        async let blowing = guide.currentWind(at: here)
        let (weather, wind) = await (air, blowing)
        guard isStillCentre(here) else { return }
        centreWeather = weather
        centreWind = wind
        centreLoaded = true
    }

    /// Whether the map is still looking at the point a request was made for,
    /// to the resolution `centreKey` asks questions at.
    private func isStillCentre(_ asked: Geo.Coordinate) -> Bool {
        guard let now = centreCoordinate else { return false }
        return abs(now.latitude - asked.latitude) < 0.01
            && abs(now.longitude - asked.longitude) < 0.01
    }

    private var mapWithWash: some View {
        // Read during body evaluation, not inside the content builder. A read
        // that happens inside `Map`'s builder registers no observation
        // dependency, so the pins would draw once — nameless and numberless —
        // and never update when the readings landed. Same for the wash's own
        // cells. The phone's map hoists all three for exactly this reason.
        let cells = layer == .off ? [] : wash.cells
        let field = layer == .off ? nil : wash.field
        return MapReader { proxy in
            Map(position: $camera, interactionModes: []) {
                // The wash goes first: map content draws in order, and the
                // field belongs under every pin.
                ForEach(cells) { cell in
                    MapPolygon(coordinates: cell.coordinates)
                        .foregroundStyle(cell.color)
                }
                ForEach(reporting, id: \.station.id) { pin in
                    Annotation(pin.station.name, coordinate: pin.station.clCoordinate) {
                        MeterBadge(name: pin.station.name,
                                   observation: pin.observation,
                                   showsName: showsMeterNames)
                    }
                    .annotationTitles(.hidden)
                }
            }
            // While the wash is up the basemap goes muted — Apple's own grey
            // voice — so the chart keeps the shapes and the wash owns the
            // palette. It comes back the moment the wind is switched off.
            // Never focusable. With no interaction modes there is nothing
            // to focus it *for*, and a map that quietly takes the focus is
            // indistinguishable from focus disappearing: nothing highlights,
            // and the next press goes nowhere.
            .focusable(false)
            .mapStyle(layer == .off
                      ? .standard(elevation: .flat, pointsOfInterest: .excludingAll)
                      : .standard(elevation: .flat, emphasis: .muted,
                                  pointsOfInterest: .excludingAll))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                mapWidth = width
                if let visible {
                    wash.mapMeasured(widthPoints: width, displayScale: displayScale,
                                     visible: visible)
                }
            }
            .onMapCameraChange(frequency: .continuous) { _ in
                // The wash holds its repaint while this is true. Cheap and
                // idempotent, so it is safe on every frame of a pan.
                wash.cameraMoving()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                let before = centreKey
                visible = context.region
                // Carried across for the Radar tab, which opens on whatever
                // this map is showing rather than making a rider find the
                // same coast twice.
                location.mapRegion = context.region
                // `viewSettled` gives the camera's hold back itself, after it
                // has worked out whether the drawn window moved.
                wash.viewSettled(on: context.region, layer: layer,
                                 widthPoints: mapWidth, displayScale: displayScale)
                // Asked here rather than left to `.task(id: centreKey)`,
                // which was observed not to restart when the key changed —
                // see `refreshCentre`. One in flight at a time; a settle
                // supersedes whatever the last one was asking about.
                if centreKey != before {
                    centreTask?.cancel()
                    centreTask = Task { await refreshCentre() }
                }
            }
            // The living streaks over the wash: the phone's particle
            // animation, streaming with the field. An overlay rather than map
            // content — it wants the projection, not the diffing.
            .overlay {
                if let field {
                    WashParticleLayer(field: field, proxy: proxy)
                }
            }
        }
    }

    // MARK: - Driving

    /// The map's turn with the remote.
    ///
    /// A focusable button covering the glass, because a focusable *button* is
    /// the only thing on tvOS that hears Select. Its four directions are
    /// intercepted by `onMoveCommand` rather than moving focus, which is what
    /// keeps a pan upward from landing in the tab bar, and Menu is the way
    /// out — the gesture a television viewer already knows.
    private var drivingSurface: some View {
        Button { zoom(by: 0.6) } label: {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
        }
        // `.plain` is not plain enough. On tvOS every button style draws a
        // focused appearance, and a *full-screen* button drawing one is a
        // white panel over the entire map — which is exactly how this was
        // reported. The style below returns the label and nothing else, and
        // `focusEffectDisabled` stops the system adding its own halo on top.
        // The legend is the only thing that should say this surface has the
        // remote.
        .buttonStyle(NoStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .map)
        // Both, and deliberately. `startDriving` sets the focus before this
        // view exists, which SwiftUI is entitled to drop; `defaultFocus` says
        // the same thing again at the moment it appears. Landing anywhere but
        // here means the first press of a direction goes to the tab bar,
        // which is a rider pressing "up" to pan and leaving the screen.
        .defaultFocus($focus, .map)
        .onMoveCommand { direction in
            switch direction {
            case .up:    pan(dx: 0, dy: Self.panStep)
            case .down:  pan(dx: 0, dy: -Self.panStep)
            case .left:  pan(dx: -Self.panStep, dy: 0)
            case .right: pan(dx: Self.panStep, dy: 0)
            @unknown default: break
            }
        }
        .onPlayPauseCommand { zoom(by: 1 / 0.6) }
        .onExitCommand { stopDriving() }
    }

    private func startDriving() {
        isDriving = true
        focus = .map
    }

    private func stopDriving() {
        isDriving = false
        focus = .move
    }

    /// Pan by a fraction of what is on screen, so one press moves the same
    /// proportion of the view at every zoom.
    private func pan(dx: Double, dy: Double) {
        guard let region = visible ?? openingRegion else { return }
        var moved = region
        moved.center.latitude = (region.center.latitude + region.span.latitudeDelta * dy)
            .clamped(to: -85 ... 85)
        moved.center.longitude = region.center.longitude + region.span.longitudeDelta * dx
        commit(moved)
    }

    private func zoom(by factor: Double) {
        guard let region = visible ?? openingRegion else { return }
        let latitudeDelta = (region.span.latitudeDelta * factor)
            .clamped(to: Self.tightestSpan ... Self.widestSpan)
        // Scale longitude by what latitude actually did, so a clamped zoom
        // does not squash the aspect the map is drawn at.
        let applied = latitudeDelta / region.span.latitudeDelta
        commit(MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta,
                                   longitudeDelta: region.span.longitudeDelta * applied)))
    }

    /// Hand the map a new rectangle, and believe it immediately. The settle
    /// callback will correct this to whatever MapKit fitted to the screen; in
    /// the meantime it is what the next key press builds on, which is what
    /// makes holding a direction down feel like panning rather than nudging.
    private func commit(_ region: MKCoordinateRegion) {
        visible = region
        withAnimation(.easeOut(duration: 0.2)) {
            camera = .region(region)
        }
    }

    /// Whether the kept pin is already where the crosshairs are, within a
    /// couple of hundred metres — so the button can show it is set rather
    /// than inviting the same press twice.
    private var isPinnedHere: Bool {
        guard location.isChosen, let pin = location.here, let centre = centreCoordinate
        else { return false }
        return Geo.distance(pin, centre) < 200
    }

    /// Keep this point. Named after the guide's nearest launch when there is
    /// one close enough to be what somebody means by here, so the cameras tab
    /// and the search button read "Napeague" rather than a pair of decimals.
    private func setPin() {
        guard let centre = centreCoordinate else { return }
        let nearest = guide.nearestSpot(to: centre)
        let name: String = {
            if let nearest,
               Geo.distance(centre, .init(latitude: nearest.latitude,
                                          longitude: nearest.longitude)) < 10_000 {
                return nearest.name
            }
            return String(format: "%.2f°%@ %.2f°%@",
                          abs(centre.latitude), centre.latitude >= 0 ? "N" : "S",
                          abs(centre.longitude), centre.longitude >= 0 ? "E" : "W")
        }()
        // The map is already looking at this point, so it must not be
        // re-framed underneath the rider — only the *place* changes.
        justPinned = true
        location.choose(name: name, at: centre)
    }

    /// Back to the opening span, without moving the centre.
    ///
    /// Separate from `goHome` on purpose. Zooming in four times to look at a
    /// harbour mouth and wanting the coastline back is not the same wish as
    /// wanting to leave the coast you are looking at — and a single button
    /// that did both would take the second wish away from anyone who only had
    /// the first.
    private func resetZoom() {
        guard let region = visible else { return recentre() }
        commit(MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(latitudeDelta: Self.openingSpan,
                                   longitudeDelta: Self.openingSpan)))
    }

    /// Back to wherever the box thinks it is, at the opening span.
    ///
    /// Gives the fix its say back first: a rider who typed a place and has now
    /// pressed the location button is asking for the fix, not for the typed
    /// place at a different zoom.
    private func goHome() {
        location.useTheFix()
        recentre()
    }

    private func recentre() {
        guard let region = openingRegion else { return }
        commit(region)
    }

    private var openingRegion: MKCoordinateRegion? {
        guard let here = location.here else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude),
            span: MKCoordinateSpan(latitudeDelta: Self.openingSpan,
                                   longitudeDelta: Self.openingSpan))
    }

    // MARK: - The control bar

    /// Four things, and the remote's ordinary focus rules. Nothing here eats
    /// a direction, so a press upward reaches the tab bar the way it does on
    /// every other screen in the app.
    /// What the map draws, as a list that can grow.
    ///
    /// Rows rather than another row of capsules: a switch has to say what it
    /// is *and* what it currently is, and a capsule carrying both ends up as
    /// "Wind on" — which reads as a command half the time and as a state the
    /// other half.
    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MAP OPTIONS")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 38)
                .padding(.top, 8)

            OptionRow(title: "Wind overlay",
                      detail: "The model's field, painted over the chart",
                      systemImage: "wind",
                      isOn: showsWind) { showsWind.toggle() }
                .focused($focus, equals: .optWind)
                .prefersDefaultFocus(in: panel)

            OptionRow(title: "Wind meter names",
                      detail: "Which instrument each reading came from",
                      systemImage: "textformat.size",
                      isOn: showsMeterNames) { showsMeterNames.toggle() }
                .focused($focus, equals: .optNames)

            // How to leave, said where leaving is done. Menu closes the panel
            // rather than the tab — see `closeOptions` — but nothing on a
            // television says Menu goes anywhere, so this does.
            Label("Menu to close", systemImage: "chevron.backward")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 38)
                .padding(.top, 4)
                .padding(.bottom, 4)
        }
        .padding(.vertical, 14)
        .frame(width: 760)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .focusSection()
        .focusScope(panel)
        // Menu closes the panel rather than leaving the tab, which is what
        // Back means while something is open in front of you.
        .onExitCommand { closeOptions() }
    }

    private func toggleOptions() {
        isShowingOptions.toggle()
        focus = isShowingOptions ? .optWind : .options
    }

    private func closeOptions() {
        isShowingOptions = false
        focus = .options
    }

    private var controls: some View {
        HStack(spacing: 22) {
            // First, biggest, and the only one tinted: this is the door to
            // the forecast, and everything else on the bar only moves the
            // map around. A rider who presses one thing on this screen
            // should press this.
            ControlButton(title: "Conditions here", systemImage: "chart.bar.doc.horizontal",
                          isProminent: true) { isShowingConditions = true }
                .focused($focus, equals: .conditions)
                .prefersDefaultFocus(in: bar)
            Divider().frame(height: 44)
            hourStepper
            Divider().frame(height: 44)
            ControlButton(title: "Pan & zoom", systemImage: "dpad.fill", action: startDriving)
                .focused($focus, equals: .move)
            // One door rather than a switch each. Two toggles already made
            // this bar eight things wide, and the layers a wind map wants —
            // currents, stations, buoys, the phone has all of them — would
            // make it a wall. A panel costs one press and holds as many as
            // it likes.
            ControlButton(title: "Options", systemImage: "slider.horizontal.3",
                          isOn: isShowingOptions) { toggleOptions() }
                .focused($focus, equals: .options)
            // Icons rather than labels: the bar is already carrying three
            // words and a clock, and these are the sort of thing a rider
            // does often enough to learn the glyph for.
            // Drop the pin where the crosshairs are, and keep it.
            //
            // The crosshairs used to be a readout and nothing more: they told
            // you the wind under them and forgot the moment you panned away,
            // and the cameras tab went on listing whatever coast the box had
            // guessed at. Setting the pin makes this the place the app is
            // about — remembered across launches, and the cameras re-found
            // around it — until it is set somewhere else.
            ControlIcon(systemImage: isPinnedHere ? "mappin.circle.fill" : "mappin.and.ellipse",
                        label: "Set the pin here",
                        isOn: isPinnedHere, action: setPin)
                .focused($focus, equals: .setPin)
            ControlIcon(systemImage: "arrow.up.left.and.arrow.down.right",
                        label: "Reset the zoom", action: resetZoom)
                .focused($focus, equals: .reset)
            ControlIcon(systemImage: "location.fill",
                        label: "Back to my location", action: goHome)
                .focused($focus, equals: .locate)
            ControlButton(title: location.name.isEmpty ? "Set location" : location.name,
                          systemImage: "location.magnifyingglass") { isSearching = true }
                .focused($focus, equals: .place)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 18)
        .background(.thinMaterial, in: Capsule())
        // The three modifiers that decide where "down" goes, and all three
        // are needed.
        //
        // Without `focusSection` tvOS resolves a move by geometry alone: it
        // looks for the focusable item directly *below* whatever the tab bar
        // had, and from the "Map" tab that is the hour stepper's back
        // chevron near the middle of the bar — never "Conditions here" at the
        // far left. `focusSection` makes the whole bar one target, so Down
        // means "into the bar" rather than "into whatever is under my x".
        //
        // `focusScope` plus `prefersDefaultFocus` on the first button then
        // says which item that is. `defaultFocus` alone did not: it applies
        // when the view appears, and focus coming back down off the tab bar
        // is not an appearance.
        .focusSection()
        .focusScope(bar)
        .defaultFocus($focus, .conditions)
    }

    /// The hour, as two buttons around a label rather than one control that
    /// listens for left and right. A focusable thing that swallows the
    /// sideways keys is a focus trap on a television — the rider can see the
    /// button beside it and cannot reach it.
    private var hourStepper: some View {
        HStack(spacing: 16) {
            StepButton(systemImage: "chevron.left", isEnabled: offsetHours > 0) {
                offsetHours = max(0, offsetHours - 1)
            }
            .focused($focus, equals: .hourBack)
            Text(offsetHours == 0
                 ? "Now"
                 : (scrubbed ?? .now).formatted(.dateTime.weekday(.abbreviated).hour()))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 180)
            StepButton(systemImage: "chevron.right", isEnabled: offsetHours < Self.horizon) {
                offsetHours = min(Self.horizon, offsetHours + 1)
            }
            .focused($focus, equals: .hourForward)
        }
    }

    /// What the map is not saying out loud: whose model this is, and that a
    /// field is on its way. Both are the phone's own captions, shrunk to a
    /// line — a television has no room for a hud and no need for one, since
    /// nobody here is waiting to tap anything.
    @ViewBuilder private var statusChip: some View {
        if layer != .off {
            HStack(spacing: 14) {
                if wash.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(layer.loadingLabel)
                } else if wash.loadFailed {
                    // Said where the model's name would be, because that is
                    // the line a rider already reads to find out what the
                    // colours are. A missing wash otherwise looks exactly
                    // like a wash somebody switched off.
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Wind overlay didn't load")
                } else if let caption = layer.caption {
                    Text(caption)
                }
            }
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(wash.loadFailed && !wash.isBusy ? AnyShapeStyle(.orange)
                                                            : AnyShapeStyle(.secondary))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 40)
            .padding(.trailing, 60)
        }
    }

    // MARK: - What is under the crosshairs

    /// The centre's reading for the hour the clock is on: the live fetch at
    /// now, that point's own hourly row at any other hour. Nil while a series
    /// is still coming, which the readout draws as a pulse — better than a
    /// number belonging to a different hour.
    private var scrubbedCentreWind: WindReading? {
        guard let scrubbed, let here = centreCoordinate else { return centreWind }
        return guide.reading(for: SpotGuideStore.windKey(for: here), at: scrubbed)
    }

    /// A pulse, or a dash. Waiting is a fetch that has not come back; a dash
    /// is a fetch that came back with nothing, and a shimmer that never ends
    /// is indistinguishable from a broken app.
    private var isWaitingOnCentre: Bool {
        guard let here = centreCoordinate else { return true }
        if scrubbed != nil {
            return guide.windHours[SpotGuideStore.windKey(for: here)] == nil
        }
        return !centreLoaded
    }

    private var centreCoordinate: Geo.Coordinate? {
        guard let centre = visible?.center else { return nil }
        return Geo.Coordinate(latitude: centre.latitude, longitude: centre.longitude)
    }

    /// About a kilometre. Anything finer re-asks Open-Meteo for a point it
    /// has already answered for, at a resolution its model does not have.
    private var centreKey: String {
        guard let here = centreCoordinate else { return "-" }
        return String(format: "%.2f,%.2f", here.latitude, here.longitude) + "|" + modelRaw
    }

    // MARK: - Meters

    /// Only meters that actually answered, with a reading recent enough to
    /// mean anything.
    ///
    /// `WIND_MAP_RULES` R1, applied to the one screen that most wants to break
    /// it: a number on the map is a measurement, or there is no number. An
    /// instrument that is silent gets no pin here at all rather than a pin
    /// wearing the model's guess — the wash behind it is already the model,
    /// and a rider reading a capsule at four metres cannot tell the two apart.
    private var reporting: [(station: FreeStation, observation: StationObservation)] {
        meters.compactMap { station in
            guard let observation = readings[station.id],
                  observation.reports, !observation.isStale
            else { return nil }
            return (station, observation)
        }
    }

    /// Fetch the instruments around the view, then their readings.
    ///
    /// The list first and the numbers after, the way the conditions screen
    /// does it: each reading is its own request, and a pin that appears a
    /// moment before its number is better than a map that stays empty until
    /// the slowest station answers.
    private func refreshMeters() async {
        guard let centre = centreCoordinate else { return }
        // Scaled to the view: at a harbour's zoom a forty-kilometre radius is
        // meters far off screen, and at a coastline's zoom it is too few.
        let span = visible?.span.latitudeDelta ?? Self.openingSpan
        let radius = min(max(span * 111_000 * 0.8, 25_000), 180_000)
        // Twelve. Eighteen came out as overlapping capsules wherever the
        // instruments genuinely cluster — three airports around East Hampton
        // wrote over each other — and an unreadable number is worse than an
        // absent one.
        let found = await FreeStations.near(centre, limit: 12, radius: radius)
        meters = found
        await withTaskGroup(of: (String, StationObservation?).self) { group in
            for station in found {
                group.addTask { (station.id, await FreeStations.latest(for: station)) }
            }
            for await (id, observation) in group {
                if let observation { readings[id] = observation }
            }
        }
    }

    // MARK: - Keys

    /// What the meter list depends on, rounded so a settle whose span differs
    /// in the twelfth decimal place does not re-ask for anything.
    private var pinKey: String {
        visible.map {
            String(format: "%.2f,%.2f,%.2f",
                   $0.center.latitude, $0.center.longitude, $0.span.latitudeDelta)
        } ?? "-"
    }

    private var scrubKey: String { "\(offsetHours != 0)|\(pinKey)|\(centreKey)" }

    /// The place the map should be sitting on, as a string that changes only
    /// when it is genuinely somewhere else.
    private var placeKey: String {
        guard let here = location.here else { return "-" }
        return String(format: "%.3f,%.3f", here.latitude, here.longitude)
    }
}

// MARK: - The crosshairs

/// The fixed centre marker and what is happening there.
///
/// The marker never moves; the world moves under it, and whatever lands
/// beneath the dot is what the pills above it describe. Same idea as the
/// phone's `CentrePinReadout`, at the size a room reads — and with the air
/// beside the wind, because on a television there is space for the second
/// question somebody asks.
private struct CentreReadout: View {

    let wind: WindReading?
    let weather: SpotWeather?
    let isWaiting: Bool

    @State private var isPulsing = false

    private static let dotSize: CGFloat = 22
    private static let stemHeight: CGFloat = 26

    private var temperature: String? {
        guard let weather else { return nil }
        return Format.temperature(weather.temperatureC,
                                  unit: UnitPreferences.forThisDevice.temperatureUnit)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                windPill
                if let weather, let temperature {
                    HStack(spacing: 10) {
                        Image(systemName: weather.symbol)
                            .font(.system(size: 26))
                            .foregroundStyle(weather.tint)
                        Text(temperature)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 2))
                    .foregroundStyle(.white)
                } else if !isWaiting {
                    // The capsule used to simply not be drawn, which says
                    // nothing at all — and the temperature is the second
                    // question anybody asks of this screen.
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                        Text("Temp didn't load")
                            .font(.system(size: 24, weight: .semibold))
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 2))
                    .foregroundStyle(.white)
                }
            }
            Rectangle()
                .fill(.white)
                .frame(width: 3, height: Self.stemHeight)
            Circle()
                .fill(Color.black.opacity(0.75))
                .strokeBorder(.white, lineWidth: 4)
                .frame(width: Self.dotSize, height: Self.dotSize)
        }
        // Drawn hanging upward from the map's centre: the dot's middle has to
        // sit on the camera's centre coordinate, so the whole stack rises by
        // its own height less half the dot.
        .alignmentGuide(VerticalAlignment.center) { $0[.bottom] - Self.dotSize / 2 }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .allowsHitTesting(false)
    }

    /// The reading, in the map pins' shared language at headline size: an
    /// arrow pointing downwind — the streamline convention the whole app
    /// draws wind by — knots, the gust, and the firing tint.
    private var windPill: some View {
        HStack(spacing: 14) {
            if let wind {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 24, weight: .heavy))
                    .rotationEffect(.degrees(wind.directionDeg + 180))
                Text("\(Int(wind.speedKn.rounded()))")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 0) {
                    Text("kn \(wind.cardinal)")
                        .font(.system(size: 22, weight: .semibold))
                    if let gust = wind.gustKn {
                        Text("g\(Int(gust.rounded()))")
                            .font(.system(size: 20))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            } else if isWaiting {
                // Waiting breathes rather than spinning: a spinner over a map
                // reads as something being wrong.
                Image(systemName: "wind")
                    .font(.system(size: 24, weight: .semibold))
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(isPulsing ? 0.55 : 0.2))
                    .frame(width: 70, height: 26)
                    .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                               value: isPulsing)
                    .onAppear { isPulsing = true }
            } else {
                // A dash on its own was the whole message, and a dash reads
                // as "nothing here" — which about the wind is never true.
                // The request did not land, and saying so is the difference
                // between a rider waiting for a number and a rider knowing
                // there is nothing to wait for.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Wind didn't load")
                    .font(.system(size: 24, weight: .semibold))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .foregroundStyle(.white)
        // A literal dark capsule, never `.primary`: everything on this pill
        // is white, and map chrome carrying white content has to stay dark in
        // both appearances.
        .background((wind?.isFiring ?? false) ? AnyShapeStyle(Color.accentColor)
                                              : AnyShapeStyle(Color.black.opacity(0.75)),
                    in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 2))
    }
}

// MARK: - Chrome

/// A button that draws its label and nothing else — no focus background, no
/// lift, no press state. For the driving surface, which is a full-screen
/// invisible target and must stay invisible while it holds the focus.
///
/// Internal rather than private: the cameras map drives the same way, and two
/// copies of "the style that draws nothing" is how one of them quietly starts
/// drawing something.
struct NoStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// One pill on the control bar.
///
/// Focus is drawn rather than left to tvOS's card lift: a capsule that grows
/// over a map covers the water it is describing, so this brightens instead.
/// The look lives in the label, because `isFocused` is only true for views
/// *inside* the focusable thing.
private struct ControlButton: View {

    let title: String
    let systemImage: String
    var isOn = false
    /// The one button on the bar that is a destination rather than a
    /// control. Tinted unfocused so it reads as the primary action from
    /// across a room, where a row of identical grey capsules does not.
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ControlPill(title: title, systemImage: systemImage,
                        isOn: isOn, isProminent: isProminent)
        }
        .buttonStyle(.plain)
    }
}

/// One switch in the options panel.
///
/// The state is a word at the end of the row — On or Off — rather than a
/// checkmark or a tint, because from three metres a tick is a smudge and a
/// tint is a guess about whether that colour means anything.
private struct OptionRow: View {

    let title: String
    let detail: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OptionRowBody(title: title, detail: detail,
                          systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct OptionRowBody: View {

    let title: String
    let detail: String
    let systemImage: String
    let isOn: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 28, weight: .medium))
                Text(detail)
                    .font(.system(size: 19))
                    .opacity(0.65)
            }
            Spacer(minLength: 30)
            Text(isOn ? "On" : "Off")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black
                                 : (isOn ? Color.accentColor : Color.white.opacity(0.5)))
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .foregroundStyle(isFocused ? Color.black : Color.white)
        .background(isFocused ? Color.white : Color.clear,
                    in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
    }
}

/// A control the bar shows as a glyph alone.
///
/// The label still exists — VoiceOver reads it, and it is the only name this
/// button has — it simply is not drawn, because a bar with six words on it is
/// a bar nobody reads any of.
private struct ControlIcon: View {

    let systemImage: String
    let label: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ControlGlyph(systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct ControlGlyph: View {

    let systemImage: String
    var isOn = false

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 26, weight: .semibold))
            .frame(width: 62, height: 56)
            .foregroundStyle(isFocused ? Color.black : (isOn ? Color.accentColor : Color.white))
            .background(isFocused ? Color.white : Color.white.opacity(0.14), in: Capsule())
    }
}

private struct ControlPill: View {

    let title: String
    let systemImage: String
    let isOn: Bool
    var isProminent = false

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .foregroundStyle(isFocused ? Color.black
                         : (isProminent || isOn ? Color.accentColor : Color.white))
        .background(isFocused ? AnyShapeStyle(Color.white)
                    : AnyShapeStyle(Color.white.opacity(isProminent ? 0.22 : 0.14)),
                    in: Capsule())
    }
}

/// One end of the hour stepper.
///
/// Dimmed at the limit but never `disabled`. A disabled button is not
/// focusable, and this one sits in the middle of the bar — so at "Now", which
/// is where the screen opens, the back chevron was a hole in the focus row
/// exactly where the tab bar's own "Map" item sends a press of Down. Dimmed
/// and inert reads the same from three metres and keeps the row whole; the
/// actions clamp, so pressing at the limit is simply nothing.
private struct StepButton: View {

    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StepGlyph(systemImage: systemImage, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
    }
}

private struct StepGlyph: View {

    let systemImage: String
    let isEnabled: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 26, weight: .bold))
            .frame(width: 56, height: 52)
            .foregroundStyle(isFocused ? Color.black
                             : (isEnabled ? Color.white : Color.white.opacity(0.3)))
            .background(isFocused ? Color.white : Color.white.opacity(0.14), in: Capsule())
    }
}

/// What the keys do while the map has them. On screen the whole time the map
/// is being driven, because a television cannot be explored — an unlabelled
/// button on a remote is one nobody presses twice.
private struct DrivingLegend: View {

    var body: some View {
        HStack(spacing: 30) {
            legend("dpad.fill", "Pan")
            legend("plus.magnifyingglass", "Select")
            legend("minus.magnifyingglass", "Play/Pause")
            legend("chevron.backward.circle", "Menu to finish")
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 18)
        .background(.thinMaterial, in: Capsule())
    }

    private func legend(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
            Text(label)
                .font(.system(size: 24, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Before there is a place

/// The one state a map cannot paint its way out of: a box that does not know
/// where it is and has not been told.
///
/// The search button is here while the box is still trying, too. A fix that
/// never arrives is the failure this screen is most likely to meet — tvOS
/// answers or it does not, there is no receiver warming up — and a rider
/// watching a spinner with no way past it is the worst version of that.
private struct NoPlaceYet: View {

    let isTrying: Bool
    let search: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            if isTrying {
                ProgressView()
                    .controlSize(.large)
                    .frame(height: 80)
            } else {
                Image(systemName: "location.slash")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }
            Text(isTrying ? "Working out where you are…"
                          : "This Apple TV does not know where it is")
                .font(.system(size: 50, weight: .bold))
                .multilineTextAlignment(.center)
            Text(isTrying
                 ? "It has no receiver, so this is the network's best guess and it may\ncome to nothing. You can name the place instead."
                 : "It has no receiver, and Location Services may be off at the system\nlevel. Type a town, a beach or a launch and the map opens there\nfrom now on — it only has to be answered once.")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Search for a place", action: search)
                .padding(.top, 14)
        }
        .padding(70)
    }
}

// MARK: - One spot on the map

/// One anemometer, carrying what it measured.
///
/// Deliberately unlike the wash it sits on. The field behind it is a model and
/// this is an instrument, so the badge is white-on-dark with a hard border
/// rather than another translucent capsule tinted from the same ramp — a rider
/// glancing at this map has to be able to tell "the model says" from "a mast
/// at the end of that jetty says" without reading a word.
private struct MeterBadge: View {

    let name: String
    let observation: StationObservation
    let showsName: Bool

    /// A steel blue, and not the black everything else on this map wears.
    ///
    /// The centre readout and the weather pill are black capsules with a
    /// white edge, and until now so were these — three identical shapes
    /// saying three different kinds of thing. The dot in the middle is the
    /// *model* at the point you are looking at; these are instruments,
    /// somewhere else, that actually measured something. Same grammar,
    /// different material: a rider should be able to see which is which from
    /// the sofa without reading either.
    private static let instrument = Color(red: 0.09, green: 0.24, blue: 0.35)

    /// The weather service writes a gust with no mean as "0G4", and that is a
    /// reading. Following what the instrument actually said rather than
    /// insisting on a mean is `WIND_MAP_RULES` R4's third clause.
    private var speed: String {
        if let mean = observation.windKn { return "\(Int(mean.rounded()))" }
        if let gust = observation.gustKn { return "g\(Int(gust.rounded()))" }
        return "—"
    }

    private var isFiring: Bool { (observation.windKn ?? 0) >= 15 }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if let direction = observation.directionDeg {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 13))
                        .rotationEffect(.degrees(direction + 180))
                }
                Text(speed)
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                if let gust = observation.gustKn, observation.windKn != nil {
                    Text("g\(Int(gust.rounded()))")
                        .font(.system(size: 16, weight: .semibold))
                        .opacity(0.75)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(isFiring ? AnyShapeStyle(Color.accentColor)
                                 : AnyShapeStyle(Self.instrument.opacity(0.92)),
                        in: Capsule())
            // A lighter, cooler edge than the centre readout's flat white —
            // the second half of telling the two apart at a glance.
            .overlay(Capsule().stroke(Color.cyan.opacity(0.55), lineWidth: 2))

            if showsName {
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(Self.instrument.opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

extension FreeStation {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

extension GuideSpot {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
