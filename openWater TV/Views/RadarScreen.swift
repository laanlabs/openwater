import CoreImage
import CoreImage.CIFilterBuiltins
import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// Radar over the map, and two hours of it running.
///
/// The phone's radar screen, on the television's own terms. Same providers,
/// same tiles, same overlay — all of that moved into `OpenWaterSpots` so the
/// two apps cannot drift — and what differs is the input and the framing.
///
/// **It opens where the map tab is.** A rider who has just moved the wind map
/// to Montauk and pressed across to Radar means Montauk; asking them to drive
/// a second map to the same place would be the app forgetting something it was
/// told ten seconds ago. `TVLocation.mapRegion` carries the wind map's own
/// camera across, span included, so this opens at the same zoom.
///
/// **The loop is the reason this screen exists on a television.** A still
/// radar image answers "is it raining", which the weather screen already
/// answers better. Two hours of frames running answers "is it coming here",
/// which nothing else in the app does — and it is exactly the sort of thing a
/// big screen across a room is good at and a phone is not.
struct RadarScreen: View {

    /// Whether the radar tab is the one on screen. The frame images are tens
    /// of megabytes, and a `TabView` keeps every tab alive — so this frees
    /// them the moment the tab is left, the way the wind map sleeps its wash.
    let isActive: Bool

    @Environment(TVLocation.self) private var location

    @State private var frames: [RainViewerFrame] = []
    @State private var index = 0
    /// Paused, on the newest frame.
    ///
    /// It used to open playing, and that was wrong twice over. A loop nobody
    /// asked for is the first thing on screen flickering; and more to the
    /// point the question this tab answers first is "is it raining now",
    /// which is one frame, not thirteen. The loop answers the *second*
    /// question — is it coming here — and that is worth pressing for.
    @State private var isPlaying = false
    /// Fraction of the loop's tiles already in the cache, 0–1.
    /// How much of the loop has been rendered to images, 0–1. The map view
    /// reports it; the Play button reads it.
    @State private var loaded: Double = 0
    @State private var product: RadarProduct = .base
    @State private var isGlobal = true
    /// Whether the overlay-type choices are showing in place of the main bar.
    @State private var showingLayers = false

    /// The forecast in place of the radar: model rain over the next twelve
    /// hours, drawn by the wind map's own wash with a rain field in it.
    ///
    /// This is what weather.gov and weather.com call "future radar", and
    /// what it actually is — a model's precipitation in radar colours. The
    /// observed loop answers "is it coming here" for the next hour or two
    /// by extrapolating the eye; this answers it for the afternoon, and
    /// says plainly in its caption that it is a model saying so.
    @State private var isForecast = false
    @State private var wash = WindWashModel()
    /// Which forecast step is showing — an index into `hrrrFrames` over the
    /// US, into `forecastOffsets` under the model wash elsewhere.
    @State private var forecastStep = 0
    @State private var camera: MapCameraPosition = .automatic
    @State private var mapWidth: CGFloat = 1920
    @Environment(\.displayScale) private var displayScale

    /// The HRRR's own radar pictures for the steps below, when the map is
    /// over the continental US — see `HRRRReflectivity`. Empty elsewhere, and
    /// while they are being fetched.
    @State private var hrrrFrames: [HRRRReflectivity.Frame] = []

    /// The instants the forecast steps through, as seconds ahead of now.
    ///
    /// Every quarter hour for two hours. The question this layer exists to
    /// answer is whether that shower reaches the beach before the session
    /// does, and two hours is the span a rider standing in the kitchen is
    /// actually deciding over; the model publishes at fifteen minutes, so
    /// fifteen minutes is the step. It used to run to eight hours with
    /// hourly frames on the end, which made the loop long, the memory heavy
    /// and the far end a shape the model was guessing at. The weather
    /// screen's day rows carry the rest.
    private static let forecastOffsets: [TimeInterval] = (0 ... 8).map { Double($0) * 900 }
    /// A forecast step lingers longer than a radar frame: thirteen frames
    /// of the same storm read as motion at a third of a second, but each
    /// forecast step is a different picture and wants to be read. The last
    /// one is held longer still, the way every radar loop pauses on its
    /// end frame so the eye can catch up before it jumps back.
    private static let forecastInterval: Duration = .milliseconds(1100)
    private static let forecastHold: Duration = .milliseconds(1800)

    /// How long the image map has to carry one frame into the next — the
    /// whole interval, so the motion between two forecast steps is drawn
    /// as travel rather than shown as a cut. Nil while paused.
    private var frameAnimation: TimeInterval? {
        guard isPlaying else { return nil }
        if isForecast { return 1.1 }
        return showsFuture ? Self.combinedInterval : Self.frameInterval
    }

    /// Whether the observed loop runs on into the forecast.
    ///
    /// The main screen is the radar — what the sky has actually done for the
    /// last two hours — and this is the one checkbox on it: keep going. With
    /// it on, the loop plays the observed frames and then the model's next
    /// two hours in the same picture, so "is it coming here" is answered by
    /// watching the cells cross the line between what was seen and what is
    /// expected. Remembered, because a rider who wants the future on a
    /// Tuesday wants it on Wednesday.
    @AppStorage("tv.radar.future") private var showsFuture = false

    /// Whether the forecast frames can be had for this coast at all.
    private var futureAvailable: Bool { HRRRReflectivity.covers(regionCentre) }

    /// The observed loop, and the forecast after it when asked for.
    private var loopFrames: [RadarFrame] {
        let observed = frames.map { RadarFrame.tiles(.rainViewer(frame: $0)) }
        guard showsFuture else { return observed }
        return observed + hrrrFrames.map(RadarFrame.hrrr)
    }

    @FocusState private var focus: Control?
    @Namespace private var bar

    private enum Control: Hashable { case play, step, future, more, back, optGlobal, optForecast, optProduct }

    /// How fast the loop runs. Slower than real time by a long way: thirteen
    /// frames covering two hours at three a second reads as weather moving,
    /// where anything quicker reads as a flicker.
    private static let frameInterval: TimeInterval = 0.32
    /// The pace when the loop runs on into the forecast: one pace for both
    /// halves, so the join is a change of caption and not of rhythm, and
    /// slow enough for the motion between frames to be drawn as travel.
    private static let combinedInterval: TimeInterval = 0.55
    private static let combinedHold: TimeInterval = 1.6

    var body: some View {
        Group {
            if location.here == nil {
                Unavailable(text: "Open the Map tab and say where you are. Radar follows it.")
            } else {
                radar
            }
        }
        .task {
            frames = await RainViewer.frames()
            // Open on the newest observation, not the oldest. `frames` is
            // ordered past → nowcast, so index 0 is two hours ago — which is
            // not what "is it raining" means.
            index = max(0, latestObservation)
        }
        // The loop is a task rather than a timer: it dies with the view, so a
        // tab left behind is not animating tiles at somebody's router.
        .onChange(of: isActive) { _, active in
            // Leaving the tab stops the clock — the loop is a task that would
            // otherwise keep advancing frames at somebody's router — and the
            // map view frees its images. The wash sleeps with it, the way
            // the wind map's does.
            if !active {
                isPlaying = false
                wash.sleep()
            } else if isForecast {
                wash.wake()
            }
        }
        .onChange(of: isForecast) { _, forecast in
            // The forecast opens playing. The observed loop opens paused
            // because "is it raining now" is one frame; the forecast has no
            // such frame — its whole answer is the motion, and a rider who
            // chose it chose to watch it. The frames arrive over a few
            // seconds and the loop simply catches them as they land.
            isPlaying = forecast
            forecastStep = 0
            if forecast, usesModelWash {
                wash.wake()
            } else {
                // The field is a few megabytes of bitmap the radar loop has
                // no use for, and the loop's own images are about to come
                // back.
                wash.sleep()
                wash.clear()
            }
        }
        // The model's radar pictures, for wherever they exist. Re-asked when
        // the forecast is opened, so a run that landed while the loop was
        // showing is picked up; the cache behind it makes a re-ask cheap.
        .task(id: wantsForecastFrames) {
            guard wantsForecastFrames else {
                hrrrFrames = []
                return
            }
            hrrrFrames = await HRRRReflectivity.frames(aheadOfNow: Self.forecastOffsets)
        }
        // Switching the future off can leave the index in the half that
        // just vanished.
        .onChange(of: showsFuture) { _, _ in
            index = min(index, max(0, loopFrames.count - 1))
        }
        .task(id: isPlaying) {
            guard isPlaying, isActive else { return }
            while !Task.isCancelled {
                if isForecast {
                    let last = forecastCount > 0 && forecastStep == forecastCount - 1
                    try? await Task.sleep(for: last ? Self.forecastHold : Self.forecastInterval)
                    guard !Task.isCancelled, forecastCount > 0 else { continue }
                    forecastStep = (forecastStep + 1) % forecastCount
                } else {
                    let count = loopFrames.count
                    let last = count > 0 && index == count - 1
                    let pace = showsFuture ? (last ? Self.combinedHold : Self.combinedInterval)
                                           : Self.frameInterval
                    try? await Task.sleep(for: .seconds(pace))
                    guard !Task.isCancelled, count > 0 else { continue }
                    index = (index + 1) % count
                }
            }
        }
        // The forecast's clock. Step zero is now — the wash's own default —
        // and every other step is a re-render from the rows already fetched,
        // never a request.
        .task(id: forecastStep) {
            guard isForecast, usesModelWash, Self.forecastOffsets.indices.contains(forecastStep) else { return }
            wash.scrub(to: forecastStep == 0 ? nil
                       : Date().addingTimeInterval(Self.forecastOffsets[forecastStep]))
        }
    }

    /// Where the forecast is being asked about — the map's centre.
    private var regionCentre: Geo.Coordinate {
        Geo.Coordinate(latitude: region.center.latitude, longitude: region.center.longitude)
    }

    /// The forecast outside the HRRR's box — the rest of the world — is the
    /// wash's model rain. Inside it, the model's own radar pictures.
    private var usesModelWash: Bool {
        isForecast && !HRRRReflectivity.covers(regionCentre)
    }

    /// Whether the HRRR pictures are wanted at all: for the forecast-only
    /// loop, or for the observed loop running on into the future.
    private var wantsForecastFrames: Bool {
        futureAvailable && (isForecast || (isGlobal && showsFuture))
    }

    /// How many steps the forecast has: one per HRRR picture, or one per
    /// offset under the wash.
    private var forecastCount: Int {
        usesModelWash ? Self.forecastOffsets.count : hrrrFrames.count
    }

    /// Everything the image map should hold, in the loop's order.
    private var displayFrames: [RadarFrame] {
        if isForecast {
            return usesModelWash ? [] : hrrrFrames.map(RadarFrame.hrrr)
        }
        if isGlobal, !frames.isEmpty { return loopFrames }
        return sources.map(RadarFrame.tiles)
    }

    private var radar: some View {
        ZStack(alignment: .bottom) {
            if usesModelWash {
                forecastMap
                    .ignoresSafeArea()
            } else {
                RadarImageMap(region: region, frames: displayFrames,
                              index: shownIndex, animation: frameAnimation,
                              isActive: isActive, loaded: $loaded)
                    .ignoresSafeArea()
            }
            controls
                .padding(.bottom, 40)
        }
        .overlay(alignment: .top) { caption }
    }

    /// The wind map's own rectangle, so the two tabs agree about where you
    /// are looking. Falls back to a sensible box around the chosen place for
    /// the case where Radar is opened before the map has ever settled.
    private var region: MKCoordinateRegion {
        if let carried = location.mapRegion { return carried }
        let here = location.here ?? Geo.Coordinate(latitude: 0, longitude: 0)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude),
            span: MKCoordinateSpan(latitudeDelta: 3.5, longitudeDelta: 3.5))
    }

    /// Which layer is on screen.
    ///
    /// RainViewer is the one with a past, so it is the default and the only
    /// one the loop means anything for. NOAA's mosaic is a single current
    /// frame at four times the resolution, and is worth having for the same
    /// reason the phone keeps it: over the US it is simply a better picture.
    /// Every layer the map should be holding, not just the one on show.
    ///
    /// All of them go on the map together and the loop switches between them
    /// by opacity. Swapping one overlay for another per frame — which is what
    /// this did — leaves the map bare for however long MapKit takes to draw
    /// the replacement, and that gap *is* the flash: it is not a download,
    /// which is why warming the cache did not cure it. Thirteen tile overlays
    /// is a few megabytes of PNG that were being fetched anyway.
    private var sources: [RadarSource] {
        if isGlobal, !frames.isEmpty {
            return frames.map { .rainViewer(frame: $0) }
        }
        let here = location.here ?? Geo.Coordinate(latitude: 40, longitude: -74)
        return [.noaa(region: RadarRegion.covering(here), product: product)]
    }

    /// Which of them is visible. Always zero for the single NOAA still.
    private var shownIndex: Int {
        if isForecast { return min(forecastStep, max(0, hrrrFrames.count - 1)) }
        return isGlobal ? min(index, max(0, loopFrames.count - 1)) : 0
    }

    /// The frame the observed loop is on, when it is on one.
    private var loopFrame: RadarFrame? {
        guard isGlobal, !isForecast, loopFrames.indices.contains(shownIndex) else { return nil }
        return loopFrames[shownIndex]
    }

    /// The one the caption is describing.
    private var source: RadarSource {
        sources.indices.contains(shownIndex) ? sources[shownIndex] : sources[0]
    }

    /// The newest observation, ignoring the nowcast frames that follow it.
    /// "Now" on this screen means the last thing the radar actually saw.
    private var latestObservation: Int {
        frames.lastIndex { !$0.isForecast } ?? max(0, frames.count - 1)
    }

    private var building: Bool {
        if usesModelWash { return wash.isBusy && wash.raster == nil }
        if isForecast { return hrrrFrames.isEmpty || loaded < 1 }
        return isGlobal && loaded < 1
    }

    private var playLabel: String {
        if isForecast {
            if usesModelWash, building { return "Getting the rain" }
            if building { return hrrrFrames.isEmpty ? "Getting the forecast" : "Loading \(Int(loaded * 100))%" }
            return isPlaying ? "Pause" : "Play 2 hours"
        }
        if building { return "Loading \(Int(loaded * 100))%" }
        return isPlaying ? "Pause" : "Play loop"
    }

    /// Whether Play and Step mean anything on the layer showing: the radar
    /// loop and the forecast both have a clock, a NOAA still does not.
    private var hasClock: Bool { isGlobal || isForecast }

    private func togglePlay() {
        // The frames are rendered to images by the map view as they arrive;
        // this only starts and stops the clock. Disabled until they are in.
        isPlaying.toggle()
    }

    private var caption: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 14) {
                if isForecast {
                    // The clock leads here too, and says how far ahead it is
                    // — "+3 h" is the number a rider is actually asking for.
                    Text(forecastLabel)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("FORECAST")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(Color.accentColor)
                    Text(forecastAttribution)
                        .font(.system(size: 20))
                        .foregroundStyle(usesModelWash && wash.loadFailed ? .orange : .secondary)
                } else if case .hrrr(let ahead)? = loopFrame {
                    // The loop has crossed from what was seen into what is
                    // expected. Same capsule, same clock, and the word that
                    // marks the crossing — so the join is visible without
                    // the picture having to change its manners.
                    Text(aheadLabel(for: ahead))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("FORECAST")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(Color.accentColor)
                    Text(forecastAttribution)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                } else if isGlobal, frames.indices.contains(shownIndex) {
                    // The clock is the point of a loop. Without it a rider
                    // cannot tell the newest frame from the oldest, and a
                    // two-hour-old sweep read as current is worse than none.
                    Text(frames[shownIndex].time, format: .dateTime.hour().minute())
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if frames[shownIndex].isForecast {
                        Text("NOWCAST")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(source.attribution)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                } else if !isForecast {
                    Text(source.attribution)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())

            if isForecast || (showsFuture && isGlobal && !hrrrFrames.isEmpty) { rainLegend }
        }
        .padding(.top, 30)
        .padding(.trailing, 60)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var controls: some View {
        Group {
            if showingLayers { layerBar } else { mainBar }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 18)
        .background(.thinMaterial, in: Capsule())
        .focusSection()
        .focusScope(bar)
        // Menu backs out of the overlay picker rather than leaving the tab —
        // and only then, so on the main bar Menu still does whatever tvOS
        // does with a tab. The `nil` handler is what lets it pass through.
        .onExitCommand(perform: showingLayers ? { showingLayers = false; focus = .more } : nil)
    }

    /// Play, step, and the door to everything else.
    ///
    /// The bar used to carry the loop *and* the coverage toggle *and* four
    /// NOAA products in one row — six things, most of them about which
    /// overlay to draw rather than about playing it. Those moved behind
    /// "More options", so the bar a rider sees first is just: is it playing,
    /// step it, or change what it shows.
    private var mainBar: some View {
        HStack(spacing: 22) {
            // Play and Step belong to the loop, so they only appear when the
            // loop is what is showing. On a NOAA still there is nothing to
            // play — the bar named the current layer with a dead "Play loop"
            // beside it, which is the confusing state that was reported — so
            // a still just names itself and leaves the loop's controls out.
            if hasClock {
                RadarButton(title: playLabel,
                            systemImage: isPlaying ? "pause.fill" : "play.fill",
                            isOn: isPlaying) { togglePlay() }
                    .focused($focus, equals: .play)
                    .prefersDefaultFocus(hasClock, in: bar)
                    .disabled(isForecast ? (building || (usesModelWash && wash.loadFailed))
                                         : (frames.isEmpty || building))

                if isForecast || !frames.isEmpty {
                    // Pausing and stepping is the whole of scrubbing on a
                    // remote — a slider would need the D-pad this has not got.
                    // On the forecast a step is a quarter hour near now and
                    // an hour further out — see `forecastOffsets`.
                    RadarButton(title: isForecast ? "Step ahead" : "Step",
                                systemImage: "forward.frame.fill") {
                        isPlaying = false
                        if isForecast {
                            if forecastCount > 0 { forecastStep = (forecastStep + 1) % forecastCount }
                        } else if !loopFrames.isEmpty {
                            index = (index + 1) % loopFrames.count
                        }
                    }
                    .focused($focus, equals: .step)
                    .disabled(isForecast && (forecastCount == 0 || (usesModelWash && wash.loadFailed)))
                }

                // The one checkbox on the radar: let the loop run on into
                // the model's next two hours. Only where the model's
                // pictures exist; elsewhere the forecast is the wash, one
                // door further in.
                if isGlobal, !isForecast {
                    RadarButton(title: "Show future",
                                systemImage: showsFuture ? "checkmark.square.fill" : "square",
                                isOn: showsFuture) {
                        showsFuture.toggle()
                    }
                    .focused($focus, equals: .future)
                    .disabled(!futureAvailable)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "flag.fill")
                    Text("NOAA · \(product.label)")
                }
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            }

            Divider().frame(height: 44)

            RadarButton(title: "More options", systemImage: "slider.horizontal.3") {
                showingLayers = true
                focus = .back
            }
            .focused($focus, equals: .more)
            .prefersDefaultFocus(!hasClock, in: bar)
        }
    }

    /// The overlay picker, with the way back at its head.
    ///
    /// Global loop is RainViewer — the one with a past to animate — and the
    /// four NOAA layers are single current stills of things RainViewer does
    /// not publish: storm cores, tops, precipitation type. Back returns to
    /// the main bar; so does Menu.
    private var layerBar: some View {
        HStack(spacing: 18) {
            RadarButton(title: "Back", systemImage: "chevron.backward") {
                showingLayers = false
                focus = .more
            }
            .focused($focus, equals: .back)
            .prefersDefaultFocus(in: bar)

            Divider().frame(height: 44)

            // Choosing a layer closes the picker and puts the remote on the
            // control that matters for it. The picker used to stay open,
            // which left a rider who had just chosen the forecast looking at
            // a row of layer names with no Play in sight — the loop was one
            // Back press away and nothing said so.
            RadarButton(title: "Global loop", systemImage: "globe", isOn: isGlobal && !isForecast) {
                isForecast = false
                isGlobal = true
                showingLayers = false
                focus = .play
            }
            .focused($focus, equals: .optGlobal)

            // What is *coming*, beside what was seen. The one layer here that
            // is not an observation, which is why its caption says so.
            RadarButton(title: "Rain forecast", systemImage: "cloud.rain", isOn: isForecast) {
                isForecast = true
                showingLayers = false
                focus = .play
            }
            .focused($focus, equals: .optForecast)

            ForEach(RadarProduct.allCases, id: \.self) { option in
                RadarButton(title: option.label,
                            systemImage: "square.stack.3d.down.right",
                            isOn: !isGlobal && !isForecast && option == product) {
                    isForecast = false
                    isGlobal = false
                    isPlaying = false
                    product = option
                    showingLayers = false
                    focus = .more
                }
                .focused($focus, equals: .optProduct)
            }
        }
    }

    // MARK: - The forecast

    /// The wind map's own construction — a `Map` with the wash as one image
    /// over it — pointed at the radar's rectangle and told to draw rain.
    ///
    /// Not the `RadarImageMap` below: that one composites tiles somebody
    /// else rendered, where this asks the model for a field and paints it,
    /// which is exactly what `WindWashModel` and `WashRasterLayer` already
    /// do for the wind. No comets: rain has no direction the wash can use,
    /// and the field carries no vectors to stream through.
    private var forecastMap: some View {
        // Read here, not inside the map's builder — see the wind map for why
        // a read inside the builder registers no observation.
        let raster = wash.raster
        return MapReader { proxy in
            Map(position: $camera, interactionModes: [])
                .focusable(false)
                .mapStyle(.standard(elevation: .flat, emphasis: .muted,
                                    pointsOfInterest: .excludingAll))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    mapWidth = width
                    wash.mapMeasured(widthPoints: width, displayScale: displayScale,
                                     visible: region)
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    wash.viewSettled(on: context.region, layer: .rain,
                                     widthPoints: mapWidth, displayScale: displayScale)
                }
                .overlay {
                    if let raster {
                        WashRasterLayer(raster: raster, proxy: proxy)
                            .allowsHitTesting(false)
                    }
                }
        }
        .onAppear { camera = .region(region) }
        // The wind map moved while this tab was away: follow it, the way the
        // radar images do by rebuilding.
        .onChange(of: regionKey) { _, _ in camera = .region(region) }
    }

    private var regionKey: String {
        String(format: "%.3f,%.3f,%.3f", region.center.latitude,
               region.center.longitude, region.span.latitudeDelta)
    }

    /// What the forecast frames are and where they came from, for the
    /// caption. The HRRR line names the run, because a picture from a run
    /// three hours old is a different promise from one that just landed.
    private var forecastAttribution: String {
        if usesModelWash {
            return wash.loadFailed ? "Rain forecast didn't load" : (WashLayer.rain.caption ?? "")
        }
        guard let run = hrrrFrames.first?.runAt else { return "HRRR model radar · NOAA via Iowa State Mesonet" }
        return "HRRR model radar, \(run.formatted(.dateTime.hour())) run · NOAA via Iowa State Mesonet — not an observation"
    }

    /// A model frame's clock: how far ahead it is, and when that is.
    private func aheadLabel(for frame: HRRRReflectivity.Frame) -> String {
        let ahead = frame.validAt.timeIntervalSinceNow
        let clock = frame.validAt.formatted(.dateTime.hour().minute())
        if ahead < 5 * 60 { return "Now · \(clock)" }
        let minutes = Int((ahead / 60).rounded())
        if minutes < 60 { return "+\(minutes) min · \(clock)" }
        let rest = minutes % 60
        return rest == 0 ? "+\(minutes / 60) h · \(clock)" : "+\(minutes / 60) h \(rest) min · \(clock)"
    }

    /// "Now", "+45 min · 7:15 PM", or "+4 h · 8 PM".
    ///
    /// Under the HRRR the clock is the frame's own valid time — a run that
    /// began at three shows four o'clock's picture as "+1 h · 4 PM" whatever
    /// the minute is now, which is the honest reading of a model step. Under
    /// the wash the offsets are relative to now.
    private var forecastLabel: String {
        if !usesModelWash {
            guard hrrrFrames.indices.contains(shownIndex) else { return "…" }
            return aheadLabel(for: hrrrFrames[shownIndex])
        }
        guard forecastStep > 0, Self.forecastOffsets.indices.contains(forecastStep) else { return "Now" }
        let ahead = Self.forecastOffsets[forecastStep]
        let at = Date().addingTimeInterval(ahead)
        if ahead < 3600 {
            return "+\(Int(ahead / 60)) min · \(at.formatted(.dateTime.hour().minute()))"
        }
        let wholeHours = Int(ahead) / 3600
        let minutes = (Int(ahead) % 3600) / 60
        let lead = minutes == 0 ? "+\(wholeHours) h" : "+\(wholeHours) h \(minutes) min"
        let clock = minutes == 0
            ? at.formatted(.dateTime.hour())
            : at.formatted(.dateTime.hour().minute())
        return "\(lead) · \(clock)"
    }

    /// What the colours mean, in three words. The sentence about what this
    /// layer is lives in the caption above it, once.
    ///
    /// Two palettes, because the two forecasts are drawn in two languages:
    /// the wash in this app's own rain ramp, the HRRR pictures in the
    /// weather service's reflectivity colours — green for rain, yellow for
    /// heavy, red for a storm core — which are the server's, not ours.
    private var rainLegend: some View {
        let swatches: [(String, Color)] = usesModelWash
            ? [("Light", Color(uiColor: RainPalette.colour(for: 0.3))),
               ("Moderate", Color(uiColor: RainPalette.colour(for: 2.0))),
               ("Heavy", Color(uiColor: RainPalette.colour(for: 7.0)))]
            : [("Light", Color(red: 0.01, green: 0.99, blue: 0.01)),
               ("Heavy", Color(red: 0.99, green: 0.97, blue: 0.01)),
               ("Storm", Color(red: 0.99, green: 0.0, blue: 0.0))]
        return HStack(spacing: 18) {
            ForEach(swatches, id: \.0) { name, colour in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(colour)
                        .frame(width: 28, height: 16)
                    Text(name)
                }
            }
        }
        .font(.system(size: 19, weight: .medium))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
    }
}

// MARK: - The map underneath

/// A muted base map with the radar painted over it as a flat image.
///
/// Not a tile overlay. Every earlier attempt animated `MKTileOverlay`s —
/// swapping them, cross-fading them, mutating them — and every one flickered,
/// because MapKit re-composites a tile overlay's whole geometry each time it
/// changes and does it on its own schedule. A radar loop cannot be smooth on
/// top of that.
///
/// So each frame is rendered *once* into a single `UIImage` the size of the
/// map, geo-registered by asking the map where each tile's rectangle lands,
/// and the loop is a `UIImageView` swapping its `image`. That is a pointer
/// assignment the GPU draws in one frame — no tiling, no re-composite, no
/// flicker. The map does not pan while looping, so one alignment holds for
/// every frame; a change of place or zoom rebuilds the set.
/// One picture in the loop: a set of slippy tiles from a radar service, or a
/// single georeferenced image from the HRRR. Both end up as one map-sized
/// bitmap; they differ only in how the bitmap is composed.
private enum RadarFrame: Hashable {
    case tiles(RadarSource)
    case hrrr(HRRRReflectivity.Frame)

    var stamp: String {
        switch self {
        case .tiles(let source):
            if case .rainViewer(let frame) = source { return frame.id }
            if case .noaa(let region, let product) = source {
                return "noaa-\(region.rawValue)-\(product.rawValue)"
            }
            return "noaa"
        case .hrrr(let frame):
            return frame.id
        }
    }
}

/// Where a latitude and longitude land on the glass, as two constants each,
/// captured on the main thread so a render off it can place a picture.
///
/// Longitude is linear on a Mercator map. Latitude is not — it is linear in
/// `ln(tan(π/4 + φ/2))` — and an equirectangular picture stretched straight
/// onto the map would put a shower off by a few kilometres at the edges of a
/// regional view. So the HRRR image is drawn in latitude strips, each placed
/// through this.
private struct GeoPlacement: Sendable {
    let x0: Double, kx: Double, lon0: Double
    let y0: Double, ky: Double, merc0: Double

    static func merc(_ latitude: Double) -> Double {
        let clamped = min(max(latitude, -85), 85) * .pi / 180
        return log(tan(.pi / 4 + clamped / 2))
    }

    func x(of longitude: Double) -> CGFloat { CGFloat(x0 + (longitude - lon0) * kx) }
    func y(of latitude: Double) -> CGFloat { CGFloat(y0 + (Self.merc(latitude) - merc0) * ky) }
}

private struct RadarImageMap: UIViewRepresentable {

    let region: MKCoordinateRegion
    let frames: [RadarFrame]
    let index: Int
    /// How long a change of frame has to play out, or nil to cut. See
    /// `Coordinator.show`.
    let animation: TimeInterval?
    let isActive: Bool
    @Binding var loaded: Double

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        map.isUserInteractionEnabled = false
        map.setRegion(region, animated: false)
        context.coordinator.loaded = $loaded
        context.coordinator.attach(to: map)
        context.coordinator.update(frames: frames, index: index, animation: animation,
                                   region: region, active: isActive, to: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.loaded = $loaded
        context.coordinator.update(frames: frames, index: index, animation: animation,
                                   region: region, active: isActive, to: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {

        /// The radar, as one flat picture over the base map.
        private let radarView = UIImageView()
        /// The frame arriving, while a change of frame is being drawn as
        /// motion — see `show`. Empty and invisible the rest of the time.
        private let arrivingView = UIImageView()
        /// One rendered image per frame, keyed by the frame's own stamp.
        private var images: [String: UIImage] = [:]
        /// How far the echoes moved from one frame to the next, in points,
        /// keyed "from>to". Measured from the rendered pictures once both
        /// exist — see `estimateMotion`.
        private var motion: [String: CGVector] = [:]
        /// Which frame is on the glass, so a change can be told apart from
        /// a repeat and a step forward from a jump.
        private var shownStamp: String?
        private var shownIndex: Int?
        /// What the current image set was built for — frames plus the exact
        /// rectangle. A new signature means a rebuild.
        private var signature = ""
        private var buildTask: Task<Void, Never>?
        var loaded: Binding<Double>?

        /// The last thing SwiftUI asked for, kept so the map's own callbacks
        /// can finish a render the view was too young for — see `update`.
        private var latest: (frames: [RadarFrame], index: Int, animation: TimeInterval?, region: MKCoordinateRegion)?

        /// How strongly the sweep sits over the chart.
        private static let strength: CGFloat = 0.78

        func attach(to map: MKMapView) {
            for view in [radarView, arrivingView] {
                view.contentMode = .scaleToFill
                view.isUserInteractionEnabled = false
                view.frame = map.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                map.addSubview(view)
            }
            radarView.alpha = Self.strength
            arrivingView.alpha = 0
            map.delegate = self
        }

        deinit { buildTask?.cancel() }

        func update(frames: [RadarFrame], index: Int, animation: TimeInterval?,
                    region: MKCoordinateRegion, active: Bool, to map: MKMapView) {
            guard active else { return free() }
            latest = (frames, index, animation, region)
            let sig = Self.signature(of: frames, region: region)
            if sig != signature {
                // A map with no size yet cannot be rendered into, and the
                // signature is only claimed once it has been. This was the
                // "Rain shows nothing after Rain forecast" bug: leaving the
                // forecast creates this view afresh, `makeUIView` asked for
                // a render before layout, the tiles were composed into zero
                // points, and — signature claimed — nothing ever asked
                // again. Switching to Cores and back only worked because it
                // changed the signature. Now the first render waits for the
                // map's own region callback below.
                if rebuild(frames: frames, region: region, map: map) {
                    signature = sig
                }
            }
            show(frames: frames, index: index, over: animation)
        }

        /// The map has a size, or a new one: if a render is owed, do it now.
        private func retryIfOwed(_ map: MKMapView) {
            guard signature.isEmpty, let latest, map.bounds.width > 0 else { return }
            update(frames: latest.frames, index: latest.index, animation: latest.animation,
                   region: latest.region, active: true, to: map)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            retryIfOwed(mapView)
        }

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            retryIfOwed(mapView)
        }

        /// Drop everything the tab was holding. The signature is cleared too,
        /// so returning to the tab rebuilds from scratch rather than showing
        /// nothing.
        private func free() {
            guard !images.isEmpty || buildTask != nil else { return }
            buildTask?.cancel()
            buildTask = nil
            images = [:]
            motion = [:]
            settle()
            radarView.image = nil
            shownStamp = nil
            shownIndex = nil
            signature = ""
            loaded?.wrappedValue = 0
        }

        /// Put a frame on the glass.
        ///
        /// Three ways, by what the change is:
        ///
        /// - **The next frame, while playing, with its motion known:** the
        ///   frame on screen slides along the vector the echoes were measured
        ///   to have moved while fading out, and the new frame slides in from
        ///   behind that same vector while fading up, over the whole interval
        ///   until the frame after. The eye reads this as the cells
        ///   travelling — which is the point of a loop: not nine pictures but
        ///   where the rain is going. It is the trick every weather app's
        ///   future radar plays, done here with two image views and a
        ///   transform, so it costs nothing the loop was not already paying.
        /// - **Any other change while playing, or a step by hand:** a short
        ///   cross-dissolve. A jump from the last frame back to the first is
        ///   not motion and must not be drawn as some.
        /// - **The same frame again:** nothing.
        private func show(frames: [RadarFrame], index: Int, over duration: TimeInterval?) {
            guard frames.indices.contains(index) else { return }
            let stamp = frames[index].stamp
            guard let image = images[stamp], stamp != shownStamp else { return }

            let from = shownStamp
            let steppedForward = shownIndex.map { $0 + 1 == index } ?? false
            settle()

            if let duration, steppedForward, let from,
               let vector = motion["\(from)>\(stamp)"], hypot(vector.dx, vector.dy) > 0.5 {
                arrivingView.image = image
                arrivingView.transform = CGAffineTransform(translationX: -vector.dx, y: -vector.dy)
                arrivingView.alpha = 0
                UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
                    self.radarView.transform = CGAffineTransform(translationX: vector.dx, y: vector.dy)
                    self.radarView.alpha = 0
                    self.arrivingView.transform = .identity
                    self.arrivingView.alpha = Self.strength
                } completion: { finished in
                    // Hand the arrived picture to the resting view whether or
                    // not the animation ran its course: a new frame may have
                    // cut in, and it will have settled us already.
                    guard finished, self.arrivingView.image === image else { return }
                    self.settle()
                    self.radarView.image = image
                }
            } else {
                UIView.transition(with: radarView, duration: 0.22,
                                  options: [.transitionCrossDissolve, .beginFromCurrentState]) {
                    self.radarView.image = image
                }
            }
            shownStamp = stamp
            shownIndex = index
        }

        /// Both views at rest: whatever is arriving is now simply shown, and
        /// nothing is mid-flight. Safe to call at any moment.
        private func settle() {
            radarView.layer.removeAllAnimations()
            arrivingView.layer.removeAllAnimations()
            if let arrived = arrivingView.image, arrivingView.alpha > 0 {
                radarView.image = arrived
            }
            radarView.transform = .identity
            radarView.alpha = Self.strength
            arrivingView.transform = .identity
            arrivingView.alpha = 0
            arrivingView.image = nil
        }

        /// Start rendering the set. False when the map has no size yet and
        /// nothing could be drawn — the caller leaves the signature unclaimed
        /// so a later pass tries again.
        @discardableResult
        private func rebuild(frames: [RadarFrame], region: MKCoordinateRegion, map: MKMapView) -> Bool {
            buildTask?.cancel()
            images = [:]
            loaded?.wrappedValue = 0

            map.setRegion(region, animated: false)
            map.layoutIfNeeded()
            let size = map.bounds.size
            guard size.width > 0 else { return false }
            guard !frames.isEmpty else { loaded?.wrappedValue = 1; return true }

            // The region the map *actually* shows, not the one it was asked
            // for. MapKit fits the requested region into a 16:9 view, which
            // makes the shown area wider in longitude — and tiles computed
            // from the narrower request left the ocean side of the map bare,
            // with a hard edge where the tiles stopped.
            let visible = map.region
            let zoom = Self.renderZoom(for: visible)
            let tiles = RadarTiles.tiles(covering: visible, zoom: zoom)
            // Where each tile's square lands on the glass — computed once,
            // on the main thread, because it is the same for every frame.
            let placements: [(x: Int, y: Int, rect: CGRect)] = tiles.map { tile in
                // The tile's north-west and south-east corners as screen
                // points. On a Mercator map a tile's square projects to an
                // axis-aligned rectangle, so two corners define it exactly.
                let nw = Self.corner(x: tile.x, y: tile.y, z: zoom)
                let se = Self.corner(x: tile.x + 1, y: tile.y + 1, z: zoom)
                let p1 = map.convert(nw, toPointTo: map)
                let p2 = map.convert(se, toPointTo: map)
                let rect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                  width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
                return (tile.x, tile.y, rect)
            }
            guard !placements.isEmpty else { loaded?.wrappedValue = 1; return true }

            // The same question for a whole picture: two points each way,
            // asked of the map here, so the render can place any latitude
            // and longitude without coming back to the main thread.
            let centre = visible.center
            let west = CLLocationCoordinate2D(latitude: centre.latitude,
                                              longitude: centre.longitude - visible.span.longitudeDelta / 2)
            let east = CLLocationCoordinate2D(latitude: centre.latitude,
                                              longitude: centre.longitude + visible.span.longitudeDelta / 2)
            let north = CLLocationCoordinate2D(latitude: centre.latitude + visible.span.latitudeDelta / 2,
                                               longitude: centre.longitude)
            let south = CLLocationCoordinate2D(latitude: centre.latitude - visible.span.latitudeDelta / 2,
                                               longitude: centre.longitude)
            let pw = map.convert(west, toPointTo: map), pe = map.convert(east, toPointTo: map)
            let pn = map.convert(north, toPointTo: map), ps = map.convert(south, toPointTo: map)
            let geo = GeoPlacement(
                x0: pw.x, kx: (pe.x - pw.x) / (east.longitude - west.longitude), lon0: west.longitude,
                y0: pn.y, ky: (ps.y - pn.y) / (GeoPlacement.merc(south.latitude) - GeoPlacement.merc(north.latitude)),
                merc0: GeoPlacement.merc(north.latitude))

            motion = [:]
            buildTask = Task { @MainActor [weak self] in
                var previous: (stamp: String, image: UIImage)?
                for (i, frame) in frames.enumerated() {
                    if Task.isCancelled { return }
                    let image: UIImage?
                    switch frame {
                    case .tiles(let source):
                        image = await Self.render(source: source, placements: placements,
                                                  zoom: zoom, size: size)
                    case .hrrr(let hrrr):
                        image = await Self.render(picture: hrrr, visible: visible, geo: geo, size: size)
                    }
                    if Task.isCancelled { return }
                    if let image {
                        self?.images[frame.stamp] = image
                        // How far the weather moved between this frame and
                        // the one before, for `show` to draw as travel.
                        if let previous {
                            let vector = await Self.estimateMotion(from: previous.image, to: image)
                            if Task.isCancelled { return }
                            self?.motion["\(previous.stamp)>\(frame.stamp)"] = vector
                        }
                        previous = (frame.stamp, image)
                    }
                    // Setting loaded re-runs the SwiftUI body, which calls
                    // `update` → `show`, so the newest frame appears as soon
                    // as it is ready rather than only when the set is whole.
                    self?.loaded?.wrappedValue = Double(i + 1) / Double(frames.count)
                }
            }
            return true
        }

        /// How far the echoes shifted from one picture to the next, as one
        /// vector in points.
        ///
        /// Block matching on the alpha channel: both pictures are shrunk to
        /// about a hundred pixels across — where the rain is, not what colour
        /// — and the offset that lines the second up best over the first is
        /// searched for within a dozen small pixels each way, which at a
        /// regional zoom is a couple of hundred kilometres an hour, more than
        /// weather moves. One vector for the whole picture: a storm system's
        /// cells share a steering flow, and a single translation is what the
        /// eye needs to read the loop as motion. If nothing matches better
        /// than not moving, nothing moves.
        nonisolated private static func estimateMotion(from before: UIImage, to after: UIImage) async -> CGVector {
            let width = 120
            let height = max(2, Int((Double(width) * Double(before.size.height) / Double(before.size.width)).rounded()))
            guard let a = coverage(of: before, width: width, height: height),
                  let b = coverage(of: after, width: width, height: height)
            else { return .zero }
            let reach = 12
            func cost(dx: Int, dy: Int) -> Int {
                // Sum of absolute differences where the shifted second
                // picture overlaps the first.
                var total = 0
                for y in max(0, -dy)..<min(height, height - dy) {
                    let rowA = y * width, rowB = (y + dy) * width
                    for x in max(0, -dx)..<min(width, width - dx) {
                        total += abs(Int(a[rowA + x]) - Int(b[rowB + x + dx]))
                    }
                }
                return total
            }
            let still = cost(dx: 0, dy: 0)
            guard still > 0 else { return .zero }
            var best = (dx: 0, dy: 0, cost: still)
            for dy in -reach...reach {
                for dx in -reach...reach where dx != 0 || dy != 0 {
                    let c = cost(dx: dx, dy: dy)
                    if c < best.cost { best = (dx, dy, c) }
                }
            }
            // Only a clear improvement counts. Noise between two frames can
            // always be shaved a little by a one-pixel nudge, and drawing that
            // as travel would make a stationary cell jitter.
            guard Double(best.cost) < Double(still) * 0.92 else { return .zero }
            // Between the pixels: a parabola through the costs either side of
            // the best offset says where the true minimum sits. Without it
            // the speed steps in whole small pixels — sixteen points at a
            // regional zoom — and a system drifting at a pixel and a half
            // alternated between one and two from frame to frame.
            func peak(_ lower: Int, _ centre: Int, _ upper: Int) -> Double {
                let curve = Double(lower - 2 * centre + upper)
                return curve > 0 ? max(-0.5, min(0.5, 0.5 * Double(lower - upper) / curve)) : 0
            }
            let subX = abs(best.dx) < reach
                ? peak(cost(dx: best.dx - 1, dy: best.dy), best.cost, cost(dx: best.dx + 1, dy: best.dy)) : 0
            let subY = abs(best.dy) < reach
                ? peak(cost(dx: best.dx, dy: best.dy - 1), best.cost, cost(dx: best.dx, dy: best.dy + 1)) : 0
            let pointsPerPixel = Double(before.size.width) / Double(width)
            return CGVector(dx: (Double(best.dx) + subX) * pointsPerPixel,
                            dy: (Double(best.dy) + subY) * pointsPerPixel)
        }

        /// A picture's alpha, small: where there is weather at all.
        nonisolated private static func coverage(of image: UIImage, width: Int, height: Int) -> [UInt8]? {
            guard let cg = image.cgImage else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &pixels, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = CGInterpolationQuality.medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            // The alpha byte of each pixel is the only thing wanted.
            return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        }

        /// One HRRR picture, cut to the view and laid onto the map.
        ///
        /// Four steps, and the order is the point.
        ///
        /// 1. **Crop.** The picture is the whole continent at 0.02° a pixel;
        ///    only the part under the view, plus a margin, is touched.
        /// 2. **Key.** The server paints on black and draws the faintest
        ///    returns — five to fifteen dBZ, drizzle the radar can barely
        ///    see — in pale greys. Both go transparent here: the black
        ///    because it is ground, the greys because at television size
        ///    they were a speckle of white squares around every cell, which
        ///    is exactly what was reported as "pixelated". Colour with any
        ///    saturation is rain and stays.
        /// 3. **Reproject.** The source is equirectangular and the map is
        ///    Mercator, so the crop is resampled row by row into one image
        ///    whose rows *are* Mercator — each output row reads the source
        ///    row its latitude falls on, blending the two neighbours. One
        ///    picture, not forty strips: the strips smoothed each on their
        ///    own and left a seam at every boundary.
        /// 4. **Draw and soften.** The Mercator image is drawn once, scaled
        ///    to the map with bicubic interpolation, then blurred by about a
        ///    third of one source pixel's width on screen. That is what
        ///    turns 2 km squares into the soft echoes a radar shows, and it
        ///    is how every weather site does it: the model has no detail
        ///    below its pixel, and pretending the squares are edges is the
        ///    only lie a blur tells less of.
        nonisolated private static func render(picture frame: HRRRReflectivity.Frame,
                                               visible: MKCoordinateRegion,
                                               geo: GeoPlacement,
                                               size: CGSize) async -> UIImage? {
            guard let whole = await HRRRReflectivity.image(for: frame) else { return nil }
            let bounds = frame.bounds(width: whole.width, height: whole.height)
            let dpp = frame.degreesPerPixel

            // 1. Crop.
            let margin = 0.5
            let wantWest = max(bounds.west, visible.center.longitude - visible.span.longitudeDelta / 2 - margin)
            let wantEast = min(bounds.east, visible.center.longitude + visible.span.longitudeDelta / 2 + margin)
            let wantNorth = min(bounds.north, visible.center.latitude + visible.span.latitudeDelta / 2 + margin)
            let wantSouth = max(bounds.south, visible.center.latitude - visible.span.latitudeDelta / 2 - margin)
            guard wantEast > wantWest, wantNorth > wantSouth else { return nil }
            let x0 = Int((wantWest - bounds.west) / dpp)
            let x1 = min(whole.width, Int(((wantEast - bounds.west) / dpp).rounded(.up)))
            let y0 = Int((bounds.north - wantNorth) / dpp)
            let y1 = min(whole.height, Int(((bounds.north - wantSouth) / dpp).rounded(.up)))
            guard x1 > x0, y1 > y0,
                  let crop = whole.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            else { return nil }
            let width = crop.width, height = crop.height
            let latTop = bounds.north - Double(y0) * dpp
            let latBottom = bounds.north - Double(y1) * dpp
            let lonLeft = bounds.west + Double(x0) * dpp
            let lonRight = bounds.west + Double(x1) * dpp

            // 2. Key. Read the crop as RGBA and decide, pixel by pixel.
            var source = [UInt8](repeating: 0, count: width * height * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            guard let reader = CGContext(data: &source, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            reader.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            for i in stride(from: 0, to: source.count, by: 4) {
                let r = Int(source[i]), g = Int(source[i + 1]), b = Int(source[i + 2])
                let brightest = max(r, g, b), darkest = min(r, g, b)
                let isGround = brightest < 12
                let isGrey = brightest - darkest < 30
                if isGround || isGrey {
                    source[i] = 0; source[i + 1] = 0; source[i + 2] = 0; source[i + 3] = 0
                }
            }

            // 3. Reproject: one output row per source row, placed by latitude.
            let mercTop = GeoPlacement.merc(latTop), mercBottom = GeoPlacement.merc(latBottom)
            var projected = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                let t = (Double(row) + 0.5) / Double(height)
                let merc = mercTop + (mercBottom - mercTop) * t
                let latitude = atan(sinh(merc)) * 180 / .pi
                let sourceRow = (latTop - latitude) / dpp - 0.5
                let above = max(0, min(height - 1, Int(floor(sourceRow))))
                let below = max(0, min(height - 1, above + 1))
                let blend = max(0, min(1, sourceRow - Double(above)))
                for column in 0..<width {
                    let a = (above * width + column) * 4, b = (below * width + column) * 4, o = (row * width + column) * 4
                    for channel in 0..<4 {
                        let value = Double(source[a + channel]) * (1 - blend) + Double(source[b + channel]) * blend
                        projected[o + channel] = UInt8(max(0, min(255, value.rounded())))
                    }
                }
            }
            guard let writer = CGContext(data: &projected, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let mercator = writer.makeImage()
            else { return nil }

            // 4. Draw, then soften.
            let left = geo.x(of: lonLeft), right = geo.x(of: lonRight)
            let top = geo.y(of: latTop), bottom = geo.y(of: latBottom)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 0.5
            format.opaque = false
            let sharp = UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.interpolationQuality = .high
                UIImage(cgImage: mercator).draw(in: CGRect(x: left, y: top,
                                                           width: right - left, height: bottom - top))
            }
            // A source pixel's width on the glass, in the bitmap's own pixels
            // (the bitmap is half the point size). A third of that is enough
            // to lose the square without losing the cell.
            let pixelPoints = Double(right - left) / Double(width)
            let radius = max(0.8, min(9, pixelPoints * 0.5 * 0.34))
            return soften(sharp, radius: radius) ?? sharp
        }

        /// One shared Core Image context: making one per frame is the
        /// expensive part of using Core Image at all.
        nonisolated private static let softener = CIContext(options: [.useSoftwareRenderer: false])

        /// A Gaussian blur, cropped back to the picture's own extent — the
        /// filter grows the image by its radius on every side, and left as
        /// is that growth would shift the whole overlay down and right.
        nonisolated private static func soften(_ image: UIImage, radius: Double) -> UIImage? {
            guard let cg = image.cgImage else { return nil }
            let input = CIImage(cgImage: cg)
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(radius)
            guard let output = filter.outputImage?.cropped(to: input.extent),
                  let result = softener.createCGImage(output, from: input.extent)
            else { return nil }
            return UIImage(cgImage: result, scale: image.scale, orientation: .up)
        }

        /// Compose one frame's tiles into a single map-sized image.
        ///
        /// `nonisolated`, so the tile decode and the drawing run off the main
        /// thread — thirteen full-screen composites on the main actor was a
        /// visible hitch on entry. Only the finished image and the progress
        /// go back to the main thread, in the build loop.
        nonisolated private static func render(source: RadarSource,
                                   placements: [(x: Int, y: Int, rect: CGRect)],
                                   zoom: Int, size: CGSize) async -> UIImage {
            let overlay = RadarTileOverlay(source: source)
            var pieces: [(CGRect, UIImage)] = []
            await withTaskGroup(of: (CGRect, UIImage?).self) { group in
                for place in placements {
                    group.addTask {
                        (place.rect, await tileImage(overlay, place.x, place.y, zoom))
                    }
                }
                for await (rect, image) in group where image != nil {
                    pieces.append((rect, image!))
                }
            }
            let format = UIGraphicsImageRendererFormat.default()
            // Point resolution, not the screen's — radar is coarse, and a
            // 4K-scaled bitmap per frame is a great deal of memory for no
            // visible gain.
            // Half resolution. Radar is coarse and the image is stretched
            // over the whole map anyway, so full resolution buys nothing and
            // costs four times the memory — thirteen frames at full 1080p is
            // over a hundred megabytes, which is what pushes an Apple TV into
            // memory pressure.
            format.scale = 0.5
            format.opaque = false
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                for (rect, image) in pieces { image.draw(in: rect) }
            }
        }

        private static func tileImage(_ overlay: RadarTileOverlay,
                                      _ x: Int, _ y: Int, _ z: Int) async -> UIImage? {
            let data: Data? = await withCheckedContinuation { continuation in
                overlay.loadTile(at: MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 1)) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            return data.flatMap { UIImage(data: $0) }
        }

        private static func signature(of frames: [RadarFrame], region: MKCoordinateRegion) -> String {
            let box = String(format: "%.3f,%.3f,%.3f",
                             region.center.latitude, region.center.longitude,
                             region.span.latitudeDelta)
            return frames.map(\.stamp).joined(separator: ",") + "|" + box
        }

        /// The tile zoom to render at — roughly what fills the view, capped so
        /// the grid is a handful of tiles rather than a thousand.
        private static func renderZoom(for region: MKCoordinateRegion) -> Int {
            let span = max(region.span.longitudeDelta, 0.0001)
            return min(max(Int((log2(360 / span)).rounded()), 3), 9)
        }

        /// The north-west corner of a slippy tile, in latitude and longitude
        /// — the standard tile scheme, `y` counting down from the top.
        private static func corner(x: Int, y: Int, z: Int) -> CLLocationCoordinate2D {
            let n = pow(2.0, Double(z))
            let lon = Double(x) / n * 360 - 180
            let lat = atan(sinh(Double.pi * (1 - 2 * Double(y) / n))) * 180 / .pi
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}

// MARK: - Chrome

private struct RadarButton: View {

    let title: String
    let systemImage: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RadarPill(title: title, systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(.plain)
    }
}

private struct RadarPill: View {

    let title: String
    let systemImage: String
    let isOn: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .foregroundStyle(isFocused ? Color.black
                         : (isEnabled ? (isOn ? Color.accentColor : Color.white)
                            : Color.white.opacity(0.3)))
        .background(isFocused ? Color.white : Color.white.opacity(0.14), in: Capsule())
    }
}

private struct Unavailable: View {
    let text: String
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "cloud.rain")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Radar follows the map")
                .font(.system(size: 44, weight: .bold))
            Text(text)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(60)
    }
}
