import Foundation
import OpenWaterCore
import SwiftData

/// A session as it lives in the database.
///
/// The design is deliberately hybrid. The full session — every sample, every
/// channel — is stored once as an encoded `SessionArchive` blob, and the handful
/// of fields the list and the charts need to *query* are denormalised alongside
/// it as real columns.
///
/// Storing the whole object graph as SwiftData relations instead would mean a
/// row per GPS sample: a three-hour session is ten thousand rows, and the
/// session list would have to fault them all in to draw a card. The blob keeps
/// a session to one row, and the denormalised columns keep sorting, filtering
/// and trend charts fast without ever decoding it.
///
/// It also means the on-disk representation *is* the export format, so export
/// can never silently drift from what was stored.
@Model
final class StoredSession {

    #Index<StoredSession>([\.startDate], [\.sportRaw], [\.maxSpeed])

    @Attribute(.unique) var id: UUID

    // MARK: Denormalised — queried, sorted and charted without decoding

    var startDate: Date
    var endDate: Date
    var sportRaw: String
    var distance: Double
    var duration: TimeInterval
    var movingTime: TimeInterval
    var maxSpeed: Double
    var averageMovingSpeed: Double

    var best2s: Double
    var best10s: Double
    var best5x10s: Double
    var best500m: Double
    var bestAlpha: Double
    var bestNauticalMile: Double

    var runCount: Int
    var gybeCount: Int
    var dryGybeRate: Double
    var flightCount: Int
    var timeOnFoil: TimeInterval
    var foilingFraction: Double
    var fallCount: Int
    var longestCleanStreak: TimeInterval
    var glideFraction: Double

    var windDirection: Double?
    var windConfidence: Double
    var qualityScore: Double

    var title: String?
    var spotName: String?
    var notes: String
    var gearIDs: [UUID]
    var photoNames: [String]

    /// The code of the web share, if this session has ever been shared.
    ///
    /// Kept so a rider can get the same link back rather than scattering copies
    /// of one session across the internet every time they tap Share. It is
    /// deliberately *not* cleared by `update(with:)`: a link that has been sent
    /// to someone keeps working, and pretending otherwise would be worse than
    /// admitting the shared copy is a snapshot from when it was made.
    var shareCode: String?
    var sharedAt: Date?

    /// A heavily reduced copy of the track — latitude, longitude, speed,
    /// latitude … — kept as a column so the session list can draw a map
    /// preview.
    ///
    /// The alternative is decoding the archive per row, and a screen of ten
    /// three-hour sessions is a hundred thousand fixes to decode while the
    /// rider is scrolling. A couple of hundred points is more than a
    /// thumbnail-sized map can resolve anyway.
    var previewTrack: [Double] = []

    /// Bumped when the analysis engine changes, so stale rows can be found and
    /// recomputed rather than quietly showing numbers from an older algorithm.
    var analysisVersion: Int

    // MARK: The whole thing

    /// The encoded `SessionArchive`. External storage keeps multi-megabyte
    /// tracks out of the main store file, so opening the app does not page in
    /// every session ever recorded.
    @Attribute(.externalStorage) var archiveData: Data

    // MARK: Init

    init(session: Session) {
        self.id = session.id
        self.startDate = session.startDate
        self.endDate = session.endDate
        self.sportRaw = session.sport.rawValue
        self.title = session.title
        self.spotName = session.spotName
        self.notes = session.notes
        self.gearIDs = session.gearIDs
        self.photoNames = session.photoNames
        self.windDirection = session.wind?.directionFrom
        self.windConfidence = session.wind?.confidence ?? 0

        let summary = session.summary
        self.distance = summary?.distance ?? session.track.totalDistance
        self.duration = summary?.duration ?? session.duration
        self.movingTime = summary?.movingTime ?? 0
        self.maxSpeed = summary?.maxSpeed ?? 0
        self.averageMovingSpeed = summary?.averageMovingSpeed ?? 0
        self.analysisVersion = summary?.analysisVersion ?? 0
        self.qualityScore = summary?.quality.score ?? 0

        self.best2s = summary?.result(for: .time(seconds: 2))?.validSpeed ?? 0
        self.best10s = summary?.result(for: .time(seconds: 10))?.validSpeed ?? 0
        self.best5x10s = summary?.result(for: .multiTime(count: 5, seconds: 10))?.validSpeed ?? 0
        self.best500m = summary?.result(for: .distance(metres: 500))?.validSpeed ?? 0
        self.bestAlpha = summary?.result(for: .alpha(metres: 500, proximity: 50))?.validSpeed ?? 0
        self.bestNauticalMile = summary?.result(for: .distance(metres: 1852))?.validSpeed ?? 0

        self.runCount = summary?.runs.count ?? 0
        self.gybeCount = summary?.maneuverSummary.gybes ?? 0
        self.dryGybeRate = summary?.maneuverSummary.dryGybeRate ?? 0
        self.flightCount = summary?.foil.flightCount ?? 0
        self.timeOnFoil = summary?.foil.timeOnFoil ?? 0
        self.foilingFraction = summary?.foil.foilingFraction ?? 0
        self.fallCount = summary?.fallSummary.count ?? 0
        self.longestCleanStreak = summary?.fallSummary.longestCleanStreak ?? 0
        self.glideFraction = summary?.downwind.glideFraction ?? 0

        self.shareCode = nil
        self.sharedAt = nil
        self.previewTrack = StoredSession.previewTrack(for: session.track)

        self.archiveData = (try? SessionArchive(session: session).encoded()) ?? Data()
    }

    // MARK: Access

    var sport: Sport {
        get { Sport(rawValue: sportRaw) ?? .other }
        set { sportRaw = newValue.rawValue }
    }

    /// Mirrors `Session.displayTitle` so the list and the detail screen agree
    /// without the list having to decode a multi-megabyte archive.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        if let spotName, !spotName.trimmingCharacters(in: .whitespaces).isEmpty { return spotName }
        return sport.displayName
    }

    var displaySubtitle: String? {
        let name = displayTitle
        if let spotName, !spotName.isEmpty, spotName != name { return spotName }
        if sport.displayName != name { return sport.displayName }
        return nil
    }

    /// Decode the full session. Costly for a big track — call it for a detail
    /// screen, never inside a list row.
    func fullSession() -> Session? {
        guard !archiveData.isEmpty else { return nil }
        return try? SessionArchive.decode(archiveData).session
    }

    /// The full session, re-analysed if it was produced by an older engine.
    func currentSession() -> Session? {
        guard !archiveData.isEmpty else { return nil }
        return try? SessionArchive.decode(archiveData).upToDateSession()
    }

    /// Whether the cached numbers came from the engine that is running now.
    var isAnalysisCurrent: Bool { analysisVersion == SessionSummary.currentVersion }

    /// Replace the stored session, refreshing every denormalised field.
    func update(with session: Session) {
        let replacement = StoredSession(session: session)
        startDate = replacement.startDate
        endDate = replacement.endDate
        sportRaw = replacement.sportRaw
        distance = replacement.distance
        duration = replacement.duration
        movingTime = replacement.movingTime
        maxSpeed = replacement.maxSpeed
        averageMovingSpeed = replacement.averageMovingSpeed
        best2s = replacement.best2s
        best10s = replacement.best10s
        best5x10s = replacement.best5x10s
        best500m = replacement.best500m
        bestAlpha = replacement.bestAlpha
        bestNauticalMile = replacement.bestNauticalMile
        runCount = replacement.runCount
        gybeCount = replacement.gybeCount
        dryGybeRate = replacement.dryGybeRate
        flightCount = replacement.flightCount
        timeOnFoil = replacement.timeOnFoil
        foilingFraction = replacement.foilingFraction
        fallCount = replacement.fallCount
        longestCleanStreak = replacement.longestCleanStreak
        glideFraction = replacement.glideFraction
        windDirection = replacement.windDirection
        windConfidence = replacement.windConfidence
        qualityScore = replacement.qualityScore
        title = replacement.title
        spotName = replacement.spotName
        notes = replacement.notes
        gearIDs = replacement.gearIDs
        photoNames = replacement.photoNames
        analysisVersion = replacement.analysisVersion
        archiveData = replacement.archiveData
        previewTrack = replacement.previewTrack
    }

    // MARK: Map preview

    /// Reduce a track to a few hundred `latitude, longitude, speed` triples for
    /// the list thumbnail.
    ///
    /// Uniform sampling is right here, unlike the speed-aware reduction the web
    /// share uses: a thumbnail is about the *shape* of the session, and keeping
    /// only the fastest fix from each bucket would distort where the track
    /// goes. The speed of each kept sample rides along so the preview can be
    /// coloured the same way the full map is — the fast runs are what a rider
    /// is looking for when they scan the list.
    static func previewTrack(for track: Track, maximum: Int = 220) -> [Double] {
        guard track.count > 1 else { return [] }
        let step = max(1, Int(ceil(Double(track.count) / Double(maximum))))
        var result: [Double] = []
        result.reserveCapacity((track.count / step + 2) * 3)

        func append(_ index: Int) {
            let point = track.points[index]
            guard point.hasValidPosition else { return }
            result.append(point.latitude)
            result.append(point.longitude)
            result.append(track.speed[index])
        }

        var index = 0
        while index < track.count {
            append(index)
            index += step
        }
        // Always close on the real last fix, so a trimmed session's preview
        // ends where the session does.
        append(track.count - 1)
        return result
    }

    /// Fill in the preview for a session stored before previews existed.
    ///
    /// Decoding is the expensive part, so it happens once, off the main actor,
    /// and only for rows that actually appear on screen.
    func backfillPreviewTrack() async {
        guard previewTrack.isEmpty, !isDeleted, modelContext != nil else { return }
        let data = archiveData
        let points = await Task.detached {
            guard let session = try? SessionArchive.decode(data).session else { return [Double]() }
            return StoredSession.previewTrack(for: session.track)
        }.value
        guard !points.isEmpty, !isDeleted, modelContext != nil else { return }
        previewTrack = points
    }
}

private extension SpeedResult {
    /// The speed, or zero if the category was never satisfied — so an
    /// unachieved category sorts as "no result" rather than as a fast one.
    var validSpeed: Double { isValid ? speed : 0 }
}
