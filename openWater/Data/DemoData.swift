import Foundation
import OpenWaterCore

/// Generated sessions, used by the "Add Demo Session" menu item and by the
/// screenshot tests.
///
/// Sharing one generator between the two matters: App Store screenshots have to
/// show the app doing what it actually does, and a separate mock built just for
/// marketing would drift from the real thing the moment an analyzer changed.
/// These go through the identical `SessionAnalyzer` pipeline as a recorded
/// session — every number on a screenshot is really computed.
enum DemoData {

    /// A wingfoil session in a bay: many short runs rather than a few long ones,
    /// which is both what a real session looks like and the case the map
    /// legibility work exists to handle.
    static func wingSession(categories: [SpeedCategory] = SpeedCategory.all) -> Session {
        var points = SyntheticTrack.wingSession(runs: 26, runDuration: 52)
        // Motion data so flights, falls and glides all have something real to
        // work from — without it the session would show speed only.
        for i in points.indices {
            let speed = points[i].speed ?? 0
            points[i].verticalAccelSD = speed > 5 ? 0.4 : 2.6
            points[i].verticalAccelPeak = speed > 5 ? 1.8 : 8.0
        }
        return build(points: points, sport: .wingfoil, spot: "Demo Bay", categories: categories)
    }

    /// A downwind run: one long point-to-point leg with pump-and-glide cycles,
    /// so the glide metrics have something to report.
    static func downwindSession(categories: [SpeedCategory] = SpeedCategory.all) -> Session {
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<28 {
            legs.append(.init(speed: 5.4, heading: 205, duration: 7, transition: 2))
            legs.append(.init(speed: 8.6, heading: 205, duration: 14, transition: 2))
        }
        var points = SyntheticTrack.generate(legs: legs)
        for i in points.indices {
            points[i].verticalAccelSD = (points[i].speed ?? 0) < 7 ? 1.6 : 0.35
        }
        return build(points: points, sport: .downwindSUP, spot: "Demo Downwinder", categories: categories)
    }

    private static func build(
        points: [TrackPoint],
        sport: Sport,
        spot: String,
        categories: [SpeedCategory]
    ) -> Session {
        let track = TrackBuilder(options: .forSport(sport)).build(from: points)
        let summary = SessionAnalyzer(
            configuration: .init(sport: sport, categories: categories)
        ).analyse(track)

        return Session(
            sport: sport,
            startDate: track.startDate ?? Date(),
            endDate: track.endDate ?? Date(),
            track: track,
            notes: "Demo session — generated, not recorded.",
            spotName: spot,
            wind: summary.wind,
            summary: summary
        )
    }
}

extension SessionLibrary {

    /// Launch arguments the screenshot tests use to put the app into a known
    /// state. Ignored in normal use — nothing here runs unless the argument is
    /// present on the command line, which only `xcodebuild test` supplies.
    enum LaunchArgument {
        static let seedDemoData = "-openWaterSeedDemoData"
        static let resetData = "-openWaterResetData"
    }

    /// Apply any launch arguments. Called once at startup.
    func applyLaunchArgumentsIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(LaunchArgument.seedDemoData)
                || arguments.contains(LaunchArgument.resetData) else { return }

        if arguments.contains(LaunchArgument.resetData) {
            delete(ids: Set(allSessions().map(\.id)))
        }
        if arguments.contains(LaunchArgument.seedDemoData), allSessions().isEmpty {
            // Two sessions on different days, so the list, the records board and
            // the trend chart all have something to show.
            var wing = DemoData.wingSession()
            var downwind = DemoData.downwindSession()
            let now = Date()
            shift(&wing, to: now.addingTimeInterval(-2 * 86_400))
            shift(&downwind, to: now.addingTimeInterval(-9 * 86_400))
            save(downwind)
            save(wing)
        }
    }

    /// Move a generated session to a given date, so the list does not show every
    /// demo session as having happened at the same synthetic timestamp.
    private func shift(_ session: inout Session, to date: Date) {
        let delta = date.timeIntervalSince(session.startDate)
        session.startDate = session.startDate.addingTimeInterval(delta)
        session.endDate = session.endDate.addingTimeInterval(delta)
    }
}
