import Foundation
import Testing
@testable import OpenWaterCore

/// The compressed clock: rides laid end to end, the paddling between them
/// gone. What is tested here is the mapping in both directions, and the two
/// places it is easy to get wrong — the ends, and the gaps.
@Suite("Ride timeline")
struct RideTimelineTests {

    /// Three waves in a session with long paddles between them: 20 s from
    /// t=100, 10 s from t=300, 30 s from t=500. Sixty seconds of riding
    /// inside nine minutes of water.
    private func ride(_ id: Int, from: TimeInterval, to: TimeInterval) -> WaveRide {
        WaveRide(id: id, startElapsed: from, endElapsed: to,
                 startIndex: Int(from), endIndex: Int(to),
                 distance: 100, entrySpeed: 5, peakSpeed: 9, averageSpeed: 7,
                 offSwell: 20, netBearing: 0)
    }

    private var timeline: RideTimeline {
        RideTimeline(rides: [ride(0, from: 100, to: 120),
                             ride(1, from: 300, to: 310),
                             ride(2, from: 500, to: 530)])
    }

    @Test("The compressed clock is the riding time, not the session")
    func duration() {
        #expect(timeline.duration == 60)
        #expect(timeline.windows.count == 3)
        #expect(timeline.windows.map(\.offset) == [0, 20, 30])
    }

    @Test("Compressed time maps back onto the session's clock")
    func forward() {
        let t = timeline
        #expect(t.sessionElapsed(at: 0) == 100)      // first takeoff
        #expect(t.sessionElapsed(at: 10) == 110)     // mid first ride
        #expect(t.sessionElapsed(at: 20) == 300)     // the paddle is skipped
        #expect(t.sessionElapsed(at: 25) == 305)
        #expect(t.sessionElapsed(at: 30) == 500)
        #expect(t.sessionElapsed(at: 60) == 530)     // last kick-out
    }

    @Test("Scrubbing past either end sits on a ride, not on nothing")
    func clamped() {
        let t = timeline
        #expect(t.sessionElapsed(at: -5) == 100)
        #expect(t.sessionElapsed(at: 999) == 530)
        #expect(t.rideID(at: -5) == 0)
        #expect(t.rideID(at: 999) == 2)
    }

    @Test("Every point on the compressed clock names its wave")
    func naming() {
        let t = timeline
        #expect(t.rideID(at: 5) == 0)
        #expect(t.rideID(at: 25) == 1)
        #expect(t.rideID(at: 45) == 2)
    }

    @Test("On the session's clock, the paddling names no wave")
    func gapsAreEmpty() {
        let t = timeline
        #expect(t.rideID(atSessionElapsed: 110) == 0)
        #expect(t.rideID(atSessionElapsed: 200) == nil)
        #expect(t.rideID(atSessionElapsed: 505) == 2)
        #expect(t.rideID(atSessionElapsed: 0) == nil)
    }

    @Test("Switching clocks mid-paddle lands on the next wave")
    func backward() {
        let t = timeline
        #expect(t.compressed(atSessionElapsed: 110) == 10)   // inside a ride
        #expect(t.compressed(atSessionElapsed: 200) == 20)   // between: next takeoff
        #expect(t.compressed(atSessionElapsed: 0) == 0)      // before them all
        #expect(t.compressed(atSessionElapsed: 900) == 60)   // after them all
    }

    @Test("Rides handed over out of order still replay in time order")
    func sorted() {
        let t = RideTimeline(rides: [ride(2, from: 500, to: 530),
                                     ride(0, from: 100, to: 120),
                                     ride(1, from: 300, to: 310)])
        #expect(t.windows.map(\.rideID) == [0, 1, 2])
        #expect(t.sessionElapsed(at: 25) == 305)
    }

    @Test("A ride can be looked up by its own id")
    func byRide() {
        let t = timeline
        #expect(t.window(forRide: 1)?.start == 300)
        #expect(t.window(forRide: 1)?.offset == 20)
        #expect(t.window(forRide: 1)?.duration == 10)
        #expect(t.window(forRide: 99) == nil)
    }

    @Test("A window read on its own keeps the boundary instant for itself")
    func windowIsItsOwnClock() throws {
        let t = timeline
        let first = try #require(t.window(forRide: 0))
        #expect(first.sessionElapsed(at: 0) == 100)
        #expect(first.sessionElapsed(at: 10) == 110)
        // t = 20 is the first ride's kick-out *and* the second's takeoff. Read
        // through the window it stays the first ride's; the timeline-wide
        // lookup moves on to the second.
        #expect(first.sessionElapsed(at: 20) == 120)
        #expect(t.sessionElapsed(at: 20) == 300)
        #expect(first.sessionElapsed(at: 99) == 120)
    }

    @Test("No rides is empty, and answers without crashing")
    func empty() {
        let t = RideTimeline(rides: [])
        #expect(t.isEmpty)
        #expect(t.duration == 0)
        #expect(t.window(at: 0) == nil)
        #expect(t.rideID(at: 10) == nil)
        #expect(t.sessionElapsed(at: 10) == 0)
        #expect(t.compressed(atSessionElapsed: 10) == 0)
    }

    @Test("A zero-length ride is not a window")
    func degenerate() {
        let t = RideTimeline(rides: [ride(0, from: 100, to: 100),
                                     ride(1, from: 300, to: 310)])
        #expect(t.windows.map(\.rideID) == [1])
        #expect(t.duration == 10)
    }
}
