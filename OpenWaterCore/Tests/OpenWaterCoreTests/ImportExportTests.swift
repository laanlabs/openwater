import Foundation
import Testing
@testable import OpenWaterCore

// MARK: - Fixtures

/// Builds a valid FIT byte stream.
///
/// FIT is binary and self-describing, so the only honest way to test the decoder
/// is to hand it real bytes laid out to the spec. Writing this builder is also
/// the cheapest way to be sure the decoder's understanding of the container is
/// right rather than merely self-consistent.
struct FITBuilder {

    private var messages = Data()

    /// Declare the shape of the `record` messages that follow.
    mutating func addRecordDefinition(bigEndian: Bool = false) {
        var definition = Data()
        definition.append(0x40)                          // definition, local type 0
        definition.append(0x00)                          // reserved
        definition.append(bigEndian ? 0x01 : 0x00)       // architecture

        let global: UInt16 = 20                          // record
        if bigEndian {
            definition.append(UInt8(global >> 8))
            definition.append(UInt8(global & 0xFF))
        } else {
            definition.append(UInt8(global & 0xFF))
            definition.append(UInt8(global >> 8))
        }

        definition.append(4)                             // field count
        definition.append(contentsOf: [253, 4, 0x86])    // timestamp, uint32
        definition.append(contentsOf: [0, 4, 0x85])      // position_lat, sint32
        definition.append(contentsOf: [1, 4, 0x85])      // position_long, sint32
        definition.append(contentsOf: [6, 2, 0x84])      // speed, uint16 (scale 1000)

        messages.append(definition)
    }

    /// One `record` data message.
    ///
    /// Pass `nil` for latitude to emit the invalid pattern, which is how a FIT
    /// file says "no GPS fix here" — the decoder must drop those rather than
    /// reporting a position off the coast of Africa.
    mutating func addRecord(
        date: Date,
        latitude: Double?,
        longitude: Double?,
        speed: Double?,
        bigEndian: Bool = false
    ) {
        var record = Data()
        record.append(0x00)   // data message, local type 0

        let fitSeconds = UInt32(date.timeIntervalSince1970 - FIT.epochOffset)
        append(&record, uint32: fitSeconds, bigEndian: bigEndian)

        let latRaw: UInt32 = latitude.map {
            UInt32(bitPattern: Int32(($0 / FIT.degreesPerSemicircle).rounded()))
        } ?? 0x7FFF_FFFF                                  // sint32 invalid
        append(&record, uint32: latRaw, bigEndian: bigEndian)

        let lonRaw: UInt32 = longitude.map {
            UInt32(bitPattern: Int32(($0 / FIT.degreesPerSemicircle).rounded()))
        } ?? 0x7FFF_FFFF
        append(&record, uint32: lonRaw, bigEndian: bigEndian)

        let speedRaw: UInt16 = speed.map { UInt16(($0 * 1000).rounded()) } ?? 0xFFFF
        append(&record, uint16: speedRaw, bigEndian: bigEndian)

        messages.append(record)
    }

    /// Wrap the messages in a valid 14-byte file header.
    func build(truncateBy: Int = 0) -> Data {
        var header = Data()
        header.append(14)                                 // header size
        header.append(0x20)                               // protocol version 2.0
        header.append(contentsOf: [0x00, 0x08])           // profile version
        var size = UInt32(messages.count)
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }   // LE data size
        header.append(contentsOf: Array(".FIT".utf8))
        header.append(contentsOf: [0x00, 0x00])           // header CRC (unchecked)

        var body = messages
        if truncateBy > 0 { body = body.prefix(max(0, body.count - truncateBy)) }

        var file = header
        file.append(body)
        file.append(contentsOf: [0x00, 0x00])             // file CRC (unchecked)
        return file
    }

    private func append(_ data: inout Data, uint32 value: UInt32, bigEndian: Bool) {
        var v = bigEndian ? value.bigEndian : value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private func append(_ data: inout Data, uint16 value: UInt16, bigEndian: Bool) {
        var v = bigEndian ? value.bigEndian : value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

private func demoSession() -> Session {
    let points = SyntheticTrack.constantSpeed(9.5, duration: 120)
    let track = TrackBuilder().build(from: points)
    let summary = SessionAnalyzer(sport: .wingfoil).analyse(track)
    return Session(
        sport: .wingfoil,
        startDate: track.startDate ?? Date(),
        endDate: track.endDate ?? Date(),
        track: track,
        spotName: "Test Bay",
        summary: summary
    )
}

// MARK: - GPX

@Suite("GPX")
struct GPXTests {

    @Test("A written GPX reads back with its positions, times and speeds intact")
    func roundTrip() throws {
        let session = demoSession()
        let data = GPX.write(session: session)
        let imported = try GPX.read(data)

        #expect(imported.points.count == session.track.count)
        #expect(imported.format == .gpx)
        #expect(imported.hasSpeedChannel, "speed must survive the round trip")

        let original = session.track.points[10]
        let restored = imported.points[10]
        #expect(abs(original.latitude - restored.latitude) < 1e-6)
        #expect(abs(original.longitude - restored.longitude) < 1e-6)
        #expect(abs(original.timestamp.timeIntervalSince(restored.timestamp)) < 0.01)
        #expect(abs((original.speed ?? 0) - (restored.speed ?? 0)) < 0.01)
    }

    @Test("Speed is picked up from the Garmin TrackPointExtension")
    func garminExtensionSpeed() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Garmin"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
          <trk><trkseg>
            <trkpt lat="37.8265" lon="-122.3720">
              <ele>0.5</ele>
              <time>2026-07-30T18:00:00Z</time>
              <extensions><gpxtpx:TrackPointExtension>
                <gpxtpx:speed>11.5</gpxtpx:speed>
                <gpxtpx:hr>146</gpxtpx:hr>
              </gpxtpx:TrackPointExtension></extensions>
            </trkpt>
            <trkpt lat="37.8266" lon="-122.3721">
              <time>2026-07-30T18:00:01Z</time>
              <extensions><gpxtpx:TrackPointExtension>
                <gpxtpx:speed>11.8</gpxtpx:speed>
                <gpxtpx:hr>148</gpxtpx:hr>
              </gpxtpx:TrackPointExtension></extensions>
            </trkpt>
          </trkseg></trk>
        </gpx>
        """
        let imported = try GPX.read(Data(gpx.utf8))
        #expect(imported.points.count == 2)
        #expect(imported.points[0].speed == 11.5)
        #expect(imported.points[0].heartRate == 146)
        #expect(imported.hasHeartRate)
    }

    @Test("A GPX with no speed still imports, and is flagged as derived")
    func noSpeedChannel() throws {
        let gpx = """
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
          <trkpt lat="37.8265" lon="-122.3720"><time>2026-07-30T18:00:00Z</time></trkpt>
          <trkpt lat="37.8266" lon="-122.3719"><time>2026-07-30T18:00:01Z</time></trkpt>
          <trkpt lat="37.8267" lon="-122.3718"><time>2026-07-30T18:00:02Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let imported = try GPX.read(Data(gpx.utf8))
        #expect(imported.points.count == 3)
        #expect(!imported.hasSpeedChannel)

        // The pipeline must still work, just with a derived speed source.
        let session = imported.makeSession(sport: .wingfoil)
        #expect(session.track.speedSource == .derived)
        #expect(session.track.totalDistance > 0)
    }

    @Test("Timestamps without a timezone are read as UTC, not local")
    func timestampsWithoutZone() throws {
        // An hour of drift would move a session to a different tide.
        let withZone = DateParsing.parse("2026-07-30T18:00:00Z")
        let withoutZone = DateParsing.parse("2026-07-30T18:00:00")
        #expect(withZone == withoutZone)
    }

    @Test("A file with no track points is rejected rather than imported empty")
    func emptyGPX() {
        let gpx = "<gpx version=\"1.1\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><trkseg></trkseg></trk></gpx>"
        #expect(throws: ImportError.noTrackPoints) {
            try GPX.read(Data(gpx.utf8))
        }
    }
}

// MARK: - TCX

@Suite("TCX")
struct TCXTests {

    @Test("A written TCX reads back intact")
    func roundTrip() throws {
        let session = demoSession()
        let data = TCX.write(session: session)
        let imported = try TCX.read(data)

        #expect(imported.points.count == session.track.count)
        #expect(imported.format == .tcx)
        #expect(imported.hasSpeedChannel)

        let original = session.track.points[20]
        let restored = imported.points[20]
        #expect(abs(original.latitude - restored.latitude) < 1e-6)
        #expect(abs((original.speed ?? 0) - (restored.speed ?? 0)) < 0.01)
    }

    @Test("Heart rate is read from the nested Value element")
    func nestedHeartRate() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
                                xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
          <Activities><Activity Sport="Other"><Lap><Track>
            <Trackpoint>
              <Time>2026-07-30T18:00:00Z</Time>
              <Position><LatitudeDegrees>37.8265</LatitudeDegrees><LongitudeDegrees>-122.3720</LongitudeDegrees></Position>
              <HeartRateBpm><Value>152</Value></HeartRateBpm>
              <Extensions><ns3:TPX><ns3:Speed>12.25</ns3:Speed></ns3:TPX></Extensions>
            </Trackpoint>
            <Trackpoint>
              <Time>2026-07-30T18:00:01Z</Time>
              <Position><LatitudeDegrees>37.8266</LatitudeDegrees><LongitudeDegrees>-122.3721</LongitudeDegrees></Position>
              <HeartRateBpm><Value>153</Value></HeartRateBpm>
            </Trackpoint>
          </Track></Lap></Activity></Activities>
        </TrainingCenterDatabase>
        """
        let imported = try TCX.read(Data(tcx.utf8))
        #expect(imported.points.count == 2)
        #expect(imported.points[0].heartRate == 152)
        #expect(imported.points[0].speed == 12.25)
    }
}

// MARK: - FIT

@Suite("FIT")
struct FITTests {

    private func start() -> Date {
        // A whole number of seconds, so the FIT epoch conversion is exact.
        Date(timeIntervalSince1970: 1_785_000_000)
    }

    @Test("Records decode with positions, times and speeds")
    func decodesRecords() throws {
        var builder = FITBuilder()
        builder.addRecordDefinition()
        let t0 = start()
        for i in 0..<10 {
            builder.addRecord(
                date: t0.addingTimeInterval(Double(i)),
                latitude: 37.8265 + Double(i) * 0.0001,
                longitude: -122.3720,
                speed: 10 + Double(i) * 0.1
            )
        }

        let imported = try FIT.read(builder.build())
        #expect(imported.format == .fit)
        #expect(imported.points.count == 10)

        let first = imported.points[0]
        #expect(abs(first.latitude - 37.8265) < 1e-5)
        #expect(abs(first.longitude - (-122.3720)) < 1e-5)
        #expect(abs(first.timestamp.timeIntervalSince(t0)) < 0.5)
        #expect(abs((first.speed ?? 0) - 10) < 0.01)

        #expect(abs((imported.points[9].speed ?? 0) - 10.9) < 0.01)
    }

    @Test("Big-endian files decode identically to little-endian ones")
    func bigEndian() throws {
        func decode(bigEndian: Bool) throws -> ImportedTrack {
            var builder = FITBuilder()
            builder.addRecordDefinition(bigEndian: bigEndian)
            let t0 = start()
            for i in 0..<5 {
                builder.addRecord(
                    date: t0.addingTimeInterval(Double(i)),
                    latitude: 37.8265,
                    longitude: -122.3720,
                    speed: 12.5,
                    bigEndian: bigEndian
                )
            }
            return try FIT.read(builder.build())
        }

        let little = try decode(bigEndian: false)
        let big = try decode(bigEndian: true)

        #expect(little.points.count == big.points.count)
        #expect(abs(little.points[0].latitude - big.points[0].latitude) < 1e-9)
        #expect(abs((little.points[0].speed ?? 0) - (big.points[0].speed ?? 0)) < 1e-9)
    }

    @Test("Fields holding the invalid pattern are dropped, not reported as data")
    func invalidValuesAreDropped() throws {
        var builder = FITBuilder()
        builder.addRecordDefinition()
        let t0 = start()

        builder.addRecord(date: t0, latitude: 37.8265, longitude: -122.3720, speed: 11)
        // No fix: this must not become a position, and must not become 0,0.
        builder.addRecord(date: t0.addingTimeInterval(1), latitude: nil, longitude: nil, speed: nil)
        // Fix, but no speed reading.
        builder.addRecord(date: t0.addingTimeInterval(2), latitude: 37.8266, longitude: -122.3721, speed: nil)

        let imported = try FIT.read(builder.build())
        #expect(imported.points.count == 2, "the no-fix record should have been dropped")
        #expect(imported.points[0].speed == 11)
        #expect(imported.points[1].speed == nil, "a missing speed must stay missing, not become 65.535")
        #expect(!imported.points.contains { $0.latitude == 0 && $0.longitude == 0 })
    }

    @Test("A truncated file yields what it can, with a warning")
    func truncatedFile() throws {
        var builder = FITBuilder()
        builder.addRecordDefinition()
        let t0 = start()
        for i in 0..<20 {
            builder.addRecord(
                date: t0.addingTimeInterval(Double(i)),
                latitude: 37.8265 + Double(i) * 0.0001,
                longitude: -122.3720,
                speed: 10
            )
        }
        // Chop the tail, as an interrupted transfer would.
        let imported = try FIT.read(builder.build(truncateBy: 40))

        #expect(!imported.points.isEmpty)
        #expect(imported.points.count < 20)
        #expect(imported.warnings.contains { $0.contains("truncated") })
    }

    @Test("A file that is not FIT is rejected")
    func notAFITFile() {
        #expect(throws: (any Error).self) {
            try FIT.read(Data("this is not a fit file, not even close".utf8))
        }
    }

    @Test("Decoded FIT feeds the analysis pipeline")
    func endToEnd() throws {
        var builder = FITBuilder()
        builder.addRecordDefinition()
        let t0 = start()
        // Two minutes heading east at 10 m/s.
        var position = Geo.Coordinate(latitude: 37.8265, longitude: -122.3720)
        for i in 0..<120 {
            builder.addRecord(
                date: t0.addingTimeInterval(Double(i)),
                latitude: position.latitude,
                longitude: position.longitude,
                speed: 10
            )
            position = Geo.destination(from: position, bearing: 90, distance: 10)
        }

        let session = try FIT.read(builder.build()).makeSession(sport: .wingfoil)
        #expect(session.track.speedSource == .doppler)
        #expect(abs(session.track.totalDistance - 1190) < 60)

        let summary = try #require(session.summary)
        let best500 = try #require(summary.result(for: .distance(metres: 500)))
        #expect(best500.isValid)
        #expect(abs(best500.speed - 10) < 0.3)
    }
}

// MARK: - CSV and GeoJSON

@Suite("CSV and GeoJSON")
struct CSVTests {

    @Test("A written CSV reads back intact")
    func roundTrip() throws {
        let session = demoSession()
        let data = CSV.write(session: session)
        let imported = try CSV.read(data)

        #expect(imported.points.count == session.track.count)
        #expect(imported.hasSpeedChannel)
        #expect(abs(imported.points[5].latitude - session.track.points[5].latitude) < 1e-6)
    }

    @Test("Alternative column names and a Unix timestamp are accepted")
    func flexibleColumns() throws {
        let csv = """
        time,lat,lng,knots,hr
        1785000000,37.8265,-122.3720,20.0,150
        1785000001,37.8266,-122.3721,20.5,151
        1785000002,37.8267,-122.3722,21.0,152
        """
        let imported = try CSV.read(Data(csv.utf8))
        #expect(imported.points.count == 3)
        #expect(imported.points[0].heartRate == 150)
        // 20 knots is 10.29 m/s.
        #expect(abs((imported.points[0].speed ?? 0) - 10.288) < 0.01)
    }

    @Test("A CSV with no position columns is rejected with a useful message")
    func missingColumns() {
        let csv = "speed,heart_rate\n10,150\n"
        #expect(throws: (any Error).self) {
            try CSV.read(Data(csv.utf8))
        }
    }

    @Test("GeoJSON export contains the track and a feature per state segment")
    func geoJSON() throws {
        let session = demoSession()
        let data = try GeoJSON.write(session: session)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(root["type"] as? String == "FeatureCollection")

        let features = try #require(root["features"] as? [[String: Any]])
        #expect(features.count >= 1)

        let first = try #require(features.first)
        let geometry = try #require(first["geometry"] as? [String: Any])
        #expect(geometry["type"] as? String == "LineString")
        let coordinates = try #require(geometry["coordinates"] as? [[Double]])
        #expect(coordinates.count == session.track.count)
        // GeoJSON is longitude-first, which is the classic way to get a track
        // rendered in the Indian Ocean.
        #expect(coordinates[0][0] < -100)
        #expect(coordinates[0][1] > 30)
    }
}

// MARK: - Format detection

@Suite("Format detection")
struct FormatDetectionTests {

    @Test("Each format is recognised from its contents, not its extension")
    func sniffing() throws {
        let session = demoSession()

        #expect(TrackImporter.detectFormat(GPX.write(session: session)) == .gpx)
        #expect(TrackImporter.detectFormat(TCX.write(session: session)) == .tcx)
        #expect(TrackImporter.detectFormat(CSV.write(session: session)) == .csv)
        #expect(try TrackImporter.detectFormat(SessionArchive(session: session).encoded()) == .openwater)

        var builder = FITBuilder()
        builder.addRecordDefinition()
        builder.addRecord(
            date: Date(timeIntervalSince1970: 1_785_000_000),
            latitude: 37.8265, longitude: -122.3720, speed: 10
        )
        #expect(TrackImporter.detectFormat(builder.build()) == .fit)
    }

    @Test("Unknown content is reported rather than guessed at")
    func unknownFormat() {
        #expect(TrackImporter.detectFormat(Data("hello world".utf8)) == nil)
        #expect(throws: ImportError.unrecognisedFormat) {
            try TrackImporter.read(Data("hello world".utf8))
        }
    }

    @Test("The generic reader handles every readable format")
    func genericRead() throws {
        let session = demoSession()
        for data in [
            GPX.write(session: session),
            TCX.write(session: session),
            CSV.write(session: session),
            try SessionArchive(session: session).encoded(),
        ] {
            let imported = try TrackImporter.read(data)
            #expect(!imported.points.isEmpty)
        }
    }
}
