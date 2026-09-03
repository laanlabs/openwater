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
    @State private var enabled: Set<String> = []

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
                    ScrollStop { legend }
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
            // Seeded once the models are known, and only if a rider has not
            // already been in here changing them.
            if enabled.isEmpty {
                enabled = Set(outlook.models.filter { !$0.isComposite }.map(\.id))
            }
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
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
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
        .frame(height: 460)
    }

    /// The heavy white line: the mean of whatever is switched on.
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
            // A list, one model per line.
            //
            // These were chips wrapped by hand into rows of three, and the
            // wrapping was the whole problem: tvOS grows a focused chip and
            // the grown one overlapped its neighbours, so the row a rider was
            // on sat on top of the row below it. A column cannot collide with
            // itself, and up and down through a list is the one movement a
            // remote is unambiguously good at.
            VStack(spacing: 0) {
                ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                    ModelSwitch(model: model,
                                colour: Self.colour(index),
                                isOn: enabled.contains(model.id)) {
                        toggle(model)
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white)
                    .frame(width: 44, height: 8)
                Text(enabled.count == outlook.models.count
                     ? "Average of all of them"
                     : "Average of the \(enabled.count) switched on")
                    .font(.system(size: 24))
            }
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
/// A row with a box, not a chip. The chips it replaces had two faults at once:
/// tvOS grows the focused one, so a wrapped grid of them overlapped, and the
/// system's focused fill is near-white, so the white label on the focused chip
/// was white on white — the one line a rider was reading was the one line they
/// could not.
///
/// The colour swatch keeps its size and place in both states. It is the thing
/// an eye matches against a line on the chart, and a swatch that moved under
/// the press would break the match at the moment somebody is making it.
private struct ModelSwitch: View {

    let model: WindOutlook.Model
    let colour: Color
    let isOn: Bool
    let toggle: () -> Void

    @FocusState private var isFocused: Bool

    /// Dark on the focused row's light ground, white on the dark page.
    private var ink: Color { isFocused ? .black : .white }
    private var quietInk: Color {
        isFocused ? Color.black.opacity(0.55) : Color.white.opacity(0.55)
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 20) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 30, weight: .medium))
                    // The tick carries the model's own colour when it is on,
                    // so the box and the line on the chart are the same fact.
                    .foregroundStyle(isOn ? colour : quietInk)
                RoundedRectangle(cornerRadius: 3)
                    .fill(colour)
                    .frame(width: 44, height: 6)
                    .opacity(isOn ? 1 : 0.3)
                Text(model.label)
                    .font(.system(size: 26))
                    .foregroundStyle(isOn ? ink : quietInk)
                if model.isComposite {
                    // Worth saying: NBM already contains GFS and HRRR, so a
                    // rider counting it as a separate vote is counting the
                    // same physics twice. It is why this one starts off.
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
            .background(isFocused ? Color.white : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .animation(.easeOut(duration: 0.12), value: isOn)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
