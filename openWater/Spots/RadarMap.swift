import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

// The drawing lives in `OpenWaterSpots/RadarImageMap.swift`, shared with the
// television, and so do the providers, the tiles and the HRRR pictures. What
// is left here is the phone's own screen.

/// Radar over the map: the last two hours as seen, and the next two as the
/// model expects them.
///
/// **The loop used to disappear.** It was drawn as MapKit tile overlays
/// swapped frame by frame, and MapKit redraws an overlay's tiles on its own
/// schedule — so between frames the map was bare, and a loop of thirteen was
/// thirteen blinks. The television was cured of this a week earlier by
/// drawing each frame once as a flat picture; this screen now uses the same
/// map, and the loop slides from frame to frame along the way the rain is
/// measured to be moving.
///
/// **And it had no future.** RainViewer's free feed publishes no nowcast, so
/// the loop ended at the last scan. Over the continental US it now runs on
/// into NOAA's HRRR — the model radar weather.gov shows as "future radar" —
/// and says so on every frame it shows.
struct RadarScreen: View {

    let centre: Geo.Coordinate
    var title: String = "Radar"

    @Environment(AppSettings.self) private var settings

    /// Compact height is a phone on its side. A radar sweep is a picture of
    /// weather crossing a coastline, so sideways the map takes the screen and
    /// the loop's controls float over it rather than pushing it up.
    @Environment(\.verticalSizeClass) private var height
    @Environment(\.dismiss) private var dismiss

    private var landscape: Bool { height == .compact }

    @State private var frames: [RainViewerFrame] = []
    @State private var hrrrFrames: [HRRRReflectivity.Frame] = []
    @State private var index: Int = 0
    @State private var isPlaying = false
    /// How much of the set has been drawn, 0–1. The map reports it.
    @State private var loaded: Double = 0
    @State private var visible: MKCoordinateRegion?

    /// What the map is showing: the loop, or one of NOAA's still layers.
    ///
    /// Both, rather than one or the other. NOAA alone publishes storm cores,
    /// storm tops and precipitation type; RainViewer alone has a past to
    /// play. The loop leads now that it plays properly: its newest frame is
    /// "is it raining", and the frames either side are "is it coming".
    enum Layer: Hashable {
        case still(RadarProduct)
        case loop
    }

    @State private var layer: Layer = .loop

    /// Whether the loop runs on into the model's next two hours. On unless
    /// turned off, and remembered, because the question a rider opens radar
    /// with is usually "is it coming here", which the past alone answers only
    /// by guesswork.
    @AppStorage("radar.future") private var showsFuture = true

    /// Every quarter hour for two hours — the span a rider is deciding over,
    /// at the step the model publishes. See the television's `RadarScreen`.
    private static let forecastOffsets: [TimeInterval] = (0 ... 8).map { Double($0) * 900 }

    /// The observed loop's pace, and the pace when it runs on into the
    /// forecast: one pace for both halves, so the join is a change of caption
    /// and not of rhythm, and slow enough for the motion between frames to
    /// be drawn as travel. The last frame is held so the eye can catch up.
    private static let observedStep: TimeInterval = 0.42
    private static let observedHold: TimeInterval = 1.2
    private static let combinedStep: TimeInterval = 0.55
    private static let combinedHold: TimeInterval = 1.6

    private var lookingAt: Geo.Coordinate {
        guard let visible else { return centre }
        return Geo.Coordinate(latitude: visible.center.latitude, longitude: visible.center.longitude)
    }

    /// The model's pictures cover the continental US and nowhere else.
    private var futureAvailable: Bool { HRRRReflectivity.covers(lookingAt) }

    private var wantsFuture: Bool { layer == .loop && showsFuture && futureAvailable }

    private var loopFrames: [RadarFrame] {
        let observed = frames.map { RadarFrame.tiles(.rainViewer(frame: $0)) }
        return wantsFuture ? observed + hrrrFrames.map(RadarFrame.hrrr) : observed
    }

    private var displayFrames: [RadarFrame] {
        switch layer {
        case .loop: loopFrames
        case .still(let product): [.tiles(.noaa(region: .covering(lookingAt), product: product))]
        }
    }

    private var shownIndex: Int {
        layer == .loop ? min(index, max(0, loopFrames.count - 1)) : 0
    }

    private var shownFrame: RadarFrame? {
        displayFrames.indices.contains(shownIndex) ? displayFrames[shownIndex] : nil
    }

    private var runsIntoForecast: Bool { wantsFuture && !hrrrFrames.isEmpty }

    private var step: TimeInterval { runsIntoForecast ? Self.combinedStep : Self.observedStep }
    private var hold: TimeInterval { runsIntoForecast ? Self.combinedHold : Self.observedHold }

    /// How long the map has to carry one frame into the next — the whole
    /// step, so the motion is drawn as travel rather than shown as a cut.
    private var frameAnimation: TimeInterval? { isPlaying ? step : nil }

    private var isReady: Bool { loaded >= 1 }

    /// The newest observation, ignoring any nowcast frames after it. "Now"
    /// on this screen means the last thing the radar actually saw.
    private var latestObservation: Int {
        frames.lastIndex { !$0.isForecast } ?? max(0, frames.count - 1)
    }

    private var mapConfiguration: MKMapConfiguration {
        switch settings.mapStyle {
        case .standard: MKStandardMapConfiguration(elevationStyle: .flat)
        case .hybrid: MKHybridMapConfiguration(elevationStyle: .flat)
        case .imagery: MKImageryMapConfiguration(elevationStyle: .flat)
        }
    }

    private var opening: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude),
            span: MKCoordinateSpan(latitudeDelta: 3.5, longitudeDelta: 3.5))
    }

    var body: some View {
        // The map ignores the safe area and the chrome does not. Sideways
        // that is the whole difference between a full-bleed sweep and a
        // segmented control sitting on the home indicator, where a tap is the
        // system's before it is ever the app's.
        ZStack(alignment: Alignment.bottom) {
            RadarImageMap(region: opening, frames: displayFrames, index: shownIndex,
                          animation: frameAnimation, isActive: true, loaded: $loaded,
                          isInteractive: true, configuration: mapConfiguration,
                          showsUserLocation: true, renderScale: 1,
                          onRegionChange: { visible = $0 })
                .ignoresSafeArea(edges: landscape ? Edge.Set.all : Edge.Set.bottom)

            if landscape {
                footer
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
        }
            .safeAreaInset(edge: VerticalEdge.bottom) {
                if !landscape { footer }
            }
            .overlay(alignment: Alignment.topLeading) {
                // The navigation bar's back button went with the bar. This is
                // the way out, in the corner it was in — inside the safe area,
                // clear of the notch a sideways phone puts on that edge.
                if landscape {
                    MapChromeButton {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                    }
                    .padding(.leading, 8)
                    .padding(.top, 8)
                    .accessibilityLabel("Back")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(NavigationBarItem.TitleDisplayMode.inline)
            .toolbar(landscape ? Visibility.hidden : Visibility.automatic, for: ToolbarPlacement.navigationBar)
            .statusBarHidden(landscape)
            .allowsLandscape()
            .feedbackButton("Radar")
            .task {
                frames = await RainViewer.frames()
                // Open on the newest observation, not the oldest: index 0 is
                // two hours ago, which is not what "is it raining" means.
                index = latestObservation
            }
            // The model's pictures, for wherever they exist. The cache behind
            // them makes a re-ask cheap when the map crosses back into range.
            .task(id: wantsFuture) {
                guard wantsFuture else {
                    hrrrFrames = []
                    return
                }
                hrrrFrames = await HRRRReflectivity.frames(aheadOfNow: Self.forecastOffsets)
            }
            // The future switched off, or out of range, can leave the index
            // in the half that just vanished.
            .onChange(of: loopFrames.count) { _, count in
                index = min(index, max(0, count - 1))
            }
            // The loop. Restarting from the beginning when play is pressed at
            // the end matters: a rider who taps play on the last frame wants
            // to watch the rain arrive, not sit on a still.
            .task(id: isPlaying) {
                guard isPlaying, loopFrames.count > 1 else { return }
                if index >= loopFrames.count - 1 { index = 0 }
                while !Task.isCancelled, isPlaying {
                    let count = loopFrames.count
                    try? await Task.sleep(for: .seconds(index == count - 1 ? hold : step))
                    guard !Task.isCancelled, isPlaying, loopFrames.count > 1 else { return }
                    index = (index + 1) % loopFrames.count
                }
            }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Layer", selection: $layer) {
                Text("Loop").tag(Layer.loop)
                ForEach(RadarProduct.allCases, id: \.self) { Text($0.label).tag(Layer.still($0)) }
            }
            .pickerStyle(.segmented)
            .onChange(of: layer) { _, _ in
                if case .still = layer { isPlaying = false }
            }

            if layer == .loop {
                // The clock and the slider stay while frames are drawn — the
                // one on the glass is drawn first and is worth reading, and
                // after a pan the whole set is redrawn. Only Play waits.
                if loopFrames.count > 1 { scrubber }
                if !isReady { loadingBar }
                futureToggle
            }

            Text(attribution)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Where the sweep reaches is worth a line in portrait and worth a
            // third of the screen sideways. On a model frame that line is
            // what its colours mean, which are not the radar's.
            if !landscape {
                if case .hrrr? = shownFrame {
                    HStack(spacing: 10) {
                        legend
                        Text("3 km model · continental US")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if let coverage {
                    Text(coverage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(landscape ? 10 : 14)
        .background(.regularMaterial)
    }

    /// What the loop is doing before it can run.
    private var loadingBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(frames.isEmpty
                 ? "Finding frames…"
                 : "Drawing \(loopFrames.count) frames — \(Int(loaded * 100))%")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
    }

    private var scrubber: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(clock)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 34, height: 34)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                // Starting waits for the whole set; stopping never does.
                .disabled(!isReady && !isPlaying)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(
                        get: { Double(shownIndex) },
                        set: { isPlaying = false; index = Int($0.rounded()) }
                    ),
                    in: 0...Double(max(1, loopFrames.count - 1)),
                    step: 1
                )
            }
        }
    }

    private var futureToggle: some View {
        Toggle(isOn: $showsFuture) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Show future")
                    .font(.subheadline.weight(.medium))
                Text(futureAvailable
                     ? "The next two hours from the HRRR model, after the radar."
                     : "Forecast frames cover the continental US only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!futureAvailable)
    }

    /// The frame's clock. The clock is the point of a loop: without it a
    /// rider cannot tell the newest frame from the oldest, and a two-hour-old
    /// sweep read as current is worse than none.
    private var clock: String {
        switch shownFrame {
        case .tiles(.rainViewer(let frame))?:
            return frame.time.formatted(date: .omitted, time: .shortened)
        case .hrrr(let frame)?:
            return Self.aheadLabel(for: frame)
        default:
            return ""
        }
    }

    /// The word that marks the crossing from what was seen into what is
    /// expected — so the join is visible without the picture changing its
    /// manners.
    private var badge: String? {
        switch shownFrame {
        case .tiles(.rainViewer(let frame))? where frame.isForecast: "NOWCAST"
        case .hrrr?: "FORECAST"
        default: nil
        }
    }

    /// "Now · 2:15 PM", "+45 min · 3:00 PM", "+1 h 30 min · 3:45 PM" — the
    /// frame's own valid time, which is the honest reading of a model step.
    private static func aheadLabel(for frame: HRRRReflectivity.Frame) -> String {
        let ahead = frame.validAt.timeIntervalSinceNow
        let clock = frame.validAt.formatted(date: .omitted, time: .shortened)
        if ahead < 5 * 60 { return "Now · \(clock)" }
        let minutes = Int((ahead / 60).rounded())
        if minutes < 60 { return "+\(minutes) min · \(clock)" }
        let rest = minutes % 60
        return rest == 0 ? "+\(minutes / 60) h · \(clock)" : "+\(minutes / 60) h \(rest) min · \(clock)"
    }

    /// Whose picture this is. A model frame says it is a model, and which
    /// run: a picture from a run three hours old is a different promise from
    /// one that just landed.
    private var attribution: String {
        switch shownFrame {
        case .hrrr(let frame)?:
            return "HRRR model radar, \(frame.runAt.formatted(date: .omitted, time: .shortened)) run · NOAA via Iowa State Mesonet — a forecast, not an observation"
        case .tiles(let source)?:
            return runsIntoForecast
                ? "\(source.attribution) · then the HRRR model's next two hours"
                : source.attribution
        default:
            return "RainViewer"
        }
    }

    private var coverage: String? {
        guard case .tiles(let source)? = shownFrame else { return nil }
        // RainViewer's own line says it publishes no forecast, which under a
        // loop that visibly runs into one reads as a contradiction.
        if runsIntoForecast, case .rainViewer = source {
            return "Observed radar for the last two hours, then NOAA's HRRR model for the next two. The forecast half covers the continental US only."
        }
        return source.coverage
    }

    /// The model's colours, which are the weather service's rather than the
    /// radar feed's — green for rain, yellow for heavy, red for a storm core.
    private var legend: some View {
        HStack(spacing: 8) {
            ForEach([("Light", Color(red: 0.01, green: 0.99, blue: 0.01)),
                     ("Heavy", Color(red: 0.99, green: 0.97, blue: 0.01)),
                     ("Storm", Color(red: 0.99, green: 0.0, blue: 0.0))], id: \.0) { name, colour in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colour)
                        .frame(width: 12, height: 8)
                    Text(name)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
