import Foundation
import OpenWaterCore
import Testing
@testable import OpenWaterSpots

/// The compass, against the coast it was asked for.
///
/// The rider's own example is the fixture: standing at East Hampton, pressing
/// east should reach Atlantic Beach, then Hither Hills, then Montauk Point —
/// four real cameras on one stretch of the South Fork. That chain is the whole
/// feature, so it is the test, at the coordinates those cameras actually sit
/// at rather than at invented ones that would prove only the arithmetic.
@Suite("Cam compass")
struct CamCompassTests {

    // The South Fork, west to east.
    static let eastHampton = Geo.Coordinate(latitude: 40.9457, longitude: -72.1848)
    static let atlanticBeach = Geo.Coordinate(latitude: 40.9432, longitude: -72.1206)
    static let hitherHills = Geo.Coordinate(latitude: 41.0000, longitude: -72.0200)
    static let montaukPoint = Geo.Coordinate(latitude: 41.0712, longitude: -71.8573)
    /// West along the ocean beach, the other way from East Hampton.
    static let georgica = Geo.Coordinate(latitude: 40.9394, longitude: -72.2158)
    /// North across the fork, on the bay.
    static let threeMileHarbor = Geo.Coordinate(latitude: 41.0261, longitude: -72.1900)

    private func camera(_ name: String, _ coordinate: Geo.Coordinate)
    -> SpotGuideStore.GuideResource {
        SpotGuideStore.GuideResource(
            kind: .camera,
            name: name,
            url: URL(string: "https://example.com/\(name.replacingOccurrences(of: " ", with: "-"))")!,
            provider: nil,
            detail: nil,
            coordinate: coordinate
        )
    }

    private var southFork: [SpotGuideStore.GuideResource] {
        [
            camera("Georgica", Self.georgica),
            camera("East Hampton", Self.eastHampton),
            camera("Atlantic Beach", Self.atlanticBeach),
            camera("Hither Hills", Self.hitherHills),
            camera("Montauk Point", Self.montaukPoint),
            camera("Three Mile Harbor", Self.threeMileHarbor),
        ]
    }

    @Test("East from East Hampton reaches the next camera east, not the furthest")
    func eastPicksTheNearestInThatDirection() throws {
        let next = try #require(CamCompass.next(from: Self.eastHampton, towards: .east,
                                                among: southFork))
        #expect(next.name == "Atlantic Beach")
    }

    @Test("Pressing east four times walks the coast")
    func eastChainsAlongTheFork() {
        var here = Self.eastHampton
        var visited: [String] = []

        for _ in 0..<3 {
            guard let next = CamCompass.next(from: here, towards: .east, among: southFork)
            else { break }
            visited.append(next.name)
            // Each hop re-measures from where it landed, which is what makes
            // this a chain rather than four readings of one radius.
            here = next.coordinate
        }

        #expect(visited == ["Atlantic Beach", "Hither Hills", "Montauk Point"])
    }

    @Test("West from East Hampton goes the other way")
    func westGoesWest() throws {
        let next = try #require(CamCompass.next(from: Self.eastHampton, towards: .west,
                                                among: southFork))
        #expect(next.name == "Georgica")
    }

    @Test("North from East Hampton crosses to the bay")
    func northCrossesTheFork() throws {
        let next = try #require(CamCompass.next(from: Self.eastHampton, towards: .north,
                                                among: southFork))
        #expect(next.name == "Three Mile Harbor")
    }

    @Test("A direction with nothing in it is empty rather than wrong")
    func southIsOpenOcean() {
        // Everything in the fixture is on the fork or north of it; south of
        // the ocean beach is the Atlantic.
        #expect(CamCompass.next(from: Self.eastHampton, towards: .south, among: southFork) == nil)
    }

    @Test("Angles on one pole are not a direction")
    func camerasAtTheSamePlaceAreSkipped() throws {
        // A second camera 120 m east of the first — the shape of a beach with
        // two angles filed as two rows. Stepping to it and back is what the
        // separation floor exists to prevent.
        let nextDoor = Geo.Coordinate(latitude: Self.eastHampton.latitude,
                                      longitude: Self.eastHampton.longitude + 0.0014)
        #expect(Geo.distance(Self.eastHampton, nextDoor) < CamCompass.minimumSeparation)

        var pool = southFork
        pool.append(camera("East Hampton second angle", nextDoor))

        let next = try #require(CamCompass.next(from: Self.eastHampton, towards: .east,
                                                among: pool))
        #expect(next.name == "Atlantic Beach")
    }

    @Test("Distance and bearing are measured from here, not inherited")
    func measurementsAreRelativeToTheCameraBeingWatched() throws {
        // The pool's own numbers were filled in relative to whatever spot the
        // query was made from. A rider three hops along the coast is not
        // standing there any more.
        var stale = camera("Montauk Point", Self.montaukPoint)
        stale.metres = 999_999
        stale.bearing = 270

        let next = try #require(CamCompass.next(from: Self.hitherHills, towards: .east,
                                                among: [stale]))
        #expect(next.metres < 20_000)
        #expect(abs(next.bearing - 60) < 15, "Montauk is ENE of Hither Hills")
    }

    @Test("A camera already being watched is never the answer")
    func exclusionsAreHonoured() throws {
        let atlantic = camera("Atlantic Beach", Self.atlanticBeach)
        let next = try #require(CamCompass.next(from: Self.eastHampton, towards: .east,
                                                among: southFork,
                                                excluding: [atlantic.id]))
        #expect(next.name == "Hither Hills")
    }

    @Test("Only cameras are stepped to")
    func windMetersAreNotCameras() {
        var meter = camera("Atlantic Beach meter", Self.atlanticBeach)
        meter = SpotGuideStore.GuideResource(
            kind: .wind, name: meter.name, url: meter.url, provider: nil,
            detail: nil, coordinate: Self.atlanticBeach
        )
        #expect(CamCompass.next(from: Self.eastHampton, towards: .east, among: [meter]) == nil)
    }

    @Test("All four directions are read in one pass")
    func neighboursNamesEveryDirection() {
        let found = CamCompass.neighbours(from: Self.eastHampton, among: southFork)
        #expect(found[.east]?.name == "Atlantic Beach")
        #expect(found[.west]?.name == "Georgica")
        #expect(found[.north]?.name == "Three Mile Harbor")
        #expect(found[.south] == nil)
    }

    @Test("The wedges tile the compass, so nothing is unreachable",
          arguments: [0.0, 44.0, 46.0, 89.0, 91.0, 179.0, 181.0, 269.0, 271.0, 359.0])
    func everyBearingFallsInSomeDirection(_ bearing: Double) {
        let matches = CamCompass.Direction.allCases.filter {
            abs(CamCompass.difference(bearing, $0.centre)) <= CamCompass.halfWidth
        }
        #expect(!matches.isEmpty, "\(bearing)° belongs to no direction")
    }
}
