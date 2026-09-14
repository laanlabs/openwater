import Foundation

/// A launch-argument seam that opens the app directly on a given screen.
///
/// Screenshot capture otherwise means driving the UI tap by tap, which is
/// brittle across device sizes and — more importantly — has to run in the test
/// runner's simulator, where MapKit does not get network access and every map
/// renders as a blank placeholder grid. Launching straight onto a screen lets
/// the shots be taken on a normal booted simulator with `simctl`, where the map
/// behaves exactly as it does for a real user.
///
/// Inert unless the argument is present, which only the capture script passes.
enum ScreenshotRoute: String {
    case sessions
    case map
    case runs
    case analysis
    case playback
    case fullScreenMap
    case spots
    case tools
    case record

    static let argumentPrefix = "-openWaterScreen"
    /// `-openWaterSpot <slug>`: with the Spots route, push that guide spot's
    /// page as soon as the guide has loaded. For screenshots and for driving
    /// the simulator — a map pin is the one thing a synthesized tap cannot
    /// reach, and the spot page is where every forecast screen starts.
    static let spotArgumentPrefix = "-openWaterSpot"

    /// The guide spot slug requested on the command line, if any.
    static var requestedSpotSlug: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: spotArgumentPrefix),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// The route requested on the command line, if any.
    static var requested: ScreenshotRoute? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argumentPrefix),
              index + 1 < arguments.count else { return nil }
        return ScreenshotRoute(rawValue: arguments[index + 1])
    }

    /// Which tab this route lives on.
    var tab: Tab {
        switch self {
        case .spots: .spots
        case .tools: .tools
        case .record: .record
        default: .sessions
        }
    }

    /// Whether the route needs the first session opened.
    var opensSession: Bool {
        switch self {
        case .map, .runs, .analysis, .playback, .fullScreenMap: true
        default: false
        }
    }

    /// Which segment of the session detail to show.
    var detailMode: SessionDetailView.Mode? {
        switch self {
        case .map, .playback, .fullScreenMap: .map
        case .runs: .ribbon
        case .analysis: .analysis
        default: nil
        }
    }

    enum Tab: String, Hashable {
        case sessions, spots, record, records, trends, tools, settings
    }
}
