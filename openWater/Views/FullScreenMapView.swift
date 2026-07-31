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
    @Environment(\.dismiss) private var dismiss

    @State private var foilingOnly = false
    @State private var showFalls = true
    @State private var showManeuvers = false
    @State private var showControls = true
    @State private var minimumSpeed: Double = 0
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            TrackMapView(
                session: session,
                summary: summary,
                selectedRun: selectedRun,
                showFalls: showFalls,
                showManeuvers: showManeuvers,
                minimumSpeed: minimumSpeed,
                foilingOnly: foilingOnly,
                style: settings.mapStyle
            )
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                if showControls {
                    SpeedLegend(
                        maxSpeed: summary.maxSpeed,
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
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }

            Spacer()

            if let run = selectedRun,
               let selected = summary.runs.first(where: { $0.index == run }) {
                runBadge(selected)
            }

            Spacer()

            MapStyleButton(selection: Bindable(settings).mapStyle)

            Button {
                isPlaying = true
            } label: {
                Image(systemName: "play.fill")
                    .font(.headline)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
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
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .opacity(showControls ? 1 : 0)
        .animation(.snappy, value: showControls)
    }

    private func runBadge(_ run: Run) -> some View {
        VStack(spacing: 1) {
            Text("Run \(run.index + 1)")
                .font(.caption.weight(.semibold))
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
            if !summary.runs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        FilterChip(title: "All", isOn: selectedRun == nil) {
                            withAnimation { selectedRun = nil }
                        }
                        ForEach(summary.runs) { run in
                            Button {
                                withAnimation {
                                    selectedRun = selectedRun == run.index ? nil : run.index
                                }
                            } label: {
                                VStack(spacing: 0) {
                                    Text("\(run.index + 1)")
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
                                    selectedRun == run.index
                                        ? AnyShapeStyle(.tint)
                                        : AnyShapeStyle(.regularMaterial),
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .foregroundStyle(selectedRun == run.index ? .white : .primary)
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
                .disabled(summary.runs.isEmpty)

                Text(selectedRun.map { "Run \($0 + 1) of \(summary.runs.count)" } ?? "Whole session")
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
        guard !summary.runs.isEmpty else { return }
        let indices = summary.runs.map(\.index)
        withAnimation(.snappy) {
            guard let current = selectedRun,
                  let position = indices.firstIndex(of: current) else {
                selectedRun = delta > 0 ? indices.first : indices.last
                return
            }
            let next = (position + delta + indices.count) % indices.count
            selectedRun = indices[next]
        }
    }
}
