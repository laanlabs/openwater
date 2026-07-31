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
    private var samples: [(elapsed: TimeInterval, speed: Double, state: RideState)] {
        let target = 600
        let stride = max(1, session.track.count / target)
        guard stride > 1 else {
            return session.track.elapsed.indices.map {
                (session.track.elapsed[$0],
                 session.track.speed[$0],
                 summary.states[safe: $0] ?? .riding)
            }
        }

        var result: [(TimeInterval, Double, RideState)] = []
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
                summary.states[safe: peakIndex] ?? .riding
            ))
            i = end
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SPEED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart {
                // Shade the flights, so time on foil is readable straight off
                // the speed trace.
                ForEach(summary.flights) { flight in
                    RectangleMark(
                        xStart: .value("From", flight.startElapsed / 60),
                        xEnd: .value("To", flight.endElapsed / 60)
                    )
                    .foregroundStyle(.green.opacity(0.12))
                }

                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(
                        x: .value("Minutes", sample.elapsed / 60),
                        y: .value("Speed", units.speed.convert(fromMetresPerSecond: sample.speed))
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.tint)
                }

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
            .chartXAxisLabel("minutes")
            .chartYAxisLabel(units.speed.symbol)
            .frame(height: 180)

            if !summary.flights.isEmpty {
                Text("Shaded green: on the foil. Red dots: falls.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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

            Text("Solid: what you held (90th percentile). Dashed: your single best in each band.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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

            LazyVGrid(columns: columns, spacing: 8) {
                if let tacking = polar.tackingAngle {
                    SummaryTile(label: "Tacking angle", value: String(format: "%.0f°", tacking))
                }
                if let gybing = polar.gybingAngle {
                    SummaryTile(label: "Gybing angle", value: String(format: "%.0f°", gybing))
                }
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
                SummaryTile(label: "Tack symmetry", value: "\(Int(polar.symmetry * 100))%")
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

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

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

/// GPS honesty, shown on every session rather than hidden in diagnostics.
struct QualityCard: View {

    let quality: TrackQuality
    let source: SpeedSource

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
