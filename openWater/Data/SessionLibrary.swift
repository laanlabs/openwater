import Foundation
import OpenWaterCore
import SwiftData
import os

/// The app's session store. All writes go through here.
///
/// Centralising them means the record book, the watch's copy of it, and the
/// denormalised columns can never drift out of step with the sessions
/// themselves — which they would if views inserted models directly.
@MainActor
@Observable
final class SessionLibrary {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "Library")

    private let context: ModelContext

    /// All-time bests by category, recomputed on every change and pushed to the
    /// watch so a live personal-best alert means something real.
    private(set) var records: [SpeedCategory: RecordHolder] = [:]

    var onRecordsChanged: (([SpeedCategory: Double]) -> Void)?

    struct RecordHolder: Hashable, Sendable {
        let speed: Double
        let sessionID: UUID
        let date: Date
    }

    init(context: ModelContext) {
        self.context = context
        refreshRecords()
    }

    // MARK: - Writing

    /// Insert a session, or replace it if one with the same id already exists.
    ///
    /// Idempotent by design: the watch retries transfers when the phone comes
    /// back in range, so the same session can legitimately arrive twice and
    /// must not become two entries.
    @discardableResult
    func save(_ session: Session) -> StoredSession {
        let id = session.id
        let existing = try? context.fetch(
            FetchDescriptor<StoredSession>(predicate: #Predicate { $0.id == id })
        ).first

        if let existing {
            existing.update(with: session)
            persist()
            return existing
        }

        let stored = StoredSession(session: session)
        context.insert(stored)
        persist()
        return stored
    }

    /// The encoded archive for a session, fetched fresh from the store.
    ///
    /// Never read `archiveData` off a `StoredSession` a view has been holding.
    /// SwiftData invalidates a model when its row goes — deleted from another
    /// screen, or a store migration that could not carry it — and touching a
    /// property on an invalidated model is a trap, not an optional. It is not
    /// catchable and it takes the app with it; the only safe read is one that
    /// starts from a fetch.
    func archiveData(id: UUID) -> Data? {
        guard let stored = try? context.fetch(
            FetchDescriptor<StoredSession>(predicate: #Predicate { $0.id == id })
        ).first else { return nil }
        return stored.archiveData.isEmpty ? nil : stored.archiveData
    }

    // MARK: - Deleting

    /// Move a session to Recently Deleted.
    ///
    /// Deliberately not a real delete. Every destructive control in this app is
    /// one tap away from something a rider spent an afternoon producing and
    /// cannot produce again, and no amount of confirmation dialogue makes a
    /// mis-tap recoverable — only keeping the data does. Thirty days later
    /// `purgeExpiredTrash()` finishes the job.
    func delete(_ stored: StoredSession) {
        stored.deletedAt = .now
        persist()
    }

    func delete(ids: Set<UUID>) {
        for id in ids {
            session(id: id)?.deletedAt = .now
        }
        persist()
    }

    func restore(_ stored: StoredSession) {
        stored.deletedAt = nil
        persist()
    }

    /// Really delete, from the Recently Deleted screen where that is the
    /// explicit intent rather than a slip.
    func deletePermanently(_ stored: StoredSession) {
        context.delete(stored)
        persist()
    }

    func emptyTrash() {
        for stored in trashedSessions() { context.delete(stored) }
        persist()
    }

    func trashedSessions() -> [StoredSession] {
        allSessions().filter(\.isTrashed)
    }

    /// Drop anything that has served its thirty days. Called at launch.
    func purgeExpiredTrash() {
        let cutoff = Date.now.addingTimeInterval(-StoredSession.trashRetention)
        let expired = trashedSessions().filter { ($0.deletedAt ?? .now) < cutoff }
        guard !expired.isEmpty else { return }
        for stored in expired { context.delete(stored) }
        Self.logger.info("purged \(expired.count) session(s) from Recently Deleted")
        persist()
    }

    private func persist() {
        do {
            try context.save()
            refreshRecords()
        } catch {
            Self.logger.error("save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Reading

    func allSessions() -> [StoredSession] {
        let descriptor = FetchDescriptor<StoredSession>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func session(id: UUID) -> StoredSession? {
        try? context.fetch(
            FetchDescriptor<StoredSession>(predicate: #Predicate { $0.id == id })
        ).first
    }

    /// Sessions whose cached analysis predates the current engine.
    func staleSessions() -> [StoredSession] {
        let current = SessionSummary.currentVersion
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: #Predicate { $0.analysisVersion != current }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Re-run the analysis on every stale session.
    ///
    /// Explicit rather than automatic: a rider's numbers should not change under
    /// them without being told, so the app offers this and reports what moved.
    func recomputeStaleSessions(
        overrides: [Sport: SportThresholds.Overrides] = [:]
    ) async -> Int {
        let stale = staleSessions()
        var updated = 0
        for stored in stale {
            let sportOverrides = overrides[stored.sport].flatMap { $0.isEmpty ? nil : $0 }
            guard let session = stored.currentSession(overrides: sportOverrides) else { continue }
            stored.update(with: session)
            updated += 1
        }
        if updated > 0 { persist() }
        return updated
    }

    // MARK: - Records

    /// Recompute the all-time record book from the denormalised columns.
    ///
    /// Reads only the indexed fields — never decodes an archive — so this stays
    /// cheap enough to run after every single save.
    func refreshRecords() {
        // Trashed sessions do not hold records. A rider who deletes a session
        // recorded in a car expects the number to go with it, and a record
        // pointing at a row the list no longer shows is untappable.
        let sessions = allSessions().filter { !$0.isTrashed }
        var book: [SpeedCategory: RecordHolder] = [:]

        func consider(_ category: SpeedCategory, _ value: Double, _ session: StoredSession) {
            guard value > 0 else { return }
            if let current = book[category], current.speed >= value { return }
            book[category] = RecordHolder(
                speed: value, sessionID: session.id, date: session.startDate
            )
        }

        for session in sessions {
            consider(.time(seconds: 2), session.best2s, session)
            consider(.time(seconds: 10), session.best10s, session)
            consider(.multiTime(count: 5, seconds: 10), session.best5x10s, session)
            consider(.distance(metres: 500), session.best500m, session)
            consider(.distance(metres: 1852), session.bestNauticalMile, session)
            consider(.alpha(metres: 500, proximity: 50), session.bestAlpha, session)
        }

        records = book
        onRecordsChanged?(book.mapValues(\.speed))
    }

    /// Bests in the plain form WatchConnectivity can carry.
    func recordsForWatch() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.key.id, $0.value.speed) })
    }

    // MARK: - Import

    /// Read a file of any supported format without saving it yet.
    ///
    /// Import is deliberately two-step. A GPX or FIT file rarely says what sport
    /// it is, and the sport chooses the detection thresholds — import a wing
    /// session as a kayak and every flight, gybe and fall comes out wrong. So
    /// the file is parsed, the rider confirms the sport, and only then is a
    /// session built.
    func inspect(_ url: URL) throws -> ImportedTrack {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try TrackImporter.read(Data(contentsOf: url))
    }

    /// Import an openWater archive or bundle directly — these already know
    /// their sport, so they need no confirmation step.
    ///
    /// Returns `nil` when the file is not an archive, so the caller can fall
    /// back to the confirmation flow.
    @discardableResult
    func importArchive(at url: URL) throws -> Int? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard TrackImporter.detectFormat(data) == .openwater else { return nil }

        // A bundle and a single archive are both valid; try the bundle first
        // since a single-session bundle would otherwise decode as neither.
        if let bundle = try? SessionArchiveBundle.decode(data) {
            for session in bundle.sessions { save(session) }
            return bundle.sessions.count
        }
        let archive = try SessionArchive.decode(data)
        save(archive.upToDateSession())
        return 1
    }

    // MARK: - Export

    /// Every session as one bundle, for a complete backup.
    ///
    /// Complete by construction — it re-encodes the same archives that were
    /// stored, so an export can never quietly omit a channel.
    func exportAll(privacy: PrivacySettings = .init()) throws -> Data {
        // Deleted sessions stay out. They are still on disk for their thirty
        // days, but a backup is what the rider keeps, and they said they did
        // not want these — restoring one is a job for Recently Deleted, not for
        // a file that silently resurrects them somewhere else.
        let sessions = allSessions()
            .filter { !$0.isTrashed }
            .compactMap { $0.fullSession() }
        let prepared = sessions.map { privacy.apply(to: $0) }
        return try SessionArchiveBundle(sessions: prepared).encoded(pretty: false)
    }

    func export(_ stored: StoredSession, privacy: PrivacySettings = .init()) throws -> Data {
        try export(stored, as: .openwater, privacy: privacy)
    }

    /// Export one session in any writable format.
    ///
    /// Privacy trimming is applied *before* encoding in every case, so a GPX
    /// shared to a forum gets the same endpoint masking as an archive — the
    /// protection cannot be bypassed by picking a different format.
    func export(
        _ stored: StoredSession,
        as format: FileFormat,
        privacy: PrivacySettings = .init(),
        units: UnitPreferences = .default
    ) throws -> Data {
        guard let session = stored.fullSession() else {
            throw ExportError.sessionUnreadable
        }
        let prepared = privacy.apply(to: session)

        switch format {
        case .openwater:
            return try SessionArchive(session: prepared).encoded(pretty: true)
        case .gpx:
            return GPX.write(session: prepared)
        case .tcx:
            return TCX.write(session: prepared)
        case .csv:
            return CSV.write(session: prepared, units: units)
        case .fit:
            throw ExportError.formatNotWritable(format)
        }
    }

    /// GeoJSON sits outside `FileFormat` because it is export-only.
    func exportGeoJSON(_ stored: StoredSession, privacy: PrivacySettings = .init()) throws -> Data {
        guard let session = stored.fullSession() else {
            throw ExportError.sessionUnreadable
        }
        return try GeoJSON.write(session: privacy.apply(to: session))
    }

    enum ExportError: Error, LocalizedError {
        case sessionUnreadable
        case formatNotWritable(FileFormat)

        var errorDescription: String? {
            switch self {
            case .sessionUnreadable:
                "That session's data could not be read."
            case .formatNotWritable(let format):
                "openWater can read \(format.displayName) files but does not write them."
            }
        }
    }
}
