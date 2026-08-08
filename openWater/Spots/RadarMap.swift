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
    /// Flip this once a plan is in place. Everything below already works: the
    /// frame index loads, the tiles render, the scrubber animates. Nothing
    /// else has to change.
    static let allowsRainViewer = false

    var attribution: String {
        switch self {
        case .noaa(let region, _): "NOAA / National Weather Service, \(region.label) mosaic"
        case .rainViewer: "RainViewer"
        }
    }

    var coverage: String {
        switch self {
        case .noaa(let region, let product):
            "\(product.explanation) Showing \(region.label) — NOAA also covers Hawaii, Alaska, the Caribbean and Guam, and nowhere else on earth."
        case .rainViewer:
            "Global, though thin outside radar-covered countries."
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

    var label: String {
        switch self {
        case .base: "Rain"
        case .composite: "Storm cores"
        case .echoTops: "Storm tops"
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
        let all = (payload.radar?.past ?? []) + (payload.radar?.nowcast ?? [])
        return all.map {
            RainViewerFrame(host: payload.host, path: $0.path,
                            time: Date(timeIntervalSince1970: $0.time))
        }
    }
}

// MARK: - The overlay

/// `MKTileOverlay` whose URLs are computed rather than templated, because
/// NOAA's WMS needs a bounding box rather than z/x/y substitution.
///
/// `url(forTilePath:)` is called off the main actor by MapKit's tile loader,
/// so this holds nothing mutable and does its work in a `Sendable` closure.
final class RadarTileOverlay: MKTileOverlay, @unchecked Sendable {

    private let build: @Sendable (Int, Int, Int) -> URL?

    init(source: RadarSource) {
        self.build = { x, y, z in source.tileURL(x: x, y: y, z: z) }
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        // The radar sits on top of the map, it does not replace it — a radar
        // sweep with no coastline under it tells a rider nothing.
        canReplaceMapContent = false
        minimumZ = 3
        maximumZ = 12
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

    func updateUIView(_ map: MKMapView, context: Context) {
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
    @State private var product: RadarProduct = .base

    private var region: RadarRegion { .covering(centre) }

    private var source: RadarSource {
        if RadarSource.allowsRainViewer, let frame = frames[safe: index] {
            return .rainViewer(frame: frame)
        }
        return .noaa(region: region, product: product)
    }

    var body: some View {
        RadarMapView(centre: centre, source: source, style: settings.mapStyle)
            .ignoresSafeArea(edges: Edge.Set.bottom)
            .safeAreaInset(edge: VerticalEdge.bottom) { footer }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(NavigationBarItem.TitleDisplayMode.inline)
            .task {
                frames = await RainViewer.frames()
                index = max(0, frames.count - 1)
            }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Layer", selection: $product) {
                ForEach(RadarProduct.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if RadarSource.allowsRainViewer, frames.count > 1 {
                scrubber
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
                    set: { index = Int($0.rounded()) }
                ),
                in: 0...Double(max(1, frames.count - 1)),
                step: 1
            )

            if let frame = frames[safe: index] {
                Text(frame.time.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 62, alignment: .trailing)
            }
        }
    }
}
