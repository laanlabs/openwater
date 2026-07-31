import Foundation

/// The platform-independent half of recording a session.
///
/// Both the watch and the phone can record, and their numbers have to agree —
/// a rider who records the same session on both, or who switches devices
/// mid-season, must not see their personal bests shift. So everything that
/// decides a *number* lives here and is shared: fix ingestion, the live
/// analyzer, the crash-safe log, auto-pause, and the final analysis pass.
///
/// What stays in the platform shells is only what genuinely differs — the
/// watch's `HKWorkoutSession` and Water Lock, the phone's background task
/// handling, and each one's haptics and UI.
@MainActor
@Observable
public final class RecordingEngine {

    public enum State: Equatable, Sendable {
        case idle
        case recording
        case paused
        case finishing
    }

    // MARK: State

    public private(set) var state: State = .idle
    public private(set) var sport: Sport = .wingfoil
    public private(set) var metrics = LiveMetrics()
    public private(set) var startDate: Date?

    /// Personal bests hit during this session, newest first.
    public private(set) var recordsHit: [LiveRecord] = []

    /// A previous session that was cut short and can still be recovered.
    public private(set) var recoverable: RecoverableSession?

    /// Wind supplied by the rider, for the live angle display.
    public var wind: Wind? {
        didSet { analyzer?.setWind(wind) }
    }

    /// All-time bests, so a live personal-best alert means something beyond
    /// "best so far today".
    public var allTimeBests: [SpeedCategory: Double] = [:] {
        didSet { analyzer?.allTimeBests = allTimeBests }
    }

    /// Stop the clock automatically when the rider stops moving.
    ///
    /// Off by default: a mistimed auto-pause corrupts exactly the averages
    /// people care about, so it is something a rider opts into.
    public var autoPauseEnabled = false

    /// Called when a personal best falls, so the shell can fire a haptic.
    public var onRecord: ((LiveRecord) -> Void)?

    /// Called when auto-pause triggers, so the shell can react.
    public var onAutoPause: (() -> Void)?

    // MARK: Private

    private var analyzer: LiveAnalyzer?
    private var log: TrackLog?
    private var sessionID = UUID()
    private var points: [TrackPoint] = []
    private var stoppedSince: Date?

    private let deviceModel: String?
    private let appVersion: String?

    public struct RecoverableSession: Identifiable, Sendable {
        public let id = UUID()
        public let url: URL
        public let sport: Sport
        public let startDate: Date
        public let pointCount: Int
        public let duration: TimeInterval
        public let distance: Double
    }

    public init(deviceModel: String? = nil, appVersion: String? = nil) {
        self.deviceModel = deviceModel
        self.appVersion = appVersion
    }

    /// Every fix accepted so far, for building a HealthKit route.
    public var recordedPoints: [TrackPoint] { points }

    // MARK: - Lifecycle

    public func start(sport: Sport, at date: Date = Date()) {
        guard state == .idle else { return }

        self.sport = sport
        self.sessionID = UUID()
        self.startDate = date
        self.points.removeAll()
        self.recordsHit.removeAll()
        self.stoppedSince = nil

        let analyzer = LiveAnalyzer(sport: sport, allTimeBests: allTimeBests)
        analyzer.setWind(wind)
        self.analyzer = analyzer
        self.metrics = analyzer.metrics

        do {
            log = try TrackLog(
                sessionID: sessionID,
                sport: sport,
                startDate: date,
                deviceModel: deviceModel,
                appVersion: appVersion
            )
        } catch {
            // Losing the crash log is bad, but it is not a reason to refuse to
            // record — the session still works, it just is not recoverable.
            log = nil
        }

        state = .recording
    }

    public func pause() {
        guard state == .recording else { return }
        state = .paused
        try? log?.flush()
    }

    public func resume() {
        guard state == .paused else { return }
        state = .recording
        stoppedSince = nil
    }

    /// Flush pending fixes to disk. Call when the app is about to be suspended.
    public func flush() {
        try? log?.flush()
    }

    /// End the session and run the full analysis.
    ///
    /// Deliberately the *full* pipeline, not the live one: these are the numbers
    /// the rider keeps, so they get the two-pass filter and the exact solvers
    /// rather than the battery-conscious live approximations.
    public func finish(at date: Date = Date()) -> Session? {
        guard state == .recording || state == .paused else { return nil }
        state = .finishing

        log?.finish()
        let logURL = log?.url
        log = nil

        guard let startDate, points.count >= 2 else {
            if let logURL { TrackLog.delete(logURL) }
            state = .idle
            return nil
        }

        let session = Self.buildSession(
            id: sessionID,
            sport: sport,
            startDate: startDate,
            endDate: date,
            points: points,
            wind: wind,
            deviceModel: deviceModel,
            appVersion: appVersion
        )

        state = .idle
        return session
    }

    public func discard() {
        log?.discard()
        log = nil
        points.removeAll()
        analyzer = nil
        metrics = LiveMetrics()
        state = .idle
    }

    // MARK: - Ingest

    /// Feed one fix, with any motion sample already merged onto it.
    public func ingest(_ point: TrackPoint) {
        guard state == .recording else { return }

        points.append(point)
        log?.append(point)

        guard let analyzer else { return }
        for record in analyzer.add(point) {
            recordsHit.insert(record, at: 0)
            onRecord?(record)
        }
        analyzer.setWind(wind)
        metrics = analyzer.metrics

        handleAutoPause(at: point.timestamp)
    }

    private func handleAutoPause(at date: Date) {
        guard autoPauseEnabled, state == .recording else {
            stoppedSince = nil
            return
        }
        if metrics.isMoving {
            stoppedSince = nil
        } else if let since = stoppedSince {
            if date.timeIntervalSince(since) > 45 {
                pause()
                onAutoPause?()
            }
        } else {
            stoppedSince = date
        }
    }

    // MARK: - Recovery

    /// Look for a session that was interrupted before it could be saved.
    public func checkForRecoverableSession() {
        guard state == .idle else { return }
        for url in TrackLog.unfinishedLogs() {
            guard let (header, points) = try? TrackLog.read(url) else {
                TrackLog.delete(url)
                continue
            }
            // A log with almost nothing in it is not worth offering back.
            guard points.count >= 30 else {
                TrackLog.delete(url)
                continue
            }
            let track = TrackBuilder(options: .forSport(header.sport)).build(from: points)
            recoverable = RecoverableSession(
                url: url,
                sport: header.sport,
                startDate: header.startDate,
                pointCount: points.count,
                duration: track.duration,
                distance: track.totalDistance
            )
            return
        }
        recoverable = nil
    }

    /// Rebuild a session from an interrupted log.
    public func recover(_ candidate: RecoverableSession) -> Session? {
        guard let (header, points) = try? TrackLog.read(candidate.url), points.count >= 2 else {
            TrackLog.delete(candidate.url)
            recoverable = nil
            return nil
        }
        let session = Self.buildSession(
            id: header.sessionID,
            sport: header.sport,
            startDate: header.startDate,
            endDate: points.last?.timestamp ?? header.startDate,
            points: points,
            wind: nil,
            deviceModel: header.deviceModel,
            appVersion: header.appVersion
        )
        TrackLog.delete(candidate.url)
        recoverable = nil
        return session
    }

    public func dismissRecovery() {
        if let recoverable { TrackLog.delete(recoverable.url) }
        recoverable = nil
    }

    // MARK: - Building

    public nonisolated static func buildSession(
        id: UUID,
        sport: Sport,
        startDate: Date,
        endDate: Date,
        points: [TrackPoint],
        wind: Wind?,
        deviceModel: String?,
        appVersion: String?,
        endBattery: Double? = nil
    ) -> Session {
        let track = TrackBuilder(options: .forSport(sport)).build(from: points)
        let summary = SessionAnalyzer(
            configuration: .init(sport: sport, categories: SpeedCategory.all, wind: wind)
        ).analyse(track)

        return Session(
            id: id,
            sport: sport,
            startDate: startDate,
            endDate: endDate,
            track: track,
            wind: summary.wind,
            deviceModel: deviceModel,
            appVersion: appVersion,
            endBattery: endBattery,
            summary: summary
        )
    }
}
