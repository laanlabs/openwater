import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Scratch diagnostics")
struct ScratchDiagnosticTests {

    func supCycles() -> Track {
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<10 {
            legs.append(.init(speed: 3.0, heading: 180, duration: 6))
            legs.append(.init(speed: 9.0, heading: 180, duration: 12, transition: 2))
        }
        return TrackBuilder().build(from: SyntheticTrack.generate(legs: legs))
    }

    @Test("Sweep floor fraction and deceleration")
    func sweep() throws {
        let path = "/Users/jclaan/Downloads/Waterspeed- upwind test.gpx"
        guard FileManager.default.fileExists(atPath: path) else { print("NO FILE"); return }
        let track = TrackBuilder().build(from: try GPX.read(Data(contentsOf: URL(fileURLWithPath: path))).points)
        let s = SessionAnalyzer(sport: .wingfoil).analyse(track)
        let sup = supCycles()
        let supWind = Wind(directionFrom: 0, speed: 9, source: .manual, confidence: 1)

        print("target: the run is 843s / 4019m")
        print("frac  decel   glides  longest(s/m)      supCycles")
        for frac in [0.95, 0.85, 0.75, 0.65] {
            for decel in [0.35, 0.5, 0.7] {
                var a = DownwindAnalyzer.forSport(.wingfoil)
                a.glideSpeedFraction = frac
                a.maximumDeceleration = decel
                let dw = a.analyse(track: track, flights: s.flights, wind: s.wind, movingTime: s.movingTime)

                var b = DownwindAnalyzer.forSport(.downwindSUP)
                b.glideSpeedFraction = frac
                b.maximumDeceleration = decel
                let supCount = b.analyse(track: sup, flights: [], wind: supWind,
                                         movingTime: sup.duration).glideCount

                print(String(format: "%.2f  %.2f    %5d   %5.0fs / %5.0fm    %2d",
                             frac, decel, dw.glideCount,
                             dw.longestGlide?.duration ?? 0, dw.longestGlide?.distance ?? 0, supCount))
            }
        }
    }
}
