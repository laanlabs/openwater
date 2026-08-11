import Foundation
import Testing
@testable import OpenWaterCore

/// Fixtures copied from real realtime2 `.spec` files — the format's three
/// kinds of raggedness are all real rows, not inventions.
@Suite("NDBC spectral files")
struct NDBCSpectralTests {

    /// Buoy 46026 on a day it resolved the full split.
    private let fullSplit = """
    #YY  MM DD hh mm WVHT  SwH  SwP  WWH  WWP SwD WWD  STEEPNESS  APD MWD
    #yr  mo dy hr mn    m    m  sec    m  sec  -  degT     -      sec degT
    2026 08 11 16 10  1.3  1.2  9.1  0.3  3.7  NW WNW      SWELL  6.4 321
    2026 08 11 15 40  1.2  1.2  9.1  0.4  4.0  NW   W      SWELL  6.3 323
    """

    /// A wave buoy whose split sensors are down: WVHT real, split all MM.
    private let heightOnly = """
    #YY  MM DD hh mm WVHT  SwH  SwP  WWH  WWP SwD WWD  STEEPNESS  APD MWD
    #yr  mo dy hr mn    m    m  sec    m  sec  -  degT     -      sec degT
    2026 08 11 16 26  2.1   MM   MM   MM   MM  MM  MM        N/A  8.8 305
    """

    @Test("A full row parses into measured trains")
    func fullRow() throws {
        let readings = NDBCSpectral.parse(fullSplit)
        #expect(readings.count == 2)
        let newest = try #require(readings.first)

        #expect(newest.waveHeightM == 1.3)
        let swell = try #require(newest.swell)
        #expect(swell.heightM == 1.2)
        #expect(swell.periodS == 9.1)
        // "NW" is a compass word, not a number: 315° true.
        #expect(swell.directionFromDeg == 315)
        let windWave = try #require(newest.windWave)
        #expect(windWave.heightM == 0.3)
        #expect(windWave.directionFromDeg == 292.5)
        #expect(newest.averagePeriodS == 6.4)
        #expect(newest.meanDirectionDeg == 321)
        #expect(newest.steepness == "SWELL")

        // 16:10 UTC on the row is 16:10 UTC in the reading.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(utc.component(.hour, from: newest.at) == 16)
        #expect(utc.component(.minute, from: newest.at) == 10)
    }

    @Test("A buoy with no split still reports its height")
    func heightOnlyRow() throws {
        let readings = NDBCSpectral.parse(heightOnly)
        let reading = try #require(readings.first)
        #expect(reading.waveHeightM == 2.1)
        #expect(reading.swell == nil)
        #expect(reading.windWave == nil)
        #expect(reading.steepness == nil)
        #expect(reading.averagePeriodS == 8.8)
    }

    @Test("Headers alone parse to nothing, and junk rows are skipped")
    func headersAndJunk() {
        let headerOnly = """
        #YY  MM DD hh mm WVHT  SwH  SwP  WWH  WWP SwD WWD  STEEPNESS  APD MWD
        #yr  mo dy hr mn    m    m  sec    m  sec  -  degT     -      sec degT
        """
        #expect(NDBCSpectral.parse(headerOnly).isEmpty)
        #expect(NDBCSpectral.parse("not a spec file at all").isEmpty)
        #expect(NDBCSpectral.parse("").isEmpty)
    }

    @Test("All sixteen compass points resolve, and nonsense does not")
    func cardinalTable() {
        #expect(NDBCSpectral.degrees(fromCardinal: "N") == 0)
        #expect(NDBCSpectral.degrees(fromCardinal: "E") == 90)
        #expect(NDBCSpectral.degrees(fromCardinal: "SSW") == 202.5)
        #expect(NDBCSpectral.degrees(fromCardinal: "nnw") == 337.5)
        #expect(NDBCSpectral.degrees(fromCardinal: "XYZ") == nil)
        #expect(NDBCSpectral.degrees(fromCardinal: "") == nil)
    }
}
