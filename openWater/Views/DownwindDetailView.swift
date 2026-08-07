import MapKit
import OpenWaterCore
import SwiftUI

/// Where on the water the bumps were working.
///
/// The Downwind screen used to be one card of aggregates on an otherwise empty
/// page — 34 glides, 78% linked — with no way to tell whether they came in one
/// good stretch or were scattered across the run. Upwind already answers the
/// same question for beats by drawing every leg on the track; this is the
/// counterpart.
///
/// Two things are drawn. The **glides** are the fine grain: each one a coloured
/// stretch of track, brighter the faster it was, so a rider can see the section
/// of coast that was giving. The **legs** are the coarse grain, and they only
/// appear on a shuttle day: `SessionShape` splits the session where the rider
/// was carried back to the top, so three runs down the same river read as three
/// runs rather than as one confusing tangle.
struct DownwindDetailView: View {

    let session: Session
    let summary: SessionSummary

    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var selectedGlide: Int?
    @State private var isMapFullScreen = false

    private var glides: [Glide] { summary.downwind.glides }
    private var legs: [SessionLeg] { summary.shape.legs }

    /// Legs are worth drawing only when there is more than one — on an
    /// ordinary session the single leg is the whole track, and outlining it
    /// says nothing the track has not already said.
    private var showsLegs: Bool { legs.count > 1 }

    private var units: UnitPreferences { settings.units }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if glides.isEmpty {
                    nothingFound
                } else {
                    DownwindCard(downwind: summary.downwind, units: units)
                        .cardChrome()
                }

                if showsLegs { legsCard }

                if !glides.isEmpty {
                    map
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) {
                            Button {
                                isMapFullScreen = true
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(width: 36, height: 36)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .accessibilityLabel("Expand map")
                        }
                        .overlay(alignment: .bottomLeading) {
                            if selectedGlide != nil {
                                Button("Show all") {
                                    withAnimation(.snappy) { selectedGlide = nil }
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                                .padding(10)
                            }
                        }

                    glideList
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("A glide is a stretch where you were flying, not pumping, and not slowing down, with the bump doing the work. Only stretches sailed abaft the beam count — a bump can only push you the way it is going. Colour is speed through the glide.")

                    if !summary.downwind.usedMotionData {
                        // Said plainly rather than folded into a number. Without
                        // the accelerometer there is no way to tell working from
                        // gliding, so the detector is reading the speed trace and
                        // inferring, and the rider should weigh these accordingly.
                        Text("This session has no motion data, so glides were found from the speed trace alone. Treat them as indicative.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Downwind")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isMapFullScreen) {
            NavigationStack {
                map
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Glides")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isMapFullScreen = false }
                        }
                    }
            }
        }
    }

    /// Why there is nothing here.
    ///
    /// An empty screen would leave a rider guessing whether the app looks for
    /// glides at all. It does, and these are the four things it wants — said
    /// plainly, so a session that found none is legible as a flat day rather
    /// than as a broken feature.
    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No glides in this session", systemImage: "water.waves")
                .font(.subheadline.weight(.medium))

            Text("A glide is a stretch where the water carried you rather than you working for it. To count, it has to be all four of these:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                criterion("At least five seconds")
                criterion("Sailed more than \(Int(DownwindAnalyzer.downwindHalfAngle))° off the wind — a bump can only push you the way it is going")
                criterion("Faster than your own typical pace for the day")
                criterion("Speed rising out of the lull before it, not held flat")
            }

            if !summary.downwind.usedMotionData {
                Text("This session has no motion data either, which is what tells working from gliding most clearly. A watch or phone recording gives a better answer than an imported file.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardChrome()
    }

    private func criterion(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Map

    private var map: some View {
        Map {
            // The whole session as context, faded — same as Upwind, so the two
            // screens read as the same kind of picture.
            MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                .stroke(.gray.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            ForEach(glides) { glide in
                if glide.endIndex < session.track.count {
                    MapPolyline(coordinates: session.track.points[glide.startIndex...glide.endIndex].map(\.clCoordinate))
                        .stroke(
                            speedColour(glide.averageSpeed)
                                .opacity(selectedGlide == nil || selectedGlide == glide.id ? 0.95 : 0.2),
                            style: StrokeStyle(lineWidth: selectedGlide == glide.id ? 7 : 4, lineCap: .round)
                        )
                }
            }

            // Only the chosen glide gets a marker. Eighty-five numbered dots on
            // one river is the mess the Upwind screen already learned to avoid.
            if let selectedGlide, let glide = glides.first(where: { $0.id == selectedGlide }),
               glide.endIndex < session.track.count {
                Annotation("", coordinate: session.track.points[glide.startIndex].clCoordinate, anchor: .center) {
                    Text("\(glide.id + 1) · \(Format.shortDuration(glide.duration))")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(speedColour(glide.averageSpeed), in: Capsule())
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .annotationTitles(.hidden)
            }

            // A shuttle day's separate runs, ringed at each end.
            if showsLegs {
                ForEach(legs) { leg in
                    Marker("Run \(leg.id + 1)", systemImage: "flag",
                           coordinate: leg.startCoordinate.clCoordinate)
                        .tint(.teal)
                    Marker("End \(leg.id + 1)", systemImage: "flag.checkered",
                           coordinate: leg.endCoordinate.clCoordinate)
                        .tint(.indigo)
                }
            }
        }
        .mapStyle(settings.mapStyle.mapStyle)
    }

    /// The same ramp the ribbon and the track use, so a fast glide here is the
    /// same colour as a fast run there.
    private func speedColour(_ speed: Double) -> Color {
        let top = max(summary.maxSpeed, 1)
        let bottom = top * 0.35
        let t = max(0, min(1, (speed - bottom) / max(0.1, top - bottom)))
        return Color(hue: 0.58 - 0.58 * t, saturation: 0.85, brightness: 0.95)
    }

    // MARK: - Legs

    private var legsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Runs") {
                Text("split where you were driven back")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                ForEach(Array(legs.enumerated()), id: \.element.id) { position, leg in
                    if position > 0 { Divider() }
                    HStack(spacing: 10) {
                        Text("\(leg.id + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.tint, in: Circle())

                        VStack(alignment: .leading, spacing: 1) {
                            Text(Format.distance(leg.distance, unit: units.distance))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text("\(Format.shortDuration(leg.duration)) · \(Format.speed(leg.averageSpeed, unit: units.speed, decimals: 1)) avg")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        // Only a leg that actually ran somewhere gets a
                        // direction. Over a zigzag the bearing describes the
                        // drift, and "1° off dead downwind" on an hour of laps
                        // that happened to creep downwind is a sentence about
                        // nothing.
                        if leg.isRun, let alignment = leg.alignment {
                            Text("\(Int(alignment.rounded()))° off")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(alignment <= 20 ? .green : .secondary)
                        } else if leg.isRun {
                            Text(Format.cardinal(leg.bearing))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("laps")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            if legs.contains(where: { $0.isRun && $0.alignment != nil }) {
                Text("\"Off\" is how far the run's line sat from dead downwind.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .cardChrome()
    }

    // MARK: - Glide list

    private var glideList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Every glide") {
                Text("longest first")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                let sorted = glides.sorted { $0.duration > $1.duration }
                ForEach(Array(sorted.enumerated()), id: \.element.id) { position, glide in
                    if position > 0 { Divider() }
                    Button {
                        withAnimation(.snappy) {
                            selectedGlide = selectedGlide == glide.id ? nil : glide.id
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(Format.shortDuration(glide.duration))
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                                .frame(width: 56, alignment: .leading)

                            Text(Format.distance(glide.distance, unit: units.distance))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)

                            Spacer(minLength: 4)

                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(Format.speed(glide.entrySpeed, unit: units.speed, decimals: 1, includeSymbol: false)) → \(Format.speed(glide.peakSpeed, unit: units.speed, decimals: 1))")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                if glide.connected {
                                    Text("linked")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }

                            ConfidenceMark(confidence: glide.confidence)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(selectedGlide == glide.id
                                ? AnyShapeStyle(.tint.opacity(0.1))
                                : AnyShapeStyle(.clear))
                }
            }
        }
        .cardChrome()
    }
}
