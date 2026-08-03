import Foundation

/// The `.openwater` archive: a complete, lossless session.
///
/// This is the app's own format and its portability guarantee. Two properties
/// matter and are worth protecting:
///
/// 1. **It is complete.** It carries every recorded sample with every channel,
///    not a summary. A rider who exports their history has genuinely taken their
///    data with them, and can recompute everything the app computes.
/// 2. **It is versioned.** `formatVersion` and the embedded `analysisVersion`
///    mean a file written today is still readable and still interpretable after
///    the analyzers change, because the reader knows which engine produced the
///    cached numbers and can recompute if it disagrees.
///
/// It is also the transport between the watch and the phone, so the same encoder
/// is exercised on every session rather than only when somebody exports — a
/// format that is only used on the way out is a format that quietly rots.
public struct SessionArchive: Sendable, Codable {

    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var generator: String

    public var session: Session

    public init(
        session: Session,
        formatVersion: Int = SessionArchive.currentFormatVersion,
        exportedAt: Date = Date(),
        generator: String = "openWater"
    ) {
        self.session = session
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.generator = generator
    }

    // MARK: - Coding

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys always, not just when pretty-printing. Without it the
        // encoder emits keys in an arbitrary order, and on a long session the
        // multi-megabyte `session` value can land first — pushing
        // `formatVersion` past the window a format sniffer reads, so the app
        // fails to recognise its own export. Sorting puts the small metadata
        // keys ahead of `session` alphabetically, which also makes diffs stable.
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded(pretty: Bool = false) throws -> Data {
        try Self.encoder(pretty: pretty).encode(self)
    }

    public static func decode(_ data: Data) throws -> SessionArchive {
        let archive = try decoder().decode(SessionArchive.self, from: data)
        guard archive.formatVersion <= currentFormatVersion else {
            throw ArchiveError.unsupportedVersion(archive.formatVersion)
        }
        return archive
    }

    /// The session, with its cached analysis recomputed if it came from an older
    /// engine. Reading a file should never surface numbers whose provenance the
    /// running code cannot vouch for.
    ///
    /// The track is *rebuilt*, not just re-analysed. Half of what an engine
    /// bump can change lives in `TrackBuilder` — which fixes are accepted, how
    /// speed is resolved, how course is resolved — and all of it is baked into
    /// the stored track at build time. Re-running the analyzers over the old
    /// build would stamp the new version number on the old behaviour: version
    /// 2 exists to ignore placeholder course channels, and without the rebuild
    /// every affected session would recompute to exactly the same wrong polar
    /// and then declare itself current.
    public func upToDateSession(overrides: SportThresholds.Overrides? = nil) -> Session {
        var session = self.session
        if session.summary?.isCurrent != true {
            let track = TrackBuilder(options: .forSport(session.sport))
                .build(from: session.track.points)
            session.track = track
            session.summary = SessionAnalyzer(
                configuration: .init(
                    sport: session.sport,
                    categories: SpeedCategory.all,
                    wind: session.wind,
                    foilTakeoffSpeed: session.foilTakeoffSpeed,
                    overrides: overrides
                )
            ).analyse(track)
        }
        return session
    }

    public enum ArchiveError: Error, LocalizedError {
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                "This file was written by a newer version of openWater (format \(v))."
            }
        }
    }
}

/// A bundle of sessions, for a full backup or a bulk share.
public struct SessionArchiveBundle: Sendable, Codable {

    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var generator: String
    public var sessions: [Session]

    public init(
        sessions: [Session],
        formatVersion: Int = SessionArchiveBundle.currentFormatVersion,
        exportedAt: Date = Date(),
        generator: String = "openWater"
    ) {
        self.sessions = sessions
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.generator = generator
    }

    public func encoded(pretty: Bool = false) throws -> Data {
        try SessionArchive.encoder(pretty: pretty).encode(self)
    }

    public static func decode(_ data: Data) throws -> SessionArchiveBundle {
        try SessionArchive.decoder().decode(SessionArchiveBundle.self, from: data)
    }
}
