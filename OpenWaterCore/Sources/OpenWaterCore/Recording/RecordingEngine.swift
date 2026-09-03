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

    /// Optional name and spot, set before starting. Both flow into the session
    /// that `finish()` produces, so a rider who labels a session up front does
    /// not have to go back and do it afterwards.
    public var title: String?
    public var spotName: String?

    /// Wind supplied by the rider, for the live angle display.
    /// Swell the rider called before starting, metres. Nothing computes it;
    /// it rides through to the saved session as their own note on the day.
    public var swellHeight: Double?

    /// Degrees the swell comes from, if the rider called it. Independent of
    /// the wind: on a beach day they are routinely not the same quarter.
    public var swellDirection: Double?

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
    ///
    /// `save` is handed the finished session and answers whether it is now
    /// somewhere durable — the library on the phone, the sync outbox on the
    /// watch. The crash log is released only when it says yes, so a complete
    /// copy of the session exists on disk at every instant: either the shell's
    /// own, or the log recovery can rebuild from. A shell that cannot save gets
    /// the session back anyway and finds the log still waiting next launch.
    ///
    /// Saving is a parameter rather than something the caller does afterwards
    /// because the ordering is the whole guarantee. Released too early and a
    /// failed write loses the session outright; never released and every clean
    /// session is offered back as unfinished, which teaches riders to dismiss
    /// the one prompt that ever matters.
    ///
    /// Async because the analysis is real work — a three-hour session is ten
    /// thousand fixes through every detector — and it used to run on the
    /// main actor from the End button, freezing the screen for the duration
    /// and, on a cold phone, risking the watchdog exactly between the log
    /// being closed and the session being written. The state is `.finishing`
    /// throughout, so a second press finds nothing to end and the live screen
    /// stays up; the log is untouched until `save` says yes.
    @discardableResult
    public func finish(at date: Date = Date(), save: (Session) -> Bool) async -> Session? {
        guard state == .recording || state == .paused else { return nil }
        state = .finishing

        log?.finish()
        let logURL = log?.url
        log = nil

        guard let startDate, points.count >= 2 else {
            // A single fix is not a session and nothing can be rebuilt from it.
            if let logURL { TrackLog.delete(logURL) }
            state = .idle
            return nil
        }

        let (id, sport, points, wind) = (sessionID, sport, points, wind)
        let (deviceModel, appVersion) = (deviceModel, appVersion)
        let (title, spotName, swellHeight, swellDirection) = (title, spotName, swellHeight, swellDirection)
        let session = await Task.detached(priority: .userInitiated) {
            Self.buildSession(
                id: id,
                sport: sport,
                startDate: startDate,
                endDate: date,
                points: points,
                wind: wind,
                deviceModel: deviceModel,
                appVersion: appVersion,
                title: title,
                spotName: spotName,
                swellHeight: swellHeight,
                swellDirection: swellDirection
            )
        }.value

        if save(session), let logURL { TrackLog.delete(logURL) }

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
    ///
    /// Offers the newest one; the rest wait their turn, and `recover` and
    /// `dismissRecovery` look again once it has been dealt with, so a phone
    /// that was killed on three separate days gets three prompts rather than
    /// one prompt and two orphans left on disk forever.
    ///
    /// - Parameter isAlreadySaved: whether the shell already holds a session
    ///   with this id. A log whose session made it into the library — the
    ///   save landed and the delete did not, say — is finished business, not
    ///   an unfinished session, and is dropped rather than offered.
    public func checkForRecoverableSession(isAlreadySaved: (UUID) -> Bool = { _ in false }) async {
        guard state == .idle else { return }
        for url in TrackLog.unfinishedLogs() {
            // Read and rebuilt off the main actor: an interrupted three-hour
            // session is a multi-megabyte log, and this runs on the way
            // into the Record tab.
            let parsed: (header: TrackLog.Header, count: Int, duration: TimeInterval, distance: Double)?
            parsed = await Task.detached(priority: .userInitiated) {
                guard let (header, points) = try? TrackLog.read(url) else { return nil }
                let track = TrackBuilder(options: .forSport(header.sport)).build(from: points)
                return (header, points.count, track.duration, track.totalDistance)
            }.value
            // A recording may have started while the log was being read.
            guard state == .idle else { return }
            guard let parsed else {
                TrackLog.delete(url)
                continue
            }
            guard !isAlreadySaved(parsed.header.sessionID) else {
                TrackLog.delete(url)
                continue
            }
            // A log with almost nothing in it is not worth offering back.
            guard parsed.count >= 30 else {
                TrackLog.delete(url)
                continue
            }
            recoverable = RecoverableSession(
                url: url,
                sport: parsed.header.sport,
                startDate: parsed.header.startDate,
                pointCount: parsed.count,
                duration: parsed.duration,
                distance: parsed.distance
            )
            return
        }
        recoverable = nil
    }

    /// Rebuild a session from an interrupted log.
    ///
    /// Takes `save` for the same reason `finish` does, and with more at stake:
    /// this log is the *only* copy of the session, so releasing it before the
    /// shell has the session written down would lose outright the thing this
    /// whole path exists to rescue. A recovery that cannot be saved stays on
    /// offer rather than being spent.
    public func recover(_ candidate: RecoverableSession, save: (Session) -> Bool) async -> Session? {
        let url = candidate.url
        let built: Session? = await Task.detached(priority: .userInitiated) {
            guard let (header, points) = try? TrackLog.read(url), points.count >= 2 else { return nil }
            return Self.buildSession(
                id: header.sessionID,
                sport: header.sport,
                startDate: header.startDate,
                endDate: points.last?.timestamp ?? header.startDate,
                points: points,
                wind: nil,
                deviceModel: header.deviceModel,
                appVersion: header.appVersion
            )
        }.value
        guard let session = built else {
            TrackLog.delete(candidate.url)
            recoverable = nil
            return nil
        }
        guard save(session) else { return nil }

        TrackLog.delete(candidate.url)
        recoverable = nil
        await checkForRecoverableSession()
        return session
    }

    public func dismissRecovery() async {
        if let recoverable { TrackLog.delete(recoverable.url) }
        recoverable = nil
        await checkForRecoverableSession()
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
        endBattery: Double? = nil,
        title: String? = nil,
        spotName: String? = nil,
        swellHeight: Double? = nil,
        swellDirection: Double? = nil,
        timeZone: String? = TimeZone.current.identifier
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
            title: title,
            spotName: spotName,
            wind: summary.wind,
            deviceModel: deviceModel,
            appVersion: appVersion,
            endBattery: endBattery,
            swellHeight: swellHeight,
            swellDirection: swellDirection,
            timeZone: timeZone,
            summary: summary
        )
    }
}
