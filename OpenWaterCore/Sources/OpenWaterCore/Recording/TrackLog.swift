import Foundation
import os

/// A crash-safe, append-only log of fixes on disk.
///
/// The failure this exists to survive: the watch runs flat, or watchOS jetsams
/// the app, three hours into a downwinder. Holding the session only in memory
/// means losing all of it. So every fix is appended to a file as it arrives and
/// flushed on a short cadence, and an unfinished log left behind at launch is
/// offered back to the rider as a recoverable session.
///
/// The format is newline-delimited JSON rather than a packed binary: a partially
/// written final line is trivially detectable and discardable, whereas a
/// truncated binary record can be silently misread as valid. Recovering 99.9 %
/// of a session is the whole point, so the format has to fail cleanly.
public final class TrackLog {

    nonisolated private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "TrackLog")

    /// Metadata written as the first line, so a recovered log knows what it is.
    public struct Header: Codable, Sendable {
        public var sessionID: UUID
        public var sport: Sport
        public var startDate: Date
        public var deviceModel: String?
        public var appVersion: String?
        public var formatVersion: Int = 1
    }

    public let url: URL
    public let header: Header

    private var handle: FileHandle?
    private var buffer = Data()
    private var pendingCount = 0
    private let encoder = JSONEncoder()

    /// Fixes buffered before a write. At 1 Hz this flushes every few seconds,
    /// which bounds worst-case loss to a handful of samples without waking the
    /// flash controller on every single fix.
    private let flushEvery = 5

    // MARK: - Locations

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Logs that were never closed — i.e. sessions that were interrupted.
    public static func unfinishedLogs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.pathExtension == "owlog" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    // MARK: - Writing

    public init(sessionID: UUID, sport: Sport, startDate: Date, deviceModel: String?, appVersion: String?) throws {
        self.header = Header(
            sessionID: sessionID,
            sport: sport,
            startDate: startDate,
            deviceModel: deviceModel,
            appVersion: appVersion
        )
        self.url = Self.directory.appendingPathComponent("\(sessionID.uuidString).owlog")

        encoder.dateEncodingStrategy = .iso8601
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        var line = try encoder.encode(header)
        line.append(0x0A)
        try handle?.write(contentsOf: line)
    }

    public func append(_ point: TrackPoint) {
        do {
            var line = try encoder.encode(point)
            line.append(0x0A)
            buffer.append(line)
            pendingCount += 1
            if pendingCount >= flushEvery { try flush() }
        } catch {
            Self.logger.error("failed to encode fix: \(error.localizedDescription)")
        }
    }

    /// Force everything to disk. Called when the app is about to be suspended,
    /// on low battery, and when the session ends.
    public func flush() throws {
        guard !buffer.isEmpty, let handle else { return }
        try handle.write(contentsOf: buffer)
        try handle.synchronize()
        buffer.removeAll(keepingCapacity: true)
        pendingCount = 0
    }

    /// Close the log cleanly and hand back its URL.
    @discardableResult
    public func finish() -> URL {
        try? flush()
        try? handle?.close()
        handle = nil
        return url
    }

    public func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Reading

    /// Parse a log back into a header and its fixes.
    ///
    /// A trailing partial line — the signature of a crash mid-write — is dropped
    /// rather than failing the whole recovery.
    public static func read(_ url: URL) throws -> (header: Header, points: [TrackPoint]) {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw RecoveryError.empty }

        let header = try decoder.decode(Header.self, from: Data(lines.removeFirst()))

        var points: [TrackPoint] = []
        points.reserveCapacity(lines.count)
        for line in lines {
            // A malformed line is almost always the last one, torn by a crash.
            // Skipping rather than throwing is what makes recovery useful.
            guard let point = try? decoder.decode(TrackPoint.self, from: Data(line)) else { continue }
            points.append(point)
        }
        return (header, points)
    }

    public static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public enum RecoveryError: Error, LocalizedError {
        case empty

        public var errorDescription: String? {
            switch self {
            case .empty: "The session log was empty."
            }
        }
    }
}
