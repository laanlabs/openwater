import Foundation

/// What the rider was on.
///
/// Free text per part rather than a fixed catalogue: foil gear is mixed and
/// matched across brands, riders name things their own way ("the 1099", "big
/// red"), and a dropdown that does not contain somebody's kit is worse than
/// a blank line. The value is in the comparison — this front wing against
/// that one, over a season — and that works on whatever names a rider uses,
/// as long as they use them consistently.
///
/// Split into the foil and what drives it, because those are the two things
/// changed independently: a rider swaps front wings between runs and keeps
/// the same wing all year, or the reverse.
public struct Equipment: Hashable, Sendable, Codable {

    // The foil, front to back.
    public var frontWing: String
    public var fuselage: String
    public var tail: String
    public var mast: String

    // What pulls you along. One session normally uses one of these, but a
    // parawing session with a paddle for the way out is a real thing.
    public var wing: String
    public var parawing: String
    public var paddle: String

    public var board: String

    public init(
        frontWing: String = "", fuselage: String = "", tail: String = "",
        mast: String = "", wing: String = "", parawing: String = "",
        paddle: String = "", board: String = ""
    ) {
        self.frontWing = frontWing
        self.fuselage = fuselage
        self.tail = tail
        self.mast = mast
        self.wing = wing
        self.parawing = parawing
        self.paddle = paddle
        self.board = board
    }

    public var all: [(label: String, value: String)] {
        [("Front wing", frontWing), ("Fuselage", fuselage), ("Tail", tail),
         ("Mast", mast), ("Board", board), ("Wing", wing),
         ("Parawing", parawing), ("Paddle", paddle)]
    }

    /// Nothing filled in. Stored as nil in that case rather than as a struct
    /// of empty strings, so a session without gear does not carry a record
    /// claiming otherwise.
    public var isEmpty: Bool {
        all.allSatisfy { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Only the parts that were named, for display.
    public var filled: [(label: String, value: String)] {
        all.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A one-line summary — front wing and whatever drove it, which is how a
    /// rider would answer "what were you on?".
    public var headline: String? {
        let driver = [wing, parawing, paddle].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let parts = [frontWing, driver].compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
