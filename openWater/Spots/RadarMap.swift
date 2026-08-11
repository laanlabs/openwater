import MapKit
import OpenWaterCore
import SwiftUI

// MARK: - Where the tiles come from

/// A radar tile layer.
///
/// Apple's WeatherKit does not do this. It gives current conditions,
/// minute-by-minute precipitation, forecasts and alerts — no imagery and no
/// tile layer. The Weather app's radar is not exposed through the framework,
/// so radar has to come from somewhere else.
///
/// Two somewheres, kept behind one interface because the choice between them
/// is a licensing question rather than a technical one and may well change.
enum RadarSource: Hashable {

    /// NOAA's RIDGE II mosaic, served as WMS. Keyless, and US federal work —
    /// public domain, so there is nothing to agree to. One frame: whatever
    /// the mosaic currently holds.
    case noaa(region: RadarRegion, product: RadarProduct)

    /// RainViewer, global, with roughly two hours of past frames that can be
    /// animated. Each frame is a path from their index.
    ///
    /// **Not enabled.** See `RadarSource.allowsRainViewer`.
    case rainViewer(frame: RainViewerFrame)

    /// The switch.
    ///
    /// RainViewer's public endpoint needs no key and works perfectly — it is
    /// the better layer by some distance, being global and animatable. What is
    /// unresolved is whether their free tier covers an App Store app;  it
    /// reads as non-commercial, and shipping against it on that reading would
    /// be someone else's licence broken quietly.
    ///
    /// Enabled: openWater is not a commercial product, which is the condition
    /// their free tier is written around. Attribution is shown on the screen.
    static let allowsRainViewer = true

    var attribution: String {
        switch self {
        case .noaa(let region, _): "NOAA / National Weather Service, \(region.label) mosaic"
        case .rainViewer: "RainViewer"
        }
    }

    /// How far in each provider's tiles go.
    ///
    /// RainViewer's free tilecache stops at zoom 7. Above it every tile is
    /// the same 1,370-byte grey "Zoom Level Not Supported" placeholder rather
    /// than a 404, so the map fills with legible complaints instead of
    /// failing quietly — which is exactly what it did. Measured, not guessed:
    /// z5 and z7 return real data, z8 upward return the placeholder.
    ///
    /// Capping here makes MapKit upscale the last good tiles instead of
    /// asking for ones that do not exist. The loop is therefore coarser than
    /// the NOAA stills, which is the trade for having a past at all.
    var maximumZoom: Int {
        switch self {
        case .noaa: 12
        case .rainViewer: 7
        }
    }

    var coverage: String {
        switch self {
        case .noaa(let region, let product):
            "\(product.explanation) Showing \(region.label) — NOAA also covers Hawaii, Alaska, the Caribbean and Guam, and nowhere else on earth."
        case .rainViewer(let frame):
            frame.isForecast
            ? "Nowcast — where the radar echo is projected to be, not an observation."
            : "Global, though thin outside radar-covered countries. Observations only: RainViewer's free feed is not publishing a forecast."
        }
    }

    /// Web Mercator's half-circumference in metres: the edge of the projected
    /// world, and the constant every slippy-tile-to-bbox conversion turns on.
    private static let mercatorEdge = 20_037_508.342789244

    /// One tile.
    ///
    /// Both providers are addressed by the same z/x/y scheme MapKit hands us,
    /// but NOAA speaks WMS rather than XYZ, so its tile has to be described as
    /// a bounding box in projected metres. The arithmetic is the standard
    /// conversion: the world is `2^z` tiles wide, y counts down from the top.
    func tileURL(x: Int, y: Int, z: Int) -> URL? {
        switch self {
        case .noaa(let region, let product):
            let span = (Self.mercatorEdge * 2) / pow(2, Double(z))
            let minX = -Self.mercatorEdge + Double(x) * span
            let maxY = Self.mercatorEdge - Double(y) * span
            let bbox = [minX, maxY - span, minX + span, maxY]
                .map { String(format: "%.3f", $0) }
                .joined(separator: ",")
            let layer = "\(region.rawValue)_\(product.suffix)"
            var components = URLComponents(
                string: "https://opengeo.ncep.noaa.gov/geoserver/\(region.rawValue)/\(layer)/ows")!
            components.queryItems = [
                .init(name: "service", value: "WMS"),
                .init(name: "version", value: "1.1.1"),
                .init(name: "request", value: "GetMap"),
                .init(name: "layers", value: layer),
                .init(name: "styles", value: ""),
                .init(name: "format", value: "image/png"),
                .init(name: "transparent", value: "true"),
                .init(name: "srs", value: "EPSG:3857"),
                .init(name: "bbox", value: bbox),
                .init(name: "width", value: "256"),
                .init(name: "height", value: "256"),
            ]
            return components.url

        case .rainViewer(let frame):
            // colour 4 is their "Universal Blue" ramp; 1_1 asks for smoothed
            // tiles with snow shown separately.
            return URL(string: "\(frame.host)\(frame.path)/256/\(z)/\(x)/\(y)/4/1_1.png")
        }
    }
}

/// Which mosaic covers a point.
///
/// "Continental United States only" was true of the layer we happened to
/// pick, not of NOAA. The same four products exist for Hawaii, Alaska, the
/// Caribbean and Guam — and Hawaii in particular is not a footnote for this
/// sport.
enum RadarRegion: String, CaseIterable, Hashable {
    case conus, hawaii, alaska, carib, guam

    var label: String {
        switch self {
        case .conus: "the continental US"
        case .hawaii: "Hawaii"
        case .alaska: "Alaska"
        case .carib: "the Caribbean"
        case .guam: "Guam"
        }
    }

    /// Rough footprints, generous at the edges — a mosaic that returns empty
    /// tiles is a better failure than picking the wrong one and showing
    /// nothing at all.
    private var box: (lat: ClosedRange<Double>, lon: ClosedRange<Double>) {
        switch self {
        case .conus: (24...50, -125...(-66))
        case .hawaii: (18...23, -161...(-154))
        case .alaska: (51...72, -180...(-129))
        case .carib: (16...20, -68...(-64))
        case .guam: (12...16, 143...147)
        }
    }

    static func covering(_ coordinate: Geo.Coordinate) -> RadarRegion {
        allCases.first {
            $0.box.lat.contains(coordinate.latitude) && $0.box.lon.contains(coordinate.longitude)
        } ?? .conus
    }
}

/// What the radar is being asked to show.
///
/// Four products, all free, and each answers a different question. Echo tops
/// is the interesting one here: it is the height of the storm, and a tall
/// echo top is deep convection — which is as close as free public data gets
/// to "is there lightning in that cell", since no free strike feed exists.
enum RadarProduct: String, CaseIterable, Hashable {
    case base, composite, echoTops, precipitationType

    var suffix: String {
        switch self {
        case .base: "bref_qcd"
        case .composite: "cref_qcd"
        case .echoTops: "neet_v18"
        case .precipitationType: "pcpn_typ"
        }
    }

    /// Short enough to fit five segments on the narrowest phone.
    ///
    /// "Storm cores" and "Storm tops" were being truncated to "Storm co…"
    /// and "Storm to…", which are indistinguishable from each other — the
    /// one thing a label must never be. The caption underneath carries the
    /// full meaning, so these only have to tell the four apart.
    var label: String {
        switch self {
        case .base: "Rain"
        case .composite: "Cores"
        case .echoTops: "Tops"
        case .precipitationType: "Type"
        }
    }

    var explanation: String {
        switch self {
        case .base:
            "Base reflectivity — what the lowest radar sweep sees, which is closest to what is falling on you."
        case .composite:
            "Composite reflectivity — the strongest return anywhere in the column, so a cell that looks mild at ground level but is violent aloft shows up."
        case .echoTops:
            "Echo tops — how high the storm reaches. Tall tops mean deep convection: the free stand-in for a lightning map, since no free strike feed can be redistributed."
        case .precipitationType:
            "Precipitation type — rain, snow, ice or mixed, which decides what the water is doing as much as how much of it there is."
        }
    }
}

/// One radar frame from RainViewer's index, with the time it was captured.
struct RainViewerFrame: Hashable, Identifiable {
    let host: String
    let path: String
    let time: Date
    /// A nowcast frame rather than an observation.
    var isForecast: Bool = false
    var id: String { path }
}

/// Loads RainViewer's frame index — the two hours of past scans, in order.
enum RainViewer {
    static func frames() async -> [RainViewerFrame] {
        guard RadarSource.allowsRainViewer,
              let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }

        struct Payload: Decodable {
            struct Frame: Decodable { let time: Double; let path: String }
            struct Radar: Decodable { let past: [Frame]?; let nowcast: [Frame]? }
            let host: String
            let radar: Radar?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        // Observations, then the nowcast — which RainViewer publishes as its
        // own array and, on the free endpoint, has been returning empty. The
        // key is there and the frames are not, so this stays wired up and
        // simply lights up if they appear.
        let past = (payload.radar?.past ?? []).map {
            RainViewerFrame(host: payload.host, path: $0.path,
                            time: Date(timeIntervalSince1970: $0.time))
        }
        let ahead = (payload.radar?.nowcast ?? []).map {
            RainViewerFrame(host: payload.host, path: $0.path,
                            time: Date(timeIntervalSince1970: $0.time), isForecast: true)
        }
        return past + ahead
    }
}

// MARK: - The overlay

/// One cache, shared by the overlay that draws tiles and the prefetcher that
/// warms them.
///
/// Both have to go through the same store or the prefetch is wasted work: the
/// loop was flashing frames because each one began downloading only as it was
/// shown, and a 260 ms step is not long enough to fetch a screen of tiles.
enum RadarTiles {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Radar frames are small and there are at most a few hundred of them
        // in a session; this is comfortably enough to hold a whole loop.
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20,
                                          diskCapacity: 256 << 20,
                                          diskPath: "radar-tiles")
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    /// Every tile covering a region at a zoom — the set a frame needs before
    /// it can be shown whole.
    static func tiles(covering region: MKCoordinateRegion, zoom: Int) -> [(x: Int, y: Int)] {
        func x(_ longitude: Double) -> Int {
            Int((longitude + 180) / 360 * Double(1 << zoom))
        }
        func y(_ latitude: Double) -> Int {
            let clamped = min(max(latitude, -85.05), 85.05) * .pi / 180
            let value = (1 - log(tan(clamped) + 1 / cos(clamped)) / .pi) / 2
            return Int(value * Double(1 << zoom))
        }
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let limit = (1 << zoom) - 1
        var out: [(Int, Int)] = []
        for tx in max(0, x(west))...min(limit, x(east)) {
            for ty in max(0, y(north))...min(limit, y(south)) {
                out.append((tx, ty))
            }
        }
        return out
    }
}

/// `MKTileOverlay` whose URLs are computed rather than templated, because
/// NOAA's WMS needs a bounding box rather than z/x/y substitution.
///
/// `url(forTilePath:)` is called off the main actor by MapKit's tile loader,
/// so this holds nothing mutable and does its work in a `Sendable` closure.
final class RadarTileOverlay: MKTileOverlay, @unchecked Sendable {

    private let build: @Sendable (Int, Int, Int) -> URL?
    /// The deepest zoom this provider actually publishes.
    private let nativeZoom: Int

    init(source: RadarSource) {
        self.build = { x, y, z in source.tileURL(x: x, y: y, z: z) }
        self.nativeZoom = source.maximumZoom
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        // The radar sits on top of the map, it does not replace it — a radar
        // sweep with no coastline under it tells a rider nothing.
        canReplaceMapContent = false
        minimumZ = 3
        // Deliberately past the provider's own ceiling. `maximumZ` only stops
        // MapKit *asking* for deeper tiles — it does not scale the shallow
        // ones up, so capping it left the map simply blank when zoomed in.
        // `loadTile` below serves those requests from the deepest real tile.
        maximumZ = 12
    }

    /// Serve a zoomed-in tile by cropping the deepest real one.
    ///
    /// RainViewer publishes to zoom 7. Asked for zoom 10 it returns a grey
    /// "Zoom Level Not Supported" placeholder, and refusing to ask returns
    /// nothing at all — so above its ceiling this fetches the ancestor tile
    /// that contains the requested one and cuts out the right quadrant.
    /// Coarser as you zoom, which is honest: that is all the data there is.
    override nonisolated func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) {
        guard path.z > nativeZoom else {
            fetch(url(forTilePath: path), result)
            return
        }
        let step = path.z - nativeZoom
        let scale = 1 << step
        let ancestor = MKTileOverlayPath(
            x: path.x / scale, y: path.y / scale, z: nativeZoom,
            contentScaleFactor: path.contentScaleFactor
        )
        fetch(url(forTilePath: ancestor)) { data, error in
            guard let data, let source = UIImage(data: data)?.cgImage else {
                result(data, error)
                return
            }
            let side = CGFloat(source.width) / CGFloat(scale)
            let crop = CGRect(
                x: CGFloat(path.x % scale) * side,
                y: CGFloat(path.y % scale) * side,
                width: side, height: side
            )
            guard let piece = source.cropping(to: crop) else {
                result(data, nil)
                return
            }
            let size = CGSize(width: 256, height: 256)
            let scaled = UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.interpolationQuality = .high
                UIImage(cgImage: piece).draw(in: CGRect(origin: .zero, size: size))
            }
            result(scaled.pngData(), nil)
        }
    }

    /// Through the shared cache, so a prefetched frame draws instantly.
    private nonisolated func fetch(
        _ url: URL, _ result: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) {
        RadarTiles.session.dataTask(with: url) { data, _, error in
            result(data, error)
        }.resume()
    }

    override nonisolated func url(forTilePath path: MKTileOverlayPath) -> URL {
        build(path.x, path.y, path.z)
            // Never reached — both providers build from string interpolation —
            // but `url(forTilePath:)` cannot fail, so it needs somewhere to go.
            ?? URL(string: "data:image/png;base64,")!
    }
}

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

        private var showing: RadarSource?
        private var overlay: MKTileOverlay?
        var onRegionChange: ((MKCoordinateRegion) -> Void)?

        func mapView(_ map: MKMapView, regionDidChangeAnimated: Bool) {
            onRegionChange?(map.region)
        }

        /// Swap the layer only when the source actually changed — scrubbing
        /// frames re-enters this on every slider tick, and removing and adding
        /// the same overlay would flash the map white each time.
        func apply(_ source: RadarSource, to map: MKMapView) {
            guard showing != source else { return }
            if let overlay { map.removeOverlay(overlay) }
            let fresh = RadarTileOverlay(source: source)
            map.addOverlay(fresh, level: .aboveLabels)
            overlay = fresh
            showing = source
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tiles = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
            // Enough to read the sweep, not so much that the coastline and the
            // spot you are deciding about disappear under it.
            renderer.alpha = 0.7
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
        RadarMapView(centre: centre, source: source, style: settings.mapStyle,
                     onRegionChange: { visible = $0 })
            .ignoresSafeArea(edges: Edge.Set.bottom)
            .safeAreaInset(edge: VerticalEdge.bottom) { footer }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(NavigationBarItem.TitleDisplayMode.inline)
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
            Text(source.coverage)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
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
