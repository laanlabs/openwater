import OpenWaterCore
import SwiftUI

/// Set the session's wind by pointing at it.
///
/// Every angle in the app — TWA, VMG, the polar, the upwind legs, tack versus
/// gybe — is measured from one number, and when the estimator could not work
/// it out the whole analysis goes dark. Asking for that number through a text
/// field is asking a rider to do trigonometry in a car park. This asks the way
/// an instructor would: here is your track from above; drag the arrow until it
/// blows the way the wind blew.
///
/// The rider's own zig-zags are the reference: anyone who sailed the session
/// can see which way they were tacking, so putting the track under the dial
/// turns "what bearing was the wind" into "point at the picture".
struct WindSetterView: View {

    /// The track drawn inside the dial — empty before a session exists, in
    /// which case the dial is just a compass, which is still the right tool.
    let trackPoints: [TrackPoint]
    /// The wind to pre-fill and to offer a way back to.
    let reference: Wind?
    /// What the reference is called on the way-back button — "the estimate"
    /// for a recorded session, "the forecast" before one.
    let referenceLabel: String
    /// Swell to pre-fill, metres. Nil means this caller does not deal in
    /// swell and the row stays off — the record screen is asking "what is it
    /// doing", the session screens are asking "what was it like".
    let initialSwell: Double?
    /// Degrees the swell comes from, if this session already has one.
    let initialSwellDirection: Double?
    let showsSwell: Bool
    /// Degrees the wind comes from, m/s (nil when the rider skips speed),
    /// swell in metres, and degrees the swell comes from — the last two nil
    /// when not offered, left at zero, or never pointed at.
    let onApply: (Double, Double?, Double?, Double?) -> Void

    init(session: Session, onApply: @escaping (Double, Double?, Double?, Double?) -> Void) {
        self.trackPoints = session.track.points
        self.reference = session.effectiveWind
        self.referenceLabel = "the estimate"
        self.initialSwell = session.swellHeight
        self.initialSwellDirection = session.swellDirection
        self.showsSwell = true
        self.onApply = onApply
    }

    init(initialWind: Wind?, initialSwell: Double? = nil,
         initialSwellDirection: Double? = nil,
         showsSwell: Bool = false, referenceLabel: String = "the forecast",
         onApply: @escaping (Double, Double?, Double?, Double?) -> Void) {
        self.trackPoints = []
        self.reference = initialWind
        self.referenceLabel = referenceLabel
        self.initialSwell = initialSwell
        self.initialSwellDirection = initialSwellDirection
        self.showsSwell = showsSwell
        self.onApply = onApply
    }

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var direction: Double = 0
    @State private var knots: Double = 0
    @State private var swell: Double = 0
    @State private var hasDragged = false

    /// Which arrow the dial is dragging.
    ///
    /// One dial rather than two, because the number a rider is really giving
    /// us is the angle *between* wind and swell — side-shore, offshore, dead
    /// behind — and that is only readable when both arrows sit on the same
    /// circle over the same track.
    @State private var pointing: Pointing = .wind
    @State private var swellDirection: Double = 0
    /// Swell direction is only reported once it has actually been given. An
    /// untouched dial sitting at north is not a rider saying "north".
    @State private var hasSwellDirection = false

    private enum Pointing: String, CaseIterable, Identifiable {
        case wind = "Wind"
        case swell = "Swell"
        var id: String { rawValue }
    }

    /// The angle currently under the drag.
    private var pointed: Double {
        get { pointing == .wind ? direction : swellDirection }
        nonmutating set {
            if pointing == .wind { direction = newValue }
            else { swellDirection = newValue; hasSwellDirection = true }
        }
    }

    private var estimate: Wind? { reference }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)

                if showsSwell {
                    Picker("", selection: $pointing) {
                        ForEach(Pointing.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 40)
                }

                dial
                    .frame(width: 300, height: 300)

                HStack(spacing: 6) {
                    Text(Format.cardinal(pointed))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("\(Int(pointed.rounded()))°")
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(pointed))

                if showsSwell, hasSwellDirection {
                    Text(offsetLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                speedRow

                if showsSwell { swellRow }

                if let estimate {
                    Button {
                        withAnimation(.snappy) {
                            direction = estimate.directionFrom
                            if let s = estimate.speed { knots = s * 1.94384 }
                        }
                    } label: {
                        Label("Back to \(referenceLabel) (\(Format.cardinal(estimate.directionFrom)) \(Int(estimate.directionFrom.rounded()))°)",
                              systemImage: "wand.and.sparkles")
                            .font(.callout)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .navigationTitle(showsSwell ? "Conditions" : "Set the Wind")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Set the wind")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onApply(direction,
                                knots > 0.5 ? knots / 1.94384 : nil,
                                showsSwell && swell > 0.05 ? swell : nil,
                                showsSwell && hasSwellDirection ? swellDirection : nil)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let estimate {
                    direction = estimate.directionFrom
                    if let s = estimate.speed { knots = s * 1.94384 }
                }
                if let initialSwell { swell = initialSwell }
                if let initialSwellDirection {
                    swellDirection = initialSwellDirection
                    hasSwellDirection = true
                } else if let estimate {
                    // Somewhere to start dragging from, not an assertion —
                    // `hasSwellDirection` stays false until it is dragged.
                    swellDirection = estimate.directionFrom
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Dial

    private var dial: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            ZStack {
                Circle()
                    .fill(Color(.secondarySystemGroupedBackground))
                Circle()
                    .strokeBorder(.quaternary, lineWidth: 1)

                // Tick ring, fixed — the world does not rotate.
                ForEach(0..<24, id: \.self) { tick in
                    Capsule()
                        .fill(tick % 6 == 0 ? Color.secondary : Color(.systemGray4))
                        .frame(width: 2, height: tick % 6 == 0 ? 12 : 6)
                        .offset(y: -size / 2 + 12)
                        .rotationEffect(.degrees(Double(tick) * 15))
                }
                ForEach(Array([(0, "N"), (90, "E"), (180, "S"), (270, "W")]), id: \.0) { degrees, label in
                    Text(label)
                        .font(.caption.weight(degrees == 0 ? .bold : .medium))
                        .foregroundStyle(degrees == 0 ? .primary : .secondary)
                        .offset(y: -size / 2 + 30)
                        .rotationEffect(.degrees(Double(degrees)))
                }

                if !trackPoints.isEmpty {
                    trackShape
                        .stroke(.tint.opacity(0.65), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: size * 0.52, height: size * 0.52)
                } else {
                    Circle()
                        .fill(.tint.opacity(0.35))
                        .frame(width: 10, height: 10)
                }

                // The wind: rides the rim at `direction` and blows through the
                // middle of the track. One rotated group, so the arrow and its
                // streamlines cannot disagree.
                if showsSwell {
                    swellArrow(size: size)
                        .rotationEffect(.degrees(swellDirection))
                        .opacity(pointing == .swell ? 1 : 0.4)
                }

                windArrow(size: size)
                    .rotationEffect(.degrees(direction))
                    .opacity(showsSwell && pointing == .swell ? 0.4 : 1)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - centre.x
                        let dy = value.location.y - centre.y
                        guard dx * dx + dy * dy > 100 else { return }
                        hasDragged = true
                        // Screen-up is north; atan2 measured clockwise from it.
                        pointed = Geo.normalizeDegrees(Double(atan2(dx, -dy)) * 180 / Double.pi)
                    }
            )
        }
    }

    private var prompt: String {
        if pointing == .swell {
            return trackPoints.isEmpty
                ? "Drag the arrow to point the way the swell is coming from."
                : "Drag the arrow to point the way the swell was marching across your track."
        }
        return trackPoints.isEmpty
            ? "Drag the arrow to point the way the wind is blowing."
            : "Drag the arrow to point the way the wind was blowing across your track."
    }

    /// Wind against swell, said the way a rider would say it.
    ///
    /// This is the whole reason swell has its own arrow: on a beach day the
    /// wind can be side-shore or straight offshore while the bumps keep
    /// coming from one quarter, and "cross-shore" is the fact that explains
    /// the session.
    private var offsetLine: String {
        // Shortest way round the circle: 350° and 10° are 20° apart, not 340°.
        let raw = Geo.normalizeDegrees(swellDirection - direction)
        let between = raw > 180 ? 360 - raw : raw
        let rounded = Int(between.rounded())
        switch between {
        case ..<30: return "Swell running with the wind"
        case ..<70: return "Swell \(rounded)° off the wind"
        case ..<110: return "Swell across the wind — \(rounded)°"
        default: return "Swell against the wind — \(rounded)°"
        }
    }

    /// Rounder and hollow, so it never reads as a second wind arrow.
    private func swellArrow(size: CGFloat) -> some View {
        VStack(spacing: 3) {
            Circle()
                .fill(Color.teal)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "water.waves")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(radius: 2)
            // Wave crests rather than streamlines — swell arrives in lines.
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.teal.opacity(0.5 - Double(i) * 0.12))
                    .frame(width: 16, height: 2.5)
            }
            Spacer()
        }
        .frame(height: size - 8)
        .padding(.top, 6)
    }

    private func windArrow(size: CGFloat) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(.tint)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(radius: 2)
            // Streamlines, so the arrow reads as "wind entering here" rather
            // than a knob on a dial.
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(.tint.opacity(0.55 - Double(i) * 0.15))
                    .frame(width: 2.5, height: 14)
            }
            Spacer()
        }
        .frame(height: size - 8)
        .padding(.top, 4)
    }

    /// The session from above, scaled into the middle of the dial. North is
    /// up, matching the ring around it.
    private var trackShape: some Shape {
        var thinned: [(Double, Double)] = []
        let points = trackPoints
        let stride = max(1, points.count / 300)
        var i = 0
        while i < points.count {
            thinned.append((points[i].latitude, points[i].longitude))
            i += stride
        }
        return TrackPathShape(coordinates: thinned)
    }
}

/// A lat/lon polyline as a `Shape`, equirectangular, aspect-preserving.
private struct TrackPathShape: Shape {
    let coordinates: [(Double, Double)]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard coordinates.count > 1,
              let minLat = coordinates.map(\.0).min(), let maxLat = coordinates.map(\.0).max(),
              let minLon = coordinates.map(\.1).min(), let maxLon = coordinates.map(\.1).max()
        else { return path }

        let midLat = (minLat + maxLat) / 2
        let lonScale = cos(midLat * .pi / 180)
        let width = (maxLon - minLon) * lonScale
        let height = maxLat - minLat
        guard width > 0 || height > 0 else { return path }
        let scale = min(rect.width / max(width, 1e-9), rect.height / max(height, 1e-9))

        // Centre the projected shape inside the rect.
        let xOffset = rect.midX - width * scale / 2
        let yOffset = rect.midY - height * scale / 2

        for (index, c) in coordinates.enumerated() {
            let x = (c.1 - minLon) * lonScale * scale + xOffset
            let y = (maxLat - c.0) * scale + yOffset
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

extension WindSetterView {

    // MARK: - Speed

    /// What the water was doing, in the rider's own units.
    ///
    /// Nobody measures this and nothing can infer it — a rider calls it from
    /// memory, the same way they would over a beer. Which is exactly why it
    /// belongs next to the wind: on a downwinder it is the number that
    /// explains the session.
    private var swellRow: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Swell")
                    .font(.subheadline)
                Spacer()
                Text(swell > 0.05 ? swellText : "not set")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(swell > 0.05 ? .primary : .secondary)
            }
            SwellWaveGraphic(metres: swell, maximum: 5)
                .frame(height: 64)
            Slider(value: $swell, in: 0...5, step: 0.1)
            Text("Your call, not a measurement — nothing on the phone can see a wave.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
    }

    private var swellText: String {
        Format.height(swell, unit: settings.units.distance)
    }

    private var speedRow: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Wind speed")
                    .font(.subheadline)
                Spacer()
                Text(knots > 0.5 ? "\(Int(knots.rounded())) kn" : "not set")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(knots > 0.5 ? .primary : .secondary)
            }
            Slider(value: $knots, in: 0...40, step: 1)
            Text("Optional — slide to zero if you don't know.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
    }
}


/// Swell as a wave that grows with the slider.
///
/// A number in metres means little to most riders — "waist, chest, head" is
/// how the size of a day actually gets described, so the graphic carries a
/// head-high line and the wave climbs past it. It is a feel, not a
/// measurement, and it should look like one.
struct SwellWaveGraphic: View {

    let metres: Double
    let maximum: Double

    /// Where a person's height sits on this scale.
    private let headHigh: Double = 1.8

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let baseline = height - 2
            let usable = height - 6
            // Wave height is trough to crest, so the surface oscillates about
            // a line half a wave up and the trough just kisses the baseline.
            // Centring it *on* the baseline instead sent the trough clean off
            // the bottom of the frame at four metres.
            let waveHeight = usable * min(1, metres / maximum)
            let amplitude = waveHeight / 2
            let centre = baseline - amplitude

            ZStack(alignment: .topLeading) {
                wave(width: width, centre: centre, baseline: baseline,
                     amplitude: amplitude, phase: 0)
                    .fill(.tint.opacity(0.25))
                wave(width: width, centre: centre, baseline: baseline,
                     amplitude: amplitude, phase: 0)
                    .stroke(.tint, lineWidth: 2)
                wave(width: width, centre: centre, baseline: baseline,
                     amplitude: amplitude * 0.5, phase: .pi / 1.5)
                    .stroke(.tint.opacity(0.4), lineWidth: 1.5)

                // The reference sits over the water, not under it, so it stays
                // readable once the swell is bigger than a person.
                let headY = baseline - usable * (headHigh / maximum)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: headY))
                    path.addLine(to: CGPoint(x: width, y: headY))
                }
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary.opacity(0.55))

                Text("head high")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(Color(.systemBackground).opacity(0.75), in: Capsule())
                    .offset(x: 2, y: max(0, headY - 11))
            }
            .clipped()
            .animation(.snappy, value: metres)
        }
    }

    /// A sine surface closed to the baseline so it can be filled.
    private func wave(width: CGFloat, centre: CGFloat, baseline: CGFloat,
                      amplitude: CGFloat, phase: Double) -> Path {
        var path = Path()
        let wavelength = width / 1.7
        path.move(to: CGPoint(x: 0, y: baseline))
        for x in stride(from: 0.0, through: Double(width), by: 2) {
            let y = centre - amplitude * CGFloat(sin(x / Double(wavelength) * 2 * .pi + phase))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: width, y: baseline))
        path.closeSubpath()
        return path
    }
}
