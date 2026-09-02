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
    @State private var loaded: Double = 0
    @State private var isWarming = false
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
            // Warm the whole loop up front, not on the first press of Play.
            // A dissolve holds the old frame only until the new one is drawn;
            // an un-cached frame is not drawn for about a second, which is
            // longer than the dissolve, so it would blank anyway. Warming
            // here makes Step instant and the first loop pass as smooth as
            // the rest.
            await warm()
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
            RadarTileMap(region: region, sources: sources, showing: shownIndex)
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

    private var playLabel: String {
        if isWarming { return "Loading \(Int(loaded * 100))%" }
        return isPlaying ? "Pause" : "Play loop"
    }

    /// Warm every frame's tiles before the loop may run.
    ///
    /// This is the whole fix for the flashing, and it is the phone's own
    /// answer to the same complaint. Playing straight away means each frame
    /// starts downloading as it is shown, and four hundred milliseconds is
    /// nowhere near long enough to fetch a screenful of tiles — so the map
    /// blinks between a drawn frame and a half-empty one. Fetch the lot
    /// first, say so while it happens, and only then start.
    private func togglePlay() {
        // Warmed on entry, so this just plays. Kept as a guard rather than a
        // fetch: if the warm somehow has not finished, wait for it rather
        // than loop over a cold cache.
        guard !isPlaying else { return isPlaying = false }
        Task {
            if loaded < 1 { await warm() }
            isPlaying = true
        }
    }

    private func warm() async {
        guard frames.count > 1, !isWarming, loaded < 1 else { return }
        isWarming = true
        loaded = 0
        defer { isWarming = false }

        // The zoom MapKit is really asking for, not the one arithmetic
        // suggests — see `RadarTileOverlay.lastRequestedZoom`. Warming the
        // wrong zoom warms nothing.
        let zoom = RadarTileOverlay.lastRequestedZoom ?? zoomForView
        let tiles = RadarTiles.tiles(covering: region, zoom: zoom)
        guard !tiles.isEmpty else { loaded = 1; return }

        // Through the overlay's own `loadTile`, not through the URL session.
        //
        // Fetching the raw tiles was the first attempt and it did not cure
        // the stutter, because the network was never the slow part: above
        // RainViewer's zoom every tile is cropped out of a coarser one and
        // re-encoded as a PNG, and that is what the loop was repeating on
        // every pass. Going through `loadTile` performs exactly the work the
        // renderer will ask for and leaves the finished tile in the crop
        // cache, so playing is a lookup.
        let total = frames.count * tiles.count
        var done = 0
        for frame in frames {
            let overlay = RadarTileOverlay(source: .rainViewer(frame: frame))
            await withTaskGroup(of: Void.self) { group in
                for tile in tiles {
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            overlay.loadTile(at: MKTileOverlayPath(
                                x: tile.x, y: tile.y, z: zoom, contentScaleFactor: 1
                            )) { _, _ in continuation.resume() }
                        }
                    }
                }
                for await _ in group { }
            }
            done += tiles.count
            loaded = Double(done) / Double(total)
            if Task.isCancelled { return }
        }
        loaded = 1
    }

    /// Roughly the zoom MapKit is drawing this region at — the world is 360°
    /// across at zoom 0 and halves each level.
    private var zoomForView: Int {
        let span = max(region.span.longitudeDelta, 0.0001)
        return min(max(Int((log2(360 / span)).rounded()), 3), 10)
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
            RadarButton(title: playLabel,
                        systemImage: isPlaying ? "pause.fill" : "play.fill",
                        isOn: isPlaying) { togglePlay() }
                .focused($focus, equals: .play)
                .prefersDefaultFocus(in: bar)
                .disabled(!isGlobal || frames.isEmpty || isWarming)

            if isGlobal, !frames.isEmpty {
                // Pausing and stepping is the whole of scrubbing on a remote —
                // a slider would need the D-pad this screen has not got.
                RadarButton(title: "Step", systemImage: "forward.frame.fill") {
                    isPlaying = false
                    index = (index + 1) % frames.count
                }
                .focused($focus, equals: .step)
            }

            Divider().frame(height: 44)

            RadarButton(title: "More options", systemImage: "slider.horizontal.3") {
                showingLayers = true
                focus = .back
            }
            .focused($focus, equals: .more)
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

/// `MKMapView` in a wrapper, because SwiftUI's `Map` has no tile-overlay API.
///
/// The television's own, separate from the phone's: that one carries a
/// `MapStyleOption` from its settings screen, and this has no such setting to
/// carry. Everything under it — the providers, the tile maths, the overlay
/// that crops a deep tile out of a shallow one — is the shared code in
/// `OpenWaterSpots`.
private struct RadarTileMap: UIViewRepresentable {

    let region: MKCoordinateRegion
    /// Every frame, laid on the map at once.
    let sources: [RadarSource]
    let showing: Int

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        map.isUserInteractionEnabled = false
        map.setRegion(region, animated: false)
        context.coordinator.showing = region
        context.coordinator.apply(sources, index: showing, to: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Only when it actually moved. The loop re-enters this on every frame,
        // and re-setting the region each time fights any animation MapKit has
        // in flight.
        if !context.coordinator.matches(region) {
            context.coordinator.showing = region
            map.setRegion(region, animated: false)
        }
        context.coordinator.apply(sources, index: showing, to: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {

        var showing: MKCoordinateRegion?

        /// The overlay on screen, and the one coming up behind it.
        ///
        /// A hard cut, not a dissolve. Cross-fading two translucent radar
        /// layers blends both frames at once and reads as mud — the dissolve
        /// looked worse than the jump it was meant to cure. A radar loop is
        /// meant to *cut* frame to frame, the way every weather app's does;
        /// the only thing that must not happen is a bare gap between them.
        ///
        /// So the new frame is added on top, opaque, and the old one is taken
        /// down a beat later — never before. By then the new frame has drawn,
        /// because its tiles are warm (the loop is warmed on entry), so the
        /// old one comes down onto a complete picture and the cut is clean. A
        /// fresh overlay per frame keeps each frame's tiles its own; the crop
        /// cache makes a fresh one cheap.
        private var currentOverlay: RadarTileOverlay?
        private var currentKey: String?
        private var layers: [RadarSource] = []

        private static let strength: CGFloat = 0.75

        func matches(_ region: MKCoordinateRegion) -> Bool {
            guard let showing else { return false }
            return abs(showing.center.latitude - region.center.latitude) < 0.0001
                && abs(showing.center.longitude - region.center.longitude) < 0.0001
                && abs(showing.span.latitudeDelta - region.span.latitudeDelta) < 0.0001
        }

        func apply(_ sources: [RadarSource], index: Int, to map: MKMapView) {
            guard sources.indices.contains(index) else { return }

            if sources != layers {
                if let currentOverlay { map.removeOverlay(currentOverlay) }
                currentOverlay = nil
                currentKey = nil
                layers = sources
            }

            let key = stamp(sources[index])
            guard key != currentKey else { return }
            currentKey = key

            let old = currentOverlay
            let new = RadarTileOverlay(source: sources[index])
            map.addOverlay(new, level: .aboveLabels)
            currentOverlay = new

            // Take the old frame down only after the new one is up and drawn,
            // never in the same breath as adding it — the synchronous remove
            // is what left the map bare for a second. A short hop covers the
            // gap between "added" and "painted"; the warm cache keeps that
            // gap to a couple of frames, so this stays invisible.
            guard let old else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak map] in
                map?.removeOverlay(old)
            }
        }

        private func stamp(_ source: RadarSource) -> String {
            if case .rainViewer(let frame) = source { return frame.id }
            return "noaa"
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tiles = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let made = MKTileOverlayRenderer(tileOverlay: tiles)
            made.alpha = Self.strength
            return made
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
