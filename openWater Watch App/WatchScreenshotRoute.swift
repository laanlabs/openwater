import Foundation
import OpenWaterCore

/// Launch-argument seam for capturing watch screenshots.
///
/// The live screens are the ones worth showing, and they only exist while a
/// session is running — so the capture starts a *real* session and drives the
/// simulator along a real route with `simctl location`. Everything on screen is
/// genuinely computed from simulated GPS fixes, exactly as it would be from a
/// receiver. Nothing here fakes a number.
///
/// Inert unless the arguments are passed, which only the capture script does.
enum WatchScreenshotRoute {

    static let autoStartArgument = "-openWaterAutoStart"
    static let pageArgument = "-openWaterWatchPage"
    static let sportArgument = "-openWaterWatchSport"

    /// Whether to begin recording as soon as the app launches.
    static var shouldAutoStart: Bool {
        ProcessInfo.processInfo.arguments.contains(autoStartArgument)
    }

    /// Which live page to show.
    static var page: LiveSessionView.Page? {
        guard let raw = value(for: pageArgument) else { return nil }
        switch raw {
        case "speed": return .speed
        case "splits": return .splits
        case "session": return .session
        case "angles": return .angles
        case "foil": return .foil
        case "controls": return .controls
        case "countdown": return .countdown
        default: return nil
        }
    }

    static var sport: Sport? {
        value(for: sportArgument).flatMap(Sport.init(rawValue:))
    }

    private static func value(for argument: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
