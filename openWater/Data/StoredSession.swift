import Foundation
import OpenWaterCore
import SwiftData
import os

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

    private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "StoredSession")

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

    /// What recorded it — "Apple Watch", "iPhone", or nil for an imported file.
    ///
    /// Optional so old rows keep decoding: Swift's synthesized decoder does not
    /// fall back to a property default when a key is absent, and every session
    /// anybody currently has was written before this existed.
    var deviceModel: String?

    /// "Viento → Hatchery", once resolved.
    ///
    /// A column rather than part of the analysis, on purpose. Naming the ends
    /// of a run needs the spot guide and, failing that, Apple's geocoder — so
    /// it needs the network, and `SessionSummary` must stay a pure function of
    /// the track. Putting it there would also mean every rename bumped
    /// `analysisVersion` and re-ran the maths on every session in the library.
    ///
    /// `CLGeocoder` is rate-limited, so this is resolved once and kept.
    var routeName: String?

    /// Set when a route lookup has been attempted, whatever the outcome.
    ///
    /// Distinguishes "not looked up yet" from "looked up, and there is no
    /// route here" — a lap session has no A → B and never will, and without
    /// this it would be re-geocoded on every appearance forever.
    var routeResolvedAt: Date?

    /// Bumped when the analysis engine changes, so stale rows can be found and
    /// recomputed rather than quietly showing numbers from an older algorithm.
    var analysisVersion: Int

    /// When this session was moved to Recently Deleted, if it was.
    ///
    /// Nothing a rider records is ever destroyed by a single tap. A session is
    /// an hour on the water that cannot be recorded again, and the delete
    /// button is next to everything else — so it moves the row out of sight and
    /// leaves the archive on disk for thirty days. Optional, both because old
    /// rows predate it and because "nil" is the honest representation of a
    /// session that was never deleted.
    var deletedAt: Date?

    var isTrashed: Bool { deletedAt != nil }

    /// When the rider starred this session, if they did.
    ///
    /// A date rather than a flag so "favourites, most recently starred
    /// first" stays possible later. Optional so every existing row decodes
    /// as not-a-favourite, which is what it was.
    var favoritedAt: Date?

    var isFavorite: Bool { favoritedAt != nil }

    /// Days a trashed session survives before it is really gone.
    static let trashRetention: TimeInterval = 30 * 24 * 3600

    /// Days left before this one is purged, floored at zero.
    var daysLeftInTrash: Int {
        guard let deletedAt else { return 0 }
        let remaining = Self.trashRetention - Date.now.timeIntervalSince(deletedAt)
        return max(0, Int((remaining / 86_400).rounded(.up)))
    }

    // MARK: The whole thing

    /// The encoded `SessionArchive`. External storage keeps multi-megabyte
    /// tracks out of the main store file, so opening the app does not page in
    /// every session ever recorded.
    @Attribute(.externalStorage) var archiveData: Data

    // MARK: Init

    /// `nil` when the session cannot be encoded.
    ///
    /// Failable on purpose. This used to swallow the encoder's error and
    /// store an empty blob, and the library then reported the save as a
    /// success — so the recorder released its crash log, and the rider was
    /// left with a row that had every headline number and no track behind
    /// it: unopenable, unexportable, and the only other copy already gone.
    /// A NaN anywhere in the summary is enough to get there. Refusing to
    /// build the row is what lets `SessionLibrary.save` say "not persisted",
    /// which is what keeps the log on disk.
    init?(session: Session) {
        let archive: Data
        do {
            archive = try SessionArchive(session: session).encoded()
        } catch {
            Self.logger.error("session \(session.id) would not encode: \(error.localizedDescription)")
            return nil
        }

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
        self.deviceModel = session.deviceModel

        self.archiveData = archive
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
    ///
    /// - Parameter overrides: the rider's settings for this session's sport, so
    ///   a recompute picks up a threshold they changed rather than quietly
    ///   reproducing the numbers they were trying to correct.
    func currentSession(overrides: SportThresholds.Overrides? = nil) -> Session? {
        guard !archiveData.isEmpty else { return nil }
        return try? SessionArchive.decode(archiveData).upToDateSession(overrides: overrides)
    }

    /// Whether the cached numbers came from the engine that is running now.
    var isAnalysisCurrent: Bool { analysisVersion == SessionSummary.currentVersion }

    /// How an incoming copy of a session treats what the rider typed.
    enum MergePolicy {
        /// The incoming session is the truth, text and all. Right for an edit
        /// the rider just made here — including clearing a note.
        case replace
        /// Keep this row's title, notes, gear and photos wherever the incoming
        /// copy has none. Right for a session arriving from the watch: the
        /// wrist records no notes, and the outbox re-sends the same file on
        /// every reconnect, so the arrival must not blank a debrief written on
        /// the phone in the meantime.
        case keepRiderEdits
    }

    /// Replace the stored session, refreshing every denormalised field.
    ///
    /// Returns false — and changes nothing — when the session cannot be
    /// encoded, for the reason `init?(session:)` gives.
    @discardableResult
    func update(with session: Session, policy: MergePolicy = .replace) -> Bool {
        guard let replacement = StoredSession(session: session) else { return false }
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
        switch policy {
        case .replace:
            title = replacement.title
            spotName = replacement.spotName
            notes = replacement.notes
            gearIDs = replacement.gearIDs
            photoNames = replacement.photoNames
        case .keepRiderEdits:
            if let incoming = replacement.title, !incoming.isEmpty { title = incoming }
            if let incoming = replacement.spotName, !incoming.isEmpty { spotName = incoming }
            if !replacement.notes.isEmpty { notes = replacement.notes }
            if !replacement.gearIDs.isEmpty { gearIDs = replacement.gearIDs }
            if !replacement.photoNames.isEmpty { photoNames = replacement.photoNames }
        }
        analysisVersion = replacement.analysisVersion
        archiveData = replacement.archiveData
        previewTrack = replacement.previewTrack
        deviceModel = replacement.deviceModel
        return true
    }

    /// Where the session came from, for the badge on its card.
    enum Origin {
        case watch, phone, imported

        var symbol: String {
            switch self {
            case .watch: "applewatch"
            case .phone: "iphone"
            case .imported: "square.and.arrow.down"
            }
        }

        var label: String {
            switch self {
            case .watch: "Recorded on Apple Watch"
            case .phone: "Recorded on iPhone"
            case .imported: "Imported"
            }
        }
    }

    /// `nil` means "not worked out yet" and shows no badge at all; an empty
    /// string means the archive genuinely had no device, which is what an
    /// imported file looks like. Guessing "imported" for a row that simply
    /// predates this column would put the wrong icon on every old session.
    var origin: Origin? {
        guard let deviceModel else { return nil }
        if deviceModel.isEmpty { return .imported }
        return deviceModel.localizedCaseInsensitiveContains("watch") ? .watch : .phone
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
    ///
    /// `@MainActor` is load-bearing, not decoration. Without it this method is
    /// nonisolated, so after the `await` it resumes on whatever thread the
    /// detached work finished on — and the line below writes to a SwiftData
    /// model bound to the main-actor context. SwiftData asserts its queue and
    /// the assert is a trap: `_dispatch_assert_queue_fail`, straight to a
    /// crash, on a background thread with none of this code in the visible
    /// frames.
    @MainActor
    func backfillPreviewTrack() async {
        // Runs for anything the row is missing. Decoding the archive is the
        // expensive part, so the two backfills share the one pass rather than
        // each paying for their own.
        let needsPreview = previewTrack.isEmpty
        let needsDevice = deviceModel == nil
        guard needsPreview || needsDevice, !isDeleted, modelContext != nil else { return }

        let data = archiveData
        let filled: (points: [Double], device: String) = await Task.detached {
            guard let session = try? SessionArchive.decode(data).session else { return ([], "") }
            return (StoredSession.previewTrack(for: session.track), session.deviceModel ?? "")
        }.value

        guard !isDeleted, modelContext != nil else { return }
        if needsPreview, !filled.points.isEmpty { previewTrack = filled.points }
        if needsDevice { deviceModel = filled.device }
    }
}

private extension SpeedResult {
    /// The speed, or zero if the category was never satisfied — so an
    /// unachieved category sorts as "no result" rather than as a fast one.
    var validSpeed: Double { isValid ? speed : 0 }
}
