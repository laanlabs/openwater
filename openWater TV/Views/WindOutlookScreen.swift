import Charts
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// Five days of wind, with every model drawn as its own line.
///
/// This is the screen a big display is actually for. The phone shows the same
/// comparison in a card two inches across, where six overlapping lines are a
/// smear; here they are separable, and the thing the chart exists to show —
/// *whether the models agree* — is readable from the far side of a room.
///
/// The rule the whole screen turns on: agreement is the forecast's confidence.
/// Six lines in a bundle on Saturday afternoon means Saturday afternoon is
/// close to settled. The same six fanned from eight knots to twenty-two means
/// nobody knows yet, and a rider who drives three hours on that spread has
/// been misled by a single averaged line that looked just as certain.
///
/// So the average is deliberately *not* the headline here. It is one heavier
/// line among the others, and the band behind them — the spread — carries the
/// actual message.
struct WindOutlookScreen: View {

    let here: Geo.Coordinate
    let placeName: String

    @State private var outlook = WindOutlook(hours: [], models: [])
    @State private var isLoading = true

    /// The models a rider has left switched on, by id.
    ///
    /// Empty until the outlook lands, then everything that is not a blend —
    /// the phone's compare screen makes the same choice for the same reason.
    /// NBM already contains GFS and HRRR, so averaging it in alongside them
    /// counts the same physics twice and then calls the double vote
    /// agreement. It is one press away for anyone who wants it drawn.
    /// The models being drawn. Up and down walk the list, Select toggles.
    @State private var enabled: Set<String> = []

    /// Which row the remote is on, held here rather than inside each row.
    ///
    /// This is the fix for the bug that made these checkboxes unusable: with
    /// a `@FocusState` Bool *inside* every row, all five drew as focused at
    /// once — five white capsules stacked over each other, with no telling
    /// which one Select would act on. One `@FocusState` on the parent, and
    /// each row told whether it is the one, cannot say yes five times.
    @FocusState private var focused: String?

    @Namespace private var page

    /// Five days. The models carry more, but their skill does not: past about
    /// five days the lines are a weather-shaped random number generator, and
    /// drawing them at the same weight as tomorrow says otherwise.
    private static let days = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                ScrollStop { header }
                    .prefersDefaultFocus(in: page)
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 420)
                } else if outlook.isEmpty {
                    ScrollStop {
                        Text("No model wind for this point.")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollStop { chart }
                    // Not a ScrollStop. That wrapper is `.focusable()`, and on
                    // tvOS an outer focusable view *is* the focus target: the
                    // remote lands on the whole block, the buttons inside it
                    // never get a turn, and the panel lights up as one — which
                    // read as "it selects them all". The rows are focusable in
                    // their own right, and a focused row is all a tvOS
                    // ScrollView needs to bring this section on screen. The
                    // padding matches what ScrollStop would have added, so the
                    // column still lines up.
                    legend
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                    ScrollStop { agreement }
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
            outlook = await OpenMeteo.outlook(at: here, days: Self.days)
            // Everything that is not a blend, once the models are known. NBM
            // already contains GFS and HRRR, so averaging it in beside them
            // counts the same physics twice and reads the double vote as
            // agreement; it is one press away for anyone who wants it drawn.
            if enabled.isEmpty {
                enabled = Set(outlook.models.filter { !$0.isComposite }.map(\.id))
            }
            // Seeded once the models are known, and only if a rider has not
            // already been in here changing them.

            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wind, five days")
                .font(.system(size: 56, weight: .bold))
            Text(placeName)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            if let stale = outlook.staleAge {
                // The one dishonesty worse than a blank chart is a stale
                // forecast posing as a fresh one.
                Label("Last good answer, \(Int(stale / 3600)) h old — the network did not reply",
                      systemImage: "wifi.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// One line per model, the consensus heavier, and the day boundaries
    /// marked — because "Saturday afternoon" is how a decision is actually
    /// phrased, and an unlabelled 120-hour axis is not.
    ///
    /// **The arrows under the lines.** Speed is half a forecast. Twenty knots
    /// is a session from the south-west and a wasted drive from the north at
    /// most of this app's launches, and a chart of speeds alone made a rider
    /// go back to the phone for the half that decides it. So under the zero
    /// line there is a row of arrows every three hours — the blend in white,
    /// like its line, then one row per model switched on, in that model's
    /// colour — the way iKitesurf lays its model table out. They live inside
    /// the chart rather than in a strip beneath it so every arrow is exactly
    /// under its hour; a separate view would drift from the plot by the
    /// width of the axis labels.
    ///
    /// Rows go below zero on the knots axis on purpose: the axis is told to
    /// label only the positive ticks, and the negative space is simply room.
    private var chart: some View {
        Chart {
            ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                ForEach(Array(model.speeds.enumerated()), id: \.offset) { hour, speed in
                    if let speed, hour < outlook.hours.count, enabled.contains(model.id) {
                        LineMark(
                            x: .value("Hour", outlook.hours[hour]),
                            y: .value("Knots", speed),
                            series: .value("Model", model.label)
                        )
                        .foregroundStyle(Self.colour(index))
                        .lineStyle(StrokeStyle(lineWidth: model.isComposite ? 4 : 2.5))
                        .opacity(0.85)
                    }
                }
            }
            // The blend, drawn last so it sits on top and heaviest. It is not
            // the answer — the spread is — but it is the line an eye follows.
            //
            // `blend(of:)` rather than `consensus`: the whole point of a
            // switch is that turning a model off changes the average, so you
            // can see what the answer looks like without the one you distrust
            // today. `consensus` always averages everything and would sit
            // there unmoved while the lines under it came and went.
            ForEach(Array(average.enumerated()), id: \.offset) { hour, speed in
                if let speed, hour < outlook.hours.count {
                    LineMark(
                        x: .value("Hour", outlook.hours[hour]),
                        y: .value("Knots", speed),
                        series: .value("Model", "Average")
                    )
                    .foregroundStyle(.white)
                    .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
                }
            }
            // The floor of the plot, drawn: below it are directions, not
            // speeds, and the eye needs telling where one stops.
            RuleMark(y: .value("Knots", 0))
                .foregroundStyle(.white.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 2))

            ForEach(Array(directionRows.enumerated()), id: \.element.id) { row, series in
                ForEach(Array(stride(from: 0, to: outlook.hours.count, by: Self.arrowEveryHours)),
                        id: \.self) { hour in
                    if let direction = series.directions[safe: hour] ?? nil {
                        PointMark(
                            x: .value("Hour", outlook.hours[hour]),
                            y: .value("Knots", rowY(row))
                        )
                        .symbol {
                            // `arrow.down` turned by the "from" bearing points
                            // where the air is going — the twelve-hour strip's
                            // convention, and the map's comets'.
                            Image(systemName: "arrow.down")
                                .font(.system(size: 21, weight: .bold))
                                .rotationEffect(.degrees(direction))
                                .foregroundStyle(series.colour)
                        }
                    }
                }
            }

            // Fifteen knots: this app's own "firing" line, and the only
            // horizontal a rider is really reading against.
            RuleMark(y: .value("Firing", 15))
                .foregroundStyle(Color.accentColor.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .annotation(position: .top, alignment: .leading) {
                    Text("15 kn")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
        }
        .chartYScale(domain: rowY(directionRows.count) ... yMax)
        .chartYAxis {
            // Only the speeds get ticks. The rows below zero are not knots.
            AxisMarks(values: Array(stride(from: 0.0, through: yMax, by: yMax > 30 ? 10 : 5))) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.12))
                AxisValueLabel {
                    if let knots = value.as(Double.self) {
                        Text("\(Int(knots))")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.25))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.weekday(.abbreviated))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: Self.plotHeight + Self.rowHeight * CGFloat(directionRows.count + 1))
    }

    /// The speed plot's own height, before the arrow rows are added under it.
    private static let plotHeight: CGFloat = 460
    /// One row of arrows, in points — large enough to read the bearing of a
    /// glyph from a sofa, which is what sets the every-three-hours spacing.
    private static let rowHeight: CGFloat = 44
    private static let arrowEveryHours = 3

    /// The top of the knots axis: the strongest thing drawn, to a round
    /// number, and never below twenty so a calm week still has a firing
    /// line with room above it.
    private var yMax: Double {
        let strongest = outlook.models
            .filter { enabled.contains($0.id) }
            .flatMap(\.speeds)
            .compactMap { $0 }
            .max() ?? 0
        return max(20, (strongest / 5).rounded(.up) * 5)
    }

    /// Where row `index` sits on the knots axis — below zero, one row height
    /// down per row. The conversion uses the plot's own scale so a row is
    /// the same height in points whatever the week's top speed is.
    private func rowY(_ index: Int) -> Double {
        -yMax * Double(Self.rowHeight) / Double(Self.plotHeight) * (Double(index) + 1)
    }

    /// The rows of arrows: the blend first, in white, then each model that is
    /// switched on, in the colour its line is drawn in.
    private struct DirectionRow: Identifiable {
        let id: String
        let colour: Color
        let directions: [Double?]
    }

    private var directionRows: [DirectionRow] {
        var rows = [DirectionRow(id: "average", colour: .white,
                                 directions: outlook.blendDirections(of: enabled))]
        for (index, model) in outlook.models.enumerated() where enabled.contains(model.id) {
            rows.append(DirectionRow(id: model.id, colour: Self.colour(index),
                                     directions: model.directions))
        }
        return rows
    }

    /// The heavy white line: the mean of whatever is switched on.
    /// The heavy white line: the mean of whatever is switched on. Not
    /// `consensus`, which always averages everything and would sit there
    /// unmoved while the lines under it came and went.
    private var average: [Double?] { outlook.blend(of: enabled) }

    /// Off is allowed; nothing is not. An empty chart is not a view anybody
    /// wanted, and there would be no line left to press to get back.
    private func toggle(_ model: WindOutlook.Model) {
        if enabled.contains(model.id) {
            if enabled.count > 1 { enabled.remove(model.id) }
        } else {
            enabled.insert(model.id)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MODELS")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)

            // A list, one model per line: up and down to walk it, Select to
            // switch a line on or off. Which row the remote is on is decided
            // by `focused` above, one level up from the rows — see there for
            // the bug that came of each row deciding for itself.
            VStack(spacing: 8) {
                ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                    ModelRow(model: model,
                             colour: Self.colour(index),
                             isOn: enabled.contains(model.id)) {
                        toggle(model)
                    }
                    .focused($focused, equals: model.id)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white)
                    .frame(width: 44, height: 8)
                Text(enabled.count == outlook.models.count
                     ? "Average of all of them"
                     : "Average of the \(enabled.count) switched on")
                    .font(.system(size: 24))
            }
            // The arrows explained once, here beside the swatches they share
            // colours with, rather than labelled row by row inside the plot
            // where a label would sit on top of the first arrows.
            Label("Arrows point where the wind is going, every three hours — the average in white, then each model in its colour.",
                  systemImage: "arrow.down.right")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
    }

    /// What the spread means, in words.
    ///
    /// The chart shows it and this says it, because the whole point of the
    /// screen is a judgement a glance should deliver: settled, or not yet.
    private var agreement: some View {
        let verdict = outlook.agreement
        return VStack(alignment: .leading, spacing: 10) {
            Text("HOW MUCH THEY AGREE")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verdict.label)
                .font(.system(size: 38, weight: .semibold))
            Text(verdict.detail)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Distinguishable at three metres and in the order the models arrive.
    /// Not the wind palette — that ramp means *speed* everywhere else in this
    /// app, and reusing it for identity would say a model is windy.
    static func colour(_ index: Int) -> Color {
        let wheel: [Color] = [.cyan, .orange, .green, .pink, .yellow, .purple, .mint, .red]
        return wheel[index % wheel.count]
    }
}

/// One model, and whether it is drawn.
///
/// The colour swatch keeps its size and place in both states. It is the thing
/// an eye matches against a line on the chart, and a swatch that moved under
/// the press would break the match at the moment somebody is making it.
private struct ModelRow: View {

    let model: WindOutlook.Model
    let colour: Color
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ModelRowLabel(model: model, colour: colour, isOn: isOn)
        }
        .buttonStyle(.plain)
    }
}

/// The row's face, and the reason it is a separate view.
///
/// `\.isFocused` is only set *inside* a focusable button's label — read one
/// level further out, where the `Button` itself lives, it is always false.
/// Two attempts at this row got that wrong, first by passing the parent's
/// comparison down as a `Bool` and then by reading the environment above the
/// button, and both times the row kept its white text under tvOS's light
/// focus halo and came out white on light. The favourites board has always
/// had this right — its row *is* the label — and this now matches it.
private struct ModelRowLabel: View {

    let model: WindOutlook.Model
    let colour: Color
    let isOn: Bool

    @Environment(\.isFocused) private var isFocused

    /// Dark on the focused row's light halo, white on the dark page.
    private var ink: Color { isFocused ? .black : .white }
    private var quietInk: Color {
        isFocused ? Color.black.opacity(0.55) : Color.white.opacity(0.55)
    }

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 30, weight: .medium))
                // The tick carries the model's own colour when it is on, so
                // the box and the line on the chart are the same fact. Off,
                // it is only an outline and follows the row's ink.
                .foregroundStyle(isOn ? colour : quietInk)
            RoundedRectangle(cornerRadius: 3)
                .fill(colour)
                .frame(width: 44, height: 6)
                .opacity(isOn ? 1 : 0.3)
            Text(model.label)
                .font(.system(size: 26))
                .foregroundStyle(isOn ? ink : quietInk)
            if model.isComposite {
                // Worth saying: NBM already contains GFS and HRRR, so a rider
                // counting it as a separate vote is counting the same physics
                // twice. It is why this one starts off.
                Text("blend")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(quietInk)
            }
            Spacer()
            Text(isOn ? "On" : "Off")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(quietInk)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        // Only the resting surface is drawn here. The focused one is the
        // system's halo, which is already the right shape and brightness —
        // a second one under it only made the row two different whites.
        .background(isFocused ? Color.clear : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}
