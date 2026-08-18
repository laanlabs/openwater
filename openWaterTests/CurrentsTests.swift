import OpenWaterCore
import XCTest
@testable import openWater

/// The currents layer, pinned against real wire formats.
///
/// Every fixture below is a trimmed copy of an actual response captured on
/// 2026-08-17 — the mdapi station index, a harmonic station's hourly rows
/// (SFB1202, Golden Gate), a subordinate station's MAX_SLACK rows (ACT0091,
/// Eastport), and the marine model's hourly arrays. The formats have real
/// traps a synthetic fixture would miss: hourly `Speed` is a *string* while
/// `Direction` is a number, `Velocity_Major` is signed, a subordinate
/// station answers MAX_SLACK-shaped rows whatever interval is asked for,
/// and an inland model cell replies politely with nothing but nulls.
final class CurrentsTests: XCTestCase {

    // MARK: Open-Meteo model

    /// Velocities arrive in km/h and must leave in knots — the same ÷1.852
    /// the surf card applies. 1.852 km/h is exactly one knot.
    func testModelParseConvertsToKnots() {
        let fixture = """
        {"timezone":"America/New_York","hourly":{
            "time":[1755400000,1755403600],
            "ocean_current_velocity":[1.852,3.704],
            "ocean_current_direction":[50.0,230.0]}}
        """
        let outlook = OpenMeteo.parseModelCurrents(Data(fixture.utf8))
        XCTAssertEqual(outlook.hours.count, 2)
        XCTAssertEqual(outlook.hours[0].speedKn ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(outlook.hours[1].speedKn ?? 0, 2.0, accuracy: 0.0001)
        // Direction is the set — toward — and passes through untouched.
        XCTAssertEqual(outlook.hours[0].directionDeg, 50.0)
        XCTAssertEqual(outlook.timeZone?.identifier, "America/New_York")
        XCTAssertFalse(outlook.isEmpty)
    }

    /// An inland point gets a syntactically perfect reply whose values are
    /// all null. That must read as "no marine cell here" (`isEmpty`), never
    /// as a parse failure — the tab's honest empty state depends on it.
    func testInlandNullsAreEmptyNotBroken() {
        let fixture = """
        {"timezone":"America/Denver","hourly":{
            "time":[1755400000,1755403600],
            "ocean_current_velocity":[null,null],
            "ocean_current_direction":[null,null]}}
        """
        let outlook = OpenMeteo.parseModelCurrents(Data(fixture.utf8))
        XCTAssertEqual(outlook.hours.count, 2)
        XCTAssertTrue(outlook.isEmpty)
        XCTAssertNil(outlook.hours[0].speedKn)
    }

    // MARK: NOAA hourly predictions (harmonic stations)

    /// The hourly rows: `Speed` is a string, `Direction` a number, and the
    /// direction already swings flood-to-ebb between hours — stored as-is.
    func testHourlyPredictionParse() {
        let fixture = """
        {"current_predictions":{"units":"feet, knots","cp":[
            {"Speed":"0.949","Bin":"17","Time":"2026-08-17 00:00","Direction":50,"Depth":"21"},
            {"Speed":"2.636","Bin":"17","Time":"2026-08-17 02:00","Direction":52,"Depth":"21"},
            {"Speed":"0.834","Bin":"17","Time":"2026-08-17 06:00","Direction":231,"Depth":"21"}]}}
        """
        let hours = TidesAndCurrents.parseHourlyPredictions(Data(fixture.utf8))
        XCTAssertEqual(hours.count, 3)
        XCTAssertEqual(hours[0].speedKn ?? 0, 0.949, accuracy: 0.0001)
        XCTAssertEqual(hours[1].directionDeg, 52)
        // The ebb hour keeps its own set; nothing averages 52° with 231°.
        XCTAssertEqual(hours[2].directionDeg, 231)
    }

    // MARK: NOAA MAX_SLACK events

    /// `Velocity_Major` is signed — positive flood, negative ebb — and the
    /// UI wants kinds and magnitudes, so the sign becomes the kind and the
    /// number loses it. Slack rows keep no speed at all.
    func testEventParseResolvesSignIntoKind() {
        let fixture = """
        {"current_predictions":{"units":"feet, knots","cp":[
            {"Type":"flood","meanFloodDir":210,"Bin":"1","meanEbbDir":40,"Time":"2026-08-18 01:33","Velocity_Major":2.54},
            {"Type":"slack","meanFloodDir":210,"Bin":"1","meanEbbDir":40,"Time":"2026-08-18 04:05","Velocity_Major":0},
            {"Type":"ebb","meanFloodDir":210,"Bin":"1","meanEbbDir":40,"Time":"2026-08-18 07:42","Velocity_Major":-2.72}]}}
        """
        let events = TidesAndCurrents.parseEventPredictions(Data(fixture.utf8))
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].kind, .maxFlood)
        XCTAssertEqual(events[0].speedKn ?? 0, 2.54, accuracy: 0.0001)
        XCTAssertEqual(events[1].kind, .slack)
        XCTAssertNil(events[1].speedKn)
        XCTAssertEqual(events[2].kind, .maxEbb)
        XCTAssertEqual(events[2].speedKn ?? 0, 2.72, accuracy: 0.0001, "ebb keeps magnitude, loses sign")
    }

    /// A subordinate station answers MAX_SLACK-shaped rows even when asked
    /// for `interval=60`. Feeding those rows to the hourly parser must
    /// produce nothing at all — a `Type` marks an event, and events posing
    /// as hours once drew a blank chart under a working scrubber.
    func testHourlyParserRejectsEventShapedRows() {
        let fixture = """
        {"current_predictions":{"units":"feet, knots","cp":[
            {"Type":"flood","meanFloodDir":210,"Bin":"1","meanEbbDir":40,"Time":"2026-08-18 01:33","Velocity_Major":2.54}]}}
        """
        XCTAssertTrue(TidesAndCurrents.parseHourlyPredictions(Data(fixture.utf8)).isEmpty)
    }

    /// The second hourly dialect, captured from SFB1203 (Golden Gate,
    /// 0.46 nm E): no Speed/Direction keys — a signed `Velocity_Major`
    /// whose sign picks the mean flood or ebb direction. Positive floods
    /// toward 69°, negative ebbs toward 257°.
    func testHourlyParserSpeaksVelocityMajorDialect() {
        let fixture = """
        {"current_predictions":{"units":"feet, knots","cp":[
            {"meanFloodDir":69,"Bin":"18","meanEbbDir":257,"Time":"2026-08-17 01:00","Depth":"30","Velocity_Major":1.77},
            {"meanFloodDir":69,"Bin":"18","meanEbbDir":257,"Time":"2026-08-17 07:00","Depth":"30","Velocity_Major":-2.31}]}}
        """
        let hours = TidesAndCurrents.parseHourlyPredictions(Data(fixture.utf8))
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours[0].speedKn ?? 0, 1.77, accuracy: 0.0001)
        XCTAssertEqual(hours[0].directionDeg, 69, "positive runs the flood way")
        XCTAssertEqual(hours[1].speedKn ?? 0, 2.31, accuracy: 0.0001, "magnitude, sign shed")
        XCTAssertEqual(hours[1].directionDeg, 257, "negative runs the ebb way")
    }

    // MARK: Station index distillation

    /// One row per instrument: weak-and-variable stations dropped, and a
    /// station publishing several depth bins keeps only the shallowest —
    /// the water the board actually sits in.
    func testIndexDistillation() {
        let fixture = """
        {"count":5,"units":"meters","stations":[
            {"id":"LIS1001","currbin":13,"type":"H","depth":6.0,"name":"The Race","lat":41.22818,"lng":-72.06252},
            {"id":"LIS1001","currbin":1,"type":"H","depth":45.0,"name":"The Race","lat":41.22818,"lng":-72.06252},
            {"id":"ACT0091","currbin":1,"type":"S","depth":null,"name":"Eastport, Friar Roads","lat":44.9,"lng":-66.98333},
            {"id":"WEAK001","currbin":1,"type":"W","depth":null,"name":"Somewhere Sluggish","lat":40.0,"lng":-70.0},
            {"id":"SFB1202","currbin":17,"type":"H","depth":21.0,"name":"Golden Gate Bridge, 0.88 nm NE of","lat":37.82922,"lng":-122.46202}]}
        """
        let rows = TidesAndCurrents.distillCurrentsIndex(Data(fixture.utf8))
        XCTAssertEqual(rows.count, 3, "weak station dropped, duplicate id collapsed")
        XCTAssertNil(rows.first { $0.id == "WEAK001" })

        let race = rows.first { $0.id == "LIS1001" }
        XCTAssertEqual(race?.bin, 13, "the 6 m bin beats the 45 m bin")
        XCTAssertEqual(race?.isHarmonic, true)

        let eastport = rows.first { $0.id == "ACT0091" }
        XCTAssertEqual(eastport?.isHarmonic, false, "type S is events-only")
    }

    // MARK: Outlook semantics

    /// `now` interpolates speed but never direction: halfway between an
    /// hour setting 50° and an hour setting 230° the water is not running
    /// 140° — it is about to turn. The nearer hour's set wins whole.
    func testNowNeverAveragesDirectionsAcrossTheTurn() {
        let outlook = CurrentsOutlook(
            hours: [
                .init(at: Date().addingTimeInterval(-1800), speedKn: 2.0, directionDeg: 50),
                .init(at: Date().addingTimeInterval(1800), speedKn: 1.0, directionDeg: 230),
            ],
            source: .model
        )
        let now = outlook.now
        XCTAssertNotNil(now)
        XCTAssertEqual(now?.speedKn ?? 0, 1.5, accuracy: 0.01)
        XCTAssertTrue(now?.directionDeg == 50 || now?.directionDeg == 230,
                      "direction snaps to a real set, never the average")
    }

    /// A subordinate station's outlook — events, no hours — is not empty:
    /// four turns a day is a real answer.
    func testEventsOnlyOutlookIsNotEmpty() {
        let station = CurrentStation(id: "ACT0091", bin: 1, name: "Eastport, Friar Roads",
                                     metres: 500,
                                     coordinate: Geo.Coordinate(latitude: 44.9, longitude: -66.98333),
                                     isHarmonic: false)
        let outlook = CurrentsOutlook(
            hours: [],
            events: [.init(at: Date(), kind: .maxFlood, speedKn: 2.5)],
            source: .station(station)
        )
        XCTAssertFalse(outlook.isEmpty)
    }
}
