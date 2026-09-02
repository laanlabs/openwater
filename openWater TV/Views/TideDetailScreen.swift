import Charts
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The tide, as a curve and the four numbers that come off it.
///
/// A tide table is a list of times; a tide *curve* is the thing a rider
/// actually reasons with, because the question is never "when is high water"
/// on its own — it is "will there be water over the bar when I get there",
/// which is a shape between two turns rather than either turn.
///
/// The datum is stated, always. Two sources answer this and they do not share
/// one: NOAA's harmonic predictions at a named station are referenced to mean
/// lower low water, the marine model to mean sea level, and the same beach
/// reads about a metre apart between them. A curve with no datum on it is a
/// chart that invites a rider to compare two numbers that cannot be compared.
struct TideDetailScreen: View {

    let here: Geo.Coordinate
    let placeName: String

    @State private var curve = TideCurve(points: [])
    @State private var isLoading = true

    @Namespace private var page

    private var unit: DistanceUnit { UnitPreferences.forThisDevice.distance }

    /// How much of the curve is drawn.
    ///
    /// The sources hand over a week or more, and drawing all of it put
    /// fifteen tide cycles on one axis — the labels collided into a grey
    /// smear and the shape a rider actually reads, today's rise and fall,
    /// was a few pixels wide. Four days is the horizon somebody plans a
    /// weekend on, and half a day behind keeps the current cycle whole
    /// rather than starting the chart mid-fall.
    private static let daysAhead: TimeInterval = 4 * 24 * 3600
    private static let hoursBehind: TimeInterval = 12 * 3600

    private var windowStart: Date { Date().addingTimeInterval(-Self.hoursBehind) }
    private var windowEnd: Date { Date().addingTimeInterval(Self.daysAhead) }

    private var visiblePoints: [TideCurve.Point] {
        curve.points.filter { $0.at >= windowStart && $0.at <= windowEnd }
    }

    private var visibleTurns: [TideCurve.Turn] {
        curve.turns.filter { $0.at >= windowStart && $0.at <= windowEnd }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                ScrollStop { header }
                    .prefersDefaultFocus(in: page)
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else if curve.isEmpty {
                    ScrollStop {
                        Text("No tide model for this point.")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollStop { chart }
                    ForEach(upcoming) { turn in
                        ScrollStop { TurnRow(turn: turn, unit: unit) }
                    }
                    ScrollStop { datum }
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .focusScope(page)
        .background(Color.black.ignoresSafeArea())
        // White on the black this screen paints, stated rather than
        // inherited. `.primary` follows the system appearance, and on a
        // television set to Light that is black — black text on a black
        // background, which is exactly how this was reported. `.secondary`
        // and `.tertiary` below resolve against this, so they come right
        // with it.
        .foregroundStyle(.white)
        .menuBackHint()
        .task {
            isLoading = true
            curve = await Tides.curve(at: here)
            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tide")
                .font(.system(size: 56, weight: .bold))
            Text(placeName)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            if let now = curve.now {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Image(systemName: curve.isRising == true ? "arrow.up" : "arrow.down")
                        .font(.system(size: 40, weight: .semibold))
                    Text(Format.height(now.metres, unit: unit))
                        .font(.system(size: 100, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    if let state = stateWord {
                        Text(state)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var stateWord: String? {
        switch curve.isRising {
        case true?: "and rising"
        case false?: "and falling"
        default: nil
        }
    }

    /// The curve with its turns marked, and a line at now.
    ///
    /// An area rather than a stroke: the water is a quantity with a bottom,
    /// and a filled shape says "how much" in a way a line does not.
    private var chart: some View {
        Chart {
            ForEach(visiblePoints) { point in
                AreaMark(
                    x: .value("Time", point.at),
                    y: .value("Height", unit.heightValue(fromMetres: point.metres))
                )
                .foregroundStyle(.linearGradient(
                    colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(visiblePoints) { point in
                LineMark(
                    x: .value("Time", point.at),
                    y: .value("Height", unit.heightValue(fromMetres: point.metres))
                )
                .foregroundStyle(.white)
                .lineStyle(StrokeStyle(lineWidth: 4))
            }
            ForEach(visibleTurns) { turn in
                PointMark(
                    x: .value("Time", turn.at),
                    y: .value("Height", unit.heightValue(fromMetres: turn.metres))
                )
                .foregroundStyle(turn.isHigh ? Color.white : Color.cyan)
                .symbolSize(160)
            }
            RuleMark(x: .value("Now", Date()))
                .foregroundStyle(.white.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .annotation(position: .top) {
                    Text("Now")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.12))
                AxisValueLabel {
                    if let height = value.as(Double.self) {
                        Text(String(format: "%.1f", height))
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            // A label a day, and a plain gridline at noon between them.
            // Labelling every sixth hour over four days is thirty-two labels
            // on one axis, which is what turned the bottom of this chart into
            // a smear — and the hour of a tide is read off the rows below,
            // not squinted at off an axis.
            AxisMarks(values: .stride(by: .day)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.28))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.weekday(.abbreviated))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            AxisMarks(values: .stride(by: .hour, count: 12)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.10))
            }
        }
        .chartXScale(domain: windowStart ... windowEnd)
        .frame(height: 420)
    }

    /// The next four turns. Two would answer today; four covers "shall we go
    /// tomorrow morning instead", which is the question a television gets
    /// asked far more often than a phone on a beach does.
    private var upcoming: [TideCurve.Turn] {
        Array(curve.turns.filter { $0.at > Date() }.prefix(6))
    }

    private var datum: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHERE THESE NUMBERS COME FROM")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            switch curve.source {
            case .station(let name, let metres):
                Text("\(name), \(Format.distance(metres, unit: unit)) away — NOAA harmonic predictions, referenced to mean lower low water.")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .model:
                Text("Marine model, referenced to mean sea level. A named tide station would be more exact; there is not one within range of this point.")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One turn: high or low, when, and how far off it is.
private struct TurnRow: View {

    let turn: TideCurve.Turn
    let unit: DistanceUnit

    var body: some View {
        HStack(spacing: 28) {
            Image(systemName: turn.isHigh ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(turn.isHigh ? Color.white : Color.cyan)
            Text(turn.isHigh ? "High" : "Low")
                .font(.system(size: 30, weight: .medium))
                .frame(width: 110, alignment: .leading)
            Text(turn.at, format: .dateTime.weekday(.abbreviated).hour().minute())
                .font(.system(size: 30))
                .monospacedDigit()
            Spacer()
            Text(Format.height(turn.metres, unit: unit))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(turn.at, style: .relative)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 240, alignment: .trailing)
        }
    }
}
