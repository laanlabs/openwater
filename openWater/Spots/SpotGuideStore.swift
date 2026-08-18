import CoreLocation
import Foundation
import OpenWaterCore
import SwiftUI

// MARK: - Models

/// One launch from the public spot guide.
///
/// Decoded from the same Firestore REST responses the website reads — the app
/// carries no Firebase SDK for this, because the guide is a public read-only
/// dataset behind rules that only expose published, real spots. The website's
/// server does exactly this from Node; the phone can do it from URLSession.
struct GuideSpot: Identifiable, Codable, Hashable {
    let spotId: String
    let slug: String?
    let name: String
    let latitude: Double
    let longitude: Double

    let country: String?
    let countryId: String?
    let adminRegion: String?
    let adminRegionId: String?
    let browseRegionIds: [String]

    /// The headline discipline ("Wing Foiling"), plus everything flagged true.
    let preferredActivity: String?
    let activities: [String]

    let bestWinds: String?
    let bestSeason: String?
    let waterState: String?
    /// Degrees true from the beach out to open water, when the guide knows
    /// it. Nobody writes this yet — the guide's editor has no field for it
    /// — but the read side costs a line, and the day the guide grows one,
    /// every spot's surf tab starts judging wind against its own shore.
    let shoreFacingDeg: Double?
    let experienceLevel: String?
    let hazards: String?
    let parking: String?
    let googleMapsURL: String?

    /// Best non-rejected photo, approved first — the site's `bestImage` rule.
    let imageURL: String?
    let imageCredit: String?

    let windStationIds: [String]
    let cameraIds: [String]
    let guideIds: [String]
    let surfSpotIds: [String]
    let tideStationIds: [String]

    /// The nearest-tide-station match embedded on the spot itself — the
    /// fallback when no tideStations documents are linked.
    let tideChartURL: String?
    let tideProvider: String?

    var windStationCount: Int { windStationIds.count }
    var cameraCount: Int { cameraIds.count }
    var guideCount: Int { guideIds.count }
    var surfCount: Int { surfSpotIds.count }
    var tideCount: Int { max(tideStationIds.count, tideChartURL != nil ? 1 : 0) }

    var id: String { spotId }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var where_: String {
        [adminRegion, country].compactMap { $0 }.joined(separator: ", ")
    }

    var resourceCount: Int {
        windStationCount + cameraCount + guideCount + surfCount + tideCount
    }
}

/// A region document: country, admin region, or curated destination.
struct GuideRegion: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let type: String
    let description: String?
    var spotCount: Int = 0
}

/// A current wind reading for a spot, from the same free model feed the
/// website falls back to. Always a model estimate on the phone — labelled as
/// such wherever it is shown, because a rider deciding whether to drive
/// deserves to know it is not an anemometer.
struct WindReading: Codable {
    let speedKn: Double
    let gustKn: Double?
    let directionDeg: Double
    let at: Date

    var cardinal: String { Format.cardinal(directionDeg) }
    /// The "is it on?" threshold the design leads with.
    var isFiring: Bool { speedKn >= 15 }
}

/// One bar of the 12-hour outlook on the detail screen.
struct WindForecastHour: Codable, Identifiable {
    let date: Date
    let speedKn: Double
    let gustKn: Double?
    let directionDeg: Double
    var id: Date { date }
}

// MARK: - A favorites row

/// One row of the favorites tab, whichever kind of saved thing it is —
/// the tab shows them all in one list, so the order has to speak all three.
enum FavoriteItem: Identifiable {
    case spot(GuideSpot)
    case route(PlannedRoute)
    case privateSpot(PrivateSpot)

    /// The persisted order's vocabulary: typed, so a route and a spot
    /// sharing an id string could never collide.
    var key: String {
        switch self {
        case .spot(let spot): "spot:\(spot.spotId)"
        case .route(let route): "route:\(route.id.uuidString)"
        case .privateSpot(let spot): "private:\(spot.id.uuidString)"
        }
    }

    var id: String { key }
}

// MARK: - Store

/// The spot guide: 1000+ launches, cached on disk, favorites, and live wind.
@MainActor
@Observable
final class SpotGuideStore {

    private(set) var spots: [GuideSpot] = []
    private(set) var destinations: [GuideRegion] = []
    private(set) var countries: [GuideRegion] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// Wind readings by spotId. Filled in batches as spots become visible.
    private(set) var wind: [String: WindReading] = [:]

    /// Hourly series by spotId, fetched only once the map's time slider
    /// asks for an hour that is not now. `wind` stays the authority for
    /// now — `current=` is the freshest thing the model will say — and
    /// these are the forecast a scrubbed hour is entitled to.
    private(set) var windHours: [String: [WindForecastHour]] = [:]

    /// Ordered — the rider arranges these by hand in the favorites editor,
    /// so the array is the truth and membership checks ride on it. (It was
    /// a Set once; the persisted shape is the same string array, so old
    /// installs just inherit whatever order the Set happened to save.)
    private(set) var favoriteIds: [String] {
        didSet { UserDefaults.standard.set(favoriteIds, forKey: Self.favoritesKey) }
    }

    /// Spots the rider saved for themselves — never sent anywhere, so they
    /// live wholly in defaults rather than behind the Firestore door the
    /// guide and suggestions go through.
    private(set) var privateSpots: [PrivateSpot] = []

    private static let favoritesKey = "spotGuide.favorites"
    private static let favoritesOrderKey = "spotGuide.favoritesOrder"
    private static let privateSpotsKey = "spotGuide.privateSpots"
    private static let cacheTTL: TimeInterval = 24 * 3600
    private static let windTTL: TimeInterval = 10 * 60

    // The same public, rules-limited access the website's browser client has.
    // A Firebase Web key is a project identifier, not a secret — it ships in
    // every browser that loads openwaterapp.com, and what stops a stranger
    // reading unpublished spots or editing a suggestion is the security rules,
    // not the obscurity of this string. README → "Configuration and keys".
    //
    // Internal, not private: the suggestion client writes through the same
    // door (create-only, bounded by the rules) and must not grow its own copy
    // of these to drift out of sync.
    static let project = "openwaterapp-2e0f7"
    static let apiKey = "AIzaSyD_wieknJx9-v_nRuszJrzaNvohfl0gRq8"
    static let storageBucket = "openwaterapp-2e0f7.firebasestorage.app"
    static var firestoreBase: String {
        "https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)/documents"
    }

    init() {
        favoriteIds = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []
        favoritesOrder = UserDefaults.standard.stringArray(forKey: Self.favoritesOrderKey) ?? []
        if let data = UserDefaults.standard.data(forKey: Self.privateSpotsKey),
           let saved = try? JSONDecoder().decode([PrivateSpot].self, from: data) {
            privateSpots = saved
        }
    }

    func toggleFavorite(_ spotId: String) {
        if let index = favoriteIds.firstIndex(of: spotId) { favoriteIds.remove(at: index) }
        else { favoriteIds.append(spotId) }
    }

    /// In the rider's own order. An id the loaded guide can't resolve is
    /// skipped here but kept in `favoriteIds` — the guide refreshes, the
    /// favorite comes back where it was.
    var favorites: [GuideSpot] {
        favoriteIds.compactMap { id in spots.first { $0.spotId == id } }
    }

    func removeFavorite(_ spotId: String) {
        favoriteIds.removeAll { $0 == spotId }
    }

    // MARK: One list, one order

    /// The favorites tab stopped grouping by type, so the hand-arranged
    /// order has to speak spots, routes and private spots at once: typed
    /// keys, persisted whole. Items the list has never been told about
    /// keep their natural order at the end; keys whose item is gone just
    /// never match, and the next reorder writes them out.
    private(set) var favoritesOrder: [String] {
        didSet { UserDefaults.standard.set(favoritesOrder, forKey: Self.favoritesOrderKey) }
    }

    /// Everything the favorites tab shows, in the rider's own order.
    /// Routes are handed in because they live in their own store.
    func favoriteItems(routes: [PlannedRoute]) -> [FavoriteItem] {
        let items = favorites.map(FavoriteItem.spot)
            + routes.map(FavoriteItem.route)
            + privateSpots.map(FavoriteItem.privateSpot)
        let position = Dictionary(favoritesOrder.enumerated().map { ($1, $0) }) { first, _ in first }
        return items.enumerated().sorted { a, b in
            let pa = position[a.element.key] ?? Int.max
            let pb = position[b.element.key] ?? Int.max
            return pa == pb ? a.offset < b.offset : pa < pb
        }.map(\.element)
    }

    func moveFavoriteItems(routes: [PlannedRoute], fromOffsets: IndexSet, toOffset: Int) {
        var keys = favoriteItems(routes: routes).map(\.key)
        keys.move(fromOffsets: fromOffsets, toOffset: toOffset)
        favoritesOrder = keys
    }

    func addPrivateSpot(_ spot: PrivateSpot) {
        privateSpots.append(spot)
        savePrivateSpots()
    }

    func removePrivateSpot(_ id: UUID) {
        privateSpots.removeAll { $0.id == id }
        savePrivateSpots()
    }

    func renamePrivateSpot(_ id: UUID, to name: String) {
        guard let index = privateSpots.firstIndex(where: { $0.id == id }) else { return }
        privateSpots[index].name = name
        savePrivateSpots()
    }

    func setShoreFacing(_ id: UUID, to degrees: Double?) {
        guard let index = privateSpots.firstIndex(where: { $0.id == id }) else { return }
        privateSpots[index].shoreFacingDeg = degrees
        savePrivateSpots()
    }

    private func savePrivateSpots() {
        UserDefaults.standard.set(try? JSONEncoder().encode(privateSpots),
                                  forKey: Self.privateSpotsKey)
    }

    func spot(id: String) -> GuideSpot? {
        spots.first { $0.spotId == id }
    }

    func spots(inDestination region: GuideRegion) -> [GuideSpot] {
        let byBrowse = spots.filter { $0.browseRegionIds.contains(region.id) }
        if !byBrowse.isEmpty { return byBrowse }
        if let inBox = Self.curatedBox(for: region.id) { return spots.filter(inBox) }
        return []
    }

    func spots(inCountry region: GuideRegion) -> [GuideSpot] {
        spots.filter { $0.countryId == region.id }
    }

    /// The closest launch in the guide — what a call-out means by "here".
    func nearestSpot(to coordinate: Geo.Coordinate) -> GuideSpot? {
        spots.min { a, b in
            Geo.distance(coordinate, .init(latitude: a.latitude, longitude: a.longitude)) <
            Geo.distance(coordinate, .init(latitude: b.latitude, longitude: b.longitude))
        }
    }

    /// Current model wind at an arbitrary coordinate — the tools' entry
    /// point. Same feed, cache and honesty rules as the spot pins; cached
    /// under a synthetic key derived from the rounded coordinate.
    func currentWind(at coordinate: Geo.Coordinate) async -> WindReading? {
        let key = String(format: "@%.3f,%.3f", coordinate.latitude, coordinate.longitude)
        if let cached = wind[key], Date().timeIntervalSince(cached.at) < Self.windTTL {
            return cached
        }
        let reading = await Self.fetchCurrentWind(
            latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let reading { wind[key] = reading }
        return reading
    }

    // MARK: Loading

    /// Load from disk immediately, refresh from Firestore when stale.
    ///
    /// The guide changes on the scale of days, so the app never blocks on the
    /// network: a cached dataset is served instantly and a background refresh
    /// swaps in the new one when it lands.
    func load() async {
        if spots.isEmpty, let cached = Self.readCache() {
            apply(cached)
        }
        let stale = Self.cacheAge() ?? .infinity
        guard spots.isEmpty || stale > Self.cacheTTL else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let dataset = try await Self.fetchDataset()
            apply(dataset)
            Self.writeCache(dataset)
            loadError = nil
        } catch {
            // A stale guide beats an empty one; only surface the failure when
            // there is nothing to show at all.
            if spots.isEmpty { loadError = error.localizedDescription }
        }
    }

    private func apply(_ dataset: GuideDataset) {
        spots = dataset.spots
        destinations = dataset.destinations
        countries = dataset.countries
    }

    // MARK: Wind

    /// Fetch current wind for the given spots, batched, honouring the TTL.
    ///
    /// Open-Meteo takes comma-separated coordinate lists, so forty visible
    /// pins are one request, not forty. Readings older than ten minutes are
    /// refetched; anything fresher is left alone.
    func refreshWind(for targets: [GuideSpot]) async {
        let now = Date()
        let due = targets.filter { spot in
            guard let existing = wind[spot.spotId] else { return true }
            return now.timeIntervalSince(existing.at) > Self.windTTL
        }
        guard !due.isEmpty else { return }

        // Cap one round at 50 spots — the nearest have priority upstream.
        let batch = Array(due.prefix(50))
        let lats = batch.map { String(format: "%.4f", $0.latitude) }.joined(separator: ",")
        let lons = batch.map { String(format: "%.4f", $0.longitude) }.joined(separator: ",")
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: lats),
            .init(name: "longitude", value: lons),
            .init(name: "current", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            .init(name: "wind_speed_unit", value: "kn"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return }

        struct Entry: Codable {
            struct Current: Codable {
                let wind_speed_10m: Double?
                let wind_gusts_10m: Double?
                let wind_direction_10m: Double?
            }
            let current: Current?
        }
        // One location comes back as an object, several as an array.
        let entries: [Entry]
        if let many = try? JSONDecoder().decode([Entry].self, from: data) { entries = many }
        else if let one = try? JSONDecoder().decode(Entry.self, from: data) { entries = [one] }
        else { return }

        for (spot, entry) in zip(batch, entries) {
            guard let current = entry.current, let speed = current.wind_speed_10m,
                  let direction = current.wind_direction_10m else { continue }
            wind[spot.spotId] = WindReading(
                speedKn: speed, gustKn: current.wind_gusts_10m,
                directionDeg: direction, at: now
            )
        }
    }

    // MARK: The map's clock

    /// How far the time slider reaches either side of now, and the depth
    /// the hourly fetches buy to cover it.
    static let scrubPastHours = 6
    static let scrubForecastHours = 72

    /// Hourly series for the spots the map is showing, one batched request
    /// — the route grid's own fetcher, pointed at pins. Only called once
    /// the slider leaves now, so a rider who never scrubs never pays.
    func refreshWindHours(for targets: [GuideSpot]) async {
        let due = targets.filter { windHours[$0.spotId] == nil }
        guard !due.isEmpty else { return }
        // The same cap `refreshWind` uses; the nearest have priority
        // upstream, and 50 points of 78 hours is one honest request.
        let batch = Array(due.prefix(50))
        let series = await OpenMeteo.windAlong(
            batch.map { Geo.Coordinate(latitude: $0.latitude, longitude: $0.longitude) },
            hours: Self.scrubForecastHours, pastHours: Self.scrubPastHours)
        for (index, spot) in batch.enumerated() {
            guard let rows = series[safe: index], !rows.isEmpty else { continue }
            windHours[spot.spotId] = rows
        }
    }

    /// The key both wind stores use for a bare coordinate — the centre
    /// pin's "here", which is a place rather than a spot.
    static func windKey(for coordinate: Geo.Coordinate) -> String {
        String(format: "@%.3f,%.3f", coordinate.latitude, coordinate.longitude)
    }

    /// The centre pin's own hourly series, so the map's headline pill can
    /// answer for the scrubbed hour instead of contradicting every other
    /// number on screen.
    func refreshWindHours(at coordinate: Geo.Coordinate) async {
        let key = Self.windKey(for: coordinate)
        guard windHours[key] == nil else { return }
        let series = await OpenMeteo.windAlong(
            [coordinate], hours: Self.scrubForecastHours, pastHours: Self.scrubPastHours)
        guard let rows = series.first, !rows.isEmpty else { return }
        windHours[key] = rows
    }

    /// What a pin should read at an instant. Now is `wind`'s live reading;
    /// any other hour is the nearest row of that spot's series, and nil
    /// until the series lands — a pin that shows this hour's number under
    /// tomorrow's label would be a lie the map cannot afford.
    func reading(for spotId: String, at instant: Date?) -> WindReading? {
        guard let instant else { return wind[spotId] }
        guard let rows = windHours[spotId], !rows.isEmpty else { return nil }
        let nearest = rows.min {
            abs($0.date.timeIntervalSince(instant)) < abs($1.date.timeIntervalSince(instant))
        }
        guard let nearest else { return nil }
        return WindReading(speedKn: nearest.speedKn, gustKn: nearest.gustKn,
                           directionDeg: nearest.directionDeg, at: nearest.date)
    }

    private static func fetchCurrentWind(latitude: Double, longitude: Double) async -> WindReading? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", latitude)),
            .init(name: "longitude", value: String(format: "%.4f", longitude)),
            .init(name: "current", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            .init(name: "wind_speed_unit", value: "kn"),
        ]
        struct Payload: Codable {
            struct Current: Codable {
                let wind_speed_10m: Double?
                let wind_gusts_10m: Double?
                let wind_direction_10m: Double?
            }
            let current: Current?
        }
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let current = (try? JSONDecoder().decode(Payload.self, from: data))?.current,
              let speed = current.wind_speed_10m,
              let direction = current.wind_direction_10m
        else { return nil }
        return WindReading(speedKn: speed, gustKn: current.wind_gusts_10m,
                           directionDeg: direction, at: Date())
    }

    /// The 12-hour outlook for one spot, for the detail screen's bars.
    func forecast(for spot: GuideSpot) async -> [WindForecastHour] {
        await forecast(latitude: spot.latitude, longitude: spot.longitude)
    }

    /// The same outlook at an arbitrary coordinate, for the tools.
    func forecast(latitude: Double, longitude: Double) async -> [WindForecastHour] {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", latitude)),
            .init(name: "longitude", value: String(format: "%.4f", longitude)),
            .init(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            .init(name: "forecast_hours", value: "12"),
            .init(name: "wind_speed_unit", value: "kn"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }

        struct Payload: Codable {
            struct Hourly: Codable {
                let time: [Double]
                let wind_speed_10m: [Double?]
                let wind_gusts_10m: [Double?]?
                let wind_direction_10m: [Double?]
            }
            let hourly: Hourly?
        }
        guard let hourly = (try? JSONDecoder().decode(Payload.self, from: data))?.hourly else { return [] }
        return hourly.time.indices.compactMap { i in
            guard let speed = hourly.wind_speed_10m[safe: i] ?? nil,
                  let direction = hourly.wind_direction_10m[safe: i] ?? nil else { return nil }
            return WindForecastHour(
                date: Date(timeIntervalSince1970: hourly.time[i]),
                speedKn: speed,
                gustKn: hourly.wind_gusts_10m?[safe: i] ?? nil,
                directionDeg: direction
            )
        }
    }

    // MARK: Resource links

    /// One outbound link on a spot page — a wind meter on iKitesurf, a
    /// Surfline forecast, a tide chart, a webcam, a local guide. The guide's
    /// whole pitch is that these live in one place instead of five apps.
    struct SpotLink: Identifiable, Hashable {
        enum Kind: String {
            case wind, camera, tide, surf, guide

            var label: String {
                switch self {
                case .wind: "Live wind"
                case .camera: "Webcam"
                case .tide: "Tides"
                case .surf: "Surf forecast"
                case .guide: "Guide"
                }
            }

            var symbol: String {
                switch self {
                case .wind: "gauge.with.needle"
                case .camera: "video"
                case .tide: "water.waves.and.arrow.trianglehead.up"
                case .surf: "figure.surfing"
                case .guide: "book"
                }
            }
        }

        let kind: Kind
        let name: String
        let url: URL
        let provider: String?
        var id: String { url.absoluteString + name }

        var providerLabel: String {
            provider ?? url.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        }
    }

    private var linkCache: [String: [SpotLink]] = [:]

    /// Everything this spot links out to, fetched once and kept for the session.
    func links(for spot: GuideSpot) async -> [SpotLink] {
        if let cached = linkCache[spot.spotId] { return cached }

        let main: [(String, [String], SpotLink.Kind)] = [
            ("windStations", spot.windStationIds, .wind),
            ("cameras", spot.cameraIds, .camera),
            ("surfSpots", spot.surfSpotIds, .surf),
            ("guides", spot.guideIds, .guide),
        ]
        let mainPaths = main.flatMap { collection, ids, _ in ids.map { "\(collection)/\($0)" } }
        let kindByPrefix: [String: SpotLink.Kind] = [
            "windStations": .wind, "cameras": .camera, "surfSpots": .surf,
            "guides": .guide, "tideStations": .tide,
        ]

        // Tides go in their own batch — batchGet fails WHOLE when any one
        // document is unreadable, and an undeployed tideStations rule must
        // not take the wind meters and webcams down with it. The website
        // learned this the hard way; no need to learn it twice.
        async let mainDocs = Self.batchGet(paths: mainPaths)
        async let tideDocs = Self.batchGet(paths: spot.tideStationIds.map { "tideStations/\($0)" })
        let (fetchedMain, fetchedTides) = await (mainDocs, tideDocs)

        var links: [SpotLink] = []
        for doc in fetchedMain + fetchedTides {
            guard let collection = doc.path.split(separator: "/").first.map(String.init),
                  let kind = kindByPrefix[collection],
                  let urlString = doc.fields["url"]?.stringValue,
                  urlString.hasPrefix("http"),
                  let url = URL(string: urlString)
            else { continue }
            links.append(SpotLink(
                kind: kind,
                name: doc.fields["name"]?.stringValue ?? kind.label,
                url: url,
                provider: doc.fields["provider"]?.stringValue
            ))
        }

        // Inline tide fallback, exactly as the site does it.
        if !links.contains(where: { $0.kind == .tide }),
           let chart = spot.tideChartURL, let url = URL(string: chart), chart.hasPrefix("http") {
            links.append(SpotLink(kind: .tide, name: "Tide predictions", url: url,
                                  provider: spot.tideProvider ?? "NOAA CO-OPS"))
        }

        // The order riders check things: wind meter, surf forecast, tides,
        // then cams. Guides render as their own section downstream.
        let order: [SpotLink.Kind] = [.wind, .surf, .tide, .camera, .guide]
        links.sort {
            (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9)
        }
        linkCache[spot.spotId] = links
        return links
    }

    // MARK: Nearby resources

    /// A meter, camera or forecast page somewhere near a spot — not
    /// necessarily attached to it.
    ///
    /// The spot page shows what somebody linked to *this* launch. That is the
    /// curated answer and it is often thin: a new spot has nothing, and a
    /// spot two hundred metres up the beach may have the meter you want. The
    /// guide's resources all carry their own coordinates, so the uncurated
    /// answer — everything within a few kilometres, nearest first — is a
    /// query away and frequently more useful.
    struct GuideResource: Identifiable, Hashable {
        let kind: SpotLink.Kind
        let name: String
        let url: URL
        let provider: String?
        let detail: String?
        let coordinate: Geo.Coordinate
        /// From the spot it was asked about — filled in per query, not stored,
        /// because the same regional cache serves every spot in the region.
        var metres: Double = 0
        /// And which way, for the same reason.
        ///
        /// Distance alone does not separate a row from the one under it when
        /// eleven Surfline map links all resolve to the same name. "3.7 mi
        /// WNW" and "4.3 mi ENE" are two different places on two different
        /// banks of the river, which is the thing a rider is choosing between.
        var bearing: Double = 0

        var id: String { url.absoluteString + name }

        var providerLabel: String {
            provider ?? url.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        }

        /// A name a rider can read.
        ///
        /// The guide names a lot of these after the provider's internal id —
        /// "5842041F4E65Fad6A770896F — Surfline", "708136 — WX" — which is
        /// fine as a key and useless as a label, especially in a list where
        /// every row then looks identical. Two rescues, in order:
        ///
        /// 1. The URL usually carries the human name the provider gave it:
        ///    `/surf-report/bolinas-jetty/5842…` is Bolinas Jetty.
        /// 2. Failing that, say what it is and keep a short tail of the id, so
        ///    three stations from one provider stay tellable apart.
        var displayName: String {
            let head = name.components(separatedBy: " — ").first ?? name
            guard Self.isOpaque(head) else { return name }
            if let fromPath = Self.nameFromPath(url) { return fromPath }
            // A link to a point on a provider's map, named after the point.
            // There is no name to recover — so say what it is, and let the
            // distance and bearing beside it do the telling apart.
            if Self.isEscapedCoordinate(head) { return "\(Self.brand(providerLabel)) map" }
            let tail = head.count > 10 ? String(head.suffix(6)) : head
            return "\(Self.brand(providerLabel)) \(tail)"
        }

        /// An id pretending to be a name: either all digits, a long hex run,
        /// or an escaped coordinate. Real names — "Rincon Point", "Golden Gate
        /// Bridge" — fail every clause.
        private static func isOpaque(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            // Checked before the space rule, not after it. Surfline's map ids
            // escape the comma between the two coordinates and leave the space
            // that followed it — "%4045.71640%2C 121.51610%2C12Z" — so the
            // one clause meant to catch them was the one clause they failed,
            // and eleven rows in the Gorge printed their own URL fragment.
            if isEscapedCoordinate(trimmed) { return true }
            guard !trimmed.contains(" ") else { return false }
            if trimmed.allSatisfy(\.isNumber) { return true }
            return trimmed.count >= 16 && trimmed.allSatisfy(\.isHexDigit)
        }

        /// "%4033.78278%2C122.51…" — a percent-escaped `@lat,lon` map anchor.
        private static func isEscapedCoordinate(_ text: String) -> Bool {
            text.hasPrefix("%")
        }

        /// The longest hyphenated path segment — "bolinas-jetty" beats
        /// "surf-report", which is identical on every row.
        private static func nameFromPath(_ url: URL) -> String? {
            let ignored: Set<String> = ["surf-report", "surf-reports-forecasts-cams-map",
                                        "live-cams", "livecams", "spot", "station"]
            let best = url.pathComponents
                .filter { component in
                    // A map anchor — "@45.71640,-121.51610,12z" — carries a
                    // hyphen for the negative longitude and would otherwise
                    // win this on length alone.
                    guard !component.hasPrefix("@") else { return false }
                    return component.contains("-") && !ignored.contains(component)
                        && !component.contains("%")
                }
                .max { $0.count < $1.count }
            guard let best, best.count > 3 else { return nil }
            return best
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }

        /// Providers whose own capitalisation is not what a hostname gives you.
        private static func brand(_ host: String) -> String {
            let lower = host.lowercased()
            if lower.contains("ikitesurf") { return "iKitesurf" }
            if lower.contains("surfline") { return "Surfline" }
            if lower.contains("weather.gov") || lower.contains("noaa") { return "NOAA" }
            if lower.contains("windy") { return "Windy" }
            return host
        }

        /// What it costs to read, when that is knowable from the provider.
        ///
        /// Stated because it is the first thing a rider wants to know and the
        /// last thing a link tells them. Anything not recognised gets no
        /// badge rather than a guess.
        enum Access { case free, account, unknown }

        var access: Access {
            let host = (provider ?? url.host ?? "").lowercased()
            if host.contains("weather.gov") || host.contains("noaa.gov")
                || host.contains("ndbc") || host.contains("open-meteo") { return .free }
            if host.contains("ikitesurf") || host.contains("weatherflow") { return .account }
            return .unknown
        }
    }

    private var nearbyCache: [String: [GuideResource]] = [:]

    /// Everything in the guide within `radius` of a spot, nearest first.
    ///
    /// Scoped to the spot's admin region — a query the rules already allow,
    /// bounded at a few dozen documents, and geographically a superset of
    /// anything within a sensible drive. Falls back to the country when a
    /// spot has no region, and caches per region because the second spot a
    /// rider opens in the same place should cost nothing.
    func nearbyResources(to spot: GuideSpot, radius: Double = 40_000) async -> [GuideResource] {
        await nearbyResources(
            near: Geo.Coordinate(latitude: spot.latitude, longitude: spot.longitude),
            region: spot, radius: radius
        )
    }

    /// The same, for a point that is not a spot — a rider standing somewhere
    /// the guide has never heard of still wants to know what is around them.
    ///
    /// Resources are indexed by region rather than by geography, so an
    /// arbitrary coordinate has to borrow one: the nearest known spot decides
    /// which region to search. That is exact in practice, since a region is
    /// a state or a country and the nearest launch is inside the one you are
    /// standing in.
    func nearbyResources(near coordinate: Geo.Coordinate, radius: Double = 40_000) async -> [GuideResource] {
        await nearbyResources(near: coordinate, region: nearestSpot(to: coordinate), radius: radius)
    }

    /// Scoped by country, not by state.
    ///
    /// This used to filter on `adminRegionId`, which loses two whole classes
    /// of resource. Measured against the live guide in August 2026:
    ///
    /// - **205 of 525 `surfSpots` carry no `adminRegionId` at all** — every
    ///   one of them invisible to a region-scoped query, no matter how close.
    /// - **Borders.** Standing at Hood River, six of the ten nearest surf
    ///   pages are on the Washington bank of the Columbia — Swell City, the
    ///   Hatchery, Bingen, four to seven kilometres away and across the river
    ///   an Oregon query cannot see. Every rider in the Gorge is a rider in a
    ///   border region, and so is most of Europe.
    ///
    /// Every document in these collections carries a `countryId`, so country
    /// is both the wider net and the complete one. It is also cheap: the whole
    /// of the United States is 434 documents across the three collections,
    /// fetched once and cached, and `rank` still cuts it to the rider's radius.
    /// Countries are unioned rather than picked, because a lake on a border is
    /// the same problem one level up.
    private func nearbyResources(
        near here: Geo.Coordinate, region spot: GuideSpot?, radius: Double
    ) async -> [GuideResource] {
        var scopes = countryScopes(near: here, anchor: spot).map { ("countryId", $0) }
        // Only if the guide knows no country anywhere near — which means it
        // knows no spot anywhere near either, and the admin region of whatever
        // it did find is the best that can be done.
        if scopes.isEmpty, let region = spot?.adminRegionId {
            scopes = [("adminRegionId", region)]
        }
        guard !scopes.isEmpty else { return [] }

        var found: [GuideResource] = []
        for (field, value) in scopes {
            found += await resources(where: field, equals: value)
        }

        // A resource attached to two countries' spots comes back twice.
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.id).inserted }
        return Self.rank(unique, from: here, radius: radius)
    }

    /// The countries worth searching: the anchor spot's, plus those of any
    /// spot within a couple of hours' drive, nearest first and capped.
    ///
    /// Bounded by distance rather than by count so that a rider in the middle
    /// of one country searches exactly one, and a rider on a border searches
    /// both — without either paying for the other's case.
    private func countryScopes(near here: Geo.Coordinate, anchor: GuideSpot?) -> [String] {
        var nearest: [String: Double] = [:]
        if let id = anchor?.countryId { nearest[id] = 0 }
        for spot in spots {
            guard let id = spot.countryId else { continue }
            let metres = Geo.distance(here, .init(latitude: spot.latitude,
                                                  longitude: spot.longitude))
            guard metres < 200_000 else { continue }
            if metres < nearest[id] ?? .greatestFiniteMagnitude { nearest[id] = metres }
        }
        return nearest.sorted { $0.value < $1.value }.prefix(3).map(\.key)
    }

    /// One scope's worth of the guide, fetched once and kept — and, since
    /// the disk cache arrived, *kept between sessions*: the US scope is
    /// ~475 documents, identity that changes a few times a year, and
    /// re-downloading it every session was the biggest Firestore bill the
    /// app paid. Seven days fresh, the registry cross-links' own TTL; a
    /// stale copy still beats a network failure, because where the cameras
    /// stand did not change while the signal was out.
    private func resources(where field: String, equals value: String) async -> [GuideResource] {
        guard !value.isEmpty else { return [] }
        let cacheKey = "\(field)=\(value)"
        if let cached = nearbyCache[cacheKey] { return cached }

        if let held = Self.storedResources(for: cacheKey),
           held.age < Self.resourceCacheTTL {
            nearbyCache[cacheKey] = held.resources
            return held.resources
        }

        let collections: [(String, SpotLink.Kind)] = [
            ("windStations", .wind), ("cameras", .camera), ("surfSpots", .surf),
        ]
        var found: [GuideResource] = []
        await withTaskGroup(of: [GuideResource].self) { group in
            for (collection, kind) in collections {
                group.addTask {
                    let docs = (try? await Self.runQuery(
                        collection: collection, publishedOnly: false,
                        where: field, equals: value
                    )) ?? []
                    return docs.compactMap { doc -> GuideResource? in
                        guard let urlString = doc.fields["url"]?.stringValue,
                              urlString.hasPrefix("http"),
                              let url = URL(string: urlString),
                              let at = doc.fields["location"]?.coordinate
                        else { return nil }
                        return GuideResource(
                            kind: kind,
                            name: doc.fields["name"]?.stringValue ?? kind.label,
                            url: url,
                            provider: doc.fields["provider"]?.stringValue,
                            detail: doc.fields["description"]?.stringValue,
                            coordinate: at
                        )
                    }
                }
            }
            for await batch in group { found += batch }
        }

        // An empty answer is indistinguishable from a failed fetch here —
        // `runQuery` collapses errors to nothing — so an old copy on disk
        // outranks it, and only a real answer overwrites one.
        if found.isEmpty, let held = Self.storedResources(for: cacheKey) {
            nearbyCache[cacheKey] = held.resources
            return held.resources
        }
        Self.storeResources(found, for: cacheKey)
        nearbyCache[cacheKey] = found
        return found
    }

    // MARK: The resource disk cache

    private static let resourceCacheTTL: TimeInterval = 7 * 86_400

    /// The distilled row, not the domain type — the tide index's pattern:
    /// what the file holds is spelled here, so the domain type can grow
    /// without silently breaking old caches.
    private struct StoredResource: Codable {
        let kind: String
        let name: String
        let url: String
        let provider: String?
        let detail: String?
        let latitude: Double
        let longitude: Double
    }

    private static func resourceCacheURL(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return URL.cachesDirectory.appending(path: "guide-resources-\(String(safe)).json")
    }

    private static func storedResources(for key: String) -> (resources: [GuideResource], age: TimeInterval)? {
        let path = resourceCacheURL(for: key)
        guard let data = try? Data(contentsOf: path),
              let rows = try? JSONDecoder().decode([StoredResource].self, from: data)
        else { return nil }
        let written = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let resources = rows.compactMap { row -> GuideResource? in
            guard let kind = SpotLink.Kind(rawValue: row.kind),
                  let url = URL(string: row.url) else { return nil }
            return GuideResource(kind: kind, name: row.name, url: url,
                                 provider: row.provider, detail: row.detail,
                                 coordinate: Geo.Coordinate(latitude: row.latitude,
                                                            longitude: row.longitude))
        }
        return (resources, Date().timeIntervalSince(written))
    }

    private static func storeResources(_ resources: [GuideResource], for key: String) {
        let rows = resources.map { resource in
            StoredResource(kind: resource.kind.rawValue, name: resource.name,
                           url: resource.url.absoluteString,
                           provider: resource.provider, detail: resource.detail,
                           latitude: resource.coordinate.latitude,
                           longitude: resource.coordinate.longitude)
        }
        if let encoded = try? JSONEncoder().encode(rows) {
            try? encoded.write(to: resourceCacheURL(for: key), options: .atomic)
        }
    }

    /// Measure and order for one spot. Distance is never cached — the region's
    /// resources are shared by every spot in it, and the second spot a rider
    /// opens is somewhere else. A few dozen rows and no network.
    private static func rank(
        _ resources: [GuideResource], from origin: Geo.Coordinate, radius: Double
    ) -> [GuideResource] {
        resources
            .map { resource in
                var measured = resource
                measured.metres = Geo.distance(origin, resource.coordinate)
                measured.bearing = Geo.bearing(from: origin, to: resource.coordinate)
                return measured
            }
            .filter { $0.metres <= radius }
            .sorted { $0.metres < $1.metres }
    }

    // MARK: Weather

    /// Observed, like `wind`, so a card can read it during body evaluation
    /// rather than carrying its own copy of state that has to be threaded
    /// through every view that wants it.
    private(set) var weatherBySpot: [String: SpotWeather] = [:]

    func weatherReading(for spot: GuideSpot) -> SpotWeather? { weatherBySpot[spot.spotId] }

    /// Temperature and sky for a spot, alongside the wind the card already
    /// shows. Same free model, same TTL.
    @discardableResult
    func weather(for spot: GuideSpot) async -> SpotWeather? {
        await weather(
            at: Geo.Coordinate(latitude: spot.latitude, longitude: spot.longitude),
            key: spot.spotId
        )
    }

    /// The same at an arbitrary point — the Spots map shows this for wherever
    /// the rider is, which is usually not a spot in the guide. Cached under a
    /// coordinate rounded to about a hundred metres, the way the wind at a
    /// coordinate already is.
    @discardableResult
    func weather(at coordinate: Geo.Coordinate) async -> SpotWeather? {
        await weather(at: coordinate,
                      key: String(format: "@%.3f,%.3f", coordinate.latitude, coordinate.longitude))
    }

    func weatherReading(at coordinate: Geo.Coordinate) -> SpotWeather? {
        weatherBySpot[String(format: "@%.3f,%.3f", coordinate.latitude, coordinate.longitude)]
    }

    private func weather(at coordinate: Geo.Coordinate, key: String) async -> SpotWeather? {
        if let cached = weatherBySpot[key],
           Date().timeIntervalSince(cached.at) < Self.windTTL {
            return cached
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
        ]
        struct Payload: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double?
                let apparent_temperature: Double?
                let weather_code: Int?
                let is_day: Int?
            }
            let current: Current?
        }
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let current = (try? JSONDecoder().decode(Payload.self, from: data))?.current,
              let temperature = current.temperature_2m
        else { return nil }

        let reading = SpotWeather(
            temperatureC: temperature,
            apparentC: current.apparent_temperature,
            code: current.weather_code ?? 0,
            isDay: (current.is_day ?? 1) == 1,
            at: Date()
        )
        weatherBySpot[key] = reading
        return reading
    }

    private struct BatchDoc {
        let path: String
        let fields: [String: FirestoreValue]
    }

    private static func batchGet(paths: [String]) async -> [BatchDoc] {
        guard !paths.isEmpty else { return [] }
        let base = firestoreBase.replacingOccurrences(of: "/documents", with: "")
        guard let url = URL(string: "\(base)/documents:batchGet?key=\(apiKey)") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let full = paths.map { "projects/\(project)/databases/(default)/documents/\($0)" }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["documents": full])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        struct Row: Codable {
            struct Found: Codable {
                let name: String
                let fields: [String: FirestoreValue]?
            }
            let found: Found?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.compactMap { row in
            guard let found = row.found,
                  let path = found.name.components(separatedBy: "/documents/").last
            else { return nil }
            return BatchDoc(path: path, fields: found.fields ?? [:])
        }
    }

    // MARK: - Firestore REST

    struct GuideDataset: Codable {
        var spots: [GuideSpot]
        var destinations: [GuideRegion]
        var countries: [GuideRegion]
        var fetchedAt: Date
    }

    /// The website synthesizes these destination guides from bounding boxes
    /// until the publisher ships real region documents. Same list, same rule:
    /// a real Firestore destination with the same id always wins.
    nonisolated private static let curatedDestinations: [(id: String, name: String, box: (Double, Double, Double, Double), countries: [String]?, blurb: String)] = [
        ("maui", "Maui", (20.4, 21.2, -156.9, -155.8), ["united-states"],
         "Downwind heaven — Maliko runs, Kanaha, and the north-shore trades that made foiling what it is."),
        ("san-francisco-bay", "San Francisco Bay", (37.3, 38.3, -122.8, -121.8), ["united-states"],
         "City-front sessions under the Gate, ripping ebb tides, and summer thermals you can set a watch by."),
        ("the-canary-islands", "The Canary Islands", (27.5, 29.5, -18.3, -13.3), ["spain"],
         "Year-round trade winds across Fuerteventura, Tenerife and Lanzarote — Europe's winter escape."),
        ("the-greek-islands", "The Greek Islands", (36.0, 39.5, 22.0, 28.5), ["greece"],
         "Meltemi summers across Paros, Naxos, Kos and the Aegean — flat-water bays and island hopping."),
        ("south-of-france", "South of France", (42.8, 43.8, 3.0, 7.5), ["france"],
         "Mistral and Tramontane from Leucate to Hyères — the Med's windiest coastline."),
        ("aruba-bonaire-curacao", "Aruba, Bonaire & Curaçao", (11.9, 12.9, -70.2, -67.9), nil,
         "The ABC islands — steady Caribbean trades, flat turquoise water and downwind routes between the beaches."),
        ("oahu", "Oʻahu", (21.2, 21.8, -158.4, -157.5), ["united-states"],
         "Town's prone scene from Waikīkī to Kakaʻako, and the Kailua trades on the windward side."),
        ("tarifa-and-the-strait", "Tarifa & the Strait", (35.9, 36.4, -6.2, -5.2), ["spain"],
         "Europe's wind capital — Levante and Poniente funnelling through the Strait of Gibraltar."),
        ("cape-town", "Cape Town", (-34.5, -33.5, 18.2, 19.0), ["south-africa"],
         "Miller's Run and the Blouberg southeaster — the world's most famous downwind commute."),
        ("lake-garda", "Lake Garda", (45.4, 46.0, 10.5, 11.0), ["italy"],
         "The Ora on schedule every afternoon, framed by cliffs — the alpine lake that raised generations of racers."),
    ]

    private static func fetchDataset() async throws -> GuideDataset {
        async let spotRows = runQuery(collection: "spots", publishedOnly: true)
        async let regionRows = runQuery(collection: "regions", publishedOnly: false)
        let (rawSpots, rawRegions) = try await (spotRows, regionRows)

        var spots = rawSpots.compactMap(Self.decodeSpot)
        spots.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var regionsById: [String: FirestoreDoc] = [:]
        for region in rawRegions { regionsById[region.id] = region }

        // Countries, ranked by how many published spots they hold.
        var countByCountry: [String: Int] = [:]
        for spot in spots { if let c = spot.countryId { countByCountry[c, default: 0] += 1 } }
        let countries = rawRegions
            .filter { ($0.fields["type"]?.stringValue) == "country" }
            .compactMap { doc -> GuideRegion? in
                guard let count = countByCountry[doc.id], count > 0 else { return nil }
                return GuideRegion(
                    id: doc.id,
                    name: doc.fields["name"]?.stringValue ?? doc.id,
                    type: "country",
                    description: doc.fields["description"]?.stringValue,
                    spotCount: count
                )
            }
            .sorted { $0.spotCount > $1.spotCount || ($0.spotCount == $1.spotCount && $0.name < $1.name) }

        // Destinations: real region docs first, curated boxes as the fallback.
        var destinations: [GuideRegion] = []
        var claimed = Set<String>()
        for doc in rawRegions where (doc.fields["type"]?.stringValue) == "destination" {
            let ids = spots.filter { $0.browseRegionIds.contains(doc.id) }
            guard !ids.isEmpty else { continue }
            destinations.append(GuideRegion(
                id: doc.id,
                name: doc.fields["name"]?.stringValue ?? doc.id,
                type: "destination",
                description: doc.fields["description"]?.stringValue,
                spotCount: ids.count
            ))
            claimed.insert(doc.id)
        }
        for curated in curatedDestinations where !claimed.contains(curated.id) {
            let (latMin, latMax, lonMin, lonMax) = curated.box
            let inBox = spots.filter { spot in
                spot.latitude >= latMin && spot.latitude <= latMax &&
                spot.longitude >= lonMin && spot.longitude <= lonMax &&
                (curated.countries == nil || curated.countries!.contains(spot.countryId ?? ""))
            }
            guard inBox.count >= 4 else { continue }
            destinations.append(GuideRegion(
                id: curated.id, name: curated.name, type: "destination",
                description: curated.blurb, spotCount: inBox.count
            ))
        }
        destinations.sort { $0.spotCount > $1.spotCount }

        return GuideDataset(spots: spots, destinations: destinations, countries: countries, fetchedAt: Date())
    }

    /// Membership test for curated (bounding-box) destinations, mirrored from
    /// the fetch so `spots(inDestination:)` works for both kinds.
    nonisolated static func curatedBox(for regionId: String) -> ((GuideSpot) -> Bool)? {
        guard let curated = curatedDestinations.first(where: { $0.id == regionId }) else { return nil }
        let (latMin, latMax, lonMin, lonMax) = curated.box
        return { spot in
            spot.latitude >= latMin && spot.latitude <= latMax &&
            spot.longitude >= lonMin && spot.longitude <= lonMax &&
            (curated.countries == nil || curated.countries!.contains(spot.countryId ?? ""))
        }
    }

    // MARK: Firestore decoding

    /// A Firestore REST value — the tagged union the API wraps every field in.
    private struct FirestoreValue: Codable {
        var stringValue: String?
        var doubleValue: Double?
        var integerValue: String?
        var booleanValue: Bool?
        var mapValue: MapValue?
        var arrayValue: ArrayValue?
        var geoPointValue: GeoPoint?
        struct MapValue: Codable { var fields: [String: FirestoreValue]? }
        struct ArrayValue: Codable { var values: [FirestoreValue]? }
        struct GeoPoint: Codable { var latitude: Double?; var longitude: Double? }

        var number: Double? { doubleValue ?? integerValue.flatMap(Double.init) }
        var strings: [String] { arrayValue?.values?.compactMap(\.stringValue) ?? [] }
        subscript(key: String) -> FirestoreValue? { mapValue?.fields?[key] }

        /// Every wind meter, camera and surf link carries its own geopoint,
        /// which is what makes "what else is near here" answerable at all.
        var coordinate: Geo.Coordinate? {
            guard let point = geoPointValue,
                  let latitude = point.latitude, let longitude = point.longitude
            else { return nil }
            return Geo.Coordinate(latitude: latitude, longitude: longitude)
        }
    }

    private struct FirestoreDoc {
        let id: String
        let fields: [String: FirestoreValue]
    }

    private static func runQuery(
        collection: String,
        publishedOnly: Bool,
        where field: String? = nil,
        equals match: String? = nil
    ) async throws -> [FirestoreDoc] {
        var query: [String: Any] = ["from": [["collectionId": collection]]]
        if let field, let match {
            query["where"] = ["fieldFilter": [
                "field": ["fieldPath": field], "op": "EQUAL",
                "value": ["stringValue": match],
            ]]
        }
        if publishedOnly {
            // The rules deny any spots query that does not filter on both.
            query["where"] = ["compositeFilter": [
                "op": "AND",
                "filters": [
                    ["fieldFilter": ["field": ["fieldPath": "status"], "op": "EQUAL",
                                     "value": ["stringValue": "published"]]],
                    ["fieldFilter": ["field": ["fieldPath": "isTest"], "op": "EQUAL",
                                     "value": ["booleanValue": false]]],
                ],
            ]]
        }
        var request = URLRequest(url: URL(string: "\(firestoreBase):runQuery?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["structuredQuery": query])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        struct Row: Codable {
            struct Document: Codable {
                let name: String
                let fields: [String: FirestoreValue]?
            }
            let document: Document?
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.compactMap { row in
            guard let doc = row.document else { return nil }
            return FirestoreDoc(
                id: String(doc.name.split(separator: "/").last ?? ""),
                fields: doc.fields ?? [:]
            )
        }
    }

    private static func decodeSpot(_ doc: FirestoreDoc) -> GuideSpot? {
        let f = doc.fields
        guard let name = f["name"]?.stringValue,
              let latitude = f["latitude"]?.number,
              let longitude = f["longitude"]?.number
        else { return nil }

        let geography = f["geography"]
        let activities = f["activities"]
        let conditions = f["conditions"]
        let access = f["access"]

        var activityNames: [String] = []
        let flags: [(String, String)] = [
            ("wingFoiling", "Wing Foiling"), ("proneFoiling", "Prone Foiling"),
            ("parawinging", "Parawinging"), ("supFoiling", "SUP Foiling"),
        ]
        for (key, label) in flags where activities?[key]?.booleanValue == true {
            activityNames.append(label)
        }
        let preferred = activities?["preferred"]?.stringValue
        if let preferred, !activityNames.contains(preferred) {
            activityNames.insert(preferred, at: 0)
        }

        // Best image: non-rejected, approved first, then score — the site rule.
        var imageURL: String?
        var imageCredit: String?
        if let candidates = f["imageCandidates"]?.arrayValue?.values {
            let rank = ["approved": 0, "pending": 1]
            let best = candidates
                .filter { c in
                    guard let url = c["url"]?.stringValue, url.hasPrefix("http") else { return false }
                    return c["reviewStatus"]?.stringValue != "rejected"
                }
                .sorted { a, b in
                    let ra = rank[a["reviewStatus"]?.stringValue ?? ""] ?? 2
                    let rb = rank[b["reviewStatus"]?.stringValue ?? ""] ?? 2
                    if ra != rb { return ra < rb }
                    return (a["score"]?.number ?? 0) > (b["score"]?.number ?? 0)
                }
                .first
            imageURL = best?["url"]?.stringValue
            if let creator = best?["creator"]?.stringValue {
                imageCredit = "Photo by \(creator) · Wikimedia Commons"
            }
        }

        return GuideSpot(
            spotId: f["spotId"]?.stringValue ?? doc.id,
            slug: f["slug"]?.stringValue,
            name: name,
            latitude: latitude,
            longitude: longitude,
            country: geography?["country"]?.stringValue,
            countryId: geography?["countryId"]?.stringValue,
            adminRegion: geography?["adminRegion"]?.stringValue,
            adminRegionId: geography?["adminRegionId"]?.stringValue,
            browseRegionIds: geography?["browseRegionIds"]?.strings ?? [],
            preferredActivity: preferred,
            activities: activityNames,
            bestWinds: conditions?["bestWinds"]?.stringValue,
            bestSeason: conditions?["bestSeason"]?.stringValue,
            waterState: conditions?["waterState"]?.stringValue,
            shoreFacingDeg: conditions?["shoreFacingDeg"]?.number,
            experienceLevel: conditions?["experienceLevel"]?.stringValue,
            hazards: conditions?["hazards"]?.stringValue,
            parking: access?["parking"]?.stringValue,
            googleMapsURL: access?["googleMapsUrl"]?.stringValue,
            imageURL: imageURL,
            imageCredit: imageCredit,
            windStationIds: f["windStationIds"]?.strings ?? [],
            cameraIds: f["cameraIds"]?.strings ?? [],
            guideIds: f["guideIds"]?.strings ?? [],
            surfSpotIds: f["surfSpotIds"]?.strings ?? [],
            tideStationIds: f["tideStationIds"]?.strings ?? [],
            tideChartURL: f["tides"]?["chartUrl"]?.stringValue,
            tideProvider: f["tides"]?["provider"]?.stringValue
        )
    }

    // MARK: Disk cache

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spot-guide.json")
    }

    private static func cacheAge() -> TimeInterval? {
        guard let cached = readCache() else { return nil }
        return Date().timeIntervalSince(cached.fetchedAt)
    }

    private static func readCache() -> GuideDataset? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(GuideDataset.self, from: data)
    }

    private static func writeCache(_ dataset: GuideDataset) {
        if let data = try? JSONEncoder().encode(dataset) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

extension Notification.Name {
    /// Posted by "Record here" on a spot page; ContentView switches tabs.
    static let openWaterSwitchToRecord = Notification.Name("openWaterSwitchToRecord")
}
