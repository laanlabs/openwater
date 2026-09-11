import Charts
import MapKit
import OpenWaterCore
import SwiftUI

// MARK: - Airtime

/// Jumps, which the app has always detected and never shown.
///
/// `JumpDetector` finds them from free-fall in the accelerometer and fills in
/// airtime, height, takeoff and landing speed and a confidence for every one —
/// and until now the only place any of it surfaced was `Settings`, which told
/// riders we detect "flights, gybes, falls, jumps". We displayed three of the
/// four.
///
/// Height is the number to be careful with. It comes from hangtime under
/// gravity (`g·t²/8`), which assumes you land at the height you left — off a
/// wave into a trough that is optimistic. It is labelled an estimate here for
/// the same reason the detector's own comment says so.
struct AirtimeScreen: View {

    @State private var session: Session
    @State private var summary: SessionSummary
    let units: UnitPreferences

    /// The parent's copy and its revision — see `SessionDetailView.revision`.
    /// Local state above lets this screen re-analyse in place; a new revision
    /// means the parent re-read the session, and the local copy yields to it.
    private let incoming: (session: Session, summary: SessionSummary)
    var revision: Int = 0

    init(session: Session, summary: SessionSummary, units: UnitPreferences, revision: Int = 0) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
        incoming = (session, summary)
        self.units = units
        self.revision = revision
    }

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @State private var isRecomputing = false

    private var jumps: [Jump] {
        summary.jumps.sorted { $0.airtime > $1.airtime }
    }

    private func reanalyse() {
        isRecomputing = true
        Task {
            if let edited = await SessionReanalyser.reanalyse(session, settings: settings, library: library),
               let newSummary = edited.summary {
                session = edited
                summary = newSummary
            }
            isRecomputing = false
        }
    }

    var body: some View {
        airtime
            .onChange(of: revision) { _, _ in
                session = incoming.session
                summary = incoming.summary
            }
    }

    private var airtime: some View {
        AnalysisDetail(title: "Airtime") {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Jumps")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    SummaryTile(label: "Jumps", value: "\(summary.jumpSummary.count)")
                    SummaryTile(label: "Best airtime",
                                value: Format.shortDuration(summary.jumpSummary.bestAirtime))
                    SummaryTile(label: "Best height",
                                value: Format.height(summary.jumpSummary.bestHeight, unit: units.distance))
                    SummaryTile(label: "Total airtime",
                                value: Format.shortDuration(summary.jumpSummary.totalAirtime))
                }

                Text(heightCaveat)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Whether the barometer was recording, said here because it
                // is the one fact about a session that cannot be checked from
                // a simulator and is otherwise invisible until the file is
                // exported. The range is the useful part: after five fast arm
                // raises it should read about a metre, and a rider standing
                // in a garden can confirm the sensor works from this line
                // alone, with no Mac in the loop.
                Text(barometerLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .cardChrome()

            if !jumps.isEmpty {
                heightChart
                jumpMap

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Every jump") {
                        Text("biggest first")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(jumps.enumerated()), id: \.element.id) { position, jump in
                            if position > 0 { Divider() }
                            jumpRow(jump)
                        }
                    }
                }
                .cardChrome()
            }

            AnalysisFooter(
                session: session,
                summary: summary,
                // Jumps are found from free-fall in the accelerometer. Without
                // it there are none, and there is no threshold that will help —
                // which the notice says rather than leaving a rider tuning
                // sliders against a track that cannot answer.
                needs: [.motionData],
                isBusy: isRecomputing,
                onReanalyse: reanalyse
            ) {
                ThresholdSlider(
                    title: "Shortest jump that counts",
                    value: settings.thresholdBinding(for: session.sport, \.jumpMinimumAirtime,
                                                     default: session.sport.thresholds.jumpMinimumAirtime),
                    range: 0.3...3, step: 0.1,
                    format: { String(format: "%.1f s", $0) },
                    note: "Airtime is worked back from height, so this is a height floor in the unit riders think in. Under half a second is usually the board skipping rather than leaving.",
                    onCommit: reanalyse
                )
                ThresholdSlider(
                    title: "Smallest jump that counts",
                    value: settings.thresholdBinding(for: session.sport, \.jumpMinimumRise,
                                                     default: session.sport.thresholds.jumpMinimumRise),
                    range: 0.25...2, step: 0.05,
                    format: { Format.height($0, unit: units.distance) },
                    note: "How far above the water you have to get. Lower it to find more jumps — and more chop. On rough water the bar rises with the swell whatever this says, because a receiver cannot tell a jump from a trough.",
                    onCommit: reanalyse
                )
                ThresholdSlider(
                    title: "How hard the landing is",
                    value: settings.thresholdBinding(for: session.sport, \.jumpLandingSpike,
                                                     default: session.sport.thresholds.jumpLandingSpike),
                    range: 4...25, step: 1,
                    format: { String(format: "%.0f m/s²", $0) },
                    note: "The spike that ends a jump. A kite lands softly under canopy and wants a lower bar; a wing drops you.",
                    onCommit: reanalyse
                )
                ThresholdSlider(
                    title: "Slowest takeoff",
                    value: settings.thresholdBinding(for: session.sport, \.jumpMinimumTakeoffSpeed,
                                                     default: session.sport.thresholds.jumpMinimumTakeoffSpeed),
                    range: 0...10, step: 0.5,
                    format: { Format.speed($0, unit: units.speed, decimals: 1) },
                    note: "You cannot jump from a standstill, and this keeps a bobbing board out of the count.",
                    onCommit: reanalyse
                )
            }
        }
    }

    /// What the height on this screen is worth, said in the direction it is
    /// actually wrong.
    ///
    /// This used to warn that hangtime "reads high off a wave into a trough".
    /// True in principle, and the opposite of the measured failure: on a
    /// receiver's altitude these read **low**, by something like two or three
    /// times. The rider's own check is the one that settles it — on a foil a
    /// jump has to lift the mast clear of the water before it is a jump at
    /// all, so roughly a mast length is the smallest one that can physically
    /// exist, and a screen reporting 1.7 ft is reporting something that cannot
    /// happen. A caveat pointing the wrong way is worse than none, because a
    /// rider reads it and discounts the number further.
    private var heightCaveat: String {
        if JumpDetector.source(for: session.track) == .barometer {
            return "Height comes from the watch's altimeter, read every second and held at its highest between fixes, so the top of a jump is in the data. Measured against the water a few seconds either side."
        }
        let foiling = session.sport.isFoiling
        let base = "Height comes from the receiver's altitude, which is filtered and sampled once a second — so a jump lasting about a second is caught part-way up as often as at the top. Treat these as a floor, not a measurement."
        guard foiling else { return base }
        return base + " On a foil the mast has to clear the water before you are airborne at all, so anything under about a mast length is under-read."
    }

    private var barometerLine: String {
        func describe(_ name: String, _ readings: [Double]) -> String {
            guard let low = readings.min(), let high = readings.max() else {
                return "\(name): no readings."
            }
            // Distinct values, not samples: a value repeated across fixes
            // means the sensor handed nothing new over, and that count is
            // the delivery rate — the thing this line exists to reveal.
            let distinct = readings.enumerated().filter { $0.offset == 0 || $0.element != readings[$0.offset - 1] }.count
            return "\(name): \(distinct) new values over \(readings.count) fixes, \(Format.height(high - low, unit: units.distance)) range."
        }
        let relative = describe("Relative barometer", session.track.points.compactMap(\.baroAltitude))
        let absolute = describe("Absolute altimeter", session.track.points.compactMap(\.absoluteAltitude))
        return relative + " " + absolute + " Recorded for comparison; not yet used for height."
    }

    /// Every jump as a bar, tallest at the top.
    ///
    /// The table underneath is the record; this is the shape of the session —
    /// whether the day was one big one and a lot of hops, or twenty of the
    /// same. A row of numbers cannot be read that way at a glance and a chart
    /// cannot be read for detail, so both are here and neither apologises for
    /// the other.
    private var heightChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("How high") {
                Text(Format.height(summary.jumpSummary.bestHeight, unit: units.distance) + " best")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Chart(Array(jumps.enumerated()), id: \.element.id) { index, jump in
                // The category has to be a *string*: given two numbers Charts
                // reads the y as continuous and draws the bars standing up,
                // which is the one orientation this cannot use — sixteen
                // vertical bars is a skyline, and the point here is comparing
                // lengths against a shared left edge.
                BarMark(
                    x: .value("Height", jump.height),
                    y: .value("Jump", String(index))
                )
                .foregroundStyle(.tint.opacity(0.35 + 0.65 * jump.confidence))
                .cornerRadius(3)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(Format.height(jump.height, unit: units.distance))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let metres = value.as(Double.self) {
                            Text(Format.height(metres, unit: units.distance))
                        }
                    }
                }
            }
            // Room for the trailing label, which otherwise clips the tallest
            // bar — the one anybody looking at this came to see.
            .chartXScale(domain: 0...(summary.jumpSummary.bestHeight * 1.35))
            .frame(height: max(90, Double(jumps.count) * 22))

            Text("Paler bars are the ones the app is less sure of.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .cardChrome()
    }

    /// Where they happened.
    ///
    /// Riders know their own water: "all of them off the sandbar" or "every
    /// one on the way back in" is a thing the map says in a second and the
    /// table cannot say at all. The track is drawn faint so the marks read as
    /// the subject, sized by height so the big one is findable.
    private var jumpMap: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Where")

            Map(initialPosition: .region(region)) {
                MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                    .stroke(.gray.opacity(0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                ForEach(jumps) { jump in
                    if let coordinate = coordinate(of: jump) {
                        Annotation("", coordinate: coordinate, anchor: .center) {
                            Circle()
                                .fill(.tint.opacity(0.75))
                                .stroke(.white, lineWidth: 1.5)
                                .frame(width: markSize(jump), height: markSize(jump))
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)

            Text("Bigger circles are higher jumps.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .cardChrome()
    }

    private func coordinate(of jump: Jump) -> CLLocationCoordinate2D? {
        let middle = (jump.startIndex + jump.endIndex) / 2
        guard session.track.points.indices.contains(middle) else { return nil }
        let point = session.track.points[middle]
        guard point.hasValidPosition else { return nil }
        return point.clCoordinate
    }

    private func markSize(_ jump: Jump) -> Double {
        let best = max(0.01, summary.jumpSummary.bestHeight)
        return 9 + 11 * min(1, jump.height / best)
    }

    /// Framed on the jumps rather than on the session: a rider who jumped in
    /// one corner of a long downwinder wants that corner, not the whole run.
    private var region: MKCoordinateRegion {
        let marks = jumps.compactMap(coordinate(of:))
        guard !marks.isEmpty else {
            return MKCoordinateRegion(
                center: session.track.points.first?.clCoordinate
                    ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        }
        let lats = marks.map(\.latitude), lons = marks.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.004, (maxLat - minLat) * 1.5),
                                   longitudeDelta: max(0.004, (maxLon - minLon) * 1.5)))
    }

    private func jumpRow(_ jump: Jump) -> some View {
        HStack(spacing: 10) {
            Text(Format.shortDuration(jump.airtime))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 56, alignment: .leading)

            Text(Format.height(jump.height, unit: units.distance))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Format.speed(jump.takeoffSpeed, unit: units.speed, decimals: 1, includeSymbol: false)) → \(Format.speed(jump.landingSpeed, unit: units.speed, decimals: 1))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("\(Int((jump.landingRetention * 100).rounded()))% kept")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ConfidenceMark(confidence: jump.confidence)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Foiling

/// The session's flights, one row each.
///
/// `summary.flights` carried distance, average and top speed, and the speeds
/// at takeoff and landing for every flight — and drew as a row of green ticks
/// on the speed chart. The ticks say *when*; this says what each one was.
struct FoilingScreen: View {

    @State private var session: Session
    @State private var summary: SessionSummary
    let units: UnitPreferences
    var onEdit: () -> Void = {}

    /// The parent's copy and its revision — see `SessionDetailView.revision`.
    /// Local state above lets this screen re-analyse in place; a new revision
    /// means the parent re-read the session, and the local copy yields to it.
    private let incoming: (session: Session, summary: SessionSummary)
    var revision: Int = 0

    init(session: Session, summary: SessionSummary, units: UnitPreferences,
         revision: Int = 0, onEdit: @escaping () -> Void = {}) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
        incoming = (session, summary)
        self.units = units
        self.revision = revision
        self.onEdit = onEdit
    }

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @State private var isRecomputing = false

    private var flights: [Flight] {
        summary.flights.sorted { $0.duration > $1.duration }
    }

    private func reanalyse() {
        isRecomputing = true
        Task {
            if let edited = await SessionReanalyser.reanalyse(session, settings: settings, library: library),
               let newSummary = edited.summary {
                session = edited
                summary = newSummary
            }
            isRecomputing = false
        }
    }

    var body: some View {
        foiling
            .onChange(of: revision) { _, _ in
                session = incoming.session
                summary = incoming.summary
            }
    }

    private var foiling: some View {
        AnalysisDetail(title: "Foiling") {
            FoilSummaryCard(
                foil: summary.foil,
                falls: summary.fallSummary,
                units: units,
                totalDistance: summary.distance,
                takeoffThreshold: session.effectiveFoilTakeoffSpeed,
                onChangeThreshold: onEdit
            )
            .cardChrome()

            if !flights.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Every flight") {
                        Text("longest first")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(flights.enumerated()), id: \.element.id) { position, flight in
                            if position > 0 { Divider() }
                            flightRow(flight)
                        }
                    }
                }
                .cardChrome()
            }

            AnalysisFooter(
                session: session,
                summary: summary,
                // Without the accelerometer a flight is a speed inference.
                needs: [.motionData],
                isBusy: isRecomputing,
                onReanalyse: reanalyse
            ) {
                ThresholdSlider(
                    title: "Flying above",
                    value: settings.thresholdBinding(for: session.sport, \.foilTakeoffSpeed,
                                                     default: session.sport.thresholds.foilTakeoffSpeed),
                    range: 2...12, step: 0.1,
                    format: { Format.speed($0, unit: units.speed, decimals: 1) },
                    note: "The speed at which your foil is carrying you. It decides time on foil, the flight count and the dry-gybe rate. Raise it if the app thinks you are flying while you are still taxiing; lower it if long glides are being missed.",
                    onCommit: reanalyse
                )
            }
        }
    }

    private func flightRow(_ flight: Flight) -> some View {
        HStack(spacing: 10) {
            Text(Format.shortDuration(flight.duration))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 56, alignment: .leading)

            Text(Format.distance(flight.distance, unit: units.distance))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Format.speed(flight.averageSpeed, unit: units.speed, decimals: 1)) avg · \(Format.speed(flight.maxSpeed, unit: units.speed, decimals: 1, includeSymbol: false)) top")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("up at \(Format.speed(flight.takeoffSpeed, unit: units.speed, decimals: 1))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ConfidenceMark(confidence: flight.confidence)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Confidence

/// Says when a detection is a guess.
///
/// Both jumps and flights carry a confidence, and it is low for a reason worth
/// telling the rider: without motion data the call rests on the speed trace
/// alone. Hiding the weak ones would flatter the numbers, and quietly listing
/// them alongside the certain ones would be worse — so the uncertain ones are
/// shown, marked.
struct ConfidenceMark: View {

    let confidence: Double

    var body: some View {
        if confidence < 0.5 {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Low confidence detection")
                .help("Detected from the speed trace alone")
        }
    }
}
