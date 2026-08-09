import Charts
import OpenWaterCore
import SwiftData
import SwiftUI

/// One session, in depth.
///
/// The map and the Ribbon are presented as peers rather than the Ribbon being
/// buried: for a session with forty overlapping runs the Ribbon is the more
/// useful of the two, and hiding it behind a menu would waste it.
struct SessionDetailView: View {

    let stored: StoredSession

    /// Captured at construction, while the model is definitely valid, so every
    /// later lookup can go through the store instead of through this reference.
    private let id: UUID

    init(stored: StoredSession) {
        self.stored = stored
        self.id = stored.id
    }

    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight
    @Environment(\.dismiss) private var dismiss
    @Environment(RouteNamer.self) private var routeNamer

    @State private var session: Session?
    @State private var view: Mode = .map
    @State private var selectedRun: Int?
    @State private var isExporting = false
    /// The archive written for an AirDrop, cleared when the sheet closes.
    @State private var archiveToSend: SharedFile?
    @State private var isSharingToWeb = false
    @State private var isSharingImage = false
    @State private var isMapFullScreen = false
    @State private var isPlayingBack = false
    @State private var isEditing = false
    @State private var isSettingWind = false
    @State private var isGivingFeedback = false
    @State private var isConfirmingDelete = false
    @State private var isConfirmingRemoveMax = false
    @State private var savedAsNewActivity = false
    /// One-line receipt after a repair — what changed, in the rider's units.
    @State private var repairMessage: String?

    /// Decode the stored archive into a usable session.
    ///
    /// Decoding a multi-megabyte track blocks, so it happens off the main actor
    /// — pushing this screen stays instant and the spinner covers the gap.
    @MainActor
    private func loadSession() async {
        // A SwiftData model can be deleted while a view still holds it — the
        // list deletes one on iPad while its detail is open, or the store is
        // reset underneath. Touching any property after that traps inside
        // SwiftData rather than returning nil, so the check has to come first.
        guard !stored.isDeleted, stored.modelContext != nil else {
            session = nil
            return
        }
        // Fetched rather than read straight off the model this view is holding:
        // the row can go while the screen is open, and an invalidated model
        // traps on property access instead of returning nil.
        guard let data = library.archiveData(id: id) else {
            session = nil
            return
        }
        session = await Task.detached {
            try? SessionArchive.decode(data).upToDateSession()
        }.value
        applyScreenshotRouteIfNeeded()
    }

    /// Re-read after editing. A sport or wind change rewrites the whole
    /// analysis, so the screen has to pick up the new numbers rather than keep
    /// showing the ones it decoded on the way in.
    private func reloadSession() {
        Task { await loadSession() }
    }

    /// Apply a screenshot route's segment and full-screen state. Inert unless
    /// the capture script passed `-openWaterScreen`.
    private func applyScreenshotRouteIfNeeded() {
        guard let route = ScreenshotRoute.requested else { return }
        if let mode = route.detailMode { view = mode }
        switch route {
        case .playback: isPlayingBack = true
        case .fullScreenMap: isMapFullScreen = true
        default: break
        }
    }

    /// Map first, because it is what a session is opened to look at and it is
    /// the tab this screen lands on.
    enum Mode: String, CaseIterable, Identifiable {
        case map = "Map"
        case summary = "Summary"
        case ribbon = "Runs"
        case analysis = "Analysis"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .map: "map"
            case .summary: "list.bullet.rectangle"
            case .ribbon: "chart.bar.doc.horizontal"
            case .analysis: "chart.xyaxis.line"
            }
        }
    }

    var body: some View {
        Group {
            if let session, let summary = session.summary {
                content(session: session, summary: summary)
            } else {
                ProgressView("Loading session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(stored.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSession() }
        // Re-read on every return to this screen: the Upwind page can change
        // the session's wind and save it, and stale angles here would
        // contradict the screen the rider just left.
        .onAppear { Task { await loadSession() } }
        .toolbar {
            // Beside the menu rather than inside it. "This says I did twelve
            // runs and I did six" is the most useful thing a rider can tell
            // us during tuning, and burying it two taps down in a menu that
            // opens with Edit and ends with Delete is a good way never to
            // hear it.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isGivingFeedback = true
                } label: {
                    Image(systemName: "ladybug")
                }
                .accessibilityLabel("Report a problem with this session")
                .disabled(session?.summary == nil)
            }

            // Every way out of the app, in the place a rider looks for it.
            // These were three items in the middle of a menu that opens with
            // Edit and ends with Delete, which is a strange place to keep the
            // thing people do most after a good session.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Share Image…", systemImage: "photo") { isSharingImage = true }
                    Button("Share a Link…", systemImage: "link") { isSharingToWeb = true }
                    Divider()
                    Button("Send to Another Device…", systemImage: "airplayaudio") {
                        sendArchive()
                    }
                    Button("Export…", systemImage: "square.and.arrow.up") { isExporting = true }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share this session")
                .disabled(session == nil)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit…", systemImage: "pencil") { isEditing = true }


                    // Offered wherever a rider might look for it, and only when
                    // there is something to put back. The full recording is
                    // always kept behind a trim, so this can never fail.
                    if let session, session.trim.isTrimmed {
                        Button("Restore Full Recording", systemImage: "arrow.uturn.backward") {
                            applyTrim(.none, to: session)
                        }
                    }
                    Divider()
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        duplicate(removingSpikes: false)
                    }
                    .disabled(session == nil)
                    // The scrub is a heuristic, so it only ever runs on a copy
                    // — the original recording is never the thing repaired.
                    Button("Duplicate & Remove Spikes", systemImage: "waveform.path.badge.minus") {
                        duplicate(removingSpikes: true)
                    }
                    .disabled(session == nil)
                    Button("Remove Max Speed…", systemImage: "gauge.with.needle") {
                        isConfirmingRemoveMax = true
                    }
                    .disabled(session == nil)
                    Divider()
                    // Sharing and exporting have their own button now. A
                    // "Flying only" toggle used to sit here too; it was bound
                    // to a variable nothing read, so it did nothing at all
                    // while the identically-labelled one in the full-screen
                    // map worked. The Map tab has its own foil filter.
                    Divider()
                    // Deleting was only possible from the list, which is not
                    // where anyone looks for it after opening a session and
                    // deciding it was a false start.
                    Button("Delete Session", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $archiveToSend) { file in
            ActivitySheet(items: [file.url])
        }
        .sheet(isPresented: $isExporting) {
            ExportView(stored: stored)
        }
        .alert("Saved as a new activity", isPresented: $savedAsNewActivity) {
            Button("OK") {}
        } message: {
            Text("\(newActivityTitle) is in your sessions. This one is unchanged.")
        }
        .confirmationDialog(
            "Remove the current max speed?",
            isPresented: $isConfirmingRemoveMax,
            titleVisibility: .visible
        ) {
            Button("Remove Max", role: .destructive) { removeMaxSpeed() }
        } message: {
            Text("Cuts the few seconds around the highest reading, and everything is recalculated without them. Nothing is deleted — Restore Full Recording brings it back.")
        }
        .alert("Done", isPresented: .constant(repairMessage != nil)) {
            Button("OK") { repairMessage = nil }
        } message: {
            Text(repairMessage ?? "")
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                library.delete(stored)
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("It moves to Recently Deleted, where you can get it back for 30 days.")
        }
        .sheet(isPresented: $isSharingImage) {
            if let session, let summary = session.summary {
                ShareImageView(session: session, summary: summary, title: stored.displayTitle)
            }
        }
        .sheet(isPresented: $isSharingToWeb) {
            if let session {
                WebShareView(stored: stored, session: session)
            }
        }
        .sheet(isPresented: $isGivingFeedback) {
            if let session, let summary = session.summary {
                FeedbackSheet(session: session, summary: summary)
            }
        }
        .sheet(isPresented: $isSettingWind) {
            if let session {
                WindSetterView(session: session) { direction, speed, swell, swellFrom in
                    applyWind(direction: direction, speed: speed, swell: swell,
                              swellFrom: swellFrom, to: session)
                }
            }
        }
        .sheet(isPresented: $isEditing, onDismiss: reloadSession) {
            SessionEditView(stored: stored)
        }
        .fullScreenCover(isPresented: $isMapFullScreen) {
            if let session, let summary = session.summary {
                FullScreenMapView(
                    session: session,
                    summary: summary,
                    selectedRun: $selectedRun
                )
            }
        }
        .fullScreenCover(isPresented: $isPlayingBack) {
            if let session, let summary = session.summary {
                SessionPlaybackView(session: session, summary: summary)
            }
        }
    }

    /// Apply a trim and re-analyse.
    ///
    /// Off the main actor because a trim re-runs the whole analysis on the
    /// surviving fixes, which on a three-hour track is real work. Nothing is
    /// destroyed — `trimmed(to:)` keeps the full recording alongside, so this
    /// is reversible and can be widened again later.
    @MainActor
    private func applyTrim(
        _ trim: SessionTrim,
        to session: Session,
        asNewActivity: Bool = false
    ) {
        let categories = settings.categories
        let overrides = settings.overrides(for: session.sport)
        Task {
            let edited = await Task.detached {
                session.trimmed(to: trim, categories: categories, overrides: overrides)
            }.value

            if asNewActivity {
                // The session on screen is left exactly as it was; the edit
                // lands in the library as its own activity, and the list is
                // where the rider will find it.
                library.save(edited.savedAsNewActivity(titled: newActivityTitle))
                savedAsNewActivity = true
            } else {
                library.save(edited)
                await loadSession()
            }
        }
    }

    /// A manual wind, straight from the dial. Goes through `Edits` so the
    /// reanalysis rule lives in exactly one place.
    @MainActor
    /// Write the session as an archive and offer it to AirDrop.
    ///
    /// The archive rather than a GPX: it carries the sport, the wind, the
    /// trim and the analysis, so the session lands on the other device as the
    /// same session rather than as a bare track to be re-guessed.
    private func sendArchive() {
        guard let session, let data = try? SessionArchive(session: session).encoded() else { return }
        let name = (session.title ?? session.displayTitle)
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).openwater")
        guard (try? data.write(to: url)) != nil else { return }
        archiveToSend = SharedFile(url: url)
    }

    private func applyWind(direction: Double, speed: Double?, swell: Double?,
                           swellFrom: Double?, to session: Session) {
        let categories = settings.categories
        let overrides = settings.overrides(for: session.sport)
        Task {
            let edited = await Task.detached {
                var edits = Session.Edits(session: session)
                edits.windDirection = direction
                edits.windSpeed = speed
                edits.swellHeight = swell
                edits.swellDirection = swellFrom
                return session.applying(edits, categories: categories, overrides: overrides)
            }.value
            library.save(edited)
            await loadSession()
        }
    }

    /// Names the copy after the session it came from, so two rows called
    /// "Wingfoil" do not appear with no way to tell them apart.
    private var newActivityTitle: String {
        "\(stored.displayTitle) (edited)"
    }

    /// Insert a copy into the library — exact, or with the spike scrub run
    /// over it. The session on screen is never the one changed.
    @MainActor
    private func duplicate(removingSpikes: Bool) {
        guard let session else { return }
        let categories = settings.categories
        let overrides = settings.overrides(for: session.sport)
        let baseTitle = stored.displayTitle
        Task {
            if removingSpikes {
                let (copy, removed) = await Task.detached {
                    session.duplicatedRemovingSpikes(
                        titled: "\(baseTitle) (de-spiked)",
                        categories: categories,
                        overrides: overrides
                    )
                }.value
                library.save(copy)
                repairMessage = removed == 0
                    ? "No spikes found — the copy is identical."
                    : "Removed \(removed) bad fix\(removed == 1 ? "" : "es"). The copy is in your sessions list."
            } else {
                library.save(session.duplicated(titled: "\(baseTitle) (copy)"))
                repairMessage = "The copy is in your sessions list."
            }
        }
    }

    /// Cut the stretch responsible for the current max, reversibly.
    @MainActor
    private func removeMaxSpeed() {
        guard let session else { return }
        let categories = settings.categories
        let overrides = settings.overrides(for: session.sport)
        let unit = settings.units.speed
        Task {
            let outcome = await Task.detached {
                session.removingMaxSpeed(categories: categories, overrides: overrides)
            }.value
            guard let outcome else {
                repairMessage = "Nothing to remove."
                return
            }
            library.save(outcome.session)
            await loadSession()
            repairMessage = "Max speed \(Format.speed(outcome.previousMax, unit: unit)) → \(Format.speed(outcome.newMax, unit: unit))."
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(session: Session, summary: SessionSummary) -> some View {
        VStack(spacing: 0) {
            Picker("View", selection: $view) {
                ForEach(Mode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)

            switch view {
            case .summary:
                SessionOverview(
                    stored: stored,
                    session: session,
                    summary: summary,
                    onSetWind: { isSettingWind = true }
                )
                .task { await routeNamer.resolve(for: stored, session: session) }
            case .map:
                mapView(session: session, summary: summary)
            case .ribbon:
                ribbonView(session: session, summary: summary)
            case .analysis:
                SessionAnalysisTab(
                    stored: stored,
                    session: session,
                    summary: summary,
                    onSetWind: { isSettingWind = true },
                    onEdit: { isEditing = true }
                )
            }
        }
    }

    private func mapView(session: Session, summary: SessionSummary) -> some View {
        SessionMapTab(
            session: session,
            summary: summary,
            selectedRun: $selectedRun,
            onFullScreen: { isMapFullScreen = true },
            onReplay: { isPlayingBack = true },
            onTrim: { trim, asNew in applyTrim(trim, to: session, asNewActivity: asNew) },
            onEditConditions: { isSettingWind = true }
        )
    }

    /// Upwind, Reaching and Downwind are a run's angle to the wind, so the
    /// filters are only as good as the direction they are measured from.
    private func runsWindWarning(_ session: Session) -> String? {
        guard session.sport.isWindPowered else { return nil }
        guard let wind = session.effectiveWind else {
            return "No wind direction, so runs cannot be sorted upwind from downwind. Set it."
        }
        guard wind.source.isEstimate else { return nil }
        return "Wind direction estimated from your track — the upwind and downwind filters follow it."
    }

    private func ribbonView(session: Session, summary: SessionSummary) -> some View {
        RibbonView(
            ribbon: summary.ribbon,
            maxSpeed: summary.maxSpeed,
            units: settings.units,
            bestRunIndex: summary.bestRun?.index,
            thresholds: settings.thresholds(for: session.sport),
            windWarning: runsWindWarning(session),
            onSetWind: { isSettingWind = true },
            legs: summary.shape.legs,
            isPointToPoint: summary.shape.isPointToPoint,
            track: session.track,
            mapStyle: settings.mapStyle,
            flights: summary.flights,
            selectedLane: $selectedRun
        )
    }


}
