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
    /// Which model the chart is showing, or nil for all of them together.
    ///
    /// One value stepped through, rather than a set of switches. The switches
    /// were a row of checkboxes and every one of them drew as focused at once
    /// — five white capsules stacked over each other, so a rider could not
    /// tell what the remote was on or what Select would do. A single control
    /// cannot have that problem: there is one focus target, and pressing left
    /// or right moves along a list whose current value is written in the
    /// middle of it.
    ///
    /// The comparison is still the point of the screen, so "All models" is
    /// where it starts and where the cycle returns to.
    @State private var shown: String?

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
                    if let speed, hour < outlook.hours.count, isDrawn(model) {
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
    /// Everything that is not a blend, which is what "all models" means here.
    ///
    /// NBM already contains GFS and HRRR, so averaging it in beside them
    /// counts the same physics twice and reads the double vote as agreement.
    /// It is one press away on the cycle for anyone who wants to see it.
    private var comparable: [WindOutlook.Model] {
        outlook.models.filter { !$0.isComposite }
    }

    private func isDrawn(_ model: WindOutlook.Model) -> Bool {
        guard let shown else { return !model.isComposite }
        return model.id == shown
    }

    /// The heavy white line: the mean of the models being compared. It is not
    /// drawn at all while a single model is up, because the average of one
    /// thing is that thing, drawn twice.
    private var average: [Double?] {
        shown == nil ? outlook.blend(of: Set(comparable.map(\.id))) : []
    }

    /// The order the control steps through: all of them, then each in turn,
    /// then back to all.
    private var cycle: [String?] { [nil] + outlook.models.map(\.id) }

    private func step(by delta: Int) {
        guard !outlook.models.isEmpty else { return }
        let order = cycle
        let at = order.firstIndex(of: shown) ?? 0
        shown = order[(at + delta + order.count) % order.count]
    }

    /// What the control says it is showing.
    private var shownLabel: String {
        guard let shown else { return "All models" }
        return outlook.models.first { $0.id == shown }?.label ?? "All models"
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MODELS")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)

            // One control, stepped. See `shown` for what the checkboxes it
            // replaces got wrong.
            HStack(spacing: 24) {
                Button { step(by: -1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 26, weight: .semibold))
                }
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(shownColour)
                        .frame(width: 52, height: 8)
                    Text(shownLabel)
                        .font(.system(size: 30, weight: .medium))
                        .lineLimit(1)
                    if outlook.models.first(where: { $0.id == shown })?.isComposite == true {
                        // NBM already contains GFS and HRRR, so a rider
                        // counting it as a separate vote is counting the same
                        // physics twice. Said here because this is the one
                        // moment it is on screen alone.
                        Text("blend")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 420)
                Button { step(by: 1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 26, weight: .semibold))
                }
            }

            // The key, which is now a reading aid rather than a set of
            // controls: nothing here is pressable, so nothing here can steal
            // the focus from the one thing that is.
            HStack(spacing: 28) {
                ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.colour(index))
                            .frame(width: 34, height: 6)
                            .opacity(isDrawn(model) ? 1 : 0.25)
                        Text(model.label)
                            .font(.system(size: 22))
                            .foregroundStyle(isDrawn(model) ? .white : .secondary)
                    }
                }
            }

            if shown == nil {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white)
                        .frame(width: 44, height: 8)
                    Text("Average of all of them")
                        .font(.system(size: 24))
                }
            }
        }
    }

    /// The swatch beside the control: the model's own colour when one is up,
    /// white when the average is.
    private var shownColour: Color {
        guard let shown,
              let index = outlook.models.firstIndex(where: { $0.id == shown })
        else { return .white }
        return Self.colour(index)
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
