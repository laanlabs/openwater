import Foundation
import OpenWaterCore
import WatchConnectivity
import os

/// Sends finished sessions to the phone, and asks the phone for the record book.
///
/// Transfers use `transferFile` rather than `sendMessage` for a specific reason:
/// file transfers are queued by the system and survive the phone being out of
/// range, the app being killed, and the watch being taken off. A three-hour
/// downwinder is megabytes of track and the phone is usually locked in a car
/// park a kilometre away, so anything that requires both apps to be awake at the
/// same moment is the wrong tool.
///
/// The watch keeps its own copy until the phone acknowledges, so a failed
/// transfer never loses a session.
@MainActor
@Observable
final class WatchSyncClient: NSObject {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "Sync")

    private(set) var isReachable = false
    private(set) var isActivated = false
    private(set) var pendingTransfers = 0
    private(set) var lastError: String?

    /// Sessions written out and waiting for the phone to confirm receipt.
    private(set) var queuedSessions: [URL] = []

    private var bestsHandler: (([SpeedCategory: Double]) -> Void)?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    static var outboxDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
        refreshQueue()
    }

    // MARK: - Sending

    /// Write a session to the outbox and hand it to the transfer queue.
    func send(_ session: Session) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(SessionArchive(session: session))

            let url = Self.outboxDirectory
                .appendingPathComponent("\(session.id.uuidString).openwater")
            try data.write(to: url, options: .atomic)

            queuedSessions.append(url)
            transfer(url, sessionID: session.id)
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("failed to queue session: \(error.localizedDescription)")
        }
    }

    private func transfer(_ url: URL, sessionID: UUID) {
        guard let session, session.activationState == .activated else { return }
        session.transferFile(url, metadata: [
            "type": "session",
            "id": sessionID.uuidString,
        ])
        pendingTransfers = session.outstandingFileTransfers.count
    }

    /// Retry anything still sitting in the outbox — called at launch and
    /// whenever the phone becomes reachable again.
    func retryQueued() {
        refreshQueue()
        for url in queuedSessions {
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            transfer(url, sessionID: id)
        }
    }

    private func refreshQueue() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.outboxDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        queuedSessions = files.filter { $0.pathExtension == "openwater" }
    }

    // MARK: - Receiving

    /// Ask the phone for the all-time bests, so live PB alerts mean something.
    func requestBests(_ handler: @escaping ([SpeedCategory: Double]) -> Void) {
        bestsHandler = handler
        guard let session, session.activationState == .activated, session.isReachable else {
            // Fall back to the last set the phone pushed via application context,
            // which survives the phone being unreachable.
            if let cached = session?.receivedApplicationContext {
                handler(Self.decodeBests(from: cached))
            }
            return
        }
        session.sendMessage(["request": "bests"], replyHandler: { reply in
            let bests = Self.decodeBests(from: reply)
            Task { @MainActor in handler(bests) }
        }, errorHandler: { error in
            Self.logger.notice("bests request failed: \(error.localizedDescription)")
        })
    }

    /// Bests travel as `[categoryID: speed]`, since `SpeedCategory` is not a
    /// property-list type and WatchConnectivity only carries those.
    ///
    /// `nonisolated` because the `WCSessionDelegate` callbacks are delivered off
    /// the main actor and decode their payload before hopping back — the class
    /// is `@MainActor`, so without this the delegate cannot call it.
    private nonisolated static func decodeBests(from payload: [String: Any]) -> [SpeedCategory: Double] {
        guard let raw = payload["bests"] as? [String: Double] else { return [:] }
        var result: [SpeedCategory: Double] = [:]
        for category in SpeedCategory.all {
            if let value = raw[category.id] { result[category] = value }
        }
        return result
    }
}

extension WatchSyncClient: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        let activated = activationState == .activated
        Task { @MainActor in
            self.isActivated = activated
            self.isReachable = reachable
            if activated { self.retryQueued() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if reachable { self.retryQueued() }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let url = fileTransfer.file.fileURL
        let outstanding = session.outstandingFileTransfers.count
        Task { @MainActor in
            self.pendingTransfers = outstanding
            if let error {
                // Leave the file in the outbox; it will be retried.
                self.lastError = error.localizedDescription
                Self.logger.error("transfer failed: \(error.localizedDescription)")
            } else {
                // The system confirmed delivery, so the watch's copy can go.
                try? FileManager.default.removeItem(at: url)
                self.queuedSessions.removeAll { $0 == url }
            }
        }
    }

    /// The phone asking for anything still sitting on the wrist.
    ///
    /// A transfer queued while the watch was out of range is retried by the
    /// system on its own, but "on its own" can mean the next time the two
    /// devices happen to be awake together. A rider standing in the car park
    /// wondering where their session went should be able to ask.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["request"] as? String == "sync" else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            self.retryQueued()
            replyHandler([
                "queued": self.queuedSessions.count,
                "outstanding": self.pendingTransfers,
            ])
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let bests = Self.decodeBests(from: applicationContext)
        Task { @MainActor in
            guard !bests.isEmpty else { return }
            self.bestsHandler?(bests)
        }
    }
}
