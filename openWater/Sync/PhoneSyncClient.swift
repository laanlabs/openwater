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
        session.sendMessage(["request": "sync"]) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isSyncing = false
                let queued = reply["queued"] as? Int ?? 0
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
        session.sendMessage(["request": "heartRate"]) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isCheckingHeartRate = false
                self.heartRateMessage = Self.heartRateVerdict(from: reply)
            }
        } errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.isCheckingHeartRate = false
                self?.heartRateMessage = error.localizedDescription
            }
        }
    }

    /// What the watch's answer means, in a sentence a rider can act on.
    static func heartRateVerdict(from reply: [String: Any]) -> String {
        guard reply["available"] as? Bool == true else {
            return "This watch cannot record heart rate."
        }
        guard reply["asked"] as? Bool == true else {
            return "openWater has not asked for heart rate yet. Start a session on the watch and tap Review when Health asks."
        }
        if reply["canRead"] as? Bool == true {
            return "Heart rate is on — the watch can read it, and your sessions will carry it."
        }
        return "Heart rate is off. On this iPhone: Health app ▸ your profile ▸ Privacy ▸ Apps ▸ openWater, and turn on Heart Rate. It applies to the next session."
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
        }

        var payload: [String: Any] = ["bests": library.recordsForWatch()]
        if let value = publishedExtendedDisplay, let stamp = publishedExtendedDisplayChangedAt {
            payload["extendedDisplay"] = value
            payload["extendedDisplayChangedAt"] = stamp
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

        Task { @MainActor in
            guard let data else {
                self.lastError = "A session arrived from the watch but could not be read."
                return
            }
            do {
                let archive = try SessionArchive.decode(data)
                self.library.save(archive.upToDateSession())
                self.receivedCount += 1
                self.lastReceived = Date()
                self.lastError = nil
                Self.logger.info("received session from watch")
            } catch {
                self.lastError = error.localizedDescription
                Self.logger.error("could not decode session: \(error.localizedDescription)")
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
