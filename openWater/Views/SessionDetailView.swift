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

    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var session: Session?
    @State private var view: Mode = .map
    @State private var selectedRun: Int?
    @State private var highlight: ClosedRange<TimeInterval>?
    @State private var foilingOnly = false
    @State private var isExporting = false
    @State private var isSharingToWeb = false
    @State private var isSharingImage = false
    @State private var isMapFullScreen = false
    @State private var isPlayingBack = false
    @State private var isEditing = false
    @State private var isConfirmingDelete = false

    /// Decode the stored archive into a usable session.
    ///
    /// Decoding a multi-megabyte track blocks, so it happens off the main actor
    /// — pushing this screen stays instant and the spinner covers the gap.
    private func loadSession() async {
        // A SwiftData model can be deleted while a view still holds it — the
        // list deletes one on iPad while its detail is open, or the store is
        // reset underneath. Touching any property after that traps inside
        // SwiftData rather than returning nil, so the check has to come first.
        guard !stored.isDeleted, stored.modelContext != nil else {
            session = nil
            return
        }
        let data = stored.archiveData
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

    enum Mode: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case map = "Map"
        case ribbon = "Runs"
        case charts = "Charts"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .summary: "list.bullet.rectangle"
            case .map: "map"
            case .ribbon: "chart.bar.doc.horizontal"
            case .charts: "chart.xyaxis.line"
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit…", systemImage: "pencil") { isEditing = true }
                    Button("Share Image…", systemImage: "photo") { isSharingImage = true }
                        .disabled(session == nil)
                    Button("Share a Link…", systemImage: "link") { isSharingToWeb = true }
                        .disabled(session == nil)
                    Button("Export…", systemImage: "square.and.arrow.up") { isExporting = true }
                    Toggle("Flying only", systemImage: "airplane", isOn: $foilingOnly)
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
        .sheet(isPresented: $isExporting) {
            ExportView(stored: stored)
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
            Text("Its track and every metric go with it, and this cannot be undone.")
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
    private func applyTrim(_ trim: SessionTrim, to session: Session) {
        let categories = settings.categories
        Task {
            let trimmed = await Task.detached {
                session.trimmed(to: trim, categories: categories)
            }.value
            library.save(trimmed)
            await loadSession()
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
                    onEdit: { isEditing = true },
                    onOpenMap: { isMapFullScreen = true },
                    onReplay: { isPlayingBack = true }
                )
            case .map:
                mapView(session: session, summary: summary)
            case .ribbon:
                ribbonView(session: session, summary: summary)
            case .charts:
                chartsView(session: session, summary: summary)
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
            onTrim: { trim in applyTrim(trim, to: session) }
        )
    }

    private func ribbonView(session: Session, summary: SessionSummary) -> some View {
        RibbonView(
            ribbon: summary.ribbon,
            maxSpeed: summary.maxSpeed,
            units: settings.units,
            selectedLane: $selectedRun
        )
    }

    private func chartsView(session: Session, summary: SessionSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SpeedChart(session: session, summary: summary, units: settings.units)

                if let polar = summary.polar {
                    PolarChart(polar: polar, units: settings.units)
                    AngleSummary(polar: polar, units: settings.units)
                } else if session.sport.isWindPowered {
                    // Silently omitting the angles section leaves a rider
                    // wondering whether the app has them and they are lost, or
                    // whether it never had them. Say which, and offer the fix.
                    NoWindCard(session: session) { isEditing = true }
                }
                // The foiling, turns, glide and quality cards live on the
                // Summary tab. Repeating them here made Charts a second copy of
                // it with two graphs on top, and neither tab was then worth
                // scrolling to the bottom of.
            }
            .padding()
        }
    }

    /// A horizontal strip of runs, ordered by time and coloured by speed.
    /// Tapping one isolates it on the map.
    private func runScrubber(summary: SessionSummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                FilterChip(title: "All runs", isOn: selectedRun == nil) {
                    withAnimation { selectedRun = nil; highlight = nil }
                }
                ForEach(summary.runs) { run in
                    Button {
                        withAnimation {
                            selectedRun = selectedRun == run.index ? nil : run.index
                            highlight = nil
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Text("\(run.index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                            Text(Format.speed(run.averageSpeed, unit: settings.units.speed,
                                              decimals: 1, includeSymbol: false))
                                .font(.system(size: 9, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            selectedRun == run.index
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.quaternary),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(selectedRun == run.index ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

}
