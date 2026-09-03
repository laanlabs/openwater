import CryptoKit
import Foundation

/// A track pulled out of a third-party file, before it becomes a `Session`.
///
/// Kept separate from `Session` because an imported file rarely knows what it
/// is: a Garmin FIT from a wing session and one from a bike ride look almost
/// identical, and guessing the sport wrong would silently apply the wrong
/// detection thresholds. So the importer reports only what the file actually
/// said, and the app asks the rider to confirm.
public struct ImportedTrack: Sendable, Identifiable {

    /// Assigned on parse, not derived from the contents — importing the same
    /// file twice should produce two distinct pending items rather than one that
    /// silently replaces the other.
    public let id = UUID()

    public let points: [TrackPoint]

    /// Track or activity name from the file, if any.
    public let name: String?

    /// Sport, only when the file stated something we could map confidently.
    public let sportHint: Sport?

    public let format: FileFormat

    /// Anything the reader wants the rider to know — missing channels,
    /// truncated data, unit assumptions.
    public let warnings: [String]

    public init(
        points: [TrackPoint],
        name: String? = nil,
        sportHint: Sport? = nil,
        format: FileFormat,
        warnings: [String] = []
    ) {
        self.points = points
        self.name = name
        self.sportHint = sportHint
        self.format = format
        self.warnings = warnings
    }

    public var startDate: Date? { points.first?.timestamp }
    public var endDate: Date? { points.last?.timestamp }

    /// Whether the file carried Doppler speed. Without it, peak figures are
    /// derived from positions and are meaningfully less reliable — the UI says
    /// so rather than presenting them as equivalent.
    public var hasSpeedChannel: Bool {
        points.contains { $0.speed != nil }
    }

    public var hasHeartRate: Bool {
        points.contains { $0.heartRate != nil }
    }

    /// Build a session, running the full analysis.
    ///
    /// The id is derived from the file's contents rather than minted, so the
    /// same GPX tapped twice in Messages — or a folder of exports imported
    /// again — lands on the session it already made instead of beside it.
    /// `SessionLibrary.save` is idempotent by id, which is all this needs.
    public func makeSession(sport: Sport, wind: Wind? = nil) -> Session {
        let track = TrackBuilder(options: .lenient).build(from: points)
        let summary = SessionAnalyzer(
            configuration: .init(sport: sport, categories: SpeedCategory.all, wind: wind)
        ).analyse(track)

        return Session(
            id: stableID,
            sport: sport,
            startDate: track.startDate ?? Date(),
            endDate: track.endDate ?? Date(),
            track: track,
            spotName: name,
            wind: summary.wind,
            trackFilter: .lenient,
            summary: summary
        )
    }

    /// One id per distinct recording: the first and last stamps, the count,
    /// and the format, digested. Two rides cannot share all four.
    public var stableID: UUID {
        var text = "\(format.rawValue)|\(points.count)"
        if let first = points.first?.timestamp { text += "|\(first.timeIntervalSince1970)" }
        if let last = points.last?.timestamp { text += "|\(last.timeIntervalSince1970)" }
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                           digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }
}

public enum FileFormat: String, Sendable, CaseIterable {
    case gpx, tcx, fit, csv, openwater

    public var displayName: String {
        switch self {
        case .gpx: "GPX"
        case .tcx: "TCX"
        case .fit: "FIT"
        case .csv: "CSV"
        case .openwater: "openWater archive"
        }
    }

    public var fileExtension: String { rawValue }

    /// Formats openWater can read.
    public static let readable: [FileFormat] = [.gpx, .tcx, .fit, .csv, .openwater]

    /// Formats openWater can write.
    ///
    /// FIT is deliberately absent. Reading a FIT file a rider already owns is
    /// straightforward — the container format is documented and this decoder is
    /// written from that description. *Writing* one means claiming conformance
    /// to a vendor profile, which is a licensing question rather than a
    /// technical one, so it stays out until that is settled properly.
    public static let writable: [FileFormat] = [.gpx, .tcx, .csv, .openwater]
}

public enum ImportError: Error, LocalizedError, Equatable {
    case unrecognisedFormat
    case malformed(String)
    case noTrackPoints
    case truncated
    case unsupportedFITVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unrecognisedFormat:
            "That file is not a GPX, TCX, FIT, CSV or openWater file."
        case .malformed(let detail):
            "The file could not be read: \(detail)"
        case .noTrackPoints:
            "That file has no GPS points in it."
        case .truncated:
            "The file ends unexpectedly — it may have been cut short during transfer."
        case .unsupportedFITVersion(let version):
            "This FIT file uses protocol version \(version), which openWater does not read yet."
        }
    }
}

/// Reads any supported file, working out which it is from its contents.
///
/// Sniffing content rather than trusting the extension: files arrive from
/// AirDrop, email attachments and cloud drives with names like `activity.dat`
/// or with the extension stripped entirely, and a rider should not have to
/// rename a file to get their session in.
public enum TrackImporter {

    public static func detectFormat(_ data: Data) -> FileFormat? {
        // FIT carries a literal ".FIT" signature at byte 8.
        if data.count > 12 {
            let signature = data[data.startIndex + 8 ..< data.startIndex + 12]
            if signature.elementsEqual([0x2E, 0x46, 0x49, 0x54]) { return .fit }
        }

        // The text formats are identified by their root element or header.
        // 2 KB is plenty — the XML declaration and root tag are always near the
        // front, and reading the whole file just to sniff it would be wasteful
        // on a large FIT.
        let prefixLength = min(data.count, 2048)
        guard let prefix = String(data: data.prefix(prefixLength), encoding: .utf8)?.lowercased() else {
            return nil
        }

        if prefix.contains("<gpx") { return .gpx }
        if prefix.contains("<trainingcenterdatabase") || prefix.contains("<tcx") { return .tcx }

        // JSON: our archives sort their keys so the metadata is near the front,
        // but a file written by an older build (or hand-edited) may not. So a
        // leading brace plus any of our markers is enough, and a leading brace
        // on its own is still worth trying as an archive — the decoder will
        // reject it cleanly if it is something else.
        let leading = prefix.drop { $0.isWhitespace }
        if leading.first == "{" {
            if prefix.contains("\"formatversion\"")
                || prefix.contains("\"sessions\"")
                || prefix.contains("\"session\"")
                || prefix.contains("\"generator\"") {
                return .openwater
            }
            return .openwater
        }

        if prefix.contains("timestamp") && prefix.contains(",") { return .csv }

        return nil
    }

    public static func read(_ data: Data) throws -> ImportedTrack {
        guard let format = detectFormat(data) else { throw ImportError.unrecognisedFormat }
        return try read(data, as: format)
    }

    public static func read(_ data: Data, as format: FileFormat) throws -> ImportedTrack {
        switch format {
        case .gpx: try GPX.read(data)
        case .tcx: try TCX.read(data)
        case .fit: try FIT.read(data)
        case .csv: try CSV.read(data)
        case .openwater:
            // An archive is already a session; expose its track so the same
            // import path handles every format.
            try {
                let archive = try SessionArchive.decode(data)
                return ImportedTrack(
                    points: archive.session.track.points,
                    name: archive.session.spotName,
                    sportHint: archive.session.sport,
                    format: .openwater
                )
            }()
        }
    }

    public static func read(contentsOf url: URL) throws -> ImportedTrack {
        try read(Data(contentsOf: url))
    }
}
