import MapKit
import OpenWaterCore
import SwiftUI

/// Where on the water the bumps were working.
///
/// Two things are drawn. The **glides** are the fine grain: each one a coloured
/// stretch of track, brighter the faster it was, so a rider can see the section
/// of coast that was giving. The **legs** are the coarse grain, and they only
/// appear on a shuttle day: `SessionShape` splits the session where the rider
/// was carried back to the top, so three runs down the same river read as three
/// runs rather than as one confusing tangle.
///
/// The thresholds sit at the bottom of this screen rather than in Settings,
/// because this is where a rider finds out they disagree with them. Every one
/// was arrived at by arguing with a real session, and none is a fact about the
/// world — a big board in small swell holds a glide at a speed a race foil
/// would call slogging.
struct DownwindDetailView: View {

    @State private var session: Session
    @State private var summary: SessionSummary

    init(session: Session, summary: SessionSummary) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
    }

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var selectedGlide: Int?
    @State private var isMapFullScreen = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var isRecomputing = false
    @State private var showsThresholds = false

    private var glides: [Glide] { summary.downwind.glides }
    private var legs: [SessionLeg] { summary.shape.legs }

    /// Legs are worth drawing only when there is more than one — on an
    /// ordinary session the single leg is the whole track, and outlining it
    /// says nothing the track has not already said.
    private var showsLegs: Bool { legs.count > 1 }

    private var units: UnitPreferences { settings.units }

    /// What this session was actually analysed with, the rider's changes
    /// included.
    private var thresholds: SportThresholds {
        settings.thresholds(for: session.sport)
    }

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
                    mapCard
                    glideList
                }

                explanation
                thresholdCard
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Downwind")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isRecomputing {
                ProgressView("Re-reading the session…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
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

    // MARK: - Map

    private var mapCard: some View {
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
                    Button("Show all") { select(nil) }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
    }

    private var map: some View {
        Map(position: $camera) {
            // The whole session as context, faded — same as Upwind, so the two
            // screens read as the same kind of picture.
            MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                .stroke(.gray.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            ForEach(glides) { glide in
                if glide.endIndex < session.track.count {
                    MapPolyline(coordinates: coordinates(of: glide))
                        .stroke(
                            speedColour(glide.averageSpeed)
                                .opacity(selectedGlide == nil || selectedGlide == glide.id ? 0.95 : 0.2),
                            style: StrokeStyle(lineWidth: selectedGlide == glide.id ? 7 : 4, lineCap: .round)
                        )
                }
            }

            // A tap target per glide, because a `MapPolyline` cannot take one.
            // Small and numbered so a session with a dozen stays legible; the
            // chosen one grows and says how long it lasted.
            ForEach(glides) { glide in
                if glide.endIndex < session.track.count {
                    Annotation("", coordinate: midpoint(of: glide), anchor: .center) {
                        Button {
                            select(selectedGlide == glide.id ? nil : glide.id)
                        } label: {
                            if selectedGlide == glide.id {
                                Text("\(position(of: glide)) · \(Format.shortDuration(glide.duration))")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(speedColour(glide.averageSpeed), in: Capsule())
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                            } else {
                                Text("\(position(of: glide))")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(speedColour(glide.averageSpeed).opacity(0.9), in: Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
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

    private func coordinates(of glide: Glide) -> [CLLocationCoordinate2D] {
        session.track.points[glide.startIndex...glide.endIndex].map(\.clCoordinate)
    }

    private func midpoint(of glide: Glide) -> CLLocationCoordinate2D {
        session.track.points[(glide.startIndex + glide.endIndex) / 2].clCoordinate
    }

    private var sortedGlides: [Glide] {
        glides.sorted { $0.duration > $1.duration }
    }

    /// Where this glide sits in the list below, which is sorted longest-first,
    /// so the number on the map is the number on the row.
    private func position(of glide: Glide) -> Int {
        (sortedGlides.firstIndex { $0.id == glide.id } ?? 0) + 1
    }

    /// Choose a glide and frame it, or clear the choice and show the session.
    ///
    /// Framing is the point. A four-kilometre glide inside an hour of laps is a
    /// thin thread on a map scaled to the whole session, and picking it out by
    /// eye is exactly the work this screen exists to save.
    private func select(_ id: Int?) {
        withAnimation(.snappy) {
            selectedGlide = id
            guard let id, let glide = glides.first(where: { $0.id == id }),
                  glide.endIndex < session.track.count
            else {
                camera = .automatic
                return
            }
            camera = .region(region(covering: coordinates(of: glide)))
        }
    }

    private func region(covering coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max()
        else { return MKCoordinateRegion() }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                // A floor on the span, or a short glide fills the screen at a
                // zoom where nothing around it is recognisable.
                latitudeDelta: max(0.004, (maxLat - minLat) * 1.4),
                longitudeDelta: max(0.004, (maxLon - minLon) * 1.4)
            )
        )
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
                ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                    if index > 0 { Divider() }
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
                ForEach(Array(sortedGlides.enumerated()), id: \.element.id) { index, glide in
                    if index > 0 { Divider() }
                    Button {
                        select(selectedGlide == glide.id ? nil : glide.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(speedColour(glide.averageSpeed).opacity(0.9), in: Circle())

                            Text(Format.shortDuration(glide.duration))
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                                .frame(width: 56, alignment: .leading)

                            Text(Format.distance(glide.distance, unit: units.distance))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)

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

    // MARK: - Prose

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A glide is a stretch where you were flying, not pumping, and not slowing down, with the bump doing the work. Colour is speed through the glide; tap one to frame it on the map.")

            if !summary.downwind.usedMotionData {
                // Said plainly rather than folded into a number. Without the
                // accelerometer there is no way to tell working from gliding,
                // so the detector is reading the speed trace and inferring.
                Text("This session has no motion data, so glides were found from the speed trace alone. Treat them as indicative.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Why there is nothing here.
    ///
    /// An empty screen would leave a rider guessing whether the app looks for
    /// glides at all. It does, and these are the four things it wants — said
    /// plainly, with their current values, so a session that found none is
    /// legible as a flat day rather than as a broken feature.
    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No glides in this session", systemImage: "water.waves")
                .font(.subheadline.weight(.medium))

            Text("A glide is a stretch where the water carried you rather than you working for it. To count, it has to be all four of these:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                criterion("At least \(Int(thresholds.glideMinimumDuration)) seconds")
                criterion("Sailed more than \(Int(thresholds.glideDownwindAngle))° off the wind — a bump can only push you the way it is going")
                criterion("At least \(Int(thresholds.glideSpeedFraction * 100))% of your typical downwind speed")
                criterion("Speed rising \(Int(thresholds.glideMinimumGain * 100))% out of the lull before it")
            }

            Text("All four are adjustable at the bottom of this screen.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

    // MARK: - Thresholds

    private var overrides: SportThresholds.Overrides {
        settings.sportOverrides[session.sport] ?? .init()
    }

    private var defaults: SportThresholds { session.sport.thresholds }

    private func binding(
        _ key: WritableKeyPath<SportThresholds.Overrides, Double?>,
        default fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { overrides[keyPath: key] ?? fallback },
            set: { newValue in
                var o = overrides
                // Back at the default means back to *following* the default,
                // not pinned to today's value of it.
                o[keyPath: key] = abs(newValue - fallback) < 0.0001 ? nil : newValue
                settings.sportOverrides[session.sport] = o.isEmpty ? nil : o
            }
        )
    }

    private var thresholdCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { showsThresholds.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsThresholds ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("What counts as a glide")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    if !overrides.isEmpty {
                        Text("adjusted")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsThresholds {
                VStack(alignment: .leading, spacing: 16) {
                    slider(
                        "Off the wind",
                        binding(\.glideDownwindAngle, default: defaults.glideDownwindAngle),
                        range: 90...150, step: 5,
                        format: { "\(Int($0))°" },
                        note: "How far off the wind you have to be pointing. A bump can only push you the way it is going, so riding across the swell does not count."
                    )
                    slider(
                        "At least this long",
                        binding(\.glideMinimumDuration, default: defaults.glideMinimumDuration),
                        range: 2...20, step: 1,
                        format: { "\(Int($0)) s" },
                        note: "Below this it is a nudge off a bit of chop rather than a glide."
                    )
                    slider(
                        "Share of your downwind pace",
                        binding(\.glideSpeedFraction, default: defaults.glideSpeedFraction),
                        range: 0.5...1.0, step: 0.05,
                        format: { "\(Int($0 * 100))%" },
                        note: "Measured against your median speed going downwind, so a current that slows every downwind leg does not raise the bar. Near 100% splits your riding in half, since half of it is below its own median by definition."
                    )
                    slider(
                        "Speed rise out of the lull",
                        binding(\.glideMinimumGain, default: defaults.glideMinimumGain),
                        range: 0...0.3, step: 0.01,
                        format: { "\(Int($0 * 100))%" },
                        note: "The bump gives you speed. Without a rise there is nothing to separate gliding from riding along at one speed."
                    )

                    if !overrides.isEmpty {
                        Button("Reset to the defaults for \(session.sport.displayName)", role: .destructive) {
                            settings.sportOverrides[session.sport] = nil
                            recompute()
                        }
                        .font(.callout)
                    }

                    Text("These apply to every \(session.sport.displayName.lowercased()) session as it is analysed, not only this one.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardChrome()
    }

    private func slider(
        _ title: String,
        _ value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String,
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 8)
                Text(format(value.wrappedValue))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            // Re-reading a session is half a second of work on a long track, so
            // it happens when the drag ends rather than on every frame of it.
            Slider(value: value, in: range, step: step) { editing in
                if !editing { recompute() }
            }
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Re-run the analysis with the rider's thresholds and keep the result.
    ///
    /// Saved to the library rather than held here, so the rest of the app
    /// agrees with what this screen shows — the same discipline the Upwind
    /// screen follows when the wind is changed.
    private func recompute() {
        isRecomputing = true
        let categories = settings.categories
        let overrides = settings.overrides(for: session.sport)
        let current = session
        Task {
            let edited = await Task.detached {
                current.applying(Session.Edits(session: current),
                                 categories: categories, overrides: overrides)
            }.value
            library.save(edited)
            if let newSummary = edited.summary {
                session = edited
                summary = newSummary
                select(nil)
            }
            isRecomputing = false
        }
    }
}
