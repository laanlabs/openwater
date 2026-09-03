import Foundation
import Testing
@testable import OpenWaterSpots

/// Station data must mean the same instant on every phone.
///
/// NOAA's `lst_ldt` clock was being parsed as the phone's own, which is only
/// right for a rider standing on the station's shore. Every request now asks
/// for GMT and every parser reads GMT, so a stamp is one instant whatever
/// the device's zone — and the bundled current-station snapshot is read from
/// the package it lives in.
@Suite("Station time and snapshots")
struct StationTimeTests {

    @Test("A water-level stamp parses as GMT, not as the phone's clock")
    func waterLevelParsesInGMT() throws {
        // Six rows so the half-hour thinning keeps the first and the sixth.
        let rows = (0..<6).map { i in
            #"{"t": "2026-09-02 06:\#(String(format: "%02d", i * 6))", "v": "0.\#(i)"}"#
        }
        let data = Data(#"{"predictions": [\#(rows.joined(separator: ","))]}"#.utf8)
        let points = TidesAndCurrents.parseWaterLevel(data)

        let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-02T06:00:00Z"))
        #expect(points.first?.at == expected)
        #expect(points.count == 2)
    }

    @Test("The bundled current-station snapshot resolves from the package")
    func bundledCurrentsResolve() {
        let rows = TidesAndCurrents.bundledCurrentsIndex()
        #expect(rows.count > 1000, "the snapshot decoded to \(rows.count) rows")
        #expect(rows.contains { $0.id == "ACT0091" })
    }
}
