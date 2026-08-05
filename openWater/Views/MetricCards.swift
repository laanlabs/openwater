import Charts
import OpenWaterCore
import SwiftUI

/// The speed-category grid.
///
/// Every tile is tappable and reports the time range its result came from, so
/// the map can show exactly where it happened. A headline number you cannot
/// locate on the water is a number you cannot check.
struct MetricGrid: View {

    let summary: SessionSummary
    let units: UnitPreferences
    var onSelect: (ClosedRange<TimeInterval>?) -> Void = { _ in }

    /// Categories the session was too short or too slow to satisfy, hidden by
    /// default.
    ///
    /// A twenty-minute session cannot have a one-hour average, and showing
    /// eight greyed-out tiles saying so pushes the numbers that *do* exist off
    /// the screen. They stay reachable — "not achieved" is information, and a
    /// rider working toward a nautical mile wants to know how close they got —
    /// but they should not be the first thing in view.
    @State private var showsUnachieved = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    private var achieved: [SpeedResult] { summary.speedResults.filter(\.isValid) }
    private var unachieved: [SpeedResult] { summary.speedResults.filter { !$0.isValid } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 8) {
                SummaryTile(
                    label: "Max",
                    value: Format.speed(summary.maxSpeed, unit: units.speed, decimals: 1)
                )
                SummaryTile(
                    label: "Distance",
                    value: Format.distance(summary.distance, unit: units.distance)
                )
                SummaryTile(
                    label: "Moving",
                    value: Format.duration(summary.movingTime)
                )
                SummaryTile(
                    label: "Avg moving",
                    value: Format.speed(summary.averageMovingSpeed, unit: units.speed, decimals: 1)
                )
            }

            Text("SPEED CATEGORIES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(achieved) { result in
                    CategoryTile(result: result, units: units) {
                        onSelect(result.startElapsed...result.endElapsed)
                    }
                }
            }

            if !unachieved.isEmpty {
                Button {
                    withAnimation(.snappy) { showsUnachieved.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsUnachieved ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text(showsUnachieved
                             ? "Hide \(unachieved.count) not reached"
                             : "\(unachieved.count) not reached this session")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showsUnachieved {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(unachieved) { result in
                            CategoryTile(result: result, units: units) {
                                onSelect(nil)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

struct SummaryTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One speed category. Unachieved categories are shown greyed rather than
/// hidden — "you did not go far enough for a nautical mile" is information.
struct CategoryTile: View {

    let result: SpeedResult
    let units: UnitPreferences
    let action: () -> Void

    @State private var showingExplanation = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text(result.category.shortName.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if result.isValid && result.confidence < 0.6 {
                        // Say so rather than presenting a soft number as firm.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                }

                if result.isValid {
                    Text(Format.speed(result.speed, unit: units.speed, decimals: 2, includeSymbol: false))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text(result.invalidReason?.displayName ?? "")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .opacity(result.isValid ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .onLongPressGesture { showingExplanation = true }
        .popover(isPresented: $showingExplanation) {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.category.displayName)
                    .font(.headline)
                Text(result.category.explanation)
                    .font(.callout)
                if result.isValid {
                    Divider()
                    Text("Set between \(Format.duration(result.startElapsed)) and \(Format.duration(result.endElapsed)) into the session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Confidence \(Int(result.confidence * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Speed chart

struct SpeedChart: View {

    let session: Session
    let summary: SessionSummary
    let units: UnitPreferences

    /// Downsample for drawing. A three-hour session is ten thousand points and
    /// Swift Charts will not draw that smoothly — but taking every nth point
    /// would clip the peaks, which are the whole story. So each bucket keeps its
    /// *maximum*, preserving every spike while cutting the point count.
    private var samples: [(elapsed: TimeInterval, speed: Double, state: RideState, course: Double)] {
        let target = 600
        let stride = max(1, session.track.count / target)
        guard stride > 1 else {
            return session.track.elapsed.indices.map {
                (session.track.elapsed[$0],
                 session.track.speed[$0],
                 summary.states[safe: $0] ?? .riding,
                 session.track.course[$0])
            }
        }

        var result: [(TimeInterval, Double, RideState, Double)] = []
        var i = 0
        while i < session.track.count {
            let end = min(i + stride, session.track.count)
            var peak = 0.0
            var peakIndex = i
            for k in i..<end where session.track.speed[k] > peak {
                peak = session.track.speed[k]
                peakIndex = k
            }
            result.append((
                session.track.elapsed[peakIndex],
                peak,
                summary.states[safe: peakIndex] ?? .riding,
                session.track.course[peakIndex]
            ))
            i = end
        }
        return result
    }

    /// Where the session's fastest sample sits on the trace.
    private var peak: (minutes: Double, speed: Double)? {
        let speeds = session.track.speed
        guard let index = speeds.indices.max(by: { speeds[$0] < speeds[$1] }),
              speeds[index] > 0 else { return nil }
        return (session.track.elapsed[index] / 60,
                units.speed.convert(fromMetresPerSecond: speeds[index]))
    }

    /// The plot's own units, so the lanes below can be positioned in them.
    private var displayMax: Double {
        max(units.speed.convert(fromMetresPerSecond: summary.maxSpeed), 1) * 1.08
    }

    /// Height of one activity lane, in y-axis units.
    private var laneHeight: Double { displayMax * 0.05 }

    @ChartContentBuilder
    private var trace: some ChartContent {
        ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
            LineMark(
                x: .value("Minutes", sample.elapsed / 60),
                y: .value("Speed", units.speed.convert(fromMetresPerSecond: sample.speed)),
                series: .value("Series", "Speed")
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(.tint)
        }
    }

    /// Velocity made good, as a second trace under the speed.
    ///
    /// The gap between the two lines is the point: it is the price of the
    /// angle being sailed. Speed alone flatters a beam reach; VMG is what the
    /// session was worth against the wind, and drawing them together shows
    /// exactly where a fast line was a slow course. Magnitude rather than
    /// signed, because a chart that dives below zero every time the rider
    /// turns downwind reads as falling when they are working.
    @ChartContentBuilder
    private var vmgTrace: some ChartContent {
        if let wind = session.effectiveWind {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Minutes", sample.elapsed / 60),
                    y: .value("Speed", units.speed.convert(
                        fromMetresPerSecond: wind.vmgMagnitude(speed: sample.speed, heading: sample.course))),
                    series: .value("Series", "VMG")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.gray.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
        }
    }

    /// Runs and flights as bars under the trace rather than shading over it.
    ///
    /// The shading answered "was I flying here?" at the cost of washing out the
    /// part of the chart the speeds are drawn in, and it could only ever show
    /// one thing at a time. Two thin lanes below the axis show flights *and*
    /// runs together and leave the trace alone. They live inside this chart, in
    /// negative y where no speed can go, because that is the only way to be
    /// certain they line up with it — a separate chart underneath drifts by the
    /// width of the y-axis labels.
    @ChartContentBuilder
    private var laneMarks: some ChartContent {
        ForEach(summary.runs) { run in
            RectangleMark(
                xStart: .value("From", run.startElapsed / 60),
                xEnd: .value("To", run.endElapsed / 60),
                yStart: .value("Lane", -laneHeight * 2.3),
                yEnd: .value("Lane", -laneHeight * 1.3)
            )
            .foregroundStyle(.blue.opacity(0.55))
            .cornerRadius(1)
        }
        ForEach(summary.flights) { flight in
            RectangleMark(
                xStart: .value("From", flight.startElapsed / 60),
                xEnd: .value("To", flight.endElapsed / 60),
                yStart: .value("Lane", -laneHeight),
                yEnd: .value("Lane", 0)
            )
            .foregroundStyle(.green.opacity(0.75))
            .cornerRadius(1)
        }
    }

    @ChartContentBuilder
    private var fallMarks: some ChartContent {
        ForEach(summary.fallSummary.falls) { fall in
            PointMark(
                x: .value("Minutes", fall.elapsed / 60),
                y: .value("Speed", 0)
            )
            .symbol(.circle)
            .symbolSize(28)
            .foregroundStyle(.red)
        }
    }

    /// The headline number, on the trace that produced it. It was printed at
    /// the top of the screen with nothing on the chart saying which spike it
    /// came from.
    @ChartContentBuilder
    private var peakMark: some ChartContent {
        if let peak {
            PointMark(
                x: .value("Minutes", peak.minutes),
                y: .value("Speed", peak.speed)
            )
            .symbol(.circle)
            .symbolSize(70)
            .foregroundStyle(.red)
            .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text(Format.speed(summary.maxSpeed, unit: units.speed, decimals: 1))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SPEED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart {
                vmgTrace
                trace
                laneMarks
                fallMarks
                peakMark
            }
            // Room below zero for the lanes, without letting them shrink the
            // speed trace into the top half of the plot.
            .chartYScale(domain: -laneHeight * 2.6 ... displayMax)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    if let speed = value.as(Double.self), speed >= 0 {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
            }
            .chartXAxisLabel("minutes")
            .chartYAxisLabel(units.speed.symbol)
            .frame(height: 200)

            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            if !summary.flights.isEmpty {
                LaneKey(colour: .green.opacity(0.75), label: "On foil")
            }
            if !summary.runs.isEmpty {
                LaneKey(colour: .blue.opacity(0.55), label: "Runs")
            }
            if !summary.fallSummary.falls.isEmpty {
                LaneKey(colour: .red, label: "Falls", isDot: true)
            }
            if session.effectiveWind != nil {
                LaneKey(colour: .gray.opacity(0.55), label: "VMG")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct LaneKey: View {
    let colour: Color
    let label: String
    var isDot = false

    var body: some View {
        HStack(spacing: 4) {
            if isDot {
                Circle().fill(colour).frame(width: 6, height: 6)
            } else {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(colour)
                    .frame(width: 14, height: 5)
            }
            Text(label)
        }
    }
}

// MARK: - Polar

struct PolarChart: View {

    let polar: PolarAnalysis
    let units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("POLAR")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                WindSourceBadge(wind: polar.wind)
            }

            Chart {
                ForEach(polar.bins.filter(\.isSubstantial)) { bin in
                    LineMark(
                        x: .value("Angle", bin.angle),
                        y: .value("Speed", units.speed.convert(fromMetresPerSecond: bin.p90Speed)),
                        series: .value("Series", "Typical")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.tint)
                }
                ForEach(polar.bins.filter(\.isSubstantial)) { bin in
                    LineMark(
                        x: .value("Angle", bin.angle),
                        y: .value("Speed", units.speed.convert(fromMetresPerSecond: bin.maxSpeed)),
                        series: .value("Series", "Best")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.tint.opacity(0.35))
                    .lineStyle(StrokeStyle(dash: [3, 3]))
                }
            }
            .chartXScale(domain: 0...180)
            .chartXAxis {
                AxisMarks(values: [0, 45, 90, 135, 180]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let angle = value.as(Double.self) {
                            Text("\(Int(angle))°")
                        }
                    }
                }
            }
            .chartXAxisLabel("true wind angle")
            .chartYAxisLabel(units.speed.symbol)
            .frame(height: 180)

            // What the chart is, not only how to read it. "Polar" is a sailing
            // word, and a rider who has not met it sees two curves against an
            // axis labelled in degrees and has no way in.
            Text("""
            How fast you went at each angle to the wind. 0° is straight upwind,             90° is across it, 180° is straight downwind — so the shape shows             where this board and this wing actually work.

            Solid: what you held (90th percentile). Dashed: your single best in             each band. Angles you spent less than 100 m at are left out.
            """)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Why there is no polar for a sport that has no wind angle.
///
/// The card used to be absent with nothing in its place, which reads as a bug:
/// a rider who has seen a polar on one session and not on the next has no way
/// to tell whether the app lost it, is still working, or never had it. Sports
/// without a sail or a wing are the common case — this says so once and takes
/// no more room than that.
struct NoPolarCard: View {

    let sport: Sport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No polar for \(sport.displayName)", systemImage: "chart.dots.scatter")
                .font(.subheadline.weight(.medium))
            Text("A polar plots your speed against the angle you were riding to the wind, which only means something under a sail, a wing or a kite. On \(sport.displayName) your speed comes from the water rather than from a wind angle, so there is nothing to plot it against.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Wind provenance, always shown next to anything derived from it.
struct WindSourceBadge: View {
    let wind: Wind

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "wind")
                .font(.system(size: 9))
            Text(Format.bearing(wind.directionFrom))
                .font(.caption2)
            if wind.source.isEstimate {
                Text("· est \(Int(wind.confidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Cards

struct AngleSummary: View {

    let polar: PolarAnalysis
    let units: UnitPreferences

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ANGLES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            WindAngleRose(polar: polar)
                .frame(height: 190)
                .frame(maxWidth: .infinity)

            LazyVGrid(columns: columns, spacing: 8) {
                if let port = polar.upwindAngle(.port) {
                    SummaryTile(label: "Upwind · port", value: String(format: "%.0f° off wind", port))
                }
                if let stbd = polar.upwindAngle(.starboard) {
                    SummaryTile(label: "Upwind · starboard", value: String(format: "%.0f° off wind", stbd))
                }
                if let tacking = polar.tackingAngle {
                    SummaryTile(label: "Tacking through", value: String(format: "%.0f°", tacking))
                }
                if let gybing = polar.gybingAngle {
                    SummaryTile(label: "Gybing through", value: String(format: "%.0f°", gybing))
                }
                // Two different VMG claims, on purpose. "Best" is the polar's
                // single finest bin — one tack, no turning cost — which is the
                // number that flatters gear. "Beat" is net progress dead
                // upwind over the best full kilometre with both tacks in it,
                // which is the number that settles arguments.
                if let up = polar.bestUpwindVMG {
                    SummaryTile(
                        label: "Best VMG up",
                        value: Format.speed(up.vmg, unit: units.speed, decimals: 1)
                    )
                }
                if let down = polar.bestDownwindVMG {
                    SummaryTile(
                        label: "Best VMG down",
                        value: Format.speed(down.vmg, unit: units.speed, decimals: 1)
                    )
                }
                if let beat = polar.beat {
                    SummaryTile(
                        label: "Beat VMG · both tacks",
                        value: Format.speed(beat.vmg, unit: units.speed, decimals: 1)
                    )
                }
                if let run = polar.broadRun {
                    SummaryTile(
                        label: "Run VMG · both tacks",
                        value: Format.speed(run.vmg, unit: units.speed, decimals: 1)
                    )
                }
                SummaryTile(label: "Tack symmetry", value: "\(Int(polar.symmetry * 100))%")
            }

            if polar.beat != nil {
                Text("Beat and run VMG are measured over your best continuous kilometre with real distance on both tacks — turning cost included, single-tack wind-shift flattery excluded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let weaker = polar.weakerTack, polar.tackSpeedDelta > 0.08 {
                Label(
                    "Your \(weaker.displayName.lowercased()) tack is \(Int(polar.tackSpeedDelta * 100))% slower. That is the side worth practising.",
                    systemImage: "lightbulb"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// The session's mean courses, drawn against the wind.
///
/// Wind-up rather than north-up: the wind blows straight down the page, so
/// "how high did I point" reads directly — the closer a spoke is to vertical,
/// the higher the angle. This is how riders sketch it on a whiteboard, and it
/// makes two sessions comparable at a glance regardless of where the wind
/// actually sat.
struct WindAngleRose: View {

    let polar: PolarAnalysis

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 26

            // Rings and the wind axis.
            for f in [0.5, 1.0] {
                let r = radius * f
                context.stroke(
                    Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(.secondary.opacity(0.18)), lineWidth: 1
                )
            }
            var axis = Path()
            axis.move(to: CGPoint(x: centre.x, y: centre.y - radius))
            axis.addLine(to: CGPoint(x: centre.x, y: centre.y + radius))
            context.stroke(axis, with: .color(.secondary.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // The wind, arriving from the top.
            var arrow = Path()
            arrow.move(to: CGPoint(x: centre.x, y: centre.y - radius - 16))
            arrow.addLine(to: CGPoint(x: centre.x, y: centre.y - radius - 2))
            arrow.move(to: CGPoint(x: centre.x - 4, y: centre.y - radius - 7))
            arrow.addLine(to: CGPoint(x: centre.x, y: centre.y - radius - 2))
            arrow.addLine(to: CGPoint(x: centre.x + 4, y: centre.y - radius - 7))
            context.stroke(arrow, with: .color(.secondary), lineWidth: 1.5)
            context.draw(
                Text("wind").font(.system(size: 9)).foregroundStyle(.secondary),
                at: CGPoint(x: centre.x + 20, y: centre.y - radius - 10)
            )

            // Spokes: port drawn to the left of the axis, starboard right.
            func spoke(offWind: Double?, port: Bool, colour: Color, label: String) {
                guard let offWind else { return }
                // 0° off wind is straight up; port angles open leftward.
                let theta = (port ? -offWind : offWind) * .pi / 180
                let dx = sin(theta) * radius
                let dy = -cos(theta) * radius
                let end = CGPoint(x: centre.x + dx, y: centre.y + dy)
                var path = Path()
                path.move(to: centre)
                path.addLine(to: end)
                context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                let labelPoint = CGPoint(x: centre.x + dx * 1.16, y: centre.y + dy * 1.16)
                context.draw(
                    Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(colour),
                    at: labelPoint
                )
            }
            spoke(offWind: polar.upwindAngle(.port), port: true, colour: .red,
                  label: String(format: "%.0f°", polar.upwindAngle(.port) ?? 0))
            spoke(offWind: polar.upwindAngle(.starboard), port: false, colour: .green,
                  label: String(format: "%.0f°", polar.upwindAngle(.starboard) ?? 0))
            spoke(offWind: polar.downwindAngle(.port), port: true, colour: .red.opacity(0.5),
                  label: String(format: "%.0f°", polar.downwindAngle(.port) ?? 0))
            spoke(offWind: polar.downwindAngle(.starboard), port: false, colour: .green.opacity(0.5),
                  label: String(format: "%.0f°", polar.downwindAngle(.starboard) ?? 0))
        }
        .accessibilityLabel("Mean courses against the wind")
    }
}

struct FoilSummaryCard: View {

    let foil: FoilSummary
    let falls: FallSummary
    let units: UnitPreferences
    /// Session total, so the on-foil distance can be shown as a share.
    let totalDistance: Double
    /// The speed above which the detector counts the board as flying.
    let takeoffThreshold: Double
    /// Set to make the threshold adjustable from here.
    var onChangeThreshold: (() -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FOILING")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 8) {
                SummaryTile(label: "Time on foil", value: Format.duration(foil.timeOnFoil))
                SummaryTile(label: "Time %", value: "\(Int(foil.foilingFraction * 100))%")
                SummaryTile(
                    label: "Distance on foil",
                    value: Format.distance(foil.distanceOnFoil, unit: units.distance)
                )
                // Distance share is a different number from time share, and for
                // a foiler it is usually the flattering one — you cover far more
                // ground per minute up than down.
                SummaryTile(
                    label: "Distance %",
                    value: totalDistance > 0
                        ? "\(Int((foil.distanceOnFoil / totalDistance) * 100))%"
                        : "—"
                )
                SummaryTile(
                    label: "Avg speed on foil",
                    value: Format.speed(foil.averageFlightSpeed, unit: units.speed, decimals: 1)
                )
                SummaryTile(label: "Flights", value: "\(foil.flightCount)")
                if let longest = foil.longestFlight {
                    SummaryTile(label: "Longest flight", value: Format.duration(longest.duration))
                    SummaryTile(
                        label: "Longest segment",
                        value: Format.distance(longest.distance, unit: units.distance)
                    )
                }
                SummaryTile(
                    label: "Avg takeoff",
                    value: Format.speed(foil.averageTakeoffSpeed, unit: units.speed, decimals: 1)
                )
                if let first = foil.timeToFirstFlight {
                    SummaryTile(label: "Time to first foil", value: Format.shortDuration(first))
                }
                SummaryTile(label: "Falls", value: "\(falls.count)")
                SummaryTile(
                    label: "Longest clean run",
                    value: Format.duration(falls.longestCleanStreak)
                )
                if let recovery = falls.averageRecoveryTime {
                    SummaryTile(label: "Avg restart", value: Format.shortDuration(recovery))
                }
            }

            // The takeoff threshold is a judgement call, not a constant: a big
            // board on a big foil flies at a speed a small one is still
            // ploughing at. Saying what was used — and letting it be changed —
            // is the difference between a number a rider trusts and one they
            // argue with.
            if let onChangeThreshold {
                Button {
                    onChangeThreshold()
                } label: {
                    Text("Counting as flying above \(Format.speed(takeoffThreshold, unit: units.speed, decimals: 1)) · change")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            if !foil.usedMotionData {
                Label(
                    "No motion data in this session, so flights were inferred from speed alone. Recording on the watch gives a much better answer.",
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct DownwindCard: View {

    let downwind: DownwindSummary
    let units: UnitPreferences

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GLIDES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 8) {
                SummaryTile(label: "Glides", value: "\(downwind.glideCount)")
                // The time, not only the share of it. "Time on foil" is a
                // headline figure and its downwind counterpart was being shown
                // as a percentage of a duration printed on another screen.
                SummaryTile(label: "Time gliding", value: Format.duration(downwind.glideTime))
                SummaryTile(label: "Gliding", value: "\(Int(downwind.glideFraction * 100))%")
                if let longest = downwind.longestGlide {
                    SummaryTile(label: "Longest glide", value: Format.shortDuration(longest.duration))
                }
                SummaryTile(label: "Linked", value: "\(Int(downwind.connectionRate * 100))%")
                if let pumps = downwind.averagePumpsPerGlide {
                    SummaryTile(label: "Pumps per glide", value: String(format: "%.1f", pumps))
                }
                if let period = downwind.bumpPeriod {
                    SummaryTile(label: "Bump period", value: Format.shortDuration(period))
                }
            }

            Text("\"Linked\" is how often you reached the next glide without dropping off the foil.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ManeuverCard: View {

    let summary: ManeuverSummary
    /// The maneuvers themselves, for the outcome line — outcomes are derived
    /// per turn, not stored on the summary.
    var maneuvers: [Maneuver] = []

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    /// Turns that cross the wind — the ones "landed" is worth saying about.
    private var crossings: [Maneuver] {
        maneuvers.filter { $0.kind == .gybe || $0.kind == .tack }
    }

    private func count(_ outcome: Maneuver.Outcome) -> Int {
        crossings.filter { $0.outcome == outcome }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TURNS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 8) {
                SummaryTile(label: "Gybes", value: "\(summary.gybes)")
                SummaryTile(label: "Tacks", value: "\(summary.tacks)")
                if let dry = summary.dryGybeRate {
                    SummaryTile(label: "Dry gybes", value: "\(Int(dry * 100))%")
                }
                SummaryTile(label: "Avg speed loss", value: "\(Int(summary.meanSpeedLoss * 100))%")
                SummaryTile(label: "Best turn", value: "\(Int(summary.bestScore))")
            }

            // What happened through them, in the words a rider uses. "Landed"
            // counts clean and touchdown — coming out still sailing — against
            // the turns whose outcome is actually known; guessing about the
            // rest would make the number a lie.
            if !crossings.isEmpty {
                let known = crossings.filter { $0.outcome != .unknown }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count(.clean)) clean · \(count(.touchdown)) touchdowns · \(count(.blown)) blown"
                         + (count(.unknown) > 0 ? " · \(count(.unknown)) unknown" : ""))
                    if !known.isEmpty {
                        Text("Landed \(known.filter(\.isLanded).count) of \(known.count) \(known.count == 1 ? "turn" : "turns")")
                            .fontWeight(.medium)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let port = summary.scoreByExitTack[.port],
               let starboard = summary.scoreByExitTack[.starboard],
               abs(port - starboard) > 8 {
                Label(
                    "Your turns onto \(port < starboard ? "port" : "starboard") score \(Int(abs(port - starboard))) points lower.",
                    systemImage: "lightbulb"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// The upwind story: what working to windward was actually worth.
///
/// Modelled on the summary every analysis tool leads with — one representative
/// VMG with its working angle, and how it was earned (legs, distance, tack
/// balance) — rather than a single flattering segment.
struct UpwindCard: View {

    let polar: PolarAnalysis
    let runs: [Run]
    let units: UnitPreferences

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    /// Fastest upwind leg — best average speed of any run sailed above a beam
    /// reach.
    private var bestUpwindLeg: Run? {
        runs.filter { run in
            guard let twa = run.trueWindAngle else { return false }
            return abs(twa) < 90
        }
        .max { $0.averageSpeed < $1.averageSpeed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UPWIND")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if let beat = polar.beat {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(Format.speed(beat.vmg, unit: units.speed, decimals: 1,
                                              includeSymbol: false))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("\(units.speed.symbol) VMG")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        Text("made good over your best beat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(beatSubtitle(beat))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let angle = beat.meanAngle {
                        Text(String(format: "@ %.0f°", angle))
                            .font(.system(.title3, design: .monospaced).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }

            LazyVGrid(columns: columns, spacing: 8) {
                if let port = polar.upwindAngle(.port), let stbd = polar.upwindAngle(.starboard) {
                    SummaryTile(label: "Upwind angle", value: String(format: "%.0f°", (port + stbd) / 2))
                }
                if let tacking = polar.tackingAngle {
                    SummaryTile(label: "Tacking through", value: String(format: "%.0f°", tacking))
                }
                if let leg = bestUpwindLeg {
                    SummaryTile(
                        label: "Best leg",
                        value: Format.speed(leg.averageSpeed, unit: units.speed, decimals: 1)
                    )
                }
                if let run = polar.broadRun {
                    SummaryTile(
                        label: "Run VMG down",
                        value: Format.speed(run.vmg, unit: units.speed, decimals: 1)
                    )
                }
            }
        }
    }

    private func beatSubtitle(_ beat: PolarAnalysis.BothTacksVMG) -> String {
        var parts: [String] = []
        if let legs = beat.legs { parts.append("\(legs) \(legs == 1 ? "leg" : "legs")") }
        parts.append(Format.distance(beat.distance, unit: units.distance))
        parts.append("both tacks \(Int(beat.portShare * 100))/\(Int((1 - beat.portShare) * 100))")
        return parts.joined(separator: " · ")
    }
}

/// GPS honesty, shown on every session rather than hidden in diagnostics.
struct QualityCard: View {

    let quality: TrackQuality
    let source: SpeedSource
    /// Needed only to know what limit this session was *meant* to be held to,
    /// so a relaxed one can be reported rather than passed off as normal.
    let sport: Sport

    private var strictLimit: Double { sport.thresholds.maxHorizontalAccuracy }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GPS QUALITY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Gauge(value: quality.score, in: 0...100) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(quality.score))")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(gradeColour)

                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.grade.displayName)
                        .font(.subheadline.weight(.medium))
                    Text("\(source.displayName) speed · ±\(Int(quality.meanAccuracy)) m average")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if quality.dropoutCount > 0 {
                        Text("\(quality.dropoutCount) signal dropout\(quality.dropoutCount == 1 ? "" : "s"), \(Format.shortDuration(quality.dropoutDuration)) total")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Said out loud, because the alternative is what went wrong before:
            // a session quietly kept only its best fixes, drew the holes as
            // dropouts, and gave the rider no way to tell that the filter, not
            // the receiver, was what lost their afternoon.
            if let limit = quality.accuracyLimitUsed, limit > strictLimit {
                Text("Your device reported soft fixes for most of this session, so points up to ±\(Int(limit)) m were kept rather than dropping the recording. The track and distance are right; treat the peak speeds as indicative.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if source == .derived {
                Text("This track had no Doppler speed, so speeds were worked out from position changes. Peak figures are less reliable than a watch recording.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gradeColour: Color {
        switch quality.grade {
        case .excellent: .green
        case .good: .mint
        case .fair: .orange
        case .poor: .red
        }
    }
}

/// Shown on the charts tab when angles cannot be computed.
///
/// Everything angular — the polar, VMG, tacking and gybing angles, whether a
/// turn was a tack or a gybe — is measured from the wind. When openWater cannot
/// work it out from the track, those sections simply are not there, and a blank
/// gap reads as a bug rather than as a missing input. This explains which it is
/// and offers the one action that fixes it.
struct NoWindCard: View {

    let session: Session
    let onSetWind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No wind direction for this session", systemImage: "wind")
                .font(.subheadline.weight(.medium))

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Set the wind direction", systemImage: "pencil", action: onSetWind)
                .font(.callout)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var explanation: String {
        if let wind = session.effectiveWind, wind.confidence < 0.5 {
            return "openWater tried to work the wind out from the shape of your track but was not confident enough to use the answer (\(Int(wind.confidence * 100))%). Your polar, VMG and tacking angles all measure from the wind, so they are not shown. Set it by hand and they will appear."
        }
        return "Your polar, VMG, tacking and gybing angles are all measured from the wind direction. openWater normally works it out from the shape of your track, but this session did not have enough upwind and downwind sailing for that to be reliable. Set it by hand and the angle sections will appear."
    }
}
