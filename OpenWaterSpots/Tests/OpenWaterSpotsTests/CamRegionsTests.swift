import Foundation
import OpenWaterCore
import Testing
@testable import OpenWaterSpots

/// Named coastal regions and saved cams.
///
/// The region table is the website's, bundled; its boundary cases are tested
/// there too (`openwater-www/test/cam-regions.test.js`). These pin the few a
/// rider would notice from the app, and that the bundle resolves at all — a
/// missing table fails quietly, with every camera simply losing its region.
@Suite("Cam regions and favorites")
@MainActor
struct CamRegionsTests {

    @Test("The region table is in the package bundle")
    func tableResolves() {
        #expect(CamRegions.all.count > 30)
        #expect(CamRegions.all.contains { $0.id == "long-island" && $0.name == "Long Island" })
    }

    @Test("Cameras land in the stretch of coast a rider would name")
    func regions() {
        let ny = "united-states--new-york", fl = "united-states--florida"
        #expect(CamRegions.region(latitude: 41.07, longitude: -71.86, adminRegionId: ny)?.id == "long-island")
        #expect(CamRegions.region(latitude: 40.59, longitude: -73.82, adminRegionId: ny)?.id == "new-york-city")
        #expect(CamRegions.region(latitude: 26.32, longitude: -80.08, adminRegionId: fl)?.id == "south-florida")
        #expect(CamRegions.region(latitude: 24.55, longitude: -81.80, adminRegionId: fl)?.id == "florida-keys")
        // The state has to match as well as the box.
        #expect(CamRegions.region(latitude: 30.27, longitude: -87.60, adminRegionId: "united-states--alabama") == nil)
        #expect(CamRegions.region(latitude: 40.94, longitude: -72.19, adminRegionId: nil) == nil)
    }

    @Test("A camera no region claims is called by its state, then its country")
    func fallbackNames() {
        let ri = cam(lat: 41.43, lon: -71.46, admin: "united-states--rhode-island", country: "united-states")
        #expect(ri.region == nil)
        #expect(ri.regionName == "Rhode Island")
        let it = cam(lat: 45.9, lon: 9.0, admin: nil, country: "italy")
        #expect(it.regionName == "Italy")
        let li = cam(lat: 40.94, lon: -72.19, admin: "united-states--new-york", country: "united-states")
        #expect(li.regionName == "Long Island")
    }

    @Test("A favorite cam is saved by document id, survives a new store, and toggles off")
    func favorites() {
        let key = "spotGuide.favoriteCams"
        let before = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let store = SpotGuideStore()
        let montauk = cam(lat: 41.07, lon: -71.86, admin: "united-states--new-york",
                          country: "united-states", docId: "cam-montauk")
        #expect(!store.isFavoriteCam(montauk))
        store.toggleFavoriteCam(montauk)
        #expect(store.isFavoriteCam(montauk))

        // A repaired link is still the same favorite, and the refresh takes it.
        let repaired = cam(lat: 41.07, lon: -71.86, admin: "united-states--new-york",
                           country: "united-states", docId: "cam-montauk",
                           url: "https://www.youtube.com/watch?v=NEWNEWNEW01")
        #expect(store.isFavoriteCam(repaired))
        store.refreshFavoriteCams(with: [repaired])
        #expect(store.favoriteCams.first?.url == repaired.url)

        let reopened = SpotGuideStore()
        #expect(reopened.favoriteCams.count == 1)
        #expect(reopened.favoriteCams.first?.docId == "cam-montauk")
        #expect(reopened.favoriteCams.first?.regionName == "Long Island")
        let measured = reopened.measuredFavoriteCams(from: Geo.Coordinate(latitude: 40.71, longitude: -74.01))
        #expect((measured.first?.metres ?? 0) > 150_000)

        reopened.toggleFavoriteCam(montauk)
        #expect(reopened.favoriteCams.isEmpty)
    }

    private func cam(lat: Double, lon: Double, admin: String?, country: String?,
                     docId: String? = nil,
                     url: String = "https://www.youtube.com/watch?v=abcdefghijk") -> SpotGuideStore.GuideResource {
        SpotGuideStore.GuideResource(
            kind: .camera, name: "Test cam",
            url: URL(string: url)!,
            provider: "youtube", detail: nil,
            coordinate: Geo.Coordinate(latitude: lat, longitude: lon),
            docId: docId, adminRegionId: admin, countryId: country
        )
    }
}
