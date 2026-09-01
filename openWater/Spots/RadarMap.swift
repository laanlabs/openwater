import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

// The provider layer, the tile maths and the overlay now live in
// `OpenWaterSpots/Radar.swift`, shared with the television. What is left here
// is the phone's own map wrapper and screen: both turn on `MapStyleOption`,
// which is this app's settings, and neither is anything the TV wants.

// MARK: - The map

/// `MKMapView` in a wrapper, because SwiftUI's `Map` has no tile-overlay API.
///
/// This is the whole reason radar is its own screen rather than a switch on
/// the Spots map: getting an overlay onto that map would mean rebuilding it as
/// an `MKMapView` and hand-rolling the wind pins that `MapContentBuilder`
/// currently gives us for free.
struct RadarMapView: UIViewRepresentable {

    let centre: Geo.Coordinate
    let source: RadarSource
    let style: MapStyleOption

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude),
            span: MKCoordinateSpan(latitudeDelta: 3.5, longitudeDelta: 3.5)
        ), animated: false)
        context.coordinator.apply(source, to: map)
        return map
    }

    /// Reported back so the screen knows which tiles a loop would need.
    var onRegionChange: ((MKCoordinateRegion) -> Void)?

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onRegionChange = onRegionChange
        map.preferredConfiguration = switch style {
        case .standard: MKStandardMapConfiguration(elevationStyle: .flat)
        case .hybrid: MKHybridMapConfiguration(elevationStyle: .flat)
        case .imagery: MKImageryMapConfiguration(elevationStyle: .flat)
        }
        context.coordinator.apply(source, to: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {

        /// One frame on the map: the overlay and the renderer whose alpha is
        /// this class's whole business.
        private struct Layer {
            let overlay: MKTileOverlay
            let renderer: MKTileOverlayRenderer
        }

        /// Enough of the sweep to read, not so much that the coastline and
        /// the spot you are deciding about disappear under it.
        private static let opacity: CGFloat = 0.7

        /// Long enough to read as a dissolve, short enough that the loop's
        /// own 420 ms frame does not overtake it.
        private static let crossFade: CFTimeInterval = 0.28

        /// How long to wait for a frame's tiles before showing it anyway.
        /// They are nearly always cached — the loop is preloaded and the
        /// crops are kept — so this is the safety net, not the path.
        private static let patience: CFTimeInterval = 0.7

        private var showing: RadarSource?
        private var current: Layer?
        /// Frames on their way out. Usually one; more only if the loop
        /// advances faster than a fade can finish.
        private var retiring: [Layer] = []
        private var renderers: [ObjectIdentifier: MKTileOverlayRenderer] = [:]

        private weak var map: MKMapView?
        private var clock: CADisplayLink?
        private var began: CFTimeInterval = 0
        private var isFading = false

        var onRegionChange: ((MKCoordinateRegion) -> Void)?

        deinit { clock?.invalidate() }

        func mapView(_ map: MKMapView, regionDidChangeAnimated: Bool) {
            onRegionChange?(map.region)
        }

        /// Swap the layer only when the source actually changed — scrubbing
        /// frames re-enters this on every slider tick.
        ///
        /// The swap used to be a removal and an addition, which is what made
        /// the loop blink: for the beat between them there was no radar on
        /// the map at all, and even with every tile cached
        /// `MKTileOverlayRenderer` re-renders from scratch for an overlay it
        /// was not just drawing. Thirteen frames a loop, thirteen blinks.
        ///
        /// So the new frame goes on *above* the old one at zero alpha, waits
        /// until it can actually draw, and then the two cross-fade. The old
        /// frame is only removed once the new one has taken over, and the map
        /// is never bare.
        func apply(_ source: RadarSource, to map: MKMapView) {
            guard showing != source else { return }
            showing = source
            self.map = map

            // Whatever was mid-transition lands now rather than being left
            // half-faded under the next one.
            settle()

            let overlay = RadarTileOverlay(source: source)
            let renderer = MKTileOverlayRenderer(tileOverlay: overlay)
            let isFirst = current == nil
            renderer.alpha = isFirst ? Self.opacity : 0
            renderers[ObjectIdentifier(overlay)] = renderer

            if let current { retiring.append(current) }
            current = Layer(overlay: overlay, renderer: renderer)
            // Above labels, and above the frame it is replacing: overlays
            // draw in the order they were added.
            map.addOverlay(overlay, level: .aboveLabels)

            guard !isFirst else { return }
            began = CACurrentMediaTime()
            isFading = false
            let clock = CADisplayLink(target: self, selector: #selector(tick))
            // A dissolve does not need sixty steps, and each one asks the
            // renderer to redraw its tiles.
            clock.preferredFramesPerSecond = 30
            clock.add(to: .main, forMode: .common)
            self.clock = clock
        }

        /// One step of the wait-then-dissolve.
        @objc private func tick() {
            guard let current else { return settle() }
            let now = CACurrentMediaTime()

            if !isFading {
                // Nothing is shown of the new frame until it has tiles to
                // show; until then the old one is still the whole picture.
                let ready = map.map { canDraw(current.renderer, in: $0) } ?? true
                guard ready || now - began >= Self.patience else { return }
                isFading = true
                began = now
            }

            let t = min(1, (now - began) / Self.crossFade)
            // Smoothstep: a linear alpha ramp reads as a lurch at both ends.
            let eased = CGFloat(t * t * (3 - 2 * t))
            current.renderer.alpha = Self.opacity * eased
            current.renderer.setNeedsDisplay()
            for layer in retiring {
                layer.renderer.alpha = Self.opacity * (1 - eased)
                layer.renderer.setNeedsDisplay()
            }
            if t >= 1 { settle() }
        }

        /// Has this renderer got what it needs to draw what is on screen?
        private func canDraw(_ renderer: MKTileOverlayRenderer, in map: MKMapView) -> Bool {
            let rect = map.visibleMapRect
            guard rect.size.width > 0, map.bounds.width > 0 else { return true }
            let zoom = MKZoomScale(map.bounds.width / CGFloat(rect.size.width))
            return renderer.canDraw(rect, zoomScale: zoom)
        }

        /// End the transition wherever it is: the new frame at full strength,
        /// the old ones off the map.
        private func settle() {
            clock?.invalidate()
            clock = nil
            isFading = false
            if let current {
                current.renderer.alpha = Self.opacity
                current.renderer.setNeedsDisplay()
            }
            for layer in retiring {
                map?.removeOverlay(layer.overlay)
                renderers.removeValue(forKey: ObjectIdentifier(layer.overlay))
            }
            retiring.removeAll()
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tiles = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            // The renderer is made in `apply`, because its alpha is the thing
            // being animated and MapKit would otherwise hand back one this
            // class has no reference to.
            if let known = renderers[ObjectIdentifier(tiles)] { return known }
            let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
            renderer.alpha = Self.opacity
            renderers[ObjectIdentifier(tiles)] = renderer
            return renderer
        }
    }
}

// MARK: - The screen

/// Radar over the map, with the loop when the source has one.
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
    @State private var index: Int = 0
    @State private var isPlaying = false
    /// What the map is showing: one of NOAA's still layers, or the loop.
    ///
    /// Both, rather than one or the other. NOAA alone publishes storm cores,
    /// storm tops and precipitation type; RainViewer alone has a past to
    /// play. Neither replaces the other.
    enum Layer: Hashable {
        case still(RadarProduct)
        case loop
    }

    @State private var layer: Layer = .still(.base)
    /// Fraction of the loop's tiles already in the cache, 0–1.
    @State private var loaded: Double = 0
    @State private var isPreloading = false
    @State private var visible: MKCoordinateRegion?

    private var product: RadarProduct {
        if case .still(let product) = layer { return product }
        return .base
    }

    private var showsLoop: Bool { layer == .loop }

    private var region: RadarRegion { .covering(centre) }

    /// RainViewer for plain rain — global, and the only source with a past to
    /// animate. NOAA for the three products it alone publishes: storm cores,
    /// storm tops and precipitation type have no RainViewer equivalent, and
    /// losing them to get a scrubber would be a poor trade.
    private var source: RadarSource {
        if showsLoop, let frame = frames[safe: index] {
            return .rainViewer(frame: frame)
        }
        return .noaa(region: region, product: product)
    }

    /// Only the animated source gets a scrubber.
    private var isAnimated: Bool { showsLoop && frames.count > 1 }

    private var isReady: Bool { loaded >= 1 }

    private var preloadKey: String {
        guard showsLoop, let visible else { return "" }
        return String(format: "%.2f,%.2f,%.2f,%d", visible.center.latitude,
                      visible.center.longitude, visible.span.latitudeDelta, frames.count)
    }

    /// Warm every frame's tiles before the loop can run.
    ///
    /// Playing straight away is what produced the flashes: each frame began
    /// downloading only as it was shown, and a quarter of a second is not
    /// enough to fetch a screenful. So the whole loop is fetched first, with
    /// the progress on screen, and play stays disabled until it is there.
    private func preload() async {
        guard showsLoop, frames.count > 1, let region = visible else { return }
        isPreloading = true
        loaded = 0
        defer { isPreloading = false }

        let zoom = min(RadarSource.rainViewer(frame: frames[0]).maximumZoom,
                       Self.zoom(for: region))
        let tiles = RadarTiles.tiles(covering: region, zoom: zoom)
        guard !tiles.isEmpty else { loaded = 1; return }

        let total = frames.count * tiles.count
        var done = 0
        for frame in frames {
            let source = RadarSource.rainViewer(frame: frame)
            await withTaskGroup(of: Void.self) { group in
                for tile in tiles {
                    guard let url = source.tileURL(x: tile.x, y: tile.y, z: zoom) else { continue }
                    group.addTask { _ = try? await RadarTiles.session.data(from: url) }
                }
                for await _ in group { }
            }
            done += tiles.count
            loaded = Double(done) / Double(total)
            if Task.isCancelled { return }
        }
        loaded = 1
    }

    /// The slippy-map zoom that best matches a region on screen.
    private static func zoom(for region: MKCoordinateRegion) -> Int {
        let fraction = max(region.span.longitudeDelta, 0.01) / 360
        return max(3, min(12, Int((log2(1 / fraction)).rounded())))
    }

    var body: some View {
        // The map ignores the safe area and the chrome does not. Sideways
        // that is the whole difference between a full-bleed sweep and a
        // segmented control sitting on the home indicator, where a tap is the
        // system's before it is ever the app's.
        ZStack(alignment: Alignment.bottom) {
            RadarMapView(centre: centre, source: source, style: settings.mapStyle,
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
                index = max(0, frames.count - 1)
            }
            // The loop. `isPlaying` used to toggle a glyph and nothing else —
            // the button looked like it worked and the map never moved.
            //
            // Restarting from the beginning when play is pressed at the end
            // matters: the last frame is now, and a rider who taps play there
            // wants to watch the last two hours arrive, not sit on a still.
            .task(id: preloadKey) { await preload() }
            .task(id: isPlaying) {
                guard isPlaying, isReady, frames.count > 1 else { return }
                if index >= frames.count - 1 { index = 0 }
                while !Task.isCancelled, isPlaying {
                    try? await Task.sleep(for: .milliseconds(index == frames.count - 1 ? 1200 : 420))
                    guard !Task.isCancelled, isPlaying else { return }
                    index = index >= frames.count - 1 ? 0 : index + 1
                }
            }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Layer", selection: $layer) {
                ForEach(RadarProduct.allCases, id: \.self) { Text($0.label).tag(Layer.still($0)) }
                Text("Loop").tag(Layer.loop)
            }
            .pickerStyle(.segmented)
            .onChange(of: layer) { _, _ in
                if case .still = layer { isPlaying = false }
            }

            if isAnimated {
                if isReady {
                    scrubber
                } else {
                    loadingBar
                }
            }
            Text(source.attribution)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            // Where the sweep reaches is worth a line in portrait and worth a
            // third of the screen sideways. The source's own name stays
            // either way — that one is not ours to drop.
            if !landscape {
                Text(source.coverage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(landscape ? 10 : 14)
        .background(.regularMaterial)
    }

    /// What the loop is doing before it can run.
    private var loadingBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(frames.isEmpty
                     ? "Finding frames…"
                     : "Loading \(frames.count) frames — \(Int(loaded * 100))%")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            ProgressView(value: loaded)
            Text("The whole loop is fetched before it plays, so it runs smoothly instead of flashing frames as they arrive.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var scrubber: some View {
        HStack(spacing: 12) {
            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { Double(index) },
                    set: { isPlaying = false; index = Int($0.rounded()) }
                ),
                in: 0...Double(max(1, frames.count - 1)),
                step: 1
            )

            if let frame = frames[safe: index] {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(frame.time.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    if frame.isForecast {
                        Text("forecast")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 62, alignment: .trailing)
            }
        }
    }
}
