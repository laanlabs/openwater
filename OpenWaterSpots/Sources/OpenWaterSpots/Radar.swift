import MapKit
import OpenWaterCore
import SwiftUI
import UIKit

// The radar's provider layer, its tile maths and its overlay — moved here
// from the phone so the television draws the same sweep from the same
// sources. What stayed behind is only the two apps' map wrappers: the phone's
// carries a `MapStyleOption` that is its own settings screen's idea, and the
// television has no such setting to carry.

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
public enum RadarSource: Hashable, Sendable {

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
    public static let allowsRainViewer = true

    public var attribution: String {
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
    public var maximumZoom: Int {
        switch self {
        case .noaa: 12
        case .rainViewer: 7
        }
    }

    public var coverage: String {
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
    public func tileURL(x: Int, y: Int, z: Int) -> URL? {
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
                // 512, not 256. Both providers will render a tile at either
                // size, and on a 4K television a 256-pixel tile is drawn at
                // roughly twice its own resolution — which is exactly the
                // blockiness reported from a living room. WMS renders the
                // same bounding box at whatever size it is asked for, so this
                // is real detail rather than an upscale.
                .init(name: "width", value: "512"),
                .init(name: "height", value: "512"),
            ]
            return components.url

        case .rainViewer(let frame):
            // colour 4 is their "Universal Blue" ramp; 1_1 asks for smoothed
            // tiles with snow shown separately.
            // 512 for the reason NOAA's width is 512: RainViewer publishes
            // both sizes at the same paths, and the larger one is the
            // difference between a sweep and a mosaic of squares on a big
            // screen.
            return URL(string: "\(frame.host)\(frame.path)/512/\(z)/\(x)/\(y)/4/1_1.png")
        }
    }
}

/// Which mosaic covers a point.
///
/// "Continental United States only" was true of the layer we happened to
/// pick, not of NOAA. The same four products exist for Hawaii, Alaska, the
/// Caribbean and Guam — and Hawaii in particular is not a footnote for this
/// sport.
public enum RadarRegion: String, CaseIterable, Hashable, Sendable {
    case conus, hawaii, alaska, carib, guam

    public var label: String {
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

    public static func covering(_ coordinate: Geo.Coordinate) -> RadarRegion {
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
public enum RadarProduct: String, CaseIterable, Hashable, Sendable {
    case base, composite, echoTops, precipitationType

    public var suffix: String {
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
    public var label: String {
        switch self {
        case .base: "Rain"
        case .composite: "Cores"
        case .echoTops: "Tops"
        case .precipitationType: "Type"
        }
    }

    public var explanation: String {
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
public struct RainViewerFrame: Hashable, Identifiable, Sendable {
    let host: String
    let path: String
    /// When the sweep was taken. Read by both apps' scrubbers, which have to
    /// print it — a loop with no clock on it is an animation, not a record.
    public let time: Date
    /// A nowcast frame rather than an observation.
    public var isForecast: Bool = false
    public var id: String { path }
}

/// Loads RainViewer's frame index — the two hours of past scans, in order.
public enum RainViewer {
    public static func frames() async -> [RainViewerFrame] {
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
public enum RadarTiles {
    /// Public because both apps prefetch through it. The whole point of this
    /// store is that the warming and the drawing share one cache — a loop
    /// where each frame starts downloading as it is shown flashes, because a
    /// 300 ms step is not long enough to fetch a screen of tiles.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Radar frames are small and there are at most a few hundred of them
        // in a session; this is comfortably enough to hold a whole loop.
        // Kept modest for the television, which has far less memory headroom
        // than a phone and shares this process with a live map and the wash.
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20,
                                          diskCapacity: 128 << 20,
                                          diskPath: "radar-tiles")
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    /// Every tile covering a region at a zoom — the set a frame needs before
    /// it can be shown whole.
    public static func tiles(covering region: MKCoordinateRegion, zoom: Int) -> [(x: Int, y: Int)] {
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
public final class RadarTileOverlay: MKTileOverlay, @unchecked Sendable {

    /// The one frame this overlay serves. Fixed for its life — the loop
    /// swaps whole overlays rather than mutating one, so each frame has a
    /// stable identity and MapKit never confuses one frame's tiles for
    /// another's. See `RadarTileMap.Coordinator.apply`.
    nonisolated private let source: RadarSource

    /// Identifies which frame a cropped tile belongs to, so the cache can
    /// hold a whole loop without confusing one frame for another.
    nonisolated private var stamp: String {
        switch source {
        case .rainViewer(let frame):
            return frame.id
        case .noaa(let region, let product):
            // Region *and* product, not a bare "noaa". They shared the crop
            // cache under one key, so the first NOAA layer fetched — Rain —
            // answered for every other, and Cores, Tops and Type all drew
            // Rain's tiles. Each is a different WMS layer and deserves its
            // own key.
            return "noaa-\(region.rawValue)-\(product.rawValue)"
        }
    }
    /// The deepest zoom this provider actually publishes.
    private var nativeZoom: Int { source.maximumZoom }

    public init(source: RadarSource) {
        self.source = source
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 512, height: 512)
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

    /// Finished tiles, kept.
    ///
    /// This is the loop's whole performance story, and it was measured rather
    /// than guessed. MapKit asks this overlay for zoom 8 while RainViewer
    /// publishes to 7, so every single tile takes the crop path below:
    /// decode a 512-pixel PNG, cut a quadrant out of it, redraw it and
    /// **encode a new PNG**. Instrumented over one loop that was 392 of them,
    /// and `MKTileOverlayRenderer` throws its rendered tiles away for an
    /// overlay it is not currently drawing — so every pass round the loop did
    /// the whole thing again. That is the stutter: not the network, which the
    /// warm step had already covered, but a PNG encoder running thirteen
    /// times a loop.
    ///
    /// Held on the type rather than the instance because the overlays
    /// themselves are rebuilt whenever the layer set changes, and the work is
    /// worth keeping across that. Bounded by count and by bytes: a loop's
    /// worth of tiles is a few megabytes, and the limit is there so a long
    /// session panning around cannot grow without end.
    nonisolated(unsafe) private static let crops: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 400
        // Compressed PNG tile data, so a whole loop is a few megabytes; the
        // ceiling is a backstop, not a working size, and 40 MB is plenty on a
        // television without crowding out the map and the radar images.
        cache.totalCostLimit = 40 << 20
        return cache
    }()

    /// The zoom MapKit last actually asked for.
    ///
    /// Recorded rather than derived. The obvious arithmetic — the world is
    /// 360° across and halves each level — gives 7 for the view that was
    /// measured asking for 8, because MapKit fits a region to a 16:9 screen
    /// and rounds its own way, and 512-pixel tiles shift it again. A preload
    /// that warms the wrong zoom warms nothing, so the one number that
    /// matters is taken from the horse's mouth.

    /// Serve a zoomed-in tile by cropping the deepest real one.
    ///
    /// RainViewer publishes to zoom 7. Asked for zoom 10 it returns a grey
    /// "Zoom Level Not Supported" placeholder, and refusing to ask returns
    /// nothing at all — so above its ceiling this fetches the ancestor tile
    /// that contains the requested one and cuts out the right quadrant.
    /// Coarser as you zoom, which is honest: that is all the data there is.
    public override nonisolated func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) {
        let key = "\(stamp)/\(path.z)/\(path.x)/\(path.y)" as NSString
        if let ready = Self.crops.object(forKey: key) {
            result(ready as Data, nil)
            return
        }
        guard path.z > nativeZoom else {
            fetch(url(forTilePath: path)) { data, error in
                if let data { Self.crops.setObject(data as NSData, forKey: key, cost: data.count) }
                result(data, error)
            }
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
            // The overlay's own tile size, not a literal — these two drifting
            // apart is how a crop comes back at half resolution.
            let size = self.tileSize
            let scaled = UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.interpolationQuality = .high
                UIImage(cgImage: piece).draw(in: CGRect(origin: .zero, size: size))
            }
            let encoded = scaled.pngData()
            if let encoded {
                Self.crops.setObject(encoded as NSData, forKey: key, cost: encoded.count)
            }
            result(encoded, nil)
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

    public override nonisolated func url(forTilePath path: MKTileOverlayPath) -> URL {
        source.tileURL(x: path.x, y: path.y, z: path.z)
            // Never reached — both providers build from string interpolation —
            // but `url(forTilePath:)` cannot fail, so it needs somewhere to go.
            ?? URL(string: "data:image/png;base64,")!
    }
}
