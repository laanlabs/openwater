import OpenWaterCore
import OpenWaterSpots
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
    /// Current to pre-fill: m/s, and the bearing it set toward.
    let initialCurrent: Double?
    let initialCurrentToward: Double?
    /// Whether this caller deals in current at all. The session screens do —
    /// "what was that day like" is exactly where a knot of water belongs —
    /// and the record screen does not: it is asking what the wind is doing
    /// now, and the recorder has nowhere to put a set.
    let showsCurrent: Bool

    /// What the sheet hands back.
    ///
    /// A struct rather than six positional arguments: four of them are
    /// `Double?` and two of those are bearings, so a call site that
    /// transposed swell and current would compile perfectly and be wrong on
    /// the water. Everything is nil when it was not offered, left at zero, or
    /// never pointed at. The timeline is the model's record of the day and
    /// travels regardless of how far the rider drags the dials away from it:
    /// their call and the archive's account are allowed to disagree, and both
    /// are worth keeping.
    struct Applied {
        var windDirection: Double
        /// m/s, nil when the rider skips speed.
        var windSpeed: Double?
        var swellHeight: Double?
        var swellDirection: Double?
        /// m/s, and the bearing the water sets *toward*.
        var currentSpeed: Double?
        var currentDirectionToward: Double?
        var windTimeline: WindTimeline?
    }

    let onApply: (Applied) -> Void

    /// Where and when the session happened, so the models can be asked what
    /// that day was doing. Nil on the record screen — the forecast already
    /// covers "now", and there is nothing historical about it yet.
    let lookup: (coordinate: Geo.Coordinate, window: DateInterval)?

    init(session: Session, onApply: @escaping (Applied) -> Void) {
        self.trackPoints = session.track.points
        self.reference = session.effectiveWind
        self.referenceLabel = "the estimate"
        self.initialSwell = session.swellHeight
        self.initialSwellDirection = session.swellDirection
        self.showsSwell = true
        self.initialCurrent = session.currentSpeed
        self.initialCurrentToward = session.currentDirectionToward
        self.showsCurrent = true
        self.onApply = onApply
        let points = session.track.points
        self.lookup = points.isEmpty ? nil : (
            points[points.count / 2].coordinate,
            DateInterval(start: session.startDate,
                         duration: max(600, session.track.duration))
        )
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
        self.initialCurrent = nil
        self.initialCurrentToward = nil
        self.showsCurrent = false
        // No lookup on this path, so there is never a timeline to hand on.
        self.onApply = { applied in
            onApply(applied.windDirection, applied.windSpeed,
                    applied.swellHeight, applied.swellDirection)
        }
        self.lookup = nil
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
    @State private var currentKnots: Double = 0
    /// Degrees the water sets *toward* — the chart convention, opposite to
    /// the wind's, and the one `Session.currentDirectionToward` stores.
    @State private var currentToward: Double = 0
    /// Same rule as the swell's: a dial nobody dragged is not an assertion.
    @State private var hasCurrentToward = false

    @State private var isLookingUp = false
    @State private var isRestoringEstimate = false
    @State private var lookupNote: String?
    /// The hourly record behind the lookup's averages, held so Save can hand
    /// it on rather than letting it die in the note below the dial.
    @State private var fetchedTimeline: WindTimeline?

    private enum Pointing: String, CaseIterable, Identifiable {
        case wind = "Wind"
        case swell = "Swell"
        case current = "Current"
        var id: String { rawValue }

        /// What the legend calls this tab when it is still empty. The wind
        /// tab is never short of a direction — it is the strength that goes
        /// missing — so it is named for the thing that is actually blank.
        var waitingName: String {
            switch self {
            case .wind: "wind speed"
            case .swell: "swell"
            case .current: "current"
            }
        }
    }

    /// Which arrows this caller offers. Current rides on its own flag, so the
    /// record screen keeps the two it can store.
    private var pointings: [Pointing] {
        showsCurrent ? Pointing.allCases : Pointing.allCases.filter { $0 != .current }
    }

    /// The segments, drawn rather than picked.
    ///
    /// One dial answers three questions and two of them are a tap away, so a
    /// rider who never touches the segments never learns that the swell and
    /// the current can be given at all — hence a mark on any segment whose
    /// tab is still empty, the same orange triangle `AnalysisRow` wears for a
    /// metric running on a guess, going out the moment that slider leaves
    /// zero.
    ///
    /// It is hand-built because `Picker(.segmented)` cannot carry it:
    /// interpolating an image into a segment's `Text` renders the words and
    /// drops the glyph on the floor, which was measured on screen rather than
    /// assumed. The styling is the system control's — a fill track, a raised
    /// pill under the selection — so nothing about it announces that it is
    /// ours.
    private var arrowPicker: some View {
        HStack(spacing: 2) {
            ForEach(pointings) { option in
                Button {
                    pointing = option
                } label: {
                    HStack(spacing: 4) {
                        Text(option.rawValue)
                            .font(.subheadline.weight(pointing == option ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        if isUnanswered(option) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if pointing == option {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isUnanswered(option) ? "\(option.rawValue), not set" : option.rawValue)
                .accessibilityAddTraits(pointing == option ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, showsCurrent ? 24 : 40)
        // The arrows dim and brighten with this, and the row below swaps with
        // it — all of which is one movement.
        .animation(.snappy, value: pointing)
    }

    /// What the mark on a segment means, said once at the foot of the sheet.
    ///
    /// A badge nobody can decode is just an alarm. So the legend names the
    /// tabs still waiting — a rider should not have to visit all three to
    /// find out which one the triangle was about — and it says the thing that
    /// stops the mark reading as an error: none of this is required. It is
    /// here only while there is a badge to explain, and goes when the last
    /// one does.
    @ViewBuilder
    private var badgeLegend: some View {
        let waiting = pointings.filter(isUnanswered)
        if !waiting.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("marks a tab nobody has filled in yet — \(named(waiting)). Each is optional; the arrows alone are a complete answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    /// The waiting tabs in a sentence: "swell", "swell and current",
    /// "wind speed, swell and current".
    private func named(_ options: [Pointing]) -> String {
        let names = options.map(\.waitingName)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// Whether a segment's tab still has nothing in it.
    ///
    /// Strength decides, never direction: the estimator always has an opinion
    /// about where the wind came from, and an untouched arrow still points
    /// somewhere, so a bearing is never evidence that anybody answered.
    private func isUnanswered(_ option: Pointing) -> Bool {
        switch option {
        case .wind: knots <= 0.5
        case .swell: swell <= 0.05
        case .current: currentKnots <= 0.05
        }
    }

    /// The angle currently under the drag.
    private var pointed: Double {
        get {
            switch pointing {
            case .wind: direction
            case .swell: swellDirection
            case .current: currentToward
            }
        }
        nonmutating set {
            switch pointing {
            case .wind: direction = newValue
            case .swell: swellDirection = newValue; hasSwellDirection = true
            case .current: currentToward = newValue; hasCurrentToward = true
            }
        }
    }

    private var estimate: Wind? { reference }

    var body: some View {
        NavigationStack {
            // A scroll view, not a fixed column. With the lookup row and its
            // result this outgrew one screen, and a VStack that overflows
            // centres itself — the prompt slid up underneath the toolbar and
            // the buttons fell off the bottom edge.
            ScrollView {
            VStack(spacing: 16) {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)

                if showsSwell { arrowPicker }

                // The two ways to fill these dials without guessing — snap
                // back to the model's number, or ask the archive what that
                // day was doing — lived at the bottom of the column, under
                // two sliders, off the bottom edge of most screens. Nobody
                // scrolls a dial screen to find out what else it can do, so
                // the app's two best answers to "I don't remember" went
                // unfound. They flank the dial now, in the corners the
                // circle leaves empty: beside the control they fill is the
                // one place a rider is already looking.
                dial
                    .frame(width: 300, height: 300)
                    .overlay(alignment: .bottomLeading) {
                        if let estimate {
                            dialAction(isRestoringEstimate ? "Setting…" : estimateCaption,
                                       symbol: "wand.and.sparkles",
                                       busy: isRestoringEstimate) {
                                Task { await restoreEstimate(estimate) }
                            }
                            .offset(x: -22)
                            .disabled(isRestoringEstimate)
                            .accessibilityLabel("Back to \(referenceLabel), \(Format.cardinal(estimate.directionFrom)) \(Int(estimate.directionFrom.rounded())) degrees")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let lookup {
                            dialAction(isLookingUp ? "Checking…" : "Look up",
                                       symbol: "clock.arrow.circlepath",
                                       busy: isLookingUp) {
                                Task { await lookUp(lookup) }
                            }
                            .offset(x: 22)
                            .disabled(isLookingUp)
                            .accessibilityLabel("Look up that day's conditions")
                        }
                    }

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

                // Which way round this bearing means, said out loud. Wind and
                // swell are named for where they come from; a current is
                // named for where it takes you, and a dial carrying all three
                // has to settle that every time the arrow changes.
                Text(pointing == .current ? "setting toward" : "coming from")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if pointing == .current, hasCurrentToward {
                    Text(currentLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if showsSwell, hasSwellDirection, pointing != .current {
                    Text(offsetLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Right under the readout, where the eye lands after the
                // lookup snaps the dial — a result that renders below the
                // sliders is a lookup that appears to have done nothing.
                if let lookupNote {
                    Text(lookupNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }

                // One slider, and it is the one the segment is pointing at.
                //
                // Three stacked rows made the sheet a scroll: the dial, its
                // readout, then a wind slider, a swell slider with its wave
                // graphic, and a current slider — most of them answering a
                // question the rider was not being asked. The segment already
                // says which of the three is under the hand, so the row below
                // follows it, and the sheet fits a screen again.
                Group {
                    switch pointing {
                    case .wind: speedRow
                    case .swell: swellRow
                    case .current: currentRow
                    }
                }
                .transition(.opacity)
                .animation(.snappy, value: pointing)

                if showsSwell { badgeLegend }
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
            }
            .navigationTitle(showsSwell ? "Conditions" : "Set the Wind")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Set the wind")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onApply(Applied(
                            windDirection: direction,
                            windSpeed: knots > 0.5 ? knots / 1.94384 : nil,
                            swellHeight: showsSwell && swell > 0.05 ? swell : nil,
                            swellDirection: showsSwell && hasSwellDirection ? swellDirection : nil,
                            currentSpeed: showsCurrent && currentKnots > 0.05 ? currentKnots / 1.94384 : nil,
                            currentDirectionToward: showsCurrent && hasCurrentToward ? currentToward : nil,
                            windTimeline: fetchedTimeline
                        ))
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
                if let initialCurrent { currentKnots = initialCurrent * 1.94384 }
                if let initialCurrentToward {
                    currentToward = initialCurrentToward
                    hasCurrentToward = true
                } else if let estimate {
                    // Somewhere to start, never an assertion: dead downwind is
                    // where a rider expects the water to be going before they
                    // know better, and `hasCurrentToward` stays false until
                    // they say so.
                    currentToward = Geo.normalizeDegrees(estimate.directionFrom + 180)
                }
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

    /// What the left-hand action restores, in a word. The reference is "the
    /// estimate" on a recorded session and "the forecast" before one.
    private var estimateCaption: String {
        referenceLabel.hasSuffix("forecast") ? "Forecast" : "Estimate"
    }

    /// A round control at the dial's corner: the icon in a dial-coloured
    /// circle, what it does in a word underneath. Sized and placed so it
    /// stays clear of the circle itself — the corner is outside the drag
    /// surface, so a tap here can never be mistaken for pointing at a wind.
    private func dialAction(_ caption: String, symbol: String,
                            busy: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color(.secondarySystemGroupedBackground))
                    Circle()
                        .strokeBorder(.quaternary, lineWidth: 1)
                    if busy {
                        ProgressView()
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .frame(width: 46, height: 46)

                Text(caption)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

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

                // Rotated by the bearing it sets *toward*, with the head at
                // that rim pointing outward — no +180 anywhere, because the
                // stored number already means "this way", the same as
                // `CurrentsOutlook`'s.
                if showsCurrent {
                    currentArrow(size: size)
                        .rotationEffect(.degrees(currentToward))
                        .opacity(pointing == .current ? 1 : 0.4)
                }

                windArrow(size: size)
                    .rotationEffect(.degrees(direction))
                    .opacity(pointing == .wind ? 1 : 0.4)
            }
            .contentShape(Circle())
            // High priority, because the dial now lives inside a scroll
            // view: a plain gesture loses every vertical drag to the scroll
            // pan, and pointing at a southerly wind is a vertical drag. The
            // dial's circle is the one patch of the sheet that does not
            // scroll, and it is the patch that is a control.
            .highPriorityGesture(
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
        if pointing == .current {
            return trackPoints.isEmpty
                ? "Drag the arrow to point the way the water is running — where it takes you, not where it comes from."
                : "Drag the arrow to point the way the water was taking you."
        }
        if pointing == .swell {
            return trackPoints.isEmpty
                ? "Drag the arrow to point the way the swell is coming from."
                : "Drag the arrow to point the way the swell was marching across your track."
        }
        return trackPoints.isEmpty
            ? "Drag the arrow to point the way the wind is blowing."
            : "Drag the arrow to point the way the wind was blowing across your track."
    }

    /// Snap the dials back to the reference.
    ///
    /// The work is instant and local, but the button still shows a beat of
    /// progress: when the dial is already sitting on the estimate the snap
    /// moves nothing, and a tap with no visible answer reads as a broken
    /// button. The dial snaps immediately — the beat is feedback, never a
    /// delay on the answer.
    private func restoreEstimate(_ estimate: Wind) async {
        withAnimation(.snappy) {
            isRestoringEstimate = true
            direction = estimate.directionFrom
            if let s = estimate.speed { knots = s * 1.94384 }
        }
        try? await Task.sleep(for: .seconds(1))
        withAnimation(.snappy) { isRestoringEstimate = false }
    }

    /// Fetch the day and pour it into the dials.
    private func lookUp(_ lookup: (coordinate: Geo.Coordinate, window: DateInterval)) async {
        withAnimation(.snappy) { isLookingUp = true }
        defer { withAnimation(.snappy) { isLookingUp = false } }

        // The archive often answers in a blink, and a spinner that lives for
        // a frame reads as a tap that did nothing — the rider looks at the
        // dial, sees the same number arrive, and cannot tell the model was
        // asked at all. The fetch takes as long as it takes; the spinner is
        // held up to a full second so the asking is visible.
        let started = ContinuousClock.now
        let found = await OpenMeteo.historical(at: lookup.coordinate, during: lookup.window)
        let elapsed = started.duration(to: .now)
        if elapsed < .seconds(1) {
            try? await Task.sleep(for: .seconds(1) - elapsed)
        }
        guard !found.isEmpty else {
            withAnimation(.snappy) {
                lookupNote = "Nothing on record for that day here — the marine grid has no cell for some water, and the archive runs a few days behind."
            }
            return
        }

        withAnimation(.snappy) {
            if let d = found.windDirectionFrom { direction = d }
            if let kn = found.windSpeedKn { knots = kn.rounded() }
            if showsSwell, let h = found.swellMetres { swell = min(5, h) }
            if showsSwell, let d = found.swellDirectionFrom {
                swellDirection = d
                hasSwellDirection = true
            }
            if showsCurrent, let kn = found.currentKn, let toward = found.currentSettingToward {
                currentKnots = min(6, kn)
                currentToward = toward
                hasCurrentToward = true
            }
            fetchedTimeline = found.windTimeline

            var parts: [String] = []
            if let d = found.windDirectionFrom {
                let speed = found.windSpeedKn.map { " \(Int($0.rounded())) kn" } ?? ""
                let gust = found.windGustKn.map { " gusting \(Int($0.rounded()))" } ?? ""
                parts.append("wind \(Format.cardinal(d))\(speed)\(gust)")
            }
            if let h = found.swellMetres {
                let from = found.swellDirectionFrom.map { " from \(Format.cardinal($0))" } ?? ""
                parts.append("swell \(Format.height(h, unit: settings.units.distance))\(from)")
            }
            if showsCurrent, let kn = found.currentKn, let toward = found.currentSettingToward {
                // Named for where it goes, in the same breath as two things
                // named for where they come from — so the word is said here
                // as well as under the dial.
                parts.append("current \(String(format: "%.1f", kn)) kn setting \(Format.cardinal(toward))")
            }
            lookupNote = "That day, by the model: \(parts.joined(separator: " · ")). Yours to correct."
        }
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

    /// Wind against water, said the way a rider would say it.
    ///
    /// The wind blows *from* its bearing, so it travels toward the opposite
    /// one, and that is what the current has to be compared against. Wind
    /// against tide is the sentence worth printing: it is the day the chop
    /// stands up and the same fifteen knots feels like twenty-five.
    private var currentLine: String {
        let windToward = Geo.normalizeDegrees(direction + 180)
        let raw = Geo.normalizeDegrees(currentToward - windToward)
        let between = raw > 180 ? 360 - raw : raw
        let rounded = Int(between.rounded())
        switch between {
        case ..<30: return "Water running with the wind"
        case ..<70: return "Water \(rounded)° off the wind's way"
        case ..<110: return "Water across the wind — \(rounded)°"
        default: return "Wind against tide — the day the chop stands up"
        }
    }

    /// Squarer than the wind's and pointing outward, because a current is the
    /// one arrow here that means "this way", not "from here".
    private func currentArrow(size: CGFloat) -> some View {
        VStack(spacing: 3) {
            Circle()
                .fill(Color.orange)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(radius: 2)
            // A wake behind the head, tapering back the way it came.
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.orange.opacity(0.5 - Double(i) * 0.12))
                    .frame(width: 12 - CGFloat(i) * 3, height: 2.5)
            }
            Spacer()
        }
        .frame(height: size - 8)
        .padding(.top, 8)
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
struct TrackPathShape: Shape {
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
    }

    private var swellText: String {
        Format.height(swell, unit: settings.units.distance)
    }

    /// What the water was doing under the session.
    ///
    /// Sliders in knots like the wind's, because a rider who knows their
    /// river knows it in knots — and capped at six, which is faster than any
    /// water anybody rides on purpose. Net set, not peak: a session that
    /// spanned the turn had the water go both ways, and the honest number is
    /// what it did on balance.
    private var currentRow: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Current")
                    .font(.subheadline)
                Spacer()
                Text(currentKnots > 0.05 ? currentText : "not set")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(currentKnots > 0.05 ? .primary : .secondary)
            }
            Slider(value: $currentKnots, in: 0...6, step: 0.1)
            Text("Optional, and nothing on the phone can measure it — Look up fills it from the model, or slide to zero.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
    }

    private var currentText: String {
        let speed = String(format: "%.1f kn", currentKnots)
        guard hasCurrentToward else { return speed }
        return "\(speed) setting \(Format.cardinal(currentToward))"
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
                .font(.caption)
                .foregroundStyle(.secondary)
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
