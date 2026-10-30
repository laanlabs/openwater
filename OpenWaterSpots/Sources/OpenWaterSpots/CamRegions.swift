import Foundation

/// A named stretch of coast a camera sits on — Long Island, South Florida,
/// Cape Cod & the Islands.
///
/// States are too coarse to choose a camera by: California is two hundred
/// and fifty-odd cams from Crescent City to Imperial Beach, and "New York"
/// puts Montauk beside the Brooklyn Bridge. These are the regions a rider
/// actually names.
///
/// The table is `cam-regions.json`, bundled here and shared byte for byte
/// with the website (`openwater-www/cam-regions.json`; the site's tests fail
/// when the two differ), so a camera lands in the same region on the phone,
/// the television and the web. Regions are computed from a camera's
/// coordinates and state rather than stored on the registry document, so a
/// camera added tomorrow is filed tomorrow.
public struct CamRegion: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
}

public enum CamRegions {

    struct Entry: Decodable, Sendable {
        let id: String
        let name: String
        let admin: [String]
        /// South, west, north, east.
        let box: [Double]

        func contains(latitude: Double, longitude: Double, adminRegionId: String) -> Bool {
            guard box.count == 4, admin.contains(adminRegionId) else { return false }
            return latitude >= box[0] && latitude <= box[2]
                && longitude >= box[1] && longitude <= box[3]
        }
    }

    private struct Table: Decodable { let regions: [Entry] }

    /// In file order, which is match order: the first region that claims a
    /// camera has it.
    static let entries: [Entry] = {
        guard let url = Bundle.module.url(forResource: "cam-regions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Table.self, from: data)
        else { return [] }
        return table.regions
    }()

    /// Every named region, in the table's order.
    public static var all: [CamRegion] { entries.map { CamRegion(id: $0.id, name: $0.name) } }

    /// The named region holding a point, or nil when none does.
    ///
    /// The state has to match as well as the box. Without it the Panhandle's
    /// box would reach over the line and take Orange Beach, Alabama.
    public static func region(latitude: Double, longitude: Double, adminRegionId: String?) -> CamRegion? {
        guard let adminRegionId, !adminRegionId.isEmpty else { return nil }
        for entry in entries where entry.contains(latitude: latitude, longitude: longitude,
                                                  adminRegionId: adminRegionId) {
            return CamRegion(id: entry.id, name: entry.name)
        }
        return nil
    }

    /// "united-states--new-york" → "New York"; "france" → "France". What a
    /// camera no named region claims is called instead — the state, or the
    /// country when the registry gave it no state.
    public static func placeName(fromId id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        let tail = id.components(separatedBy: "--").last ?? id
        let words = tail.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
