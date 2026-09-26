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
///
/// Since format 2 the log also carries *events* — a pause, a resume — as lines
/// of their own between the fixes. A recovered session needs them for the same
/// reason a finished one does: the fixes from a pause are kept on disk, and
/// without the events nothing says which of them the rider had stopped the
/// clock for. A format-1 reader skips them as malformed lines, which is the
/// right thing for it to do.
public final class TrackLog {

    nonisolated private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "TrackLog")

    /// Metadata written as the first line, so a recovered log knows what it is.
    /// Fixes that could not be written. Counted rather than logged one by
    /// one, so the session can say "12 fixes were not protected" once.
    public private(set) var droppedFixes = 0

    public struct Header: Codable, Sendable {
        public var sessionID: UUID
        public var sport: Sport
        public var startDate: Date
        public var deviceModel: String?
        public var appVersion: String?
        public var formatVersion: Int = 2
    }

    /// Something that happened to the recording, as opposed to a fix.
    ///
    /// Written on its own line, keyed by `event` so it can never be mistaken
    /// for a `TrackPoint` — a fix has no such key, and an event has none of a
    /// fix's required ones.
    public struct Event: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case pause, resume
        }
        public var event: Kind
        public var at: Date
        /// Who did it, for a pause. Absent on a resume.
        public var cause: RecordedPause.Cause?

        public init(_ event: Kind, at: Date, cause: RecordedPause.Cause? = nil) {
            self.event = event
            self.at = at
            self.cause = cause
        }
    }

    /// What a log holds once read back.
    public struct Contents: Sendable {
        public var header: Header
        public var points: [TrackPoint]
        public var events: [Event]

        /// The events folded into pauses, in order. An unmatched pause — the
        /// app died while the clock was stopped — is closed just after the
        /// last fix, which is where the recording ended in every sense that
        /// matters.
        public var pauses: [RecordedPause] {
            var result: [RecordedPause] = []
            for event in events {
                switch event.event {
                case .pause:
                    guard result.last?.end != nil || result.isEmpty else { continue }
                    result.append(RecordedPause(start: event.at, cause: event.cause ?? .rider))
                case .resume:
                    guard let last = result.last, last.end == nil else { continue }
                    result[result.count - 1].end = event.at
                }
            }
            if let last = result.last, last.end == nil, let lastFix = points.last?.timestamp {
                result[result.count - 1].end = max(last.start, lastFix.addingTimeInterval(1))
            }
            return result
        }
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
            droppedFixes += 1
        }
    }

    /// Note an event, and put it on disk at once.
    ///
    /// Events are rare and each one matters — a pause that reached memory but
    /// not the file would leave a recovered session counting the paused
    /// stretch as riding — so unlike fixes they are not batched.
    public func append(_ event: Event) {
        do {
            var line = try encoder.encode(event)
            line.append(0x0A)
            buffer.append(line)
            try flush()
        } catch {
            Self.logger.error("failed to write \(event.event.rawValue) event: \(error.localizedDescription)")
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
    public static func read(_ url: URL) throws -> Contents {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw RecoveryError.empty }

        let header = try decoder.decode(Header.self, from: Data(lines.removeFirst()))

        var points: [TrackPoint] = []
        points.reserveCapacity(lines.count)
        var events: [Event] = []
        for line in lines {
            let data = Data(line)
            if let point = try? decoder.decode(TrackPoint.self, from: data) {
                points.append(point)
            } else if let event = try? decoder.decode(Event.self, from: data) {
                events.append(event)
            }
            // Anything else is a malformed line — almost always the last one,
            // torn by a crash. Skipping rather than throwing is what makes
            // recovery useful.
        }
        return Contents(header: header, points: points, events: events)
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
