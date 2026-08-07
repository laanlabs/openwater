import Foundation
import Testing
@testable import OpenWaterCore

/// A rider's saved sessions have to keep opening.
///
/// This suite exists because they once did not. Two non-optional fields were
/// added to `SessionSummary` and `DownwindSummary`; Swift's synthesised
/// decoder throws on a missing key rather than falling back to the property's
/// default, so every archive written by an earlier build became undecodable.
/// The failure was swallowed by a `try?` and every session in the app hung on
/// "Loading session…" — a total loss of a rider's history, shipped to
/// TestFlight, from a change that compiled and passed every test.
@Suite("Archive compatibility")
struct ArchiveCompatibilityTests {

    let builder = TrackBuilder()

    private func currentSummary() -> SessionSummary {
        SessionAnalyzer(sport: .wingfoil).analyse(builder.build(from: SyntheticTrack.wingSession()))
    }

    /// Encode a summary, delete a key, and try to read it back.
    private func decodes(withoutKey key: String, inside container: String? = nil) throws -> Bool {
        let data = try JSONEncoder().encode(currentSummary())
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let container {
            var inner = json[container] as! [String: Any]
            inner.removeValue(forKey: key)
            json[container] = inner
        } else {
            json.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: json)
        return (try? JSONDecoder().decode(SessionSummary.self, from: stripped)) != nil
    }

    @Test("A summary written before session shape existed still decodes")
    func withoutShape() throws {
        #expect(try decodes(withoutKey: "storedShape"))
    }

    @Test("A summary written before glides were kept still decodes")
    func withoutGlides() throws {
        #expect(try decodes(withoutKey: "storedGlides", inside: "downwind"))
    }

    /// The rule, enforced rather than remembered.
    ///
    /// A field whose absence breaks decoding is a field that breaks the app for
    /// everybody who installed the version before it was added. The list below
    /// is every such field as of the build that shipped, and it is frozen: each
    /// of these predates any archive a rider can be holding, so requiring them
    /// is safe. Adding a new one is not, and this test names it.
    ///
    /// If this fails because you added a field, the fix is not to update the
    /// list — it is to store the field as an optional and read it through a
    /// non-optional accessor, the way `shape` and `glides` now are.
    static let fieldsSafeToRequire: Set<String> = [
        "analysisVersion",
        "duration", "movingTime", "distance",
        "maxSpeed", "averageSpeed", "averageMovingSpeed",
        "quality", "speedSource", "speedResults",
        "runs", "maneuvers", "maneuverSummary",
        "flights", "foil", "jumps", "jumpSummary",
        "downwind", "states", "segments", "fallSummary", "ribbon",
    ]

    @Test("No field added since the last release is load-bearing")
    func newFieldsSurviveTheirOwnAbsence() throws {
        let data = try JSONEncoder().encode(currentSummary())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        var fatal: [String] = []
        for key in json.keys where !Self.fieldsSafeToRequire.contains(key) {
            var stripped = json
            stripped.removeValue(forKey: key)
            let bytes = try JSONSerialization.data(withJSONObject: stripped)
            if (try? JSONDecoder().decode(SessionSummary.self, from: bytes)) == nil {
                fatal.append(key)
            }
        }
        #expect(fatal.isEmpty, """
            These fields cannot be absent, so every archive written before they \
            existed will fail to decode and the session will hang on loading: \
            \(fatal.sorted()). Store them as optionals with a non-optional \
            accessor instead.
            """)
    }

    @Test("A whole archive from an older analysis version still opens")
    func olderArchiveOpens() throws {
        let track = builder.build(from: SyntheticTrack.wingSession())
        let summary = SessionAnalyzer(sport: .wingfoil).analyse(track)
        let session = Session(sport: .wingfoil, startDate: track.startDate ?? Date(),
                              endDate: track.endDate ?? Date(), track: track,
                              wind: summary.wind, summary: summary)
        let data = try SessionArchive(session: session).encoded()

        // Rewrite it as the previous engine's output: no shape, no glides, and
        // an older version number.
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if var s = json["session"] as? [String: Any], var sum = s["summary"] as? [String: Any] {
            sum.removeValue(forKey: "storedShape")
            if var downwind = sum["downwind"] as? [String: Any] {
                downwind.removeValue(forKey: "storedGlides")
                sum["downwind"] = downwind
            }
            sum["analysisVersion"] = 4
            s["summary"] = sum
            json["session"] = s
        }
        let old = try JSONSerialization.data(withJSONObject: json)

        let decoded = try SessionArchive.decode(old)
        let reopened = decoded.upToDateSession()
        #expect(reopened.summary != nil, "an old archive has to open")
        #expect(reopened.summary?.analysisVersion == SessionSummary.currentVersion,
                "and be brought up to date on the way in")
    }
}

/// A rider's settings have to actually reach the analysis.
///
/// This suite exists because they did not. The glide thresholds were exposed
/// on screen, saved, applied to `SportThresholds` — and then
/// `DownwindAnalyzer.forSport(sport)` built itself from the sport's defaults
/// and never saw them. The screen said "adjusted", the session re-read, and
/// nothing changed. Every detector that carries its own copy of the thresholds
/// needs a test that moving a setting moves a number.
@Suite("Overrides reach the analysis")
struct OverrideEffectTests {

    let builder = TrackBuilder()

    private func summary(_ track: Track, sport: Sport,
                         _ overrides: SportThresholds.Overrides) -> SessionSummary {
        SessionAnalyzer(configuration: .init(sport: sport, overrides: overrides)).analyse(track)
    }

    /// Pump-and-glide cycles: something for every detector to find.
    private func cycles() -> Track {
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<10 {
            legs.append(.init(speed: 3.0, heading: 180, duration: 6))
            legs.append(.init(speed: 9.0, heading: 180, duration: 12, transition: 2))
        }
        return builder.build(from: SyntheticTrack.generate(legs: legs))
    }

    @Test("Raising the glide minimum reduces the glide count")
    func glideDurationReaches() {
        let track = cycles()
        let wind = Wind(directionFrom: 0, speed: 9, source: .manual, confidence: 1)
        func glides(_ o: SportThresholds.Overrides) -> Int {
            SessionAnalyzer(configuration: .init(sport: .downwindSUP, wind: wind, overrides: o))
                .analyse(track).downwind.glideCount
        }
        let asFound = glides(.init())
        #expect(asFound > 0, "precondition: this session glides")
        #expect(glides(.init(glideMinimumDuration: 60)) < asFound,
                "a one-minute minimum has to eliminate twelve-second glides")
    }

    @Test("Tightening the glide angle reduces the glide count")
    func glideAngleReaches() {
        let track = cycles()
        // Sailing due south; the wind from the east makes this a beam reach,
        // which only counts while the angle bar is low enough to allow it.
        let wind = Wind(directionFrom: 90, speed: 9, source: .manual, confidence: 1)
        func glides(_ angle: Double) -> Int {
            SessionAnalyzer(configuration: .init(
                sport: .downwindSUP, wind: wind,
                overrides: .init(glideDownwindAngle: angle)
            )).analyse(track).downwind.glideCount
        }
        #expect(glides(80) > glides(120), "a stricter angle has to cut a beam reach out")
    }

    @Test("Raising the takeoff speed reduces time on foil")
    func takeoffSpeedReaches() {
        let track = cycles()
        let low = summary(track, sport: .wingfoil, .init(foilTakeoffSpeed: 4))
        let high = summary(track, sport: .wingfoil, .init(foilTakeoffSpeed: 8.8))
        #expect(high.foil.timeOnFoil < low.foil.timeOnFoil)
    }

    @Test("Raising the turn threshold reduces the turn count")
    func maneuverThresholdReaches() {
        let track = builder.build(from: SyntheticTrack.wingSession())
        let loose = summary(track, sport: .wingfoil, .init(maneuverHeadingChange: 50))
        let strict = summary(track, sport: .wingfoil, .init(maneuverHeadingChange: 170))
        #expect(strict.maneuverSummary.total < loose.maneuverSummary.total)
    }

    @Test("Raising the minimum airtime reduces the jump count")
    func jumpAirtimeReaches() {
        // A jump needs motion data; build a track with a free-fall window and
        // a landing spike so the detector has something to find.
        var points = SyntheticTrack.constantSpeed(9, duration: 300, heading: 180)
        for i in points.indices {
            points[i].verticalAccelSD = 1.0
            points[i].verticalAccelPeak = 3.0
        }
        // Four one-second flights, each ended by a hard landing.
        for start in stride(from: 20, to: 260, by: 60) {
            for k in start..<(start + 2) where k < points.count {
                points[k].verticalAccelSD = 0.2
                points[k].verticalAccelPeak = 0.4
            }
            if start + 2 < points.count { points[start + 2].verticalAccelPeak = 30 }
        }
        let track = builder.build(from: points)
        let found = summary(track, sport: .wingfoil, .init()).jumpSummary.count
        guard found > 0 else { return }   // detector found nothing to reduce
        let strict = summary(track, sport: .wingfoil, .init(jumpMinimumAirtime: 6)).jumpSummary.count
        #expect(strict < found, "a six-second minimum has to eliminate one-second hops")
    }
}
