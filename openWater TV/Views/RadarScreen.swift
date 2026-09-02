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

    @FocusState private var focus: Control?
    @Namespace private var bar

    private enum Control: Hashable { case play, step, more, back, optGlobal, optProduct }

    /// How fast the loop runs. Slower than real time by a long way: thirteen
    /// frames covering two hours at three a second reads as weather moving,
    /// where anything quicker reads as a flicker.
    private static let frameInterval: Duration = .milliseconds(320)

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
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.frameInterval)
                guard !frames.isEmpty else { continue }
                index = (index + 1) % frames.count
            }
        }
    }

    private var radar: some View {
        ZStack(alignment: .bottom) {
            RadarImageMap(region: region, sources: sources,
                          index: shownIndex, loaded: $loaded)
                .ignoresSafeArea()
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
        isGlobal ? min(index, max(0, frames.count - 1)) : 0
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

    private var building: Bool { isGlobal && loaded < 1 }

    private var playLabel: String {
        if building { return "Loading \(Int(loaded * 100))%" }
        return isPlaying ? "Pause" : "Play loop"
    }

    private func togglePlay() {
        // The frames are rendered to images by the map view as they arrive;
        // this only starts and stops the clock. Disabled until they are in.
        isPlaying.toggle()
    }

    private var caption: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 14) {
                if isGlobal, frames.indices.contains(index) {
                    // The clock is the point of a loop. Without it a rider
                    // cannot tell the newest frame from the oldest, and a
                    // two-hour-old sweep read as current is worse than none.
                    Text(frames[index].time, format: .dateTime.hour().minute())
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if frames[index].isForecast {
                        Text("NOWCAST")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(source.attribution)
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
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
            if isGlobal {
                RadarButton(title: playLabel,
                            systemImage: isPlaying ? "pause.fill" : "play.fill",
                            isOn: isPlaying) { togglePlay() }
                    .focused($focus, equals: .play)
                    .prefersDefaultFocus(isGlobal, in: bar)
                    .disabled(frames.isEmpty || building)

                if !frames.isEmpty {
                    // Pausing and stepping is the whole of scrubbing on a
                    // remote — a slider would need the D-pad this has not got.
                    RadarButton(title: "Step", systemImage: "forward.frame.fill") {
                        isPlaying = false
                        index = (index + 1) % frames.count
                    }
                    .focused($focus, equals: .step)
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
            .prefersDefaultFocus(!isGlobal, in: bar)
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

            RadarButton(title: "Global loop", systemImage: "globe", isOn: isGlobal) {
                isGlobal = true
            }
            .focused($focus, equals: .optGlobal)

            ForEach(RadarProduct.allCases, id: \.self) { option in
                RadarButton(title: option.label,
                            systemImage: "square.stack.3d.down.right",
                            isOn: !isGlobal && option == product) {
                    isGlobal = false
                    isPlaying = false
                    product = option
                }
                .focused($focus, equals: .optProduct)
            }
        }
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
private struct RadarImageMap: UIViewRepresentable {

    let region: MKCoordinateRegion
    let sources: [RadarSource]
    let index: Int
    @Binding var loaded: Double

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        map.isUserInteractionEnabled = false
        map.setRegion(region, animated: false)
        context.coordinator.loaded = $loaded
        context.coordinator.attach(to: map)
        context.coordinator.update(sources: sources, index: index, region: region, to: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.loaded = $loaded
        context.coordinator.update(sources: sources, index: index, region: region, to: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {

        /// The radar, as one flat picture over the base map.
        private let radarView = UIImageView()
        /// One rendered image per frame, keyed by the frame's own stamp.
        private var images: [String: UIImage] = [:]
        /// What the current image set was built for — frames plus the exact
        /// rectangle. A new signature means a rebuild.
        private var signature = ""
        private var buildTask: Task<Void, Never>?
        var loaded: Binding<Double>?

        /// How strongly the sweep sits over the chart.
        private static let strength: CGFloat = 0.78

        func attach(to map: MKMapView) {
            radarView.contentMode = .scaleToFill
            radarView.isUserInteractionEnabled = false
            radarView.alpha = Self.strength
            radarView.frame = map.bounds
            radarView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            map.addSubview(radarView)
        }

        func update(sources: [RadarSource], index: Int, region: MKCoordinateRegion, to map: MKMapView) {
            let sig = Self.signature(of: sources, region: region)
            if sig != signature {
                signature = sig
                rebuild(sources: sources, region: region, map: map)
            }
            show(sources: sources, index: index)
        }

        /// Instant: a rendered frame is already an image.
        private func show(sources: [RadarSource], index: Int) {
            guard sources.indices.contains(index) else { return }
            if let image = images[Self.stamp(sources[index])] {
                radarView.image = image
            }
        }

        private func rebuild(sources: [RadarSource], region: MKCoordinateRegion, map: MKMapView) {
            buildTask?.cancel()
            images = [:]
            loaded?.wrappedValue = 0

            map.setRegion(region, animated: false)
            map.layoutIfNeeded()
            let size = map.bounds.size
            guard size.width > 0, !sources.isEmpty else { loaded?.wrappedValue = 1; return }

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
            guard !placements.isEmpty else { loaded?.wrappedValue = 1; return }

            let frames = sources
            buildTask = Task { @MainActor [weak self] in
                for (i, source) in frames.enumerated() {
                    if Task.isCancelled { return }
                    let image = await Self.render(source: source, placements: placements,
                                                  zoom: zoom, size: size)
                    if Task.isCancelled { return }
                    self?.images[Self.stamp(source)] = image
                    // Setting loaded re-runs the SwiftUI body, which calls
                    // `update` → `show`, so the newest frame appears as soon
                    // as it is ready rather than only when the set is whole.
                    self?.loaded?.wrappedValue = Double(i + 1) / Double(frames.count)
                }
            }
        }

        /// Compose one frame's tiles into a single map-sized image.
        @MainActor
        private static func render(source: RadarSource,
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
            format.scale = 1
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

        private static func stamp(_ source: RadarSource) -> String {
            if case .rainViewer(let frame) = source { return frame.id }
            if case .noaa(let region, let product) = source {
                return "noaa-\(region.rawValue)-\(product.rawValue)"
            }
            return "noaa"
        }

        private static func signature(of sources: [RadarSource], region: MKCoordinateRegion) -> String {
            let box = String(format: "%.3f,%.3f,%.3f",
                             region.center.latitude, region.center.longitude,
                             region.span.latitudeDelta)
            return sources.map(stamp).joined(separator: ",") + "|" + box
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
