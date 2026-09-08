import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The starred spots, one at a time, as the maps they actually are.
///
/// Every other screen in this app answers a question somebody asked. This one
/// answers a question nobody asked yet: a television left on in a kitchen
/// cycles the wind map of each saved launch, with the one line that would make
/// somebody put the kettle down — *good wind in three days* — printed under
/// the name.
///
/// It is a screensaver in the television sense rather than the system one: it
/// is a tab, it starts when you land on it, and Menu gives the box back. tvOS
/// will not let an app take over the real screensaver slot, and it should not
/// — this runs because somebody chose it, not because they walked away.
///
/// **The forecast is one request.** Open-Meteo takes comma-separated
/// coordinates, so seven days of hourly wind for every starred spot is a
/// single call made once when the tab opens — see `loadPromises`. Everything
/// on every slide comes out of that one answer, which is why cycling costs
/// nothing after the first pass and why the numbers on two consecutive slides
/// cannot disagree about what hour it is.
struct ScreensaverScreen: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(TVUnits.self) private var units
    @Environment(\.displayScale) private var displayScale

    /// Whether this is the tab on screen. The wash and its comets run at
    /// display rate; a screensaver quietly animating behind the settings
    /// screen is a fan spinning for nobody.
    let isActive: Bool

    @State private var wash = WindWashModel()

    /// Which spot is showing, as an index into `slides`. Wrapped rather than
    /// clamped: a cycle that stops at the end is a slideshow.
    @State private var index = 0
    /// Play/Pause holds the slide a rider wants to keep looking at. The wash
    /// keeps running under it — the wind has not paused.
    @State private var isPaused = false
    /// The slide the camera has already been flown to, so the flight happens
    /// once per spot rather than on every re-evaluation of the body.
    @State private var framed: String?

    @State private var camera: MapCameraPosition = .automatic
    @State private var mapWidth: CGFloat = 1920
    @State private var visible: MKCoordinateRegion?

    /// What the models promise at each slide, keyed by its id.
    @State private var promises: [String: Promise] = [:]
    @State private var hasAsked = false

    /// Whether the television's own furniture is out of the way: the tab
    /// bar, the legend and the position dots, all of which come and go
    /// together. A screensaver is the one screen in this app whose job is to
    /// be looked at rather than used, and a menu across the top of it is a
    /// menu nobody is reading.
    @State private var isImmersive = false

    /// Bumped by every press, so the idle countdown restarts. A counter
    /// rather than a `Date`, because `.task(id:)` needs something that only
    /// changes when something happened.
    @State private var inputs = 0

    /// Whether the reel surface has the remote. tvOS collapses its own tab
    /// bar when focus is in the content, which is the whole reason this
    /// screen does not hide the bar itself — see `keys`.
    @FocusState private var hasRemote: Bool

    /// How long the chrome stays up after a press before the picture takes
    /// the whole screen again.
    private static let chromeSeconds = 6.0

    /// How long the tab bar keeps the focus after this tab is selected,
    /// before the reel takes it.
    ///
    /// Long enough that a rider crossing the bar on their way to Settings is
    /// past this tab before it asks for anything, and short enough that
    /// somebody who meant to land here is not left staring at a menu. The
    /// steal is what makes the bar hideable at all — see `takeTheRemote`.
    private static let graceSeconds = 5.0

    /// How long each spot holds the screen. Long enough to read the name, the
    /// number and the line under it without hurrying, and short enough that a
    /// board of six comes round inside a kettle's boil.
    private static let slideSeconds = 14.0

    /// How far ahead the promise looks. A week is where the models stop being
    /// weather and start being climate: past it "good wind on Tuesday" is a
    /// coin toss wearing a weekday's name.
    private static let horizonDays = 7

    /// How many hours in a row have to be firing before it counts.
    ///
    /// One hour over fifteen knots is a gust front, and a television that
    /// announces a session on the strength of it is a television nobody
    /// believes twice. Three consecutive hours is a sail.
    private static let sustainedHours = 3

    /// About ninety kilometres, the same window the map opens at — one
    /// coastline rather than one launch, so the wash has something to be a
    /// shape of.
    private static let span = 0.8

    // MARK: - What is in the cycle

    /// One spot on the reel: the starred guide launches and the rider's own
    /// pins, in the order the favourites board lists them.
    private struct Slide: Identifiable, Equatable {
        let id: String
        let name: String
        let coordinate: Geo.Coordinate
    }

    private var slides: [Slide] {
        guide.favorites.map {
            Slide(id: "spot:" + $0.spotId, name: $0.name,
                  coordinate: Geo.Coordinate(latitude: $0.latitude, longitude: $0.longitude))
        } + guide.privateSpots.map {
            Slide(id: "pin:" + $0.id.uuidString, name: $0.name, coordinate: $0.coordinate)
        }
    }

    private var current: Slide? { slides[safe: index] }

    /// What the models say about one spot: what it is doing this hour, and
    /// the next stretch of wind worth driving to.
    private struct Promise {
        /// This hour, from the same series the rest of the promise came from.
        let now: WindForecastHour?
        /// The first hour of the next sustained run, and its best hour.
        let arrives: Date?
        let peakKn: Double
    }

    // MARK: - The screen

    var body: some View {
        Group {
            if slides.isEmpty {
                NothingToShow()
            } else {
                reel
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                wash.wake()
            } else {
                wash.sleep()
                isPaused = false
                // Leaving the tab gives the furniture back. Coming to this
                // tab and finding no menu bar because of what happened on
                // the last visit is how a box looks broken.
                isImmersive = false
            }
        }
        // The reel asks for the remote a few seconds after the tab is
        // selected — see `takeTheRemote` for why it has to be asked for at
        // all, and why the asking waits.
        .task(id: isActive) {
            guard isActive, !slides.isEmpty else { return }
            try? await Task.sleep(for: .seconds(Self.graceSeconds))
            guard !Task.isCancelled, isActive else { return }
            hasRemote = true
        }
        // One request for the whole reel, and then again every half hour.
        //
        // A loop rather than one pass: this is the tab a television is left
        // on, and "good wind in two days" written at seven in the morning is
        // wrong by lunchtime. Half an hour is `ForecastCache`'s own TTL, so
        // a pass that finds nothing new costs nothing.
        .task(id: slides.map(\.id).joined()) {
            while !Task.isCancelled {
                await loadPromises()
                try? await Task.sleep(for: .seconds(1800))
            }
        }
        // The camera, and only when the spot under it is genuinely new.
        //
        // It has to be told: a `Map` handed `.automatic` with no content
        // opens on MapKit's own default rectangle, which is the middle of
        // the United States — the same trap the wind map documents. The
        // guide also loads after this tab does, so on a cold launch the
        // first slide arrives a second after the screen it goes on.
        .onChange(of: frameKey, initial: true) { _, _ in frame() }
        // A fresh timer per slide, which is also what a manual skip wants:
        // pressing right should buy a full fourteen seconds on the spot you
        // just asked for, not the tail of the one you left.
        .task(id: tick) {
            guard isActive, !isPaused, slides.count > 1 else { return }
            try? await Task.sleep(for: .seconds(Self.slideSeconds))
            guard !Task.isCancelled else { return }
            advance(by: 1)
        }
        // The chrome's own clock: it goes away six seconds after the last
        // press, and every press restarts this by changing the key.
        //
        // Gated on `hasRemote`, and that gate is the safety. The tab bar can
        // only be hidden once focus is genuinely down here; if the steal
        // above ever fails, this never fires, and the worst case is a
        // screensaver that keeps its menu bar rather than a television whose
        // remote does nothing.
        .task(id: idleKey) {
            guard hasRemote, !isImmersive else { return }
            try? await Task.sleep(for: .seconds(Self.chromeSeconds))
            guard !Task.isCancelled, hasRemote else { return }
            withAnimation(.easeOut(duration: 0.5)) { isImmersive = true }
        }
        // Focus leaving the reel — Menu, or a press of Up — brings the
        // furniture back with it. It has to: the tab bar is where focus is
        // going, and it cannot go somewhere that is not drawn.
        .onChange(of: hasRemote) { _, holding in
            if !holding { isImmersive = false }
        }
    }

    /// Everything that should restart the countdown to an empty screen.
    private var idleKey: String { "\(hasRemote)|\(inputs)" }

    /// Everything the slide timer should restart for.
    private var tick: String {
        "\(isActive)|\(isPaused)|\(index)|\(slides.count)"
    }

    /// Everything the camera should be re-aimed for.
    private var frameKey: String { "\(isActive)|\(current?.id ?? "-")" }

    private var reel: some View {
        ZStack(alignment: .bottom) {
            map
                .ignoresSafeArea()
            // The bottom third carries the name and the promise, and a wash
            // is exactly the wrong ground for white type — a pale field and
            // white letters are the same colour. A gradient rather than a
            // panel, so the map keeps going under the words, and a sibling
            // of the map rather than an overlay on it: inside the map's own
            // overlay chain this was laid out against the safe-area rect and
            // stopped well short of the glass, which on a bright field read
            // as no scrim at all.
            //
            // Stops on a full-screen gradient rather than a fixed height:
            // a 620-point band pinned to the bottom is pinned to the *safe
            // area's* bottom, and a television overscans — it left a bright
            // strip of untinted map along the very edge of the glass.
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .clear, location: 0.42),
                                   .init(color: .black.opacity(0.5), location: 0.74),
                                   .init(color: .black.opacity(0.9), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
                .ignoresSafeArea()
            caption
            if !isImmersive { hint }
            // The surface that holds the remote. Same shape as the map's
            // driving surface and for the same reason: a focusable *button*
            // is the only thing on tvOS that hears Select, and `NoStyle`
            // plus `focusEffectDisabled` is what keeps a full-screen one
            // from drawing a white panel over the whole picture.
            keys
        }
        // The whole point of the request: while nobody is pressing anything,
        // the map is the only thing on the glass.
        .toolbar(isImmersive ? .hidden : .visible, for: .tabBar)
    }

    /// The surface that holds the remote while somebody is watching.
    ///
    /// A focusable button covering the glass, because a focusable *button* is
    /// the only thing on tvOS that hears Select. `NoStyle` and
    /// `focusEffectDisabled` are what stop a full-screen one drawing a white
    /// panel over the entire picture — the wind map's driving surface learned
    /// that the hard way and this is the same shape.
    ///
    /// Every press does two things: whatever it means, and waking the
    /// chrome. That second job is why Up and Menu are answered here at all
    /// — while the bar is hidden there is nothing above to move to and
    /// nothing for Menu to fall back on, so the first press of either has to
    /// be the one that draws the bar again rather than the one that tries to
    /// reach it.
    private var keys: some View {
        Button { if !isImmersive { advance(by: 1) }; wake() } label: {
            Rectangle().fill(.clear).contentShape(Rectangle())
        }
        .buttonStyle(NoStyle())
        .focusEffectDisabled()
        .focused($hasRemote)
        .onMoveCommand { direction in
            let wasImmersive = isImmersive
            wake()
            // A press that only woke the screen is spent. Skipping the spot
            // as well would mean a rider reaching for the menu also loses
            // the slide they were reading.
            guard !wasImmersive else { return }
            switch direction {
            case .left:  advance(by: -1)
            case .right: advance(by: 1)
            default: break
            }
        }
        .onPlayPauseCommand { if !isImmersive { isPaused.toggle() }; wake() }
        // Menu, in two steps, and the second step is tvOS's own.
        //
        // The handler is *installed* only while the picture has the screen
        // to itself: then Menu draws the furniture back, the way every other
        // key does. With the bar already up there is no handler at all, so
        // Menu means what it means everywhere else on this box and focus
        // goes back to the bar.
        //
        // Written this way because the obvious version does not work.
        // Letting go of the remote by hand — setting the focus binding to
        // false — was measured on the simulator to do nothing at all: tvOS
        // will not leave a screen with no focus, so the flag stayed true,
        // the bar stayed hidden, and Menu had quietly become a dead key.
        // `onExitCommand` takes an optional, and nil is the only way to say
        // "do not answer this one".
        .onExitCommand(perform: isImmersive ? { wake() } : nil)
    }

    /// A press happened: show the furniture, and start the clock again.
    private func wake() {
        inputs += 1
        if isImmersive {
            withAnimation(.easeOut(duration: 0.3)) { isImmersive = false }
        }
    }

    // MARK: - The picture

    private var map: some View {
        // Hoisted out of the builder for the reason the wind map hoists them:
        // a read inside `Map`'s content closure registers no dependency, and
        // the field would draw once and never again.
        let raster = wash.raster
        let field = wash.field
        return MapReader { proxy in
            Map(position: $camera, interactionModes: [])
                .focusable(false)
                .mapStyle(.standard(elevation: .flat, emphasis: .muted,
                                    pointsOfInterest: .excludingAll))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    mapWidth = width
                    if let visible {
                        wash.mapMeasured(widthPoints: width, displayScale: displayScale,
                                         visible: visible)
                    }
                }
                .onMapCameraChange(frequency: .continuous) { _ in wash.cameraMoving() }
                .onMapCameraChange(frequency: .onEnd) { context in
                    visible = context.region
                    wash.viewSettled(on: context.region, layer: .wind,
                                     widthPoints: mapWidth, displayScale: displayScale)
                }
                .overlay {
                    if let raster {
                        WashRasterLayer(raster: raster, proxy: proxy)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if let field {
                        WashParticleLayer(field: field, proxy: proxy)
                    }
                }
        }
    }

    // MARK: - What the slide says

    @ViewBuilder private var caption: some View {
        if let slide = current {
            VStack(alignment: .leading, spacing: 14) {
                Spacer()
                Text(slide.name)
                    .font(.system(size: 84, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let now = promises[slide.id]?.now {
                    liveLine(now)
                }
                Text(headline(for: slide))
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .foregroundStyle(isFiringSoon(slide) ? Color.accentColor : Color.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            // The name and the numbers change on the beat; the map flies. A
            // fade keyed to the slide keeps the two from arriving together
            // and reading as a stutter.
            .id(slide.id)
            .transition(.opacity)
            .overlay(alignment: .bottomTrailing) { position }
            .allowsHitTesting(false)
        }
    }

    /// The model's wind at this hour, said as a model number rather than
    /// dressed as a reading: no instrument on this screen took it, and the
    /// wash behind it came from the same forecast.
    private func liveLine(_ hour: WindForecastHour) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 30))
                .rotationEffect(.degrees(hour.directionDeg + 180))
            Text(Format.cardinal(hour.directionDeg))
                .font(.system(size: 34, weight: .medium))
            Text(units.windValue(hour.speedKn))
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 0) {
                Text(units.speedSymbol)
                    .font(.system(size: 28, weight: .semibold))
                if let gust = hour.gustKn {
                    Text("g\(units.windValue(gust))")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                }
            }
        }
        .foregroundStyle(.white)
    }

    /// Whose numbers these are, and where the reel is.
    ///
    /// Both belong in the same quiet corner. The model's name is the map's
    /// own caption, said here rather than at the top right where that screen
    /// puts it: a screensaver's top edge is the one part of the picture that
    /// should stay empty, and the tab bar lands there anyway. The dots
    /// answer the only question a cycling display leaves open, which is how
    /// many more of these there are.
    @ViewBuilder private var position: some View {
        VStack(alignment: .trailing, spacing: 14) {
            if let caption = WashLayer.wind.caption {
                Text(caption)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if slides.count > 1, !isImmersive {
                HStack(spacing: 12) {
                    if isPaused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.trailing, 4)
                    }
                    ForEach(slides.indices, id: \.self) { slot in
                        Circle()
                            .fill(slot == index ? Color.white : Color.white.opacity(0.3))
                            .frame(width: 12, height: 12)
                    }
                }
            }
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 90)
    }

    private var hint: some View {
        HStack(spacing: 30) {
            key("chevron.left.chevron.right", "Skip")
            key("playpause.fill", "Hold")
            key("chevron.backward", "Menu to leave")
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .background(.thinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 60)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func key(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
            Text(label).font(.system(size: 22, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    // MARK: - Running the reel

    /// Aim the camera at the slide that is showing, once per slide.
    private func frame() {
        guard isActive, let slide = current, slide.id != framed else { return }
        framed = slide.id
        fly(to: index)
    }

    private func advance(by step: Int) {
        guard !slides.isEmpty else { return }
        // Wrapped both ways: `%` alone answers -1 for a press of left on the
        // first slide, which is not an index.
        let next = ((index + step) % slides.count + slides.count) % slides.count
        isPaused = false
        // The caption's fade is keyed to the slide's identity, and an
        // identity transition only animates inside an animated transaction —
        // `.animation(value:)` on the container will not do it.
        withAnimation(.easeInOut(duration: 0.45)) { index = next }
    }

    /// Move the camera to a slide. Animated rather than cut, because the
    /// flight between two coasts is half of what makes this worth watching —
    /// and because MapKit only reports a settle at the end of it, which is
    /// the moment the wash should start fetching for the new place.
    private func fly(to slot: Int) {
        guard let slide = slides[safe: slot] else { return }
        withAnimation(.easeInOut(duration: 1.2)) {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: slide.coordinate.latitude,
                                               longitude: slide.coordinate.longitude),
                span: MKCoordinateSpan(latitudeDelta: Self.span, longitudeDelta: Self.span)))
        }
    }

    // MARK: - The promise

    /// Seven days of hourly wind for every spot on the reel, in one request.
    private func loadPromises() async {
        let reel = slides
        guard !reel.isEmpty else { return }
        let series = await OpenMeteo.windAlong(reel.map(\.coordinate),
                                               hours: Self.horizonDays * 24)
        var found: [String: Promise] = [:]
        for (slot, slide) in reel.enumerated() {
            guard let rows = series[safe: slot], !rows.isEmpty else { continue }
            found[slide.id] = Self.promise(in: rows)
        }
        // Set whatever came back, and say the asking is over either way. A
        // request that failed leaves a spot with no promise, and the caption
        // has an honest line for that — a shimmer that never ends does not.
        promises = found
        hasAsked = true
    }

    /// Read one spot's week: this hour, and the first sustained run of wind
    /// in it.
    ///
    /// `isFiring` is deliberately the same threshold the favourites board
    /// counts with. A screensaver that used a friendlier number would tell a
    /// rider three spots are coming good and then hand them a board that says
    /// none of them are.
    private static func promise(in rows: [WindForecastHour]) -> Promise {
        var run = 0
        var start: Date?
        var peak = 0.0
        for row in rows {
            guard WindReading(from: row).isFiring else {
                // A run that never reached the length is not a session.
                if run < sustainedHours { run = 0; start = nil; peak = 0 }
                else { break }
                continue
            }
            if run == 0 { start = row.date }
            run += 1
            peak = max(peak, row.gustKn ?? row.speedKn)
            // Long enough to be believed, and the rest of the run only makes
            // the peak better — keep reading until it drops.
        }
        let qualified = run >= sustainedHours
        return Promise(now: rows.first,
                       arrives: qualified ? start : nil,
                       peakKn: qualified ? peak : 0)
    }

    /// Whether this slide's promise is close enough to be the loud line.
    private func isFiringSoon(_ slide: Slide) -> Bool {
        guard let arrives = promises[slide.id]?.arrives else { return false }
        return arrives.timeIntervalSinceNow < 48 * 3600
    }

    /// The line the whole screen exists for.
    private func headline(for slide: Slide) -> String {
        guard let promise = promises[slide.id] else {
            return hasAsked ? "No model wind for this spot" : "Reading the models…"
        }
        guard let arrives = promise.arrives else {
            return "Nothing over 15 kn in the next \(Self.horizonDays) days"
        }
        let peak = units.windLabel(promise.peakKn)
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: .now),
                                           to: calendar.startOfDay(for: arrives)).day ?? 0
        // Already blowing: the run starts at the hour the series starts at,
        // which is this one.
        if days == 0, arrives.timeIntervalSinceNow < 3600 {
            return "It's on right now — up to \(peak)"
        }
        let time = arrives.formatted(.dateTime.hour())
        switch days {
        case 0: return "Good wind later today, from \(time) — up to \(peak)"
        case 1: return "Good wind tomorrow, from \(time) — up to \(peak)"
        default:
            let day = arrives.formatted(.dateTime.weekday(.wide))
            return "Good wind in \(days) days — \(day) from \(time), up to \(peak)"
        }
    }
}

// MARK: - Before there is anything to cycle

private struct NothingToShow: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "star")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text("No spots saved yet")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(.white)
            Text("Star the launches you actually go to on the Favourites tab.\nThis cycles their maps and tells you when the wind is next on.")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(60)
    }
}
