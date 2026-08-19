import SwiftUI
import UIKit

// MARK: - The track

/// The wind ahead as one continuous strip: quarter-hour steps while a
/// rapid-update model still has them, hourly consensus after.
///
/// Two cards used to draw this — six hours at fifteen-minute grain, then a
/// day at hourly — which put the same wind on the screen twice at two
/// scales and left the rider to join them up. One strip with a change of
/// grain says it once. Every step carries the minutes it stands for, so the
/// axis stays linear in time straight through the handover: a quarter-hour
/// column is a quarter the width of an hourly one, and the detail near now
/// costs nothing in honesty.
struct WindTrack {

    struct Step: Identifiable {
        let id: Int
        let at: Date
        let speedKn: Double?
        let gustKn: Double?
        /// Degrees the wind comes from.
        let directionDeg: Double?
        /// How much time this column stands for — its width, in effect.
        let minutes: Double
        /// Whether this step wears the labels: the hour, the arrow and the
        /// two numbers. Four labels an hour is noise, not detail.
        let isHourMark: Bool
    }

    var steps: [Step] = []
    var timeZone: TimeZone?
    /// Where the quarter-hour data hands over to the hourly consensus. Nil
    /// when the strip is one grain the whole way — which is most of the
    /// world, since the rapid-update models are regional.
    var handover: Int?

    var isEmpty: Bool { !steps.contains { $0.speedKn != nil } }

    /// Full scale, gusts folded in — the caps have to fit under the same
    /// grid the bars are read against.
    var peakKn: Double {
        max(steps.flatMap { [$0.speedKn, $0.gustKn] }.compactMap { $0 }.max() ?? 1, 1)
    }

    /// Quarter-hour steps up to where they run out, then the hours that
    /// come after them.
    ///
    /// The two feeds overlap by design — the quarter-hour models publish
    /// six hours the hourly one also has — so the hourly side starts
    /// strictly after the last fine step rather than at its own first hour.
    static func make(nearTerm: NearTermWind, outlook: WindOutlook,
                     at now: Date = Date()) -> WindTrack {
        let zone = nearTerm.timeZone ?? outlook.timeZone
        var calendar = Calendar.current
        if let zone { calendar.timeZone = zone }

        var steps: [Step] = []
        // The quarter-hour run starts at the top of its own hour, so its
        // first steps can already be behind now. A strip that opens on a
        // moment that has been and gone is the one thing it must not do;
        // the step in progress stays, because it is this quarter hour.
        let current = now.addingTimeInterval(-15 * 60)
        for index in nearTerm.times.indices where nearTerm.times[index] >= current {
            let at = nearTerm.times[index]
            steps.append(Step(id: steps.count, at: at,
                              speedKn: nearTerm.speedsKn[safe: index] ?? nil,
                              gustKn: nearTerm.gustsKn[safe: index] ?? nil,
                              directionDeg: nearTerm.directions[safe: index] ?? nil,
                              minutes: 15,
                              isHourMark: calendar.component(.minute, from: at) == 0))
        }
        let fine = steps.count

        // Independent models only, matching the consensus the bars draw.
        let consensus = outlook.consensus
        let gusts = outlook.consensusGusts
        let directions = outlook.blendDirections(
            of: Set(outlook.models.filter { !$0.isComposite }.map(\.id)))
        // With no fine steps at all, the hour in progress is still the hour
        // to open on — hence an hour back rather than now.
        let after = steps.last?.at ?? now.addingTimeInterval(-3600)
        for hour in outlook.hours.indices where outlook.hours[hour] > after {
            steps.append(Step(id: steps.count, at: outlook.hours[hour],
                              speedKn: consensus[safe: hour] ?? nil,
                              gustKn: gusts[safe: hour] ?? nil,
                              directionDeg: directions[safe: hour] ?? nil,
                              minutes: 60, isHourMark: true))
        }

        return WindTrack(steps: steps, timeZone: zone,
                         handover: (fine > 0 && fine < steps.count) ? fine : nil)
    }
}

// MARK: - The chart

/// The strip itself: a pinned gutter of labels, and a scrolling timeline of
/// bars coloured by the wind they carry.
///
/// The colour is the map's own — `WindPalette`, the same ramp the wash and
/// the flow map wear — so a green afternoon means the same thing on this
/// card as it does under the pins. It is what makes the chart readable
/// before a single number is: shape says when, colour says how much.
struct WindTrackChart: View {

    let track: WindTrack
    /// The sky over a moment, as an SF Symbol name. Supplied by the caller,
    /// which already holds the detail fetch that knows it.
    var skySymbol: (Date) -> String? = { _ in nil }

    /// Points per minute of forecast — the one constant that sets the whole
    /// axis. An hour is 36 points whether it arrives as one column or four.
    private static let perMinute: CGFloat = 0.6
    private static let gutterWidth: CGFloat = 34
    private static let plotHeight: CGFloat = 78
    private static let rowSpacing: CGFloat = 3
    private static let labelHeight: CGFloat = 13
    private static let arrowHeight: CGFloat = 14
    private static let numberHeight: CGFloat = 14

    private var zone: TimeZone { track.timeZone ?? .current }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return calendar
    }

    private var peak: Double { track.peakKn }

    private var levels: [Double] {
        ChartGrid.levels(peak: peak, step: ChartGrid.interval(for: peak))
    }

    private func width(_ step: WindTrack.Step) -> CGFloat { step.minutes * Self.perMinute }

    private var contentWidth: CGFloat { track.steps.reduce(0) { $0 + width($1) } }

    /// The height of a value on the plot.
    private func height(_ knots: Double) -> CGFloat { Self.plotHeight * knots / peak }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            gutter
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    hourRow
                    skyRow
                    arrowRow
                    plot
                    numberRow(gusts: false)
                    numberRow(gusts: true)
                }
                .frame(width: contentWidth, alignment: .leading)
            }
        }
    }

    // MARK: The pinned side

    /// What the rows mean, held still while the wind scrolls past it. The
    /// knot levels belong here rather than on the plot: a scale that slides
    /// away with the data it measures is decoration.
    private var gutter: some View {
        VStack(alignment: .trailing, spacing: Self.rowSpacing) {
            Color.clear.frame(height: Self.labelHeight)
            Color.clear.frame(height: Self.labelHeight)
            Color.clear.frame(height: Self.arrowHeight)
            ZStack(alignment: .topTrailing) {
                ForEach(levels, id: \.self) { level in
                    Text("\(Int(level))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isKey(level) ? AnyShapeStyle(.tint)
                                         : AnyShapeStyle(.tertiary))
                        // Centred on its own rule, which sits at the top of
                        // the level's share of the plot.
                        .offset(y: Self.plotHeight - height(level) - 5)
                }
            }
            .frame(width: Self.gutterWidth, height: Self.plotHeight, alignment: .topTrailing)
            rowLabel("WIND")
            rowLabel("GUST")
        }
        .frame(width: Self.gutterWidth, alignment: .trailing)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(height: Self.numberHeight, alignment: .trailing)
    }

    /// The hour, in as few characters as a column can hold.
    ///
    /// `FormatStyle.hour(amPM: .omitted)` looked right and is not: dropping
    /// the meridiem from a twelve-hour locale leaves ICU's zero-padded
    /// form, so one in the afternoon read "01" — indistinguishable from one
    /// in the morning on a strip that runs past midnight. The numeral is
    /// built here instead, unpadded where the locale counts to twelve and
    /// padded where it counts to twenty-four, with the day's two anchors
    /// spelled out: midnight wears its weekday, noon says so.
    private func hourLabel(_ date: Date) -> String {
        let hour = calendar.component(.hour, from: date)
        if hour == 0 {
            return date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))
        }
        if uses24Hour { return String(format: "%02d", hour) }
        if hour == 12 { return "noon" }
        return String(hour % 12)
    }

    /// Midnight and noon, the two points a rider orients a scrolling day by.
    private func isAnchor(_ date: Date) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour == 0 || hour == 12
    }

    /// Whether this rider's locale counts hours to twenty-four.
    private var uses24Hour: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h")
            .contains("a")
    }

    /// Fifteen knots — the app's own firing line, the same number the map
    /// pins and every other chart call out.
    private func isKey(_ level: Double) -> Bool { abs(level - 15) < 0.01 }

    // MARK: The rows

    private var hourRow: some View {
        HStack(spacing: 0) {
            ForEach(track.steps) { step in
                Group {
                    if step.isHourMark {
                        let anchor = isAnchor(step.at)
                        Text(hourLabel(step.at))
                            .font(.system(size: 10, weight: anchor ? .heavy : .semibold))
                            .foregroundStyle(anchor ? AnyShapeStyle(.primary)
                                             : AnyShapeStyle(.secondary))
                            // Never truncated to its column: a quarter-hour
                            // cell is nine points wide and its neighbours
                            // are empty, so the label simply spans them.
                            .fixedSize()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: width(step), height: Self.labelHeight)
            }
        }
    }

    /// Every third hour, because sea breezes live and die by the sun and a
    /// glyph over every column would be weather wallpaper.
    ///
    /// Drawn in one colour, deliberately. The rest of the app renders these
    /// symbols multicolour, which on this card fails twice over: the
    /// multicolour cloud is very nearly white, so an overcast day showed no
    /// icons at all against the card behind them — and a yellow sun sitting
    /// above yellow eighteen-knot bars argues with the one thing colour is
    /// allowed to mean here, which is how hard it is blowing.
    private var skyRow: some View {
        HStack(spacing: 0) {
            ForEach(track.steps) { step in
                Group {
                    if step.isHourMark,
                       calendar.component(.hour, from: step.at) % 3 == 0,
                       let symbol = skySymbol(step.at) {
                        Image(systemName: symbol)
                            .font(.system(size: 11))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: width(step), height: Self.labelHeight)
            }
        }
    }

    private var arrowRow: some View {
        HStack(spacing: 0) {
            ForEach(track.steps) { step in
                Group {
                    if step.isHourMark, let direction = step.directionDeg {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(direction))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: width(step), height: Self.arrowHeight)
            }
        }
    }

    private var plot: some View {
        ZStack(alignment: .bottom) {
            rules
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(track.steps) { bar($0) }
            }
            midnights
        }
        .frame(width: contentWidth, height: Self.plotHeight, alignment: .bottom)
        // A floor under the bars, so the plot reads as a panel rather than
        // as marks floating on the card — and so the grid has something to
        // be drawn on. See `edge` for what keeps a pale bar visible on it.
        .background(Color.deepSurface, in: RoundedRectangle(cornerRadius: 6))
    }

    private var rules: some View {
        ZStack(alignment: .top) {
            ForEach(levels, id: \.self) { level in
                Rectangle()
                    .fill(isKey(level) ? AnyShapeStyle(Color.accentColor.opacity(0.55))
                          : AnyShapeStyle(Color(.systemGray2).opacity(0.4)))
                    .frame(height: isKey(level) ? 1.5 : 0.5)
                    .offset(y: Self.plotHeight - height(level))
            }
        }
        .frame(width: contentWidth, height: Self.plotHeight, alignment: .top)
    }

    /// A rule where the day turns over, so a strip that runs past bedtime
    /// says so in the chart and not only in the labels.
    private var midnights: some View {
        HStack(spacing: 0) {
            ForEach(track.steps) { step in
                Group {
                    if step.isHourMark, calendar.component(.hour, from: step.at) == 0 {
                        Rectangle()
                            .fill(Color(.systemGray).opacity(0.5))
                            .frame(width: 1)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: width(step), alignment: .leading)
            }
        }
        .frame(height: Self.plotHeight)
    }

    /// One column: the mean in its own colour, the gust above it in the
    /// colour that gust would be. A bar that gusts orange out of a green
    /// mean is the whole forecast in one glance.
    private func bar(_ step: WindTrack.Step) -> some View {
        let cell = width(step)
        let inset: CGFloat = step.minutes >= 60 ? 2.5 : 0.75
        let radius: CGFloat = step.minutes >= 60 ? 2.5 : 1
        let speed = step.speedKn
        let gust = step.gustKn.flatMap { gust in (speed.map { gust > $0 } ?? false) ? gust : nil }

        return VStack(spacing: 0) {
            if let gust, let speed {
                UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
                    .fill(colour(gust).opacity(0.5))
                    .frame(height: max(1, height(gust - speed)))
                    .overlay(alignment: .top) { edge(gust) }
            }
            if let speed {
                UnevenRoundedRectangle(topLeadingRadius: gust == nil ? radius : 0,
                                       topTrailingRadius: gust == nil ? radius : 0)
                    .fill(colour(speed))
                    .frame(height: max(2, height(speed)))
                    .overlay(alignment: .top) { edge(speed) }
            }
        }
        .frame(width: max(1, cell - inset * 2))
        .frame(width: cell, alignment: .bottom)
    }

    private func colour(_ knots: Double) -> Color {
        Color(uiColor: WindPalette.smooth(for: knots))
    }

    /// A hairline along the top of a bar, in a darker cut of the bar's own
    /// colour.
    ///
    /// The wash palette runs to white in light air — right on the map,
    /// where a calm should let the chart underneath show through, and
    /// useless on a card, where a four-knot bar was very nearly the same
    /// colour as the surface behind it. The edge gives every bar a top to
    /// be read against without touching the ramp itself, so a colour still
    /// means on this card exactly what it means under the pins.
    private func edge(_ knots: Double) -> some View {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        WindPalette.smooth(for: knots).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Rectangle()
            .fill(Color(red: red * 0.62, green: green * 0.62, blue: blue * 0.62))
            .frame(height: 1)
    }

    /// The two numbers Windy-style riders actually read off a strip — the
    /// mean in the type that carries, the gust half a step back so the pair
    /// never reads as one four-digit number.
    private func numberRow(gusts: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(track.steps) { step in
                Group {
                    if step.isHourMark, let value = gusts ? step.gustKn : step.speedKn {
                        Text("\(Int(value.rounded()))")
                            .font(.system(size: 10, weight: gusts ? .medium : .bold))
                            .foregroundStyle(gusts ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(.primary))
                            .fixedSize()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: width(step), height: Self.numberHeight)
            }
        }
    }
}
