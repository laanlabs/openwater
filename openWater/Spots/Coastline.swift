import CoreGraphics
import CoreLocation
import Foundation
import MapKit

// MARK: - The coastline, in the app

/// Where the water is, from a coastline the app carries rather than asks for.
///
/// The current wash must not paint over land, and two earlier answers to that
/// both failed in instructive ways.
///
/// The first trusted the ocean model to say: it answers nil over land, so
/// painting only where it answered ought to have painted only water. Measured
/// on 19 August 2026 that is not what the marine API does — asked for a point
/// on dry land it *snaps to the nearest sea cell* and answers with that cell's
/// water. Hayward's hills came back with two tenths of a knot from a cell
/// twenty-one kilometres away. The wash ran up Market Street because the model
/// told it to.
///
/// The second asked Open-Meteo's elevation endpoint, which does know about
/// ground — but it is billed *per coordinate* against roughly six hundred a
/// minute, and masking one bay view at a kilometre costs about three thousand
/// of them. The tile budget that kept it inside the allowance also pinned any
/// view wider than twelve kilometres to eleven-kilometre samples, and San
/// Francisco Bay is ten to twenty kilometres wide. One sample decided an
/// eleven-kilometre square was entirely land or entirely water, which missed
/// both ways at once: wash left standing over Marin, and square holes punched
/// out of open water.
///
/// The lesson both times is that a coastline is not a per-point question. It
/// is a shape, it is geography rather than weather, and it has not moved in
/// the lifetime of this app — so it ships inside it. `scripts/build-coastline.py`
/// packs Natural Earth's 1:10m land into `coastline.bin`, the file is
/// memory-mapped rather than read, and a view's mask is rasterized from it in
/// one pass. No network, no quota, no coarser answer for a wider view, and it
/// works on a boat with no signal.
///
/// What it cannot do is resolve below about a kilometre: Alcatraz is not in
/// the 1:10m data at all. That is the right trade for a wash whose own cells
/// are a kilometre across, and a wash over Alcatraz is a rounding error beside
/// a wash over Marin.
///
/// Inland water is deliberately *not* cut out — Lake Tahoe and the Columbia
/// River both count as land here. That costs nothing: the layer this masks is
/// an ocean current model, which has nothing to say about either.
nonisolated enum Coastline {

    /// The packed file, mapped once and never copied.
    ///
    /// Three megabytes of polygons that only the coastal ones of are ever
    /// touched, so mapping is the whole trick: the kernel pages in what a view
    /// actually reads and the app's resident size barely moves.
    private static let store = Store.bundled()

    struct Store {
        let data: Data
        let count: Int
        /// Byte offsets of the three sections, worked out once from the header.
        let boxes: Int
        let offsets: Int
        let blob: Int

        static func bundled() -> Store? {
            guard let url = Bundle.main.url(forResource: "coastline", withExtension: "bin"),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count > 12
            else { return nil }
            return Store(data)
        }

        init?(_ data: Data) {
            guard data.count > 12,
                  data[data.startIndex] == 0x4F,      // O
                  data[data.startIndex + 1] == 0x57,  // W
                  data[data.startIndex + 2] == 0x4C,  // L
                  data[data.startIndex + 3] == 0x4D   // M
            else { return nil }
            self.data = data
            let version: UInt32 = data.value(at: 4)
            let count: UInt32 = data.value(at: 8)
            guard version == 1, count > 0 else { return nil }
            self.count = Int(count)
            boxes = 12
            offsets = boxes + Int(count) * 16
            blob = offsets + Int(count) * 4
            guard data.count > blob else { return nil }
        }

        /// A polygon's bounds, in micro-degrees.
        func box(_ index: Int) -> (minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32) {
            let at = boxes + index * 16
            return (data.value(at: at), data.value(at: at + 4),
                    data.value(at: at + 8), data.value(at: at + 12))
        }

        /// Walk a polygon's rings without building an array of them — this is
        /// the inner loop of rasterizing a continent, and every ring allocated
        /// here would be a ring thrown away a microsecond later.
        func forEachRing(_ index: Int, _ body: (_ points: Int, _ at: Int) -> Void) {
            var at = blob + Int(data.value(at: offsets + index * 4) as UInt32)
            let rings: UInt32 = data.value(at: at)
            at += 4
            for _ in 0..<Int(rings) {
                let points = Int(data.value(at: at) as UInt32)
                at += 4
                body(points, at)
                at += points * 8
            }
        }

        func point(at offset: Int) -> (lat: Int32, lon: Int32) {
            (data.value(at: offset), data.value(at: offset + 4))
        }
    }

    /// Whether the coastline is aboard at all. False means the asset is
    /// missing from the bundle, and every mask comes back empty — which the
    /// wash already reads as "paint it all", the same as it did before any of
    /// this existed.
    static var isAvailable: Bool { store != nil }

    /// Rasterize the land inside a region.
    ///
    /// Drawn rather than tested point by point. Filling polygons is what Core
    /// Graphics does in hardware-adjacent C, and the alternative — ray-casting
    /// every one of the wash's cells against every nearby ring — is the same
    /// arithmetic done slowly in Swift, once per cell instead of once per view.
    static func mask(for region: MKCoordinateRegion, pixels: Int = 512) -> WaterMask {
        guard let store else { return WaterMask() }

        let latSpan = region.span.latitudeDelta
        let lonSpan = region.span.longitudeDelta
        let south = region.center.latitude - latSpan / 2
        let west = region.center.longitude - lonSpan / 2
        guard latSpan > 0, lonSpan > 0 else { return WaterMask() }

        // Square pixels, so a wide-and-short region does not get a coastline
        // stretched along one axis. The long side sets the resolution.
        let aspect = lonSpan / latSpan
        let width = max(16, min(pixels, Int((Double(pixels) * min(aspect, 1)).rounded())))
        let height = max(16, min(pixels, Int((Double(pixels) / max(aspect, 1)).rounded())))

        let minLat = Int32((south * 1e6).rounded(.down))
        let maxLat = Int32(((south + latSpan) * 1e6).rounded(.up))
        let minLon = Int32((west * 1e6).rounded(.down))
        let maxLon = Int32(((west + lonSpan) * 1e6).rounded(.up))

        var land = [UInt8](repeating: 0, count: width * height)
        land.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }

            // No antialiasing: this is a yes-or-no about a cell, and a grey
            // edge pixel would have to be thresholded back into one anyway.
            context.setShouldAntialias(false)
            context.setFillColor(gray: 1, alpha: 1)

            let xScale = Double(width) / lonSpan
            let yScale = Double(height) / latSpan

            for index in 0..<store.count {
                let box = store.box(index)
                // The bboxes sit together at the front of the file precisely
                // so this scan is one contiguous run rather than a walk over
                // three megabytes.
                guard box.maxLat >= minLat, box.minLat <= maxLat,
                      box.maxLon >= minLon, box.minLon <= maxLon
                else { continue }

                let path = CGMutablePath()
                store.forEachRing(index) { points, at in
                    guard points > 2 else { return }
                    for step in 0..<points {
                        let point = store.point(at: at + step * 8)
                        let x = (Double(point.lon) / 1e6 - west) * xScale
                        let y = (Double(point.lat) / 1e6 - south) * yScale
                        if step == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    path.closeSubpath()
                }
                guard !path.isEmpty else { continue }
                context.addPath(path)
                // Even-odd, so a lagoon inside an atoll stays water. Filled
                // per polygon rather than once for the lot: two overlapping
                // islands under one even-odd fill would cancel where they
                // meet and open a hole in dry land.
                context.fillPath(using: .evenOdd)
            }
        }

        return WaterMask(south: south, west: west, latSpan: latSpan, lonSpan: lonSpan,
                         width: width, height: height, land: land)
    }
}

// MARK: - One view's answer

/// A rectangle of the world, rasterized once, answering land or water in
/// constant time.
///
/// Deliberately a value: the wash hands it to the cell builder and to the
/// field renderer, both of which run on their own schedule, and a shared
/// mutable mask would be a coastline changing shape under a draw.
nonisolated struct WaterMask {

    private var south = 0.0
    private var west = 0.0
    private var latSpan = 0.0
    private var lonSpan = 0.0
    private var width = 0
    private var height = 0
    /// Row-major from the *top*, matching Core Graphics' buffer layout: 0 is
    /// water, anything else is land.
    private var land: [UInt8] = []

    init() {}

    init(south: Double, west: Double, latSpan: Double, lonSpan: Double,
         width: Int, height: Int, land: [UInt8]) {
        self.south = south
        self.west = west
        self.latSpan = latSpan
        self.lonSpan = lonSpan
        self.width = width
        self.height = height
        self.land = land
    }

    var isEmpty: Bool { land.isEmpty }

    /// Whether this point is water — nil when it falls outside the rasterized
    /// rectangle, so a caller can tell "land" from "not known" and paint
    /// rather than blink while a new region is being drawn.
    func isWater(_ coordinate: CLLocationCoordinate2D) -> Bool? {
        guard !land.isEmpty, latSpan > 0, lonSpan > 0 else { return nil }
        let fx = (coordinate.longitude - west) / lonSpan
        let fy = (coordinate.latitude - south) / latSpan
        guard fx >= 0, fx < 1, fy >= 0, fy < 1 else { return nil }

        let column = min(width - 1, Int(fx * Double(width)))
        // The raster was drawn in Core Graphics' space, whose origin is at the
        // bottom, into a buffer whose first row is the top. Flipping here is
        // what keeps a coastline from being masked upside down.
        let row = min(height - 1, height - 1 - Int(fy * Double(height)))
        return land[row * width + column] == 0
    }
}

// MARK: - Reading the packed file

nonisolated private extension Data {
    /// A little-endian scalar at a byte offset from the start.
    ///
    /// Unaligned on purpose. Every field in this file is four-byte aligned by
    /// construction, but a mapped `Data` makes no promise about where its
    /// slice begins, and an aligned load from an odd address is a crash rather
    /// than a slow read.
    func value<T>(at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}
