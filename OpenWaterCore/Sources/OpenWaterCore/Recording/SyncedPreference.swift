import Foundation

/// Settings both devices can change, and which travel between them.
///
/// The watch is deliberately usable by someone who has never opened the phone
/// app, so a preference offered in both places has two authors and no server to
/// arbitrate. Each side stamps its own change and the more recent one wins.
public enum SyncedPreference {

    /// Whether a value arriving from the other device should replace the local
    /// one.
    ///
    /// Ties go to the local device. That matters more than it looks: a rider
    /// who flips a switch on their wrist mid-session must not have it flipped
    /// back by an application context the phone queued earlier, and the system
    /// delivers those whenever it next can rather than when they were made. A
    /// device that has never set the preference carries `.distantPast`, so the
    /// first push from the other side is always taken.
    public static func accepts(incoming changedAt: Date, over local: Date) -> Bool {
        changedAt > local
    }
}
