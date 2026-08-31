import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The tide, laid out the way the forecast screen lays out the wind.
///
/// This was a full-screen chart and nothing else: a curve you scrubbed under
/// a fixed line, with a readout on top. The scrubbing is the best thing on
/// it and stays. What it never had is the furniture that makes the forecast
/// screen answer questions rather than just draw — a day to pick, the hours
/// of that day as numbers you can read down, the highs and lows as a table,
/// and every day at a glance underneath. A tide chart is a shape; a tide
/// *table* is what a rider actually plans a session from, and the two belong
/// on the same screen.
///
/// So it is a pushed detail screen of cards now, in the forecast screen's own
/// order: what it is doing, the picture, the day switch, the numbers, then
/// the week. Anything the forecast screen does twice — a segmented day
/// picker, a card of rows with dividers, a bar per day — is done the same way
/// here on purpose, because two screens a tap apart that behave differently
/// are two screens a rider has to learn.
///
/// **Everything below the chart is its own `Equatable` view.** Scrubbing
/// changes one number, and this screen holds ten days of tide: three tables,
/// a hundred-odd rows, and a curve two thousand points wide rasterised into
/// one layer. Left in a single `body`, every sample the reading line crossed
/// rebuilt all of it, which is exactly what a dragging finger feels. The
/// cards take the state they actually depend on — the curve, the chosen day,
/// the span — so a scrub re-renders the readout and the dot and nothing else.
struct TideScreen: View {

    let curve: TideCurve
    let title: String

    @Environment(AppSettings.self) private var settings

    /// The point under the reading line.
    @State private var probe: Int?
    @State private var scroll = ScrollPosition()
    @State private var hasLanded = false
    /// Which day the tables below are speaking for. Tied to the chart in both
    /// directions: picking a day scrolls the water to it, and scrubbing the
    /// water past midnight moves the picker.
    @State private var day = 0
    @State private var span: Span = .day
    /// Whether the water is moving because a finger is moving it.
    ///
    /// The chart and the day picker drive each other, which is the point —
    /// and was very nearly a loop: picking Thursday animated the scroll,
    /// every intermediate frame of that animation reported a sample still
    /// inside Wednesday, and the picker snapped itself back to Today while
    /// the chart slid to Wednesday midnight. So the picker only follows the
    /// water when a rider is the one moving it.
    @State private var isDragging = false
    /// Worked out once when the curve lands rather than on every body pass.
    ///
    /// Both are walks of the whole run, and the run is ten days long; a
    /// scrubbing finger asks for a new body several times a second, and
    /// neither answer changes between one sample and the next.
    @State private var days: [Date] = []
    @State private var nowIndex: Int?

    enum Span: String, CaseIterable { case day = "Day", all = "All days" }

    /// Screen width per hourly sample.
    ///
    /// Widened with the horizon: four days at six points an hour fits in
    /// about two screens, which makes a scrollable chart that barely needs
    /// scrolling and crushes each tide into a spike. Twelve gives a day about
    /// a screen and a half, so the shape is legible and the scroll is worth
    /// the gesture.
    static let pointWidth: CGFloat = 12
    private static let chartHeight: CGFloat = 186

    private var zone: TimeZone { curve.timeZone ?? .current }
    private var calendar: Calendar { TideMath.calendar(in: zone) }
    private var unit: DistanceUnit { settings.units.distance }

    private var plot: TidePlot { TidePlot(curve: curve) }

    private var reading: TideCurve.Point? {
        probe.flatMap { curve.points[safe: $0] } ?? curve.now
    }

    private var selectedDay: Date? { days[safe: day] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stateCard
                curveCard
                dayPicker

                TideTurnsCard(curve: curve, selectedDay: span == .day ? selectedDay : nil,
                              unit: unit, zone: zone, calendar: calendar)
                    .equatable()

                TideHoursCard(curve: curve, selectedDay: span == .day ? selectedDay : nil,
                              unit: unit, zone: zone, calendar: calendar)
                    .equatable()

                TideDaysCard(curve: curve, days: days, selected: day,
                             unit: unit, zone: zone, calendar: calendar) { index in
                    withAnimation(.snappy) {
                        span = .day
                        day = index
                    }
                }
                .equatable()

                sourceNote
            }
            .padding(16)
            .frame(maxWidth: 700)
            .containerRelativeFrame(.horizontal)
        }
        .background(Color.deepSurface)
        .navigationTitle("Tide")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Tide")
    }

    // MARK: What it is doing

    /// The forecast screen opens with its verdict — do the models agree —
    /// and this opens with the tide's: where the water is and which way it is
    /// going, with the turn it is heading for and how long that is away.
    @ViewBuilder
    private var stateCard: some View {
        if let now = curve.now {
            let rising = curve.isRising ?? true
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: rising ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(rising ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(rising ? "Coming in" : "Going out")
                        .font(.headline)
                    Spacer(minLength: 0)
                    Text(Format.height(now.metres, unit: unit))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                }
                Text(nextTurnLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var nextTurnLine: String {
        guard let next = curve.nextTurn else {
            return "No turn inside the run this curve covers."
        }
        let when = next.at.formatted(Date.FormatStyle(timeZone: zone).hour().minute())
        let height = Format.height(next.metres, unit: unit)
        return "\(next.isHigh ? "High" : "Low") water \(height) at \(when), \(away(next.at)) from now."
    }

    /// How far off a turn is, in words.
    ///
    /// Not `Format.duration`: that is a stopwatch — `12:43` for a turn
    /// thirteen minutes away reads as a quarter to one, which is the one
    /// thing a tide sentence must not say.
    private func away(_ date: Date) -> String {
        let minutes = Int((date.timeIntervalSinceNow / 60).rounded())
        guard minutes >= 1 else { return "less than a minute" }
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    // MARK: The picture

    /// The curve, scrubbed under a line that does not move.
    ///
    /// The interaction is the model comparison's and stays exactly as it was:
    /// the reading line is fixed to the screen, the water slides under it,
    /// and whatever sits beneath it is what the numbers above read out. What
    /// changed is that it is a card in a column now rather than half a
    /// screen of its own, so the tables can sit under it.
    private var curveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reading {
                Text(reading.at.formatted(Date.FormatStyle(timeZone: zone)
                    .weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.height(reading.metres, unit: unit))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text(TideMath.rising(in: curve, at: probe) ? "rising" : "falling")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            chart
                .frame(height: Self.chartHeight)

            HStack(spacing: 10) {
                Label {
                    Text("Now").font(.caption2)
                } icon: {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                }
                Label {
                    Text("Reading").font(.caption2)
                } icon: {
                    Circle().fill(.teal).frame(width: 7, height: 7)
                }
                Spacer(minLength: 0)
                Text("Scroll the water under the line")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var chart: some View {
        GeometryReader { outer in
            let height = outer.size.height

            ZStack {
                GeometryReader { viewport in
                    let half = viewport.size.width / 2
                    ScrollView(.horizontal, showsIndicators: true) {
                        // The water itself, and nothing that changes while it
                        // is being dragged — see the note on this type.
                        TideTrack(points: curve.points, plot: plot, height: height,
                                  nowIndex: nowIndex, calendar: calendar)
                            .equatable()
                            .padding(.horizontal, half)
                    }
                    .scrollPosition($scroll)
                    // Transformed to the sample index rather than to the raw
                    // offset: the action runs only when the value changes, and
                    // the header can only read out one sample. Reported as a
                    // distance it fired on every pixel of a drag and rebuilt
                    // this whole view each time.
                    .onScrollGeometryChange(for: Int.self) { geometry in
                        let index = Int(geometry.contentOffset.x / TideScreen.pointWidth + 0.5)
                        return min(max(0, index), max(0, curve.points.count - 1))
                    } action: { _, index in
                        probe = index
                        follow(index)
                    }
                    .onScrollPhaseChange { _, phase in
                        isDragging = phase == .tracking
                            || phase == .interacting
                            || phase == .decelerating
                    }
                    .onChange(of: curve.points.count, initial: true) { _, _ in
                        days = TideMath.days(in: curve, calendar: calendar)
                        nowIndex = TideMath.nowIndex(in: curve)
                        guard !hasLanded, let now = nowIndex else { return }
                        hasLanded = true
                        scroll.scrollTo(x: CGFloat(now) * TideScreen.pointWidth)
                    }
                }

                // Fixed to the screen, not to the water.
                Rectangle()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: 1)
                    .allowsHitTesting(false)

                // The reading, where that line crosses the curve. It rides
                // the fixed line rather than the water, so it stays under the
                // eye while the tide slides beneath it — and it is the height
                // printed above the chart, put back on the shape it came
                // from.
                if let metres = reading?.metres {
                    Circle()
                        .fill(.teal)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .frame(width: 13, height: 13)
                        .position(x: outer.size.width / 2, y: plot.y(of: metres, in: height))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Scrubbing past midnight moves the day picker with it, so the tables
    /// under the chart are always about the water under the line.
    private func follow(_ index: Int) {
        guard isDragging,
              let at = curve.points[safe: index]?.at,
              let found = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: at) }),
              found != day
        else { return }
        day = found
    }

    // MARK: The day

    /// Up to five days is the forecast screen's segmented control, unchanged.
    /// Past that it has to be a strip: a tide run is ten days long — the moon
    /// is arithmetic, not a forecast, so the horizon is what a rider plans to
    /// rather than what a model can hold — and ten segments in a phone's
    /// width is ten unreadable slivers.
    @ViewBuilder
    private var dayPicker: some View {
        if days.count > 1 {
            VStack(spacing: 10) {
                if days.count <= 5 {
                    HStack(spacing: 10) {
                        Picker("Day", selection: $day) {
                            ForEach(days.indices, id: \.self) { index in
                                Text(TideMath.shortLabel(for: days[index], calendar: calendar, zone: zone))
                                    .tag(index)
                            }
                        }
                        .pickerStyle(.segmented)

                        spanPicker.frame(width: 150)
                    }
                } else {
                    spanPicker
                    dayStrip
                }
            }
            .onChange(of: day) { _, index in
                // Picking a day carries the water to it — the chart is the
                // same answer as the table, and they must never disagree
                // about which day is on screen.
                guard span == .day, let date = days[safe: index],
                      let first = curve.points.firstIndex(where: {
                          calendar.isDate($0.at, inSameDayAs: date)
                      })
                else { return }
                withAnimation(.snappy) {
                    scroll.scrollTo(x: CGFloat(first) * TideScreen.pointWidth)
                }
            }
        }
    }

    private var spanPicker: some View {
        Picker("Span", selection: $span) {
            ForEach(Span.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    /// The days as chips, scrolled to keep the chosen one in sight.
    private var dayStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days.indices, id: \.self) { index in
                        let isOn = index == day
                        Button {
                            withAnimation(.snappy) { day = index }
                        } label: {
                            Text(TideMath.dayLabel(for: days[index], calendar: calendar, zone: zone))
                                .font(.caption.weight(isOn ? .bold : .medium))
                                .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(isOn ? AnyShapeStyle(Color.accentColor)
                                                 : AnyShapeStyle(Color(.tertiarySystemFill)),
                                            in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.vertical, 1)
            }
            .onChange(of: day, initial: true) { _, index in
                withAnimation(.snappy) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    // MARK: Whose water this is

    /// The datum, said where the numbers are — the two sources measure from
    /// different zeroes, and a rider comparing them deserves the why before
    /// they conclude one of us is broken.
    private var sourceNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch curve.source {
            case .model:
                Text("Sea level against MSL, from Open-Meteo's marine model — worldwide, and a model rather than a harmonic prediction. NOAA's stations are measured against MLLW, so their heights read differently and their times are the authority.")
            case .station(let name, let metres):
                Text("Predicted water level against MLLW — NOAA CO-OPS harmonics for \(name), \(Format.distance(metres, unit: unit)) from here. The authority on times and heights; still a prediction, not a gauge.")
            }

            if let age = curve.staleAge {
                Label {
                    Text("No network right now — this curve is the model from \(Format.duration(age)) ago.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.harbourNavy)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The water

/// The curve, its midnights and the moment — everything inside the scroll
/// view that does *not* change while a finger is dragging it.
///
/// Equatable and rasterised once. Before it was extracted this lived in the
/// screen's own body, so every sample the reading line crossed rebuilt it and
/// `drawingGroup` re-rasterised a layer ten days wide — several times a
/// second, mid-drag, which is precisely when there is no time to spare.
private struct TideTrack: View, Equatable {

    let points: [TideCurve.Point]
    let plot: TidePlot
    let height: CGFloat
    let nowIndex: Int?
    let calendar: Calendar

    static func == (a: TideTrack, b: TideTrack) -> Bool {
        a.height == b.height
            && a.nowIndex == b.nowIndex
            && a.plot == b.plot
            && a.points.count == b.points.count
            && a.points.first?.at == b.points.first?.at
            && a.points.last?.at == b.points.last?.at
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TideShape(points: points, span: (plot.low, plot.high))
                .fill(LinearGradient(
                    colors: [.teal.opacity(0.45), .teal.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom))
            TideShape(points: points, span: (plot.low, plot.high), lineOnly: true)
                .stroke(.teal, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            dayRules

            // Now, in the water's own coordinates, so it scrolls with the
            // curve. The reading line is fixed to the screen; this one marks
            // the moment — and the dot on it says which height that moment
            // actually is, which a line crossing a curve only implies.
            if let now = nowIndex {
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2, height: height)
                    .offset(x: CGFloat(now) * TideScreen.pointWidth)
                if let metres = points[safe: now]?.metres {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 9, height: 9)
                        .offset(x: CGFloat(now) * TideScreen.pointWidth - 4.5,
                                y: plot.y(of: metres, in: height) - 4.5)
                }
            }
        }
        .frame(width: CGFloat(points.count) * TideScreen.pointWidth, height: height)
        // One layer instead of re-rasterising the curve on every frame of a
        // drag. Worth it only because this view is equatable and therefore
        // built once — the two changes go together.
        .drawingGroup()
    }

    /// A rule at each midnight, so a curve ten days long is readable as days.
    @ViewBuilder
    private var dayRules: some View {
        let midnights = points.indices.filter { index in
            guard index > 0 else { return false }
            return !calendar.isDate(points[index].at, inSameDayAs: points[index - 1].at)
        }

        ForEach(midnights, id: \.self) { index in
            let x = CGFloat(index) * TideScreen.pointWidth
            Rectangle()
                .fill(Color(.systemGray3).opacity(0.6))
                .frame(width: 1, height: height)
                .offset(x: x)
            Text(points[index].at.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .offset(x: x + 4, y: 4)
        }
    }
}

// MARK: - Highs and lows

/// The tide table, which is the thing a rider came for.
///
/// Derived from the curve rather than fetched: an hourly series resolves a
/// turn to within about half an hour, which is the precision anybody plans
/// to — and where a CO-OPS station drew this curve, these are that station's
/// own harmonics.
private struct TideTurnsCard: View, Equatable {

    let curve: TideCurve
    /// The day to show, or nil for the whole run.
    let selectedDay: Date?
    let unit: DistanceUnit
    let zone: TimeZone
    let calendar: Calendar

    static func == (a: TideTurnsCard, b: TideTurnsCard) -> Bool {
        a.selectedDay == b.selectedDay && a.unit == b.unit
            && TideMath.sameCurve(a.curve, b.curve)
    }

    private var rows: [TideCurve.Turn] {
        let future = curve.turns.filter { $0.at >= calendar.startOfDay(for: Date()) }
        guard let day = selectedDay else { return future }
        return future.filter { calendar.isDate($0.at, inSameDayAs: day) }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(selectedDay == nil ? "HIGHS AND LOWS, EVERY DAY" : "HIGHS AND LOWS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, turn in
                        HStack(spacing: 10) {
                            Image(systemName: turn.isHigh ? "arrow.up.to.line" : "arrow.down.to.line")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(turn.isHigh ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: 20)
                            Text(turn.isHigh ? "High" : "Low")
                                .font(.subheadline.weight(.semibold))
                            if selectedDay == nil {
                                Text(TideMath.dayLabel(for: turn.at, calendar: calendar, zone: zone))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(turn.at.formatted(Date.FormatStyle(timeZone: zone).hour().minute()))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(Format.height(turn.metres, unit: unit))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                                .frame(width: 72, alignment: .trailing)
                        }
                        .padding(.vertical, 9)
                        if index < rows.count - 1 { Divider() }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

// MARK: - Hour by hour

/// The hours as numbers, with the height drawn beside each one.
///
/// The same shape as the forecast's hourly table — a card of rows with a bar
/// you can read down — because the question is the same question: what will
/// it be doing when I get there. Every hour for a day; every third across the
/// run, since ten days of hourly rows is a scroll nobody finishes.
private struct TideHoursCard: View, Equatable {

    let curve: TideCurve
    let selectedDay: Date?
    let unit: DistanceUnit
    let zone: TimeZone
    let calendar: Calendar

    static func == (a: TideHoursCard, b: TideHoursCard) -> Bool {
        a.selectedDay == b.selectedDay && a.unit == b.unit
            && TideMath.sameCurve(a.curve, b.curve)
    }

    /// The rows, as indices into the curve.
    ///
    /// Indices rather than points because every row also wants to know which
    /// way the water was going, which is a question about the samples either
    /// side of it.
    ///
    /// Thinned to roughly an hour apart, and that is not always every sample:
    /// where a CO-OPS station drew this curve it arrives at six-minute grain
    /// thinned to half-hours, so taking every point printed two rows an hour
    /// wearing the same label — "12 AM" twice, with different heights, which
    /// reads as a bug rather than as detail.
    private var rows: [Int] {
        let step = TideMath.hourStep(of: curve) * (selectedDay == nil ? 3 : 1)
        let today = calendar.startOfDay(for: Date())
        let wanted = curve.points.indices.filter { index in
            let at = curve.points[index].at
            guard let day = selectedDay else { return at >= today }
            return calendar.isDate(at, inSameDayAs: day)
        }
        return wanted.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(selectedDay == nil ? "EVERY THIRD HOUR" : "HOUR BY HOUR")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.height(curve.low, unit: unit)
                         + " – " + Format.height(curve.high, unit: unit))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element) { position, index in
                        row(index)
                        if position < rows.count - 1 { Divider() }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        if let point = curve.points[safe: index] {
            let range = max(0.001, curve.high - curve.low)
            let fraction = (point.metres - curve.low) / range
            let isNow = abs(point.at.timeIntervalSinceNow) < 1800

            HStack(spacing: 10) {
                Text(point.at.formatted(Date.FormatStyle(timeZone: zone).hour()))
                    .font(.caption.weight(isNow ? .bold : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isNow ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(width: 58, alignment: .leading)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.systemGray5))
                            .frame(height: 6)
                        Capsule()
                            .fill(Color.teal.opacity(0.55))
                            .frame(width: max(4, geometry.size.width * fraction), height: 6)
                    }
                    .frame(height: geometry.size.height, alignment: .center)
                }
                .frame(height: 16)

                Image(systemName: TideMath.rising(in: curve, at: index) ? "arrow.up" : "arrow.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(Format.height(point.metres, unit: unit))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Every day

/// Each day's range as one bar, the way the forecast screen draws its week —
/// the glance that says which day has the big water in it.
private struct TideDaysCard: View, Equatable {

    let curve: TideCurve
    let days: [Date]
    let selected: Int
    let unit: DistanceUnit
    let zone: TimeZone
    let calendar: Calendar
    let onSelect: (Int) -> Void

    static func == (a: TideDaysCard, b: TideDaysCard) -> Bool {
        a.selected == b.selected && a.days == b.days && a.unit == b.unit
            && TideMath.sameCurve(a.curve, b.curve)
    }

    var body: some View {
        if days.count > 1 {
            let overall = max(0.001, curve.high - curve.low)
            VStack(alignment: .leading, spacing: 10) {
                Text("EVERY DAY")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element) { index, date in
                        let heights = curve.points
                            .filter { calendar.isDate($0.at, inSameDayAs: date) }
                            .map(\.metres)
                        if let low = heights.min(), let high = heights.max() {
                            Button { onSelect(index) } label: {
                                HStack(spacing: 10) {
                                    Text(TideMath.dayLabel(for: date, calendar: calendar, zone: zone))
                                        .font(.subheadline.weight(index == selected ? .bold : .semibold))
                                        .frame(width: 72, alignment: .leading)

                                    Text(Format.height(low, unit: unit))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .trailing)

                                    // The day's water as the slice of the run
                                    // it occupies: a neap day is a short bar
                                    // sitting mid-scale, springs run the width.
                                    GeometryReader { geometry in
                                        let x = geometry.size.width * (low - curve.low) / overall
                                        let w = geometry.size.width * (high - low) / overall
                                        ZStack(alignment: .leading) {
                                            Capsule()
                                                .fill(Color(.systemGray5))
                                                .frame(height: 6)
                                            Capsule()
                                                .fill(Color.teal.opacity(index == selected ? 0.75 : 0.4))
                                                .frame(width: max(6, w), height: 6)
                                                .offset(x: x)
                                        }
                                        .frame(height: geometry.size.height, alignment: .center)
                                    }
                                    .frame(height: 16)

                                    Text(Format.height(high, unit: unit))
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                        .frame(width: 56, alignment: .trailing)
                                }
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index < days.count - 1 { Divider() }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

// MARK: - Shared arithmetic

/// The plot's vertical scale, shared by the shape and everything drawn on it.
///
/// A dot placed with different arithmetic from the line it sits on is a dot
/// that misses, so both ends read the mapping from here.
struct TidePlot: Equatable {
    let low: Double
    let high: Double

    init(curve: TideCurve) {
        let pad = max(0.1, (curve.high - curve.low) * 0.18)
        self.low = curve.low - pad
        self.high = curve.high + pad
    }

    func y(of metres: Double, in height: CGFloat) -> CGFloat {
        height * (1 - (metres - low) / max(0.001, high - low))
    }
}

/// The small questions the screen and its cards both ask of a curve.
enum TideMath {

    static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return calendar
    }

    static func nowIndex(in curve: TideCurve) -> Int? {
        let moment = Date()
        return curve.points.indices.min {
            abs(curve.points[$0].at.timeIntervalSince(moment))
                < abs(curve.points[$1].at.timeIntervalSince(moment))
        }
    }

    /// Whether the water is coming in at a sample.
    static func rising(in curve: TideCurve, at index: Int?) -> Bool {
        guard let index, let here = curve.points[safe: index],
              let next = curve.points[safe: index + 1] ?? curve.points[safe: index - 1]
        else { return true }
        return index + 1 < curve.points.count
            ? next.metres >= here.metres
            : here.metres >= next.metres
    }

    /// How many samples make an hour on this curve — one for the hourly
    /// model, two for a station's half-hourly harmonics.
    static func hourStep(of curve: TideCurve) -> Int {
        guard curve.points.count > 1 else { return 1 }
        let spacing = max(60, curve.points[1].at.timeIntervalSince(curve.points[0].at))
        return max(1, Int((3600 / spacing).rounded()))
    }

    /// Today first, then the days ahead.
    ///
    /// The fetch carries yesterday as well — the curve needs a run-up so the
    /// first hours of today are not an edge — and the chart still scrolls
    /// back into it. The tables do not offer it: nobody plans a session in
    /// the tide that has already gone out.
    static func days(in curve: TideCurve, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: Date())
        var counts: [Date: Int] = [:]
        var found: [Date] = []
        for point in curve.points {
            let start = calendar.startOfDay(for: point.at)
            guard start >= today else { continue }
            counts[start, default: 0] += 1
            if !found.contains(start) { found.append(start) }
        }
        // A day the run only just reaches is not a day anybody can plan in:
        // the last calendar day of a ten-day fetch can hold a single hour,
        // which drew as a tab with one row behind it and a range bar that was
        // a dot. Six hours is the least that can carry a turn.
        return found.filter { (counts[$0] ?? 0) >= 6 * max(1, hourStep(of: curve)) }
    }

    /// "Today" or "Thu" — the short form, for a segmented control.
    static func shortLabel(for date: Date, calendar: Calendar, zone: TimeZone) -> String {
        calendar.isDateInToday(date) ? "Today"
            : date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))
    }

    /// "Today" or "Thu 20". Once the run is ten days long the weekday alone
    /// comes round twice, so the date joins it.
    static func dayLabel(for date: Date, calendar: Calendar, zone: TimeZone) -> String {
        calendar.isDateInToday(date) ? "Today"
            : date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).day())
    }

    /// Whether two curves are the same run — the question the cards ask to
    /// decide they have nothing to redraw. Cheap on purpose: comparing two
    /// thousand points every scroll step would cost more than the redraw.
    static func sameCurve(_ a: TideCurve, _ b: TideCurve) -> Bool {
        a.points.count == b.points.count
            && a.points.first?.at == b.points.first?.at
            && a.points.last?.at == b.points.last?.at
            && a.staleAge == b.staleAge
    }
}

/// The tide as a filled shape across its own width.
private struct TideShape: Shape {
    let points: [TideCurve.Point]
    let span: (low: Double, high: Double)
    var lineOnly = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let range = max(0.001, span.high - span.low)

        for (index, point) in points.enumerated() {
            let x = rect.width * Double(index) / Double(points.count - 1)
            let y = rect.height * (1 - (point.metres - span.low) / range)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        guard !lineOnly else { return path }

        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
