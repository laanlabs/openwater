import Foundation
import OpenWaterCore
import WatchConnectivity
import os

/// Receives sessions from the watch and serves it the record book.
///
/// The watch is the recorder and the phone is the library, so this side is
/// mostly a receiver. The one thing it pushes back is the all-time bests, sent
/// both on request and as application context — the latter survives the phone
/// being unreachable, so the watch still knows what a personal best is even if
/// it has not spoken to the phone since yesterday.
@MainActor
@Observable
final class PhoneSyncClient: NSObject {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "Sync")

    private let library: SessionLibrary

    private(set) var isReachable = false
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    private(set) var lastReceived: Date?
    private(set) var receivedCount = 0
    private(set) var lastError: String?

    init(library: SessionLibrary) {
        self.library = library
        super.init()
        // Any change to the record book is pushed straight to the watch, so a
        // PB set on the phone (via an import, say) is known on the wrist.
        library.onRecordsChanged = { [weak self] _ in
            self?.pushContext()
        }
    }

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Send the current bests as application context.
    ///
    /// Application context is the right channel here: it is a single
    /// latest-value slot the system delivers whenever it next can, which is
    /// exactly the semantics of "here is the current record book" — unlike a
    /// message, which needs both apps awake, or a file, which would queue up
    /// stale copies.
    /// True while a sync request is in flight, so the button can say so.
    var isSyncing = false

    /// Result of the last manual sync, for the panel to show.
    var lastSyncMessage: String?

    /// How many sessions the watch said it was holding, from its last answer,
    /// and nil while nobody has asked or the asking failed.
    ///
    /// Kept apart from the message because a count is something a progress
    /// row can count *against*: the watch answers immediately with a number,
    /// and the files themselves land one at a time over the following
    /// seconds. Without this, the rider gets "sending 3 sessions…" and then a
    /// still screen while all three are actually in flight.
    private(set) var queuedOnWatch: Int?

    /// Ask the watch to send anything it is still holding.
    ///
    /// Transfers queued out of range are retried by the system eventually, but
    /// eventually is not a time. This is the "eventually is now" button — it
    /// only works while the watch is reachable, and says so plainly when it is
    /// not rather than appearing to do something.
    /// The heart-rate check's own state, kept apart from the sync button's so
    /// one spinner cannot speak for the other.
    private(set) var isCheckingHeartRate = false
    var heartRateMessage: String?

    /// The same answer with its shape kept, so a screen can do more than
    /// print it — offer the walk-through for the one case that has steps,
    /// and a tick for the one that does not.
    private(set) var heartRate: HeartRateState?

    private(set) var isTakingReading = false
    private(set) var liveHeartRate: LiveHeartRate?

    func requestSync() {
        guard let session, session.activationState == .activated else {
            lastSyncMessage = "The watch is not connected."
            return
        }
        guard session.isReachable else {
            lastSyncMessage = "Your watch is out of range. Open openWater on it while it is near your phone."
            return
        }

        isSyncing = true
        lastSyncMessage = nil
        queuedOnWatch = nil
        session.sendMessage(["request": "sync"]) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isSyncing = false
                let queued = reply["queued"] as? Int ?? 0
                self.queuedOnWatch = queued
                self.lastSyncMessage = queued > 0
                    ? "Sending \(queued) session\(queued == 1 ? "" : "s") from your watch…"
                    : "Your watch has nothing waiting."
            }
        } errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.isSyncing = false
                self?.lastSyncMessage = error.localizedDescription
            }
        }
    }

    /// Ask the watch whether it can actually read a heartbeat.
    ///
    /// The phone cannot answer this itself — it has no HealthKit, by design,
    /// because the watch is the thing with the sensor — so the question goes
    /// over the wire and the watch probes its own store. Worth a button
    /// because the failure is invisible from here: a rider whose Health
    /// prompt was declined at their first session sees sessions arrive with
    /// no heart rate and nothing anywhere saying why.
    func checkHeartRate() {
        guard let session, session.activationState == .activated else {
            heartRateMessage = "The watch is not connected."
            return
        }
        guard session.isPaired else {
            heartRateMessage = "No Apple Watch is paired with this iPhone."
            return
        }
        guard session.isWatchAppInstalled else {
            heartRateMessage = "openWater is not on your watch yet. Install it from the Watch app on this iPhone."
            return
        }
        guard session.isReachable else {
            heartRateMessage = "Your watch is out of range. Open openWater on it while it is near your phone."
            return
        }

        isCheckingHeartRate = true
        heartRateMessage = nil
        heartRate = nil
        session.sendMessage(["request": "heartRate"]) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isCheckingHeartRate = false
                let state = Self.heartRateState(from: reply)
                self.heartRate = state
                self.heartRateMessage = state.message
            }
        } errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.isCheckingHeartRate = false
                self?.heartRate = nil
                self?.heartRateMessage = error.localizedDescription
            }
        }
    }

    /// The four things the watch's two booleans can mean.
    ///
    /// A shape rather than a sentence, because only one of the four has
    /// somewhere for the rider to go, and a screen that cannot tell which one
    /// it is holding has to print the route every time — including to the
    /// rider whose heart rate is already working.
    enum HeartRateState: Equatable, Sendable {
        /// No sensor, or no HealthKit on this watch.
        case unavailable
        /// Never prompted. The prompt only appears at the start of a session,
        /// so there is no switch to go and find yet.
        case notAsked
        case on
        /// Asked, and refused. The only case with steps.
        case off

        var message: String {
            switch self {
            case .unavailable:
                "This watch cannot record heart rate."
            case .notAsked:
                "openWater has not asked for heart rate yet. Start a session on the watch and tap Review when Health asks."
            case .on:
                "Heart rate is on — openWater is allowed to read it. Take a reading to confirm the watch will actually collect one."
            case .off:
                "Heart rate is off. On this iPhone: Health app ▸ your profile ▸ Privacy ▸ Apps ▸ openWater, and turn on Heart Rate. It applies to the next session."
            }
        }

        /// The diagnosis without the route to fix it.
        ///
        /// Two strings for one answer, deliberately. `message` is
        /// self-contained, for a screen that prints a line and offers nothing
        /// else — Settings. This one is the finding alone, for a screen that
        /// draws the three steps underneath it, where the full sentence would
        /// say "Health app ▸ your profile ▸ Privacy ▸ Apps" immediately above
        /// a numbered list saying the same thing again.
        var headline: String {
            switch self {
            case .unavailable: message
            case .notAsked: "openWater has not asked for heart rate yet."
            case .on: message
            case .off: "Heart rate is off. openWater asked and was refused, so sessions arrive with no beat in them."
            }
        }

        /// Whether this is the answer a rider wants and can stop reading at.
        var isGood: Bool { self == .on }

        /// Whether this answer comes with steps the screen should draw.
        var hasSteps: Bool { self == .off }
    }

    /// Ask the watch to actually collect a beat, rather than to check a
    /// permission.
    ///
    /// This is the question riders think they are asking when they check heart
    /// rate, and the one the permission probe cannot answer: a watch that is
    /// allowed to read heart rate still records nothing if the workout session
    /// will not start. It takes up to fifteen seconds, because a cold sensor
    /// takes a few seconds to produce its first beat.
    func takeHeartRateReading() {
        guard let session, session.activationState == .activated else {
            liveHeartRate = .unreachable("The watch is not connected.")
            return
        }
        guard session.isPaired, session.isWatchAppInstalled else {
            liveHeartRate = .unreachable("openWater is not on your watch yet.")
            return
        }
        guard session.isReachable else {
            liveHeartRate = .unreachable("Your watch is out of range. Open openWater on it, near this iPhone.")
            return
        }

        isTakingReading = true
        liveHeartRate = nil
        session.sendMessage(["request": "liveHeartRate"]) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isTakingReading = false
                self.liveHeartRate = Self.liveHeartRate(from: reply)
            }
        } errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.isTakingReading = false
                self?.liveHeartRate = .unreachable(error.localizedDescription)
            }
        }
    }

    static func liveHeartRate(from reply: [String: Any]) -> LiveHeartRate {
        if reply["started"] as? Bool != true {
            return .couldNotStart(reply["failure"] as? String
                ?? "The watch could not start a workout session.")
        }
        guard let beat = reply["beat"] as? Double else { return .noBeat }
        return .measured(beat, duringSession: reply["source"] as? String == "session")
    }

    /// What came back when the watch was asked to collect a beat.
    ///
    /// Deliberately separate from `HeartRateState`. That one is about
    /// permission and has a settings route to offer; this one is about the
    /// collection path and its bad cases have no switch to go and find — a
    /// workout session that refuses to start is a fault, not a preference.
    enum LiveHeartRate: Equatable, Sendable {
        /// A real beat, just now. `duringSession` when it came from a session
        /// already recording rather than from a check started for the purpose.
        case measured(Double, duringSession: Bool)
        /// Collection ran and nothing arrived. Usually the watch is off the
        /// wrist; sometimes it is a read the rider declined, which HealthKit
        /// will not admit to.
        case noBeat
        /// The workout session itself would not start — the failure that
        /// leaves a rider with no heartbeat *and* a session that dies when the
        /// wrist drops, since the same session is what keeps the sensors alive.
        case couldNotStart(String)
        /// Never got as far as asking.
        case unreachable(String)

        var message: String {
            switch self {
            case let .measured(beat, duringSession):
                let bpm = "\(Int(beat.rounded())) BPM"
                return duringSession
                    ? "Reading \(bpm) from the session running on your watch now. Heart rate is working."
                    : "Measured \(bpm) just now. The watch collected a real beat, so your sessions will carry one."
            case .noBeat:
                return "The watch started collecting but no beat arrived in fifteen seconds. Put the watch on, snug, above the wrist bone and try again — and if it still finds nothing, heart rate is being refused in Health."
            case let .couldNotStart(reason):
                return "The watch could not start a workout session, so a session recorded now would have no heart rate — and would stop recording when your wrist drops. \(reason)"
            case let .unreachable(reason):
                return reason
            }
        }

        var isGood: Bool { if case .measured = self { true } else { false } }

        var symbol: String {
            switch self {
            case .measured: "heart.fill"
            case .noBeat: "heart.slash"
            case .couldNotStart: "exclamationmark.triangle.fill"
            case .unreachable: "antenna.radiowaves.left.and.right.slash"
            }
        }
    }

    static func heartRateState(from reply: [String: Any]) -> HeartRateState {
        guard reply["available"] as? Bool == true else { return .unavailable }
        guard reply["asked"] as? Bool == true else { return .notAsked }
        return reply["canRead"] as? Bool == true ? .on : .off
    }

    /// What the watch's answer means, in a sentence a rider can act on.
    static func heartRateVerdict(from reply: [String: Any]) -> String {
        heartRateState(from: reply).message
    }

    /// Everything the watch is told about, sent as one payload.
    ///
    /// Application context is a single latest-value slot, so a push carrying
    /// only the bests would erase the display preference and vice versa. There
    /// is one writer for that slot, and it always sends the lot.
    ///
    /// `settings` is optional because the record book changes on its own —
    /// an import, a session arriving — with no settings object to hand. Those
    /// pushes carry the last preference the phone published rather than
    /// dropping the key and blanking it on the watch.
    func pushContext(settings: AppSettings? = nil) {
        guard let session, session.activationState == .activated else { return }

        if let settings {
            publishedExtendedDisplay = settings.watchExtendedDisplay
            publishedExtendedDisplayChangedAt = settings.watchExtendedDisplayChangedAt
            publishedStartWaterLocked = settings.watchStartWaterLocked
            publishedStartWaterLockedChangedAt = settings.watchStartWaterLockedChangedAt
        }

        var payload: [String: Any] = ["bests": library.recordsForWatch()]
        if let value = publishedExtendedDisplay, let stamp = publishedExtendedDisplayChangedAt {
            payload["extendedDisplay"] = value
            payload["extendedDisplayChangedAt"] = stamp
        }
        if let value = publishedStartWaterLocked, let stamp = publishedStartWaterLockedChangedAt {
            payload["startWaterLocked"] = value
            payload["startWaterLockedChangedAt"] = stamp
        }

        do {
            try session.updateApplicationContext(payload)
        } catch {
            Self.logger.notice("could not push context: \(error.localizedDescription)")
        }
    }

    /// The last display preference this phone published, so record-book pushes
    /// can carry it again rather than clearing it.
    private var publishedExtendedDisplay: Bool?
    private var publishedExtendedDisplayChangedAt: Date?
    private var publishedStartWaterLocked: Bool?
    private var publishedStartWaterLockedChangedAt: Date?
}

extension PhoneSyncClient: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let activated = activationState == .activated

        Task { @MainActor in
            self.isReachable = reachable
            self.isPaired = paired
            self.isWatchAppInstalled = installed
            if activated { self.pushContext() }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Required on iOS: the user can switch to a different watch, and the
    /// session has to be reactivated against the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    /// A session arriving from the watch.
    ///
    /// The file lands in a temporary location that is deleted the moment this
    /// returns, so it is decoded synchronously here rather than handed off.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let data = try? Data(contentsOf: file.fileURL)

        // Decoded and, if the watch ran an older engine, re-analysed off the
        // main actor: `upToDateSession` rebuilds the track, and a three-hour
        // session arriving while the rider is looking at the map used to
        // freeze it for the duration.
        Task.detached(priority: .userInitiated) {
            guard let data else {
                await MainActor.run {
                    self.lastError = "A session arrived from the watch but could not be read."
                }
                return
            }
            do {
                let session = try SessionArchive.decode(data).upToDateSession()
                await MainActor.run {
                    // The watch re-sends anything still in its outbox on
                    // every reconnect, so this can be a session the rider has
                    // already titled and written up here. Their words stay.
                    self.library.save(session, policy: .keepRiderEdits)
                    self.receivedCount += 1
                    self.lastReceived = Date()
                    self.lastError = nil
                    Self.logger.info("received session from watch")
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    Self.logger.error("could not decode session: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["request"] as? String == "bests" else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            replyHandler(["bests": self.library.recordsForWatch()])
        }
    }
}
