import Foundation

/// A launch-argument seam that opens the television straight onto a screen.
///
/// The same seam the phone has, and it exists here for a sharper reason: an
/// Apple TV cannot be driven at all from this machine. There is no way to send
/// a remote press to a tvOS simulator — no `simctl` injection, and synthesized
/// key events are refused — so "launch onto the screen and photograph it" is
/// not a convenience, it is the only way to capture a screen that is more than
/// one press from the launch tab.
///
/// Inert unless the argument is present, which only the capture script passes.
enum TVScreenshotRoute: String {
    case map
    case cameras
    /// The cameras map, which the grid opens over itself.
    case camerasMap
    case radar
    case favorites
    case settings
    /// The full report for the point under the map's crosshairs.
    case conditions
    /// The five-day model comparison, one press inside the report.
    case windOutlook

    static let argumentPrefix = "-openWaterTVScreen"

    static var requested: TVScreenshotRoute? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argumentPrefix),
              index + 1 < arguments.count else { return nil }
        return TVScreenshotRoute(rawValue: arguments[index + 1])
    }

    /// Which tab the route opens on. The deeper screens are all reached from
    /// the map, because that is the tab that knows where "here" is.
    var tab: RootView.Tab {
        switch self {
        case .cameras, .camerasMap: .cameras
        case .radar: .radar
        case .favorites: .favorites
        case .settings: .settings
        case .map, .conditions, .windOutlook: .map
        }
    }

    /// How long to let the screen settle before it is worth photographing.
    ///
    /// Not one number for all of them: the map has tiles, a wash and a wind
    /// field to fetch, while Settings is drawn on the first frame. A single
    /// generous wait would make a capture run take minutes for no gain.
    var settleSeconds: Double {
        switch self {
        case .settings, .favorites: 12
        case .cameras, .camerasMap: 20
        case .map, .radar: 26
        case .conditions, .windOutlook: 30
        }
    }
}
