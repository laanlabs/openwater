import Foundation

/// The clock a wave replay runs on when the paddling is cut out.
///
/// A ten-wave session is ninety minutes of water and five minutes of riding.
/// Played end to end it is mostly a dot paddling back out, so the rides get a
/// clock of their own: the ride windows laid end to end, the gaps between them
/// removed. The session's own clock needs no help and is not modelled here —
/// the transport offers both, and this type is only ever the compressed one.
///
/// Nothing here re-decides what a ride *is*; that is `WaveRideFinder`'s job
/// and this reads its answer.
public struct RideTimeline: Sendable {

    /// One ride's place on both clocks.
    public struct Window: Sendable, Equatable {
        /// The ride's `id`, so a caller can name the wave being watched.
        public let rideID: Int
        /// Bounds on the session's own clock.
        public let start: TimeInterval
        public let end: TimeInterval
        /// Where this window begins on the compressed clock.
        public let offset: TimeInterval

        public var duration: TimeInterval { max(0, end - start) }

        /// Session elapsed for a point on the compressed clock, read as
        /// *this* window's.
        ///
        /// A transport bounded to one ride needs this rather than the
        /// timeline-wide lookup: a ride's last instant is also the next
        /// ride's first, and asking the timeline at that boundary answers
        /// with the ride starting, not the one being watched.
        public func sessionElapsed(at t: TimeInterval) -> TimeInterval {
            min(end, start + max(0, t - offset))
        }
    }

    public let windows: [Window]

    /// Total riding time — the compressed clock's full length.
    public let duration: TimeInterval

    public init(rides: [WaveRide]) {
        var offset: TimeInterval = 0
        var built: [Window] = []
        // Time order whatever order the list was handed in: a replay that
        // jumped about because the rider had tapped "Longest" would be a
        // different session every time the picker moved.
        for ride in rides.sorted(by: { $0.startElapsed < $1.startElapsed })
        where ride.endElapsed > ride.startElapsed {
            built.append(Window(rideID: ride.id,
                                start: ride.startElapsed,
                                end: ride.endElapsed,
                                offset: offset))
            offset += ride.endElapsed - ride.startElapsed
        }
        windows = built
        duration = offset
    }

    public var isEmpty: Bool { windows.isEmpty }

    /// The window a point on the compressed clock falls in.
    ///
    /// Clamped at both ends: scrubbed to the very end the playhead sits on the
    /// last ride's kick-out rather than falling off into nothing.
    public func window(at t: TimeInterval) -> Window? {
        guard let first = windows.first, let last = windows.last else { return nil }
        if t <= 0 { return first }
        if t >= duration { return last }
        return windows.last { $0.offset <= t } ?? first
    }

    /// One ride's window, by the ride's own id.
    ///
    /// What a transport needs to bound itself to a single wave: choosing one
    /// should mean play *that*, not resume the session from wherever the
    /// playhead happened to be.
    public func window(forRide id: Int) -> Window? {
        windows.first { $0.rideID == id }
    }

    /// Session elapsed for a point on the compressed clock.
    public func sessionElapsed(at t: TimeInterval) -> TimeInterval {
        guard let window = window(at: t) else { return 0 }
        return min(window.end, window.start + max(0, t - window.offset))
    }

    /// The ride being watched at a point on the compressed clock.
    public func rideID(at t: TimeInterval) -> Int? { window(at: t)?.rideID }

    /// The ride a moment on the *session's* clock falls in, if any — what
    /// whole-session playback needs to name the wave the playhead reached.
    public func rideID(atSessionElapsed t: TimeInterval) -> Int? {
        windows.first { t >= $0.start && t <= $0.end }?.rideID
    }

    /// Where a moment on the session's clock lands on the compressed one.
    ///
    /// Between two rides there is no such moment, so it answers with the start
    /// of the next ride: switching the paddling off should land on the next
    /// wave, which is the whole point of the compressed clock.
    public func compressed(atSessionElapsed t: TimeInterval) -> TimeInterval {
        guard !windows.isEmpty else { return 0 }
        for window in windows {
            if t < window.start { return window.offset }
            if t <= window.end { return window.offset + (t - window.start) }
        }
        return duration
    }
}
