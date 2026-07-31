import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Share snapshot")
struct ShareSnapshotTests {

    /// A session with a genuine fast run in the middle of slower riding, so the
    /// downsampler has a peak it can lose.
    private func session() -> Session {
        let points = SyntheticTrack.generate(legs: [
            .init(speed: 7, heading: 90, duration: 600),
            .init(speed: 16, heading: 95, duration: 60, transition: 5),
            .init(speed: 7, heading: 270, duration: 600, transition: 5),
        ])
        let track = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        let summary = SessionAnalyzer(sport: .wingfoil).analyse(track)
        return Session(
            sport: .wingfoil,
            startDate: track.startDate ?? Date(),
            endDate: track.endDate ?? Date(),
            track: track,
            wind: summary.wind,
            summary: summary
        )
    }

    @Test("The payload is small enough to upload from a beach")
    func payloadIsSmall() throws {
        let snapshot = ShareSnapshot.make(from: session())
        let data = try snapshot.encoded()
        #expect(data.count < 100_000, "share payload was \(data.count) bytes")
        #expect(snapshot.points.count <= 1200)
    }

    @Test("Downsampling keeps the fastest sample in each bucket")
    func downsamplingKeepsPeaks() {
        let full = session()
        let snapshot = ShareSnapshot.make(from: full, maximumPoints: 120)

        let peak = snapshot.points.map { $0[2] }.max() ?? 0
        let actual = full.track.speed.max() ?? 0
        // Rounding to one decimal is the only loss allowed; taking every nth
        // point instead would shave several knots off the top run.
        #expect(abs(peak - actual) < 0.1,
                "kept peak \(peak) against a real \(actual)")
    }

    @Test("Coordinates are longitude-first, matching GeoJSON")
    func coordinateOrder() throws {
        let snapshot = ShareSnapshot.make(from: session())
        let first = try #require(snapshot.points.first)
        #expect(first.count == 3)
        // The fixture sails off the California coast; getting the order wrong
        // puts it in Kazakhstan and the web page draws an empty ocean.
        #expect(first[0] < -100, "longitude should come first, got \(first[0])")
        #expect(first[1] > 30 && first[1] < 45, "latitude should come second, got \(first[1])")
    }

    @Test("Nothing personal rides along")
    func excludesPersonalFields() throws {
        var full = session()
        full.notes = "parked behind the blue house"
        full.spotName = "home spot"
        full.deviceModel = "iPhone17,1"

        let data = try ShareSnapshot.make(from: full).encoded()
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("blue house"))
        #expect(!json.contains("iPhone17"))
        #expect(!json.contains("heartRate"))
    }

    @Test("Endpoints are trimmed before upload")
    func trimsEndpoints() throws {
        let full = session()
        let snapshot = ShareSnapshot.make(from: full)

        let firstShared = Geo.Coordinate(
            latitude: snapshot.points[0][1],
            longitude: snapshot.points[0][0]
        )
        let launch = try #require(full.track.points.first).coordinate
        // The default sharing policy masks 200 m; rounding coordinates to five
        // decimals moves them by about a metre, so the margin is generous.
        #expect(Geo.distance(firstShared, launch) > 150,
                "launch point survived the trim at \(Geo.distance(firstShared, launch)) m")
    }

    @Test("A snapshot survives a round trip")
    func roundTrip() throws {
        let snapshot = ShareSnapshot.make(from: session())
        let decoded = try ShareSnapshot.decode(snapshot.encoded())

        #expect(decoded.version == snapshot.version)
        #expect(decoded.points.count == snapshot.points.count)
        #expect(abs(decoded.maxSpeed - snapshot.maxSpeed) < 0.001)
        #expect(decoded.categories.count == snapshot.categories.count)
    }

    @Test("Codes are unguessable and URL-safe")
    func codes() {
        let codes = (0..<500).map { _ in ShareSnapshot.makeCode() }
        #expect(Set(codes).count == codes.count, "generated a duplicate code")

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        for code in codes {
            #expect(code.count == 22)
            #expect(code.unicodeScalars.allSatisfy(allowed.contains),
                    "code \(code) needs escaping in a URL")
        }
    }

    @Test("An empty track produces an empty point list rather than a crash")
    func emptyTrack() {
        let empty = Session(
            sport: .wingfoil,
            startDate: Date(),
            endDate: Date(),
            track: TrackBuilder(options: .forSport(.wingfoil)).build(from: []),
            wind: nil,
            summary: nil
        )
        let snapshot = ShareSnapshot.make(from: empty)
        #expect(snapshot.points.isEmpty)
        #expect(snapshot.speedCeiling >= 1)
    }
}
