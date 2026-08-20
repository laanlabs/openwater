import CoreLocation
import Foundation
import MapKit

/// Where the water actually is, at ninety metres.
///
/// The current wash used to trust the ocean model to say: it answers nil over
/// land, so painting only where it answered ought to have painted only water.
/// Measured on 19 August 2026, that is not what the marine API does — asked
/// for a point on dry land it *snaps to the nearest sea cell* and answers with
/// that cell's water. Hayward's hills came back with two tenths of a knot from
/// a cell twenty-one kilometres away; downtown San Francisco came back with
/// eight tenths from the bay. The wash ran up Market Street because the model
/// told it to.
///
/// So the mask comes from somewhere that knows about ground: Open-Meteo's
/// elevation endpoint, which is the Copernicus 90 m DEM, free and keyless like
/// everything else here. Sea reads 0 m and the city reads 75, which is the
/// whole test. It is fetched in tiles on a fixed global lattice so panning
/// reuses what is already held, a hundred points a tile because that is the
/// endpoint's hard limit, and cached for half a year: coastlines are geology,
/// not weather, and the one thing this app can safely keep is the shape of the
/// land.
///
/// Inland water is deliberately *not* covered — Tahoe's surface reads 1,897 m
/// and counts as land here. That costs nothing: the layer this masks is an
/// ocean current model, which has nothing to say about a lake either.
struct WaterMask {

    /// Two lattices, because one cannot serve both ends of the zoom.
    ///
    /// Fine is a tenth of a degree a tile — about a kilometre between
    /// samples, which draws a bay's shoreline properly. It is also sixty-odd
    /// tiles for a view of a whole coastline, which is sixty requests for a
    /// coastline drawn at five kilometres a cell: pointless. So a wide view
    /// switches to whole-degree tiles, eleven kilometres a sample, one or two
    /// requests, and the wash stops covering Sonoma. Both are ten samples a
    /// side because a hundred points is the endpoint's hard limit.
    enum Grain: Hashable, CaseIterable {
        case fine, medium, coarse

        var degrees: Double {
            switch self {
            case .fine: 0.1     // ~1 km a sample — a harbour's shoreline
            case .medium: 0.3   // ~3 km — a bay
            case .coarse: 1.0   // ~11 km — a coastline
            }
        }

        /// The finest lattice that covers this view inside the tile budget.
        ///
        /// Budget rather than a fixed zoom threshold, because what matters is
        /// how many requests a view costs, and that is what actually goes
        /// wrong: a first pass at this fetched sixty fine tiles for a bay in
        /// one burst and walked straight into Open-Meteo's per-minute limit,
        /// so the mask never arrived and the wash stayed over Sonoma. Two
        /// dozen requests is the most any one view is worth.
        static func serving(_ region: MKCoordinateRegion) -> Grain {
            allCases.first { tiles(for: region, grain: $0) <= budget } ?? .coarse
        }

        /// Five, and the number comes from the meter rather than from taste.
        ///
        /// Open-Meteo charges the elevation endpoint **per coordinate**, not
        /// per request — measured on 19 August 2026, when a pass of
        /// forty-odd hundred-point tiles refused itself and every request for
        /// minutes after. A hundred points is a sixth of the free minute's
        /// six hundred, so five tiles is the most a single view may ever
        /// spend, and the grain ladder does the rest: five fine tiles is a
        /// harbour at a kilometre, five medium is a bay at three, five coarse
        /// is a coastline at eleven. Ask for a finer coastline than that and
        /// the answer is not more requests — it is a bundled shoreline, which
        /// costs bytes instead of calls.
        static let budget = 5

        /// The worst case: a span crossing tile boundaries needs one more
        /// tile than it covers, never two. The extra one this used to add on
        /// each axis was enough to push a bay — thirty fine tiles — over the
        /// budget and down to the three-kilometre lattice, which is a
        /// coastline you can see the steps in from across the water.
        static func tiles(for region: MKCoordinateRegion, grain: Grain) -> Int {
            let rows = Int(ceil(region.span.latitudeDelta / grain.degrees)) + 1
            let columns = Int(ceil(region.span.longitudeDelta / grain.degrees)) + 1
            return rows * columns
        }
    }

    static let samplesPerSide = 10

    struct Key: Hashable {
        let grain: Grain
        let latIndex: Int
        let lonIndex: Int

        init(covering coordinate: CLLocationCoordinate2D, grain: Grain) {
            self.grain = grain
            latIndex = Int(floor(coordinate.latitude / grain.degrees))
            lonIndex = Int(floor(coordinate.longitude / grain.degrees))
        }

        init(grain: Grain, latIndex: Int, lonIndex: Int) {
            self.grain = grain
            self.latIndex = latIndex
            self.lonIndex = lonIndex
        }

        var south: Double { Double(latIndex) * grain.degrees }
        var west: Double { Double(lonIndex) * grain.degrees }
    }

    /// Row-major from the tile's south-west corner: true where the DEM says
    /// this sample is at or below sea level.
    private var tiles: [Key: [Bool]] = [:]

    var isEmpty: Bool { tiles.isEmpty }

    func has(_ key: Key) -> Bool { tiles[key] != nil }

    mutating func insert(_ samples: [Bool], for key: Key) {
        tiles[key] = samples
    }

    /// The hard ceiling, after the grain has already been chosen to fit the
    /// budget. Past it the wash is a continental smear.
    static let maxTiles = 40

    /// Whether every tile a region needs is held.
    ///
    /// The mask is all or nothing per view, and this is why: a half-loaded
    /// mask paints the tiles it has and leaves the rest, which is not a
    /// coastline — it is a chequerboard of rectangles that says the app is
    /// broken. So the wash paints unmasked until the whole view can be
    /// masked properly, and switches over in one go.
    func covers(_ region: MKCoordinateRegion) -> Bool {
        let needed = Self.keys(covering: region)
        return !needed.isEmpty && needed.allSatisfy { has($0) }
    }

    /// How coarse the answer for this view will be, in metres — the caption's
    /// business, and the honest footnote on a masked coastline.
    static func grainMetres(for region: MKCoordinateRegion) -> Double {
        Grain.serving(region).degrees / Double(samplesPerSide) * 110_574
    }

    /// Whether this point is water — nil when its tile has not landed yet, so
    /// a caller can tell "land" from "not known", and paint rather than blink
    /// while the mask fills in.
    func isWater(_ coordinate: CLLocationCoordinate2D) -> Bool? {
        // The finer answer wins wherever one is held: a rider zoomed into a
        // harbour keeps its kilometre coastline even though the whole-degree
        // tile over it says the same water more vaguely.
        for grain in Grain.allCases {
            if let answer = isWater(coordinate, grain: grain) { return answer }
        }
        return nil
    }

    private func isWater(_ coordinate: CLLocationCoordinate2D, grain: Grain) -> Bool? {
        let key = Key(covering: coordinate, grain: grain)
        guard let samples = tiles[key] else { return nil }
        let step = grain.degrees / Double(Self.samplesPerSide)
        let row = min(Self.samplesPerSide - 1,
                      max(0, Int((coordinate.latitude - key.south) / step)))
        let column = min(Self.samplesPerSide - 1,
                         max(0, Int((coordinate.longitude - key.west) / step)))
        return samples[row * Self.samplesPerSide + column]
    }

    // MARK: Fetching

    /// The tiles a region needs, nearest the middle first.
    ///
    /// Bounded to the *visible* region rather than the whole field: the field
    /// is floored at forty-five kilometres and can be a continent, and a mask
    /// for water nobody is looking at is a hundred requests for nothing. What
    /// is on screen gets masked; the rest fills in as a rider pans, out of the
    /// cache from then on.
    static func keys(covering region: MKCoordinateRegion, limit: Int = .max) -> [Key] {
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2
        guard north > south, east > west else { return [] }

        let grain = Grain.serving(region)
        let first = Key(covering: CLLocationCoordinate2D(latitude: south, longitude: west), grain: grain)
        let last = Key(covering: CLLocationCoordinate2D(latitude: north, longitude: east), grain: grain)
        // Past this even the coarse lattice is more requests than a view
        // that wide is worth, and one wash cell there is tens of kilometres
        // across — a coastline is nobody's question at that zoom.
        guard (last.latIndex - first.latIndex + 1) * (last.lonIndex - first.lonIndex + 1) <= maxTiles
        else { return [] }

        let centre = Key(covering: region.center, grain: grain)
        var out: [Key] = []
        for latIndex in first.latIndex...last.latIndex {
            for lonIndex in first.lonIndex...last.lonIndex {
                out.append(Key(grain: grain, latIndex: latIndex, lonIndex: lonIndex))
            }
        }
        return out.sorted {
            let a = abs($0.latIndex - centre.latIndex) + abs($0.lonIndex - centre.lonIndex)
            let b = abs($1.latIndex - centre.latIndex) + abs($1.lonIndex - centre.lonIndex)
            return a < b
        }.prefix(limit).map { $0 }
    }

    /// One tile: a hundred elevations, cached for half a year.
    static func fetch(_ key: Key) async -> [Bool]? {
        let step = key.grain.degrees / Double(samplesPerSide)
        var latitudes: [String] = [], longitudes: [String] = []
        for row in 0..<samplesPerSide {
            for column in 0..<samplesPerSide {
                latitudes.append(String(format: "%.4f", key.south + (Double(row) + 0.5) * step))
                longitudes.append(String(format: "%.4f", key.west + (Double(column) + 0.5) * step))
            }
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
        components.queryItems = [
            .init(name: "latitude", value: latitudes.joined(separator: ",")),
            .init(name: "longitude", value: longitudes.joined(separator: ",")),
        ]
        guard let url = components.url,
              // Half a year. The DEM is a decade old and the coast has not
              // moved; this is the one fetch in the app that would be safe
              // cached for ever, and half a year is only humility about that.
              let data = await ForecastCache.data(from: url, ttl: 180 * 86_400),
              // A rate-limited answer is JSON too, and reads as a tile with
              // no elevations rather than an error — hence the count check
              // below, which is what tells a refusal from a coastline.
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elevations = root["elevation"] as? [Any],
              elevations.count == samplesPerSide * samplesPerSide
        else { return nil }

        // At or below the datum is water. A metre of margin, because a DEM
        // reads a beach and a salt flat as a whisker above zero and calling
        // those land would nibble the wash off every shoreline it touches.
        return elevations.map { value in
            guard let metres = value as? Double else { return false }
            return metres <= 1
        }
    }
}
