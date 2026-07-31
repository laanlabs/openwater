import Foundation

/// Runs the whole analysis pipeline over a track and produces a cached summary.
///
/// Order matters: flights feed the maneuver detector so it can tell a dry gybe
/// from a wet one, and the wind feeds both the polar and the maneuver
/// classifier. Everything downstream of a failed stage degrades rather than
/// throwing — a session with no usable wind estimate still gets its speeds,
/// runs and flights, just without angles.
public struct SessionAnalyzer: Sendable {

    public struct Configuration: Sendable {
        public var sport: Sport
        /// Categories to evaluate, in display order.
        public var categories: [SpeedCategory]
        /// Wind supplied by the rider. When present, estimation is skipped.
        public var wind: Wind?
        /// Skip the expensive stages for a quick live-ish pass.
        public var quickMode: Bool

        public init(
            sport: Sport,
            categories: [SpeedCategory] = SpeedCategory.standard,
            wind: Wind? = nil,
            quickMode: Bool = false
        ) {
            self.sport = sport
            self.categories = categories
            self.wind = wind
            self.quickMode = quickMode
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public init(sport: Sport) {
        self.configuration = Configuration(sport: sport)
    }

    // MARK: - Analyse

    public func analyse(_ track: Track) -> SessionSummary {
        let sport = configuration.sport
        let thresholds = sport.thresholds

        // --- Basics
        let movingTime = movingTime(of: track, above: thresholds.movingSpeed)
        let maxSpeed = track.speed.max() ?? 0
        let duration = track.duration
        let distance = track.totalDistance

        // --- Speed categories
        let speedAnalyzer = SpeedAnalyzer()
        let speedResults = speedAnalyzer.evaluate(configuration.categories, on: track)

        // --- Runs
        var runs = RunSegmenter.forSport(sport).segment(track)

        // --- Flights. Non-foiling sports return an empty list rather than a
        // pile of false positives.
        let foilDetector = FoilDetector.forSport(sport)
        let flights = sport.isFoiling ? foilDetector.detect(in: track) : []
        let foilSummary = foilDetector.summarise(flights: flights, track: track, movingTime: movingTime)

        // --- Wind: the rider's value wins; otherwise infer it.
        let wind: Wind? = configuration.wind
            ?? (sport.isWindPowered ? WindEstimator().estimate(from: track) : nil)

        // --- Maneuvers, classified against the wind and the flights.
        let maneuvers = ManeuverDetector.forSport(sport)
            .detect(in: track, wind: wind, flights: flights)
        let maneuverSummary = ManeuverSummary(maneuvers: maneuvers)

        // --- Jumps. Silent without motion data, by design.
        let jumps = configuration.quickMode ? [] : JumpDetector.forSport(sport).detect(in: track)

        // --- Downwind glides.
        let downwind = configuration.quickMode
            ? DownwindSummary.none
            : DownwindAnalyzer.forSport(sport)
                .analyse(track: track, flights: flights, wind: wind, movingTime: movingTime)

        // --- Polar, and back-fill the per-run wind figures.
        var polar: PolarAnalysis?
        if let wind, sport.isWindPowered {
            polar = PolarBuilder().build(track: track, wind: wind)
            let flyingMask = foilDetector.flyingMask(flights: flights, count: track.count)
            runs = runs.map { run in
                var r = run
                let twa = wind.trueWindAngle(heading: run.meanHeading)
                r.trueWindAngle = twa
                r.vmg = wind.vmg(speed: run.averageSpeed, heading: run.meanHeading)
                if run.endIndex > run.startIndex, run.endIndex < flyingMask.count {
                    let flying = (run.startIndex...run.endIndex).reduce(0) {
                        $0 + (flyingMask[$1] ? 1 : 0)
                    }
                    r.foilingFraction = Double(flying) / Double(run.endIndex - run.startIndex + 1)
                }
                return r
            }
        }

        // --- Ride state, falls, and the drawable segments.
        //
        // This runs last because it depends on both the flights and the runs,
        // and it is what turns an unreadable tangle of overlapping passes into
        // something a rider can actually parse.
        let classifier = RideStateClassifier.forSport(sport)
        let states = classifier.classify(track: track, flights: flights)
        let segments = classifier.segments(track: track, states: states, runs: runs)
        let fallSummary = sport.isFoiling
            ? classifier.falls(track: track, states: states, flights: flights)
            : .none
        let ribbon = SessionRibbonBuilder().build(
            track: track,
            runs: runs,
            segments: segments,
            maneuvers: maneuvers,
            falls: fallSummary.falls,
            states: states
        )

        // --- Heart rate
        let heartRates = track.points.compactMap(\.heartRate).filter { $0 > 0 }

        return SessionSummary(
            duration: duration,
            movingTime: movingTime,
            distance: distance,
            maxSpeed: maxSpeed,
            averageSpeed: duration > 0 ? distance / duration : 0,
            averageMovingSpeed: movingTime > 0 ? distance / movingTime : 0,
            quality: track.quality,
            speedSource: track.speedSource,
            speedResults: speedResults,
            runs: runs,
            maneuvers: maneuvers,
            maneuverSummary: maneuverSummary,
            flights: flights,
            foil: foilSummary,
            jumps: jumps,
            jumpSummary: JumpSummary(jumps: jumps),
            downwind: downwind,
            states: states,
            segments: segments,
            fallSummary: fallSummary,
            ribbon: ribbon,
            wind: wind,
            polar: polar,
            averageHeartRate: heartRates.isEmpty
                ? nil
                : heartRates.reduce(0, +) / Double(heartRates.count),
            maxHeartRate: heartRates.max()
        )
    }

    // MARK: - Helpers

    /// Seconds spent above the moving threshold.
    ///
    /// Integrated over the intervals between samples rather than counted as
    /// samples, so a dropout does not quietly inflate or deflate it.
    func movingTime(of track: Track, above threshold: Double) -> TimeInterval {
        guard track.count > 1 else { return 0 }
        var total: TimeInterval = 0
        for i in 1..<track.count {
            let dt = track.elapsed[i] - track.elapsed[i - 1]
            // Ignore implausibly long gaps — the rider may have been anywhere.
            guard dt > 0, dt < 30 else { continue }
            let mean = (track.speed[i] + track.speed[i - 1]) / 2
            if mean >= threshold { total += dt }
        }
        return total
    }
}
