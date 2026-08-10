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
                onSeek: { time in
                    // Full screen has no scrubber of its own — the useful
                    // answer to "what happened here" is the run it belongs to,
                    // which isolates it and dims everything else.
                    withAnimation(.snappy) {
                        selectedRun = runs.first {
                            time >= $0.startElapsed && time <= $0.endElapsed
                        }?.lanes.first?.runIndex
                    }
                }
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

    private var controls: some View {
        VStack(spacing: 8) {
            if !runs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        FilterChip(title: "All", isOn: selectedRun == nil) {
                            withAnimation { selectedRun = nil }
                        }
                        ForEach(runs) { run in
                            let isOn = selectedGroup?.id == run.id
                            Button {
                                withAnimation {
                                    selectedRun = isOn ? nil : run.lanes.first?.runIndex
                                }
                            } label: {
                                VStack(spacing: 0) {
                                    Text("\(run.number)")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(Format.speed(run.averageSpeed, unit: settings.units.speed,
                                                      decimals: 1, includeSymbol: false))
                                        .font(.system(size: 9, design: .rounded))
                                        .monospacedDigit()
                                }
                                .frame(minWidth: 36)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                                .background(
                                    isOn ? AnyShapeStyle(run.kind.colour)
                                         : AnyShapeStyle(.regularMaterial),
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .foregroundStyle(isOn ? .white : run.kind.colour)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            // Step through runs one at a time — the most effective way to read
            // an overlapping track, and worth a dedicated control rather than
            // making people hunt for the right chip.
            HStack(spacing: 10) {
                Button {
                    step(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
                .disabled(runs.isEmpty)

                Text(selectedGroup.map { "\($0.kind.title) \($0.number) of \(runs.count)" }
                     ?? "Whole session")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())

                Button {
                    step(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
                .disabled(summary.runs.isEmpty)
            }
            .padding(.bottom, 6)
        }
    }

    /// Move to the next or previous run, entering run mode from "whole session"
    /// and wrapping at both ends.
    private func step(_ delta: Int) {
        let runs = runs
        guard !runs.isEmpty else { return }
        withAnimation(.snappy) {
            guard let current = selectedGroup,
                  let position = runs.firstIndex(where: { $0.id == current.id }) else {
                selectedRun = (delta > 0 ? runs.first : runs.last)?.lanes.first?.runIndex
                return
            }
            let next = (position + delta + runs.count) % runs.count
            selectedRun = runs[next].lanes.first?.runIndex
        }
    }
}
