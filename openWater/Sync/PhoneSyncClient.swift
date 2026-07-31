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
            self?.pushRecords()
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
    func pushRecords() {
        guard let session, session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext(["bests": library.recordsForWatch()])
        } catch {
            Self.logger.notice("could not push records: \(error.localizedDescription)")
        }
    }
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
            if activated { self.pushRecords() }
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
