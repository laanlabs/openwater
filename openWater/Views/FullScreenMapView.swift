import OpenWaterCore
import SwiftUI

/// The map, given the whole screen.
///
/// The session detail view has to share space between the map, the run scrubber
/// and the metric grid, which leaves the map about a third of the screen. That
/// is fine for orientation and useless for actually reading a track — the thing
/// this app exists to make legible. So the map gets a full-screen mode with the
/// controls that matter available as overlays rather than competing for layout:
/// run isolation, the flying/falls filters, and map style.
struct FullScreenMapView: View {

    let session: Session
    let summary: SessionSummary

    /// Bound to the detail view so a run selected here stays selected there.
    @Binding var selectedRun: Int?

    @Environment(AppSettings.self) private var settings

    /// The ramp the track is drawn with, so the legend cannot claim a
    /// different range from the colours beside it.
    private var speedScale: SpeedScale { SpeedScale(speeds: session.track.speed) }
    @Environment(\.dismiss) private var dismiss

    @State private var foilingOnly = false
    @State private var showFalls = true
    @State private var showManeuvers = false
    @State private var showControls = true
    @State private var minimumSpeed: Double = 0
    @State private var isPlaying = false

    /// The same grouping every other screen uses. The full-screen map was
    /// offering `summary.runs` — sixty-seven stretches where the Runs tab
    /// showed thirty runs — so the two disagreed about what a run even was.
    private var runs: [GroupedRun] {
        GroupedRun.group(summary.ribbon.lanes, flights: summary.flights)
    }

    /// The run the selection falls inside.
    ///
    /// `selectedRun` stays a stretch index, because it is shared with the
    /// Map tab and the ribbon, which both speak in stretches. A stretch
    /// identifies the run containing it perfectly well.
    private var selectedGroup: GroupedRun? {
        guard let selectedRun else { return nil }
        return runs.first { $0.lanes.contains { $0.runIndex == selectedRun } }
    }

    /// The selected run as a stretch of track.
    ///
    /// From the run's own stretches rather than from its elapsed times, so it
    /// lines up exactly with the samples the map draws.
    private var isolatedRange: ClosedRange<Int>? {
        guard let group = selectedGroup else { return nil }
        let ids = Set(group.lanes.map(\.runIndex))
        let runs = summary.runs.filter { ids.contains($0.index) }
        guard let first = runs.map(\.startIndex).min(),
              let last = runs.map(\.endIndex).max(), first <= last
        else { return nil }
        return first...last
    }

    var body: some View {
        ZStack {
            TrackMapView(
                session: session,
                summary: summary,
                isolatedRange: isolatedRange,
                showFalls: showFalls,
                showManeuvers: showManeuvers,
                minimumSpeed: minimumSpeed,
                foilingOnly: foilingOnly,
                style: settings.mapStyle,
                units: settings.units,
                // Tapping the track used to isolate the run it belonged to.
                // With the run chips gone there is nothing to clear it with,
                // so a tap would strand somebody looking at one leg of their
                // session with no way back. Full screen honours a selection
                // made on the Runs tab and never makes one of its own.
                onSeek: nil
            )
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                if showControls {
                    SpeedLegend(
                        scale: speedScale,
                        units: settings.units,
                        onDark: settings.mapStyle.isDark
                    )
                    .padding(.leading, 16)
                    .padding(.bottom, 150)
                }
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if showControls {
                    controls
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        // Tapping the map itself hides the chrome, so the track can be looked at
        // with nothing on top of it.
        .onTapGesture {
            withAnimation(.snappy) { showControls.toggle() }
        }
        .statusBarHidden(!showControls)
        .fullScreenCover(isPresented: $isPlaying) {
            SessionPlaybackView(session: session, summary: summary)
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }

            Spacer()

            if let selected = selectedGroup {
                runBadge(selected)
            }

            Spacer()

            MapStyleButton(selection: Bindable(settings).mapStyle)

            Button {
                isPlaying = true
            } label: {
                Image(systemName: "play.fill")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Replay session")

            Menu {
                Toggle("Flying only", systemImage: "airplane", isOn: $foilingOnly)
                Toggle("Show falls", systemImage: "figure.fall", isOn: $showFalls)
                Toggle("Show turns", systemImage: "arrow.triangle.turn.up.right.diamond", isOn: $showManeuvers)
                Divider()
                Menu("Minimum speed") {
                    Button("Off") { minimumSpeed = 0 }
                    ForEach([5.0, 7.5, 10.0, 12.5], id: \.self) { speed in
                        Button(Format.speed(speed, unit: settings.units.speed, decimals: 0)) {
                            minimumSpeed = speed
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .mapChrome(onDark: settings.mapStyle.isDark)
        .opacity(showControls ? 1 : 0)
        .animation(.snappy, value: showControls)
    }

    private func runBadge(_ run: GroupedRun) -> some View {
        VStack(spacing: 1) {
            Text("\(run.kind.title) \(run.number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(run.kind.colour)
            Text("\(Format.speed(run.averageSpeed, unit: settings.units.speed, decimals: 1)) · \(Format.distance(run.distance, unit: settings.units.distance))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    /// What the session was, in three numbers.
    ///
    /// The run chips that used to live here were a second copy of the Runs
    /// tab, which does the job better — it has room for the list and the map
    /// together. Full screen is for looking at the track, so what belongs
    /// over it is the handful of facts that make the track legible: how much
    /// of it was flying, how much was not, and how many times it went wrong.
    private var controls: some View {
        HStack(spacing: 0) {
            stat("airplane", "On foil", Format.shortDuration(summary.foil.timeOnFoil),
                 tint: .green)
            divider
            stat("figure.pool.swim", "Off foil", Format.shortDuration(offFoil),
                 tint: .secondary)
            divider
            stat("exclamationmark.triangle", "Falls", "\(summary.fallSummary.count)",
                 tint: summary.fallSummary.count > 0 ? .orange : .secondary)
        }
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    /// Everything that was not flying — the swim, the walk, the waiting.
    /// Session length rather than moving time, because the minutes stood on
    /// the beach are exactly the ones a rider is asking about.
    private var offFoil: TimeInterval {
        max(0, summary.duration - summary.foil.timeOnFoil)
    }

    private func stat(_ symbol: String, _ title: String, _ value: String,
                      tint: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 30)
    }

}
