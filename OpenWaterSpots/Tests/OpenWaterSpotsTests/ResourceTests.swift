import Foundation
import Testing
@testable import OpenWaterSpots

/// The bundled indexes have to survive the move into a package.
///
/// They used to be read from `Bundle.main` — the app bundle — and are now read
/// from `Bundle.module`. Nothing crashes if that lookup misses: `Coastline`
/// returns a mask that says "not known" everywhere and the wash simply stops
/// masking land, and the station indexes fall back to an empty list, so the
/// app shows no tide stations and no buoys. Both look like a quiet day rather
/// than a broken build, which is exactly why they are asserted here.
@Suite("Bundled resources")
struct ResourceTests {

    @Test("The coastline binary is in the package bundle and has its header")
    func coastlineResolves() throws {
        let url = try #require(Bundle.module.url(forResource: "coastline", withExtension: "bin"))
        let data = try Data(contentsOf: url)
        #expect(data.count > 1_000_000)
        // "OWLM" — the magic `Coastline.load` checks before reading any polygon.
        #expect(Array(data.prefix(4)) == Array("OWLM".utf8))
    }

    @Test("Every bundled station index resolves and parses",
          arguments: ["ndbc-stations", "noaa-tide-stations", "noaa-current-stations"])
    func stationIndexResolves(_ name: String) throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"),
                               "\(name).json is missing from the package bundle")
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        let count = (parsed as? [Any])?.count ?? (parsed as? [String: Any])?.count ?? 0
        #expect(count > 0, "\(name).json parsed to nothing")
    }

    @Test("The land mask actually reads the coastline")
    func maskSeparatesLandFromWater() {
        // San Francisco Bay: the Pacific west of the Golden Gate is water,
        // and downtown Oakland is not.
        let region = Coastline.mask(
            for: .init(center: .init(latitude: 37.80, longitude: -122.40),
                       span: .init(latitudeDelta: 0.6, longitudeDelta: 0.6)),
            pixels: 256)
        #expect(region.isWater(.init(latitude: 37.79, longitude: -122.70)) == true)
        #expect(region.isWater(.init(latitude: 37.80, longitude: -122.27)) == false)
    }
}
