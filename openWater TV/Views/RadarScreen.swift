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

// The map underneath — `RadarImageMap`, `RadarFrame` and the picture
// drawing — moved to `OpenWaterSpots/RadarImageMap.swift`, shared with the
// phone, whose loop had the flicker this one was cured of.

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
