import Foundation

/// A stretch of a recording during which the clock was stopped.
///
/// Pausing used to mean the recorder stopped listening: every fix that arrived
/// while the state was `.paused` was dropped on the floor. That made a pause
/// the one edit in the app that could never be undone, and the one that was
/// most often made by accident — a wet screen in a wetsuit pocket taps Pause
/// as readily as a thumb does. A rider on 2026-09-24 lost seventy-one minutes
/// of a two-hour wing session that way, and found out from a map with two
/// straight lines across it.
///
/// Now a pause is a *note*, not a hole. The receiver keeps running, every fix
/// is written down, and the pause becomes a `SessionTrim.Removal` when the
/// session is built — so a deliberate pause reads exactly as it always did,
/// with the paused time out of the averages, and a mistaken one is restored by
/// deleting the cut in Trim. The pause itself is kept on the session as well,
/// so the debrief can say what happened and who did it.
public struct RecordedPause: Hashable, Sendable, Codable, Identifiable {

    /// Who stopped the clock.
    public enum Cause: String, Hashable, Sendable, Codable {
        /// The rider, on the screen.
        case rider
        /// The engine's own auto-pause, from speed.
        case auto
    }

    public var start: Date
    /// `nil` while the pause is still open — which a finished session never
    /// carries, because ending the session closes it.
    public var end: Date?
    public var cause: Cause

    public var id: Date { start }

    public init(start: Date, end: Date? = nil, cause: Cause) {
        self.start = start
        self.end = end
        self.cause = cause
    }

    public var duration: TimeInterval {
        guard let end else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }

    /// The pause as a cut in the recording's own clock, measured from the
    /// first fix the way every `SessionTrim` offset is.
    ///
    /// A `Removal` contains both its ends, and the pause ends *on* a fix when
    /// the engine resumes itself — the fix that showed the rider moving. That
    /// fix is the first one back, not the last one out, so the cut stops a
    /// hair short of it.
    public func removal(from origin: Date) -> SessionTrim.Removal? {
        guard let end else { return nil }
        let startOffset = start.timeIntervalSince(origin)
        let endOffset = end.timeIntervalSince(origin) - 0.001
        guard endOffset > startOffset else { return nil }
        return SessionTrim.Removal(start: startOffset, end: endOffset)
    }
}

extension Array where Element == RecordedPause {

    /// The closed pauses as a trim, or `nil` when there is nothing to cut.
    public func trim(from origin: Date?) -> SessionTrim? {
        guard let origin else { return nil }
        let removals = compactMap { $0.removal(from: origin) }
        guard !removals.isEmpty else { return nil }
        return SessionTrim(removals: removals)
    }

    public var totalDuration: TimeInterval {
        reduce(0) { $0 + $1.duration }
    }
}
