import Foundation
import OpenWaterCore

// MARK: - Wind station registry

/// One provider's view of a station, from the registry.
struct RegistryLink: Hashable, Codable {
    let providerId: String
    let url: URL
    let accessTier: String?

    /// "iKitesurf", not "ikitesurf" — the label a rider knows the app by.
    var label: String {
        switch providerId {
        case "ikitesurf": "iKitesurf"
        default: providerId.capitalized
        }
    }

    /// A government view is identity, not a door: it dedupes rows but is
    /// never offered as a second place to open the station.
    var isGovernment: Bool {
        ["nws", "noaa", "ndbc", "coops"].contains(providerId)
    }
}

/// A curated station from `windStations` that is also a government sensor.
struct RegistryStation: Codable {
    let id: String
    let name: String
    /// Government ids from the `gov` block, uppercased — the join key against
    /// what `FreeStations` discovered.
    let govIds: [String]
    /// Non-government provider views of the same instrument.
    let links: [RegistryLink]
}

/// The curated half of the station story: docs/WIND_STATIONS.md's Firestore
/// registry, read for the one thing the free feeds cannot know — that a
/// station a rider is looking at is also on a network they may subscribe to.
///
/// Only rows carrying a `gov` block are fetched. Those are the cross-links,
/// they are the part the app can act on (one pin, two doors), and there are
/// a handful of them — not the thousand bulk provider rows, which stay
/// unread until they are curated. The registry is an overlay, never a gate:
/// when this returns nothing, every pin renders exactly as it did before.
///
/// Identity only, per the house rule. No reading ever comes from here.
enum WindStationRegistry {

    private static var cached: [RegistryStation] = []
    private static var loading: Task<[RegistryStation], Never>?

    /// Cross-links change when somebody curates a station, which is rarer
    /// than a NOAA hardware change — a week of cache is still generous.
    private static let maxAge: TimeInterval = 7 * 24 * 3600

    private static var cacheURL: URL {
        URL.cachesDirectory.appending(path: "wind-station-registry.json")
    }

    /// The registry keyed by government station id, uppercased.
    static func crossLinks() async -> [String: RegistryStation] {
        let rows = await load()
        var byGov: [String: RegistryStation] = [:]
        for row in rows {
            for id in row.govIds { byGov[id] = row }
        }
        return byGov
    }

    private static func load() async -> [RegistryStation] {
        if !cached.isEmpty { return cached }
        if let loading { return await loading.value }

        let task = Task { () -> [RegistryStation] in
            if let disk = fromDisk(), disk.age < maxAge { return disk.rows }
            if let fetched = await download() { return fetched }
            // Stale cross-links still point at the same hardware.
            return fromDisk()?.rows ?? []
        }
        loading = task
        cached = await task.value
        loading = nil
        return cached
    }

    private static func fromDisk() -> (rows: [RegistryStation], age: TimeInterval)? {
        guard let data = try? Data(contentsOf: cacheURL),
              let rows = try? JSONDecoder().decode([RegistryStation].self, from: data)
        else { return nil }
        let written = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return (rows, Date().timeIntervalSince(written))
    }

    /// One structured query: every row whose `gov` block exists. The same
    /// public, rules-guarded REST surface the guide reads through.
    private static func download() async -> [RegistryStation]? {
        let base = "https://firestore.googleapis.com/v1/projects/\(SpotGuideStore.project)"
            + "/databases/(default)/documents"
        guard let url = URL(string: "\(base):runQuery?key=\(SpotGuideStore.apiKey)") else { return nil }

        let query: [String: Any] = ["structuredQuery": [
            "from": [["collectionId": "windStations"]],
            "where": ["unaryFilter": [
                "field": ["fieldPath": "gov"], "op": "IS_NOT_NULL",
            ]],
        ]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: query)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        // The REST payload wraps every value in a type tag; these three
        // pluck what the registry schema promises without a general decoder.
        func string(_ value: Any?) -> String? {
            (value as? [String: Any])?["stringValue"] as? String
        }
        func map(_ value: Any?) -> [String: Any] {
            ((value as? [String: Any])?["mapValue"] as? [String: Any])
                .flatMap { $0["fields"] as? [String: Any] } ?? [:]
        }
        func array(_ value: Any?) -> [[String: Any]] {
            ((value as? [String: Any])?["arrayValue"] as? [String: Any])
                .flatMap { $0["values"] as? [[String: Any]] }?
                .map { ($0["mapValue"] as? [String: Any])
                    .flatMap { $0["fields"] as? [String: Any] } ?? [:] } ?? []
        }

        let stations = rows.compactMap { row -> RegistryStation? in
            guard let document = row["document"] as? [String: Any],
                  let path = document["name"] as? String,
                  let fields = document["fields"] as? [String: Any],
                  let name = string(fields["name"])
            else { return nil }
            let govIds = map(fields["gov"]).compactMap { string($0.value)?.uppercased() }
            guard !govIds.isEmpty else { return nil }
            // Government entries ride along too: they carry no door worth
            // showing, but their URLs are how three names for one sensor
            // are recognised as one.
            let links = array(fields["providers"]).compactMap { provider -> RegistryLink? in
                guard let providerId = string(provider["providerId"]),
                      let raw = string(provider["url"]), let url = URL(string: raw)
                else { return nil }
                return RegistryLink(providerId: providerId, url: url,
                                    accessTier: string(provider["accessTier"]))
            }
            return RegistryStation(
                id: String(path.split(separator: "/").last ?? ""),
                name: name, govIds: govIds, links: links
            )
        }

        if let encoded = try? JSONEncoder().encode(stations) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return stations
    }
}
