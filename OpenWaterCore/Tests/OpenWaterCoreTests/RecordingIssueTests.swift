import Foundation
import Testing
@testable import OpenWaterCore

/// Each missing thing is explained by its own issues and nobody else's.
@Suite("Recording issues")
struct RecordingIssueTests {

    static func session(_ issues: [String]) -> Session {
        Session(sport: .wingfoil, startDate: Date(), endDate: Date(),
                track: TrackBuilder().build(from: []), recordingIssues: issues)
    }

    /// Word for word, from the wingfoil session that reported no jumps.
    static let refused = [
        "Motion & Fitness access is denied, so the altimeter could not be read and jump height comes from GPS. Settings ▸ Privacy & Security ▸ Motion & Fitness ▸ openWater.",
        "The altimeter refused: The operation couldn’t be completed. (CMErrorDomain error 105.). Jump height comes from GPS for this session.",
    ]

    @Test("A refused altimeter is an altimeter issue with a switch")
    func refusedAltimeter() {
        let s = Self.session(Self.refused)
        #expect(s.altimeterIssues.count == 2)
        #expect(s.otherRecordingIssues.isEmpty)
        #expect(s.altimeterWasRefused)
    }

    @Test("A silent altimeter with permission is not sent to the switch")
    func silentAltimeter() {
        let s = Self.session(["The altimeter recorded nothing, so jump height comes from GPS and is under-read. Motion & Fitness was granted and it gave no error; 0 absolute and 0 relative readings arrived, and it was restarted 2 times for silence."])
        #expect(s.altimeterIssues.count == 1)
        #expect(!s.altimeterWasRefused)
    }

    @Test("Heart-rate issues stay with heart rate")
    func heartRateIssuesAreSeparate() {
        let workout = "The workout session could not start: denied. Without it there is no heart rate, and recording stops when the wrist drops."
        let s = Self.session(Self.refused + [workout])
        #expect(s.otherRecordingIssues == [workout])
        #expect(s.altimeterIssues == Self.refused)
    }
}
