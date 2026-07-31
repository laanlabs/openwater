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

    @State private var session: Session?
    @State private var view: Mode = .summary
    @State private var selectedRun: Int?
    @State private var highlight: ClosedRange<TimeInterval>?
    @State private var foilingOnly = false
    @State private var isExporting = false
    @State private var isSharingToWeb = false
    @State private var isSharingImage = false
    @State private var isMapFullScreen = false
    @State private var isPlayingBack = false
    @State private var isEditing = false

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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isExporting) {
            ExportView(stored: stored)
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
        VStack(spacing: 0) {
            TrackMapView(
                session: session,
                summary: summary,
                selectedRun: selectedRun,
                highlight: highlight,
                showFalls: true,
                showManeuvers: selectedRun != nil,
                foilingOnly: foilingOnly,
                style: settings.mapStyle
            )
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                SpeedLegend(
                    maxSpeed: summary.maxSpeed,
                    units: settings.units,
                    onDark: settings.mapStyle.isDark
                )
                .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                // Sharing the screen with the scrubber and the metric grid
                // leaves the map about a third of the display, which is enough
                // to orient by and not enough to read a track in.
                VStack(spacing: 8) {
                    MapStyleButton(selection: Bindable(settings).mapStyle)

                    Button {
                        isMapFullScreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline)
                            .padding(9)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("Full screen map")

                    Button {
                        isPlayingBack = true
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.subheadline)
                            .padding(9)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("Replay session")
                }
                .padding(10)
            }

            if !summary.runs.isEmpty {
                runScrubber(summary: summary)
            }

            ScrollView {
                MetricGrid(summary: summary, units: settings.units) { range in
                    // Tapping a metric shows exactly where on the water it
                    // happened — a number you cannot locate is hard to trust.
                    withAnimation { highlight = range; selectedRun = nil }
                }
                .padding()
            }
            .frame(maxHeight: 320)
        }
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
                if summary.foil.flightCount > 0 {
                    FoilSummaryCard(
                        foil: summary.foil,
                        falls: summary.fallSummary,
                        units: settings.units,
                        totalDistance: summary.distance,
                        takeoffThreshold: session.effectiveFoilTakeoffSpeed,
                        onChangeThreshold: { isEditing = true }
                    )
                }
                if summary.downwind.glideCount > 0 {
                    DownwindCard(downwind: summary.downwind, units: settings.units)
                }
                if summary.maneuverSummary.total > 0 {
                    ManeuverCard(summary: summary.maneuverSummary)
                }
                QualityCard(quality: summary.quality, source: summary.speedSource)
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
