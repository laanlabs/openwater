import CoreLocation
import OpenWaterCore
import SwiftUI
import WeatherKit

// MARK: - What a normal week looks like here

/// The climate averages for the week ahead at this point.
///
/// A forecast on its own is a number without a scale. "Twenty-two degrees on
/// Thursday" means one thing in the Gorge in June and another entirely in
/// Cornwall in October, and a rider who does not already know a spot has no
/// way to tell whether the week they are looking at is a good one or the
/// reason the locals stayed home.
///
/// Apple serves the other half: what this date normally does here, averaged
/// over decades of observations. Put beside the forecast the sheet already
/// has, it turns a row of numbers into a judgement — this week is four
/// degrees warmer than normal, or it is wetter than usual, or it is exactly
/// what August does here and you should plan accordingly.
///
/// Temperature and rain only. Apple's statistics API has no wind, which is the
/// one a rider would most like — `docs/WIND.md` covers what the archive models
/// can do about that instead.
struct TypicalWeek {

    /// One day's normals.
    struct Day: Identifiable, Equatable {
        let date: Date
        let normalHighC: Double
        let normalLowC: Double
        /// How often it rains on this date historically, 0…1.
        let rainChance: Double

        var id: Date { date }
    }

    var days: [Day] = []

    /// The month's own averages, for the places the day-by-day normals are
    /// not served. Coarser, and still enough to say what the season does here.
    var monthHighC: Double?
    var monthLowC: Double?
    var monthRainChance: Double?

    /// The first year the averages are built from — Apple's baseline, which
    /// is worth naming rather than letting "normal" stand unqualified.
    var baselineStart: Date?

    var isEmpty: Bool { days.isEmpty && monthHighC == nil }

    /// The averages a headline can be written from, whichever shape arrived.
    var normalHighC: Double? {
        days.isEmpty ? monthHighC : days.map(\.normalHighC).mean
    }

    var normalLowC: Double? {
        days.isEmpty ? monthLowC : days.map(\.normalLowC).mean
    }

    var normalRainChance: Double? {
        days.isEmpty ? monthRainChance : days.map(\.rainChance).mean
    }

    // MARK: The verdict

    /// This week against a normal one, in the two numbers that carry it.
    struct Comparison: Equatable {
        /// Forecast high minus normal high, averaged over the days both know.
        let temperatureDeltaC: Double
        /// Forecast rain chance minus normal, 0…1, over the same days.
        let rainDelta: Double
        /// How many days the two sources actually shared.
        let days: Int

        /// Whether the difference is big enough to be worth a sentence.
        ///
        /// A degree and a half. Below that the "difference" is the gap
        /// between a five-day model and a thirty-year mean, not the weather.
        var isNotable: Bool { abs(temperatureDeltaC) >= 1.5 }

        var isWetter: Bool { rainDelta >= 0.15 }
        var isDrier: Bool { rainDelta <= -0.15 }
    }

    /// This week's forecast measured against these normals.
    ///
    /// Split from the fetch and from the view so a fixture can exercise it.
    /// Days are matched by calendar day rather than by index: the two sources
    /// start their weeks from their own idea of today, and pairing Thursday's
    /// forecast with Wednesday's normal would put a whole degree of error into
    /// a sentence whose entire job is to be believed.
    func comparison(to forecast: [WeatherDetail.Day],
                    calendar: Calendar = .current) -> Comparison? {
        guard !days.isEmpty else { return nil }

        var temperatureDeltas: [Double] = []
        var rainDeltas: [Double] = []

        for normal in days {
            guard let day = forecast.first(where: {
                calendar.isDate($0.date, inSameDayAs: normal.date)
            }) else { continue }

            if let high = day.highC {
                temperatureDeltas.append(high - normal.normalHighC)
            }
            if let chance = day.precipitationChance {
                // Open-Meteo answers this one in percent and Apple in
                // fractions. Both land here, so both are made fractions.
                rainDeltas.append(chance / 100 - normal.rainChance)
            }
        }

        guard let temperature = temperatureDeltas.mean else { return nil }
        return Comparison(
            temperatureDeltaC: temperature,
            rainDelta: rainDeltas.mean ?? 0,
            days: temperatureDeltas.count
        )
    }
}

private extension Array where Element == Double {
    var mean: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}

// MARK: - Fetching it

extension AppleWeather {

    /// The normals for the days ahead at a point, or nothing.
    ///
    /// Two shapes, tried in order. Day-by-day normals are the good answer and
    /// carry the per-day rows; the month's averages are the fallback, which
    /// still supports the headline sentence and is served in more places.
    /// Both are climate rather than forecast, so they change on the scale of
    /// decades and there is nothing here worth re-asking for within a session.
    /// `timeZone` is the spot's, when the sheet has worked it out. The week
    /// asked for has to be the week the forecast beside it covers, and those
    /// start at the spot's midnight rather than the reader's — otherwise a
    /// rider looking at Hawaii from the east coast late in the evening gets
    /// normals for tomorrow against a forecast for today.
    static func typicalWeek(at coordinate: Geo.Coordinate, days: Int = 7,
                            from today: Date = Date(),
                            timeZone: TimeZone? = nil) async -> TypicalWeek {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var calendar = Calendar.current
        if let timeZone { calendar.timeZone = timeZone }
        let start = calendar.startOfDay(for: today)

        // `DateInterval` includes both ends, so a seven-day week is six days
        // of duration — asking for seven comes back with eight.
        if let daily = try? await WeatherService.shared.dailyStatistics(
            for: location,
            forDaysIn: DateInterval(start: start, duration: TimeInterval((days - 1) * 86_400)),
            including: .temperature, .precipitation
        ) {
            let (temperature, precipitation) = daily
            // Paired by position: the two collections answer the same
            // interval in the same order, and neither element carries a date
            // to key on — `day` is an ordinal, not a calendar day.
            let rows = temperature.days.enumerated().compactMap { index, normal -> TypicalWeek.Day? in
                guard let date = calendar.date(byAdding: .day, value: index, to: start) else { return nil }
                return TypicalWeek.Day(
                    date: date,
                    normalHighC: normal.averageHighTemperature.converted(to: .celsius).value,
                    normalLowC: normal.averageLowTemperature.converted(to: .celsius).value,
                    rainChance: Self.asFraction(
                        precipitation.days[safe: index]?.averagePrecipitationProbability ?? 0
                    )
                )
            }
            if !rows.isEmpty {
                return TypicalWeek(days: rows, baselineStart: temperature.baselineStartDate)
            }
        }

        guard let monthly = try? await WeatherService.shared.monthlyStatistics(
            for: location, including: .temperature, .precipitation
        ) else { return TypicalWeek() }

        let (temperature, precipitation) = monthly
        let month = calendar.component(.month, from: today)
        guard let normal = temperature.months.first(where: { $0.month == month }) else {
            return TypicalWeek()
        }
        return TypicalWeek(
            monthHighC: normal.averageHighTemperature.converted(to: .celsius).value,
            monthLowC: normal.averageLowTemperature.converted(to: .celsius).value,
            monthRainChance: precipitation.months.first(where: { $0.month == month })
                .map { Self.asFraction($0.averagePrecipitationProbability) },
            baselineStart: temperature.baselineStartDate
        )
    }

    /// WeatherKit states probabilities as fractions everywhere else, and this
    /// card would read as a 6,000% chance of rain if that ever stopped being
    /// true here. Cheap insurance on a number nobody would think to check.
    private static func asFraction(_ probability: Double) -> Double {
        min(1, max(0, probability > 1 ? probability / 100 : probability))
    }
}

// MARK: - The card

/// The week ahead against the week this place normally has.
///
/// The rows are the point. A column of numbers saying "26, 25, 27" tells a
/// visitor nothing; the same numbers sitting a clear band above the grey bars
/// of normal tell them the whole story before they have read a word — and the
/// sentence on top just says out loud what the shape already showed.
struct TypicalWeekCard: View {

    let typical: TypicalWeek
    /// The wind half, which comes from the reanalysis archive rather than
    /// Apple — see `TypicalWind` for why it has to.
    var wind = TypicalWind()
    /// The forecast this sheet already has, to measure the normals against.
    let forecast: [WeatherDetail.Day]
    /// The spot's own zone, which is what decides where its days begin.
    var timeZone: TimeZone?

    @Environment(AppSettings.self) private var settings

    /// Wind leads. This is a card on a wind-sports app, and "is this a good
    /// week to come here" is a question about wind with a footnote about
    /// what to wear — the temperature half is the footnote.
    @State private var metric: Metric = .wind

    enum Metric: String, CaseIterable {
        case wind = "Wind", temperature = "Temp"
    }

    private var unit: TemperatureUnit { settings.units.temperatureUnit }

    /// Only the halves that actually arrived. Either source can fail on its
    /// own — Apple needs the entitlement, the archive needs a network — and a
    /// picker offering an empty tab is worse than no picker.
    private var available: [Metric] {
        var metrics: [Metric] = []
        if !wind.isEmpty { metrics.append(.wind) }
        if !typical.isEmpty { metrics.append(.temperature) }
        return metrics
    }

    /// The metric actually on screen, which is the chosen one where it exists
    /// and the surviving one where it does not. Derived rather than corrected
    /// in place, so a late-arriving fetch cannot fight the rider's own tap.
    private var shown: Metric {
        available.contains(metric) ? metric : (available.first ?? .wind)
    }

    /// Both sources are keyed to the spot's midnight, not the reader's. A
    /// rider in Maine checking Maui late at night is a whole calendar day out
    /// of step with it, and pairing Tuesday's normals against Monday's
    /// forecast would put a season's worth of error into the sentence.
    private var calendar: Calendar {
        var calendar = Calendar.current
        if let timeZone { calendar.timeZone = timeZone }
        return calendar
    }

    private var comparison: TypicalWeek.Comparison? {
        typical.comparison(to: forecast, calendar: calendar)
    }

    var body: some View {
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("TYPICAL FOR THIS WEEK")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let figure {
                        Text(figure)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                // Only where there is a choice to make. One source on its own
                // gets the whole card rather than a control with a dead half.
                if available.count > 1 {
                    Picker("Measure", selection: $metric) {
                        ForEach(available, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if !rows.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(rows) { row in
                            dayRow(row)
                        }
                    }
                    legend
                }

                if let rain = rainSentence {
                    Text(rain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(provenance)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // Apple's mark rides on Apple's data. The wind half is
                // Open-Meteo's and does not earn the trademark, so a card
                // showing only wind must not carry it (Guideline 5.2.5 cuts
                // both ways — the mark has to be there, and only there).
                if !typical.isEmpty {
                    AppleWeatherAttribution(showsLegalLabel: true, prefix: "Temperature and rain from")
                        .font(.caption2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    /// The figure beside the title: the week's own middle, in the shown
    /// measure.
    private var figure: String? {
        switch shown {
        case .wind:
            guard let median = wind.medianKn else { return nil }
            let bearing = wind.directionDeg.map { " · \(Format.cardinal($0))" } ?? ""
            return "\(Int(median.rounded())) kn\(bearing)"
        case .temperature:
            guard let high = typical.normalHighC, let low = typical.normalLowC else { return nil }
            return "\(Format.temperature(high, unit: unit, includeSymbol: false)) / \(Format.temperature(low, unit: unit))"
        }
    }

    // MARK: The sentences

    private var headline: String {
        switch shown {
        case .wind: windHeadline
        case .temperature: temperatureHeadline
        }
    }

    private var windHeadline: String {
        guard let median = wind.medianKn else { return "Wind normals for this point." }
        let usual = "Peaks normally reach about \(Int(median.rounded())) kn here at this time of year"
        let from = wind.directionDeg.map { ", from the \(Format.cardinal($0))" } ?? ""

        guard let delta = wind.comparison(to: forecast, calendar: calendar) else {
            return usual + from + "."
        }
        // Two knots. Below that the "difference" is the gap between a five-day
        // model and a decade of reanalysis, not the week.
        guard abs(delta) >= 2 else {
            return usual + from + " — and the week ahead sits right on it."
        }
        let word = delta > 0 ? "windier" : "lighter"
        return usual + from + ". The week ahead runs about \(Int(abs(delta).rounded())) kn \(word) than that."
    }

    private var temperatureHeadline: String {
        guard let comparison, comparison.days >= 3 else {
            guard let high = typical.normalHighC, let low = typical.normalLowC else {
                return "Normals for this point."
            }
            return "This spot normally runs \(Format.temperature(high, unit: unit, includeSymbol: false)) by day and \(Format.temperature(low, unit: unit)) overnight at this time of year."
        }

        guard comparison.isNotable else {
            return "About normal for the time of year here — the week ahead sits right on the average."
        }
        // A difference, not a temperature: converting it as though it were one
        // would add Fahrenheit's 32-degree offset to a gap of three degrees.
        // Converting both ends and subtracting keeps the offset out of it.
        let delta = abs(unit.convert(fromCelsius: comparison.temperatureDeltaC)
                        - unit.convert(fromCelsius: 0))
        let rounded = max(1, Int(delta.rounded()))
        let word = comparison.temperatureDeltaC > 0 ? "warmer" : "cooler"
        return "Running about \(rounded)° \(word) than a normal week here."
    }

    private var rainSentence: String? {
        guard let normal = typical.normalRainChance else { return nil }
        let days = (normal * 10).rounded()
        let usual = days < 0.5
            ? "Rain is rare here at this time of year."
            : "Rain falls about \(Int(days)) days in 10 here at this time of year."

        guard let comparison, comparison.days >= 3 else { return usual }
        if comparison.isWetter { return usual + " The week ahead is wetter than that." }
        if comparison.isDrier { return usual + " The week ahead is drier than that." }
        return usual
    }

    private var provenance: String {
        let common = "Climate, not a forecast — it says what this place normally does, which is the scale the week above should be read against."
        switch shown {
        case .wind:
            let span = (wind.firstYear).map { first in
                wind.lastYear.map { "\(first) to \($0)" } ?? "\(first) onward"
            } ?? "the last decade"
            let window = wind.days.first.map { " About \($0.samples) past days went into each row — every archive day within three of that date." } ?? ""
            return "Daily peak wind at this point, \(span), from the ERA5 reanalysis via Open-Meteo.\(window) \(common) Apple publishes no wind averages, which is why this half comes from somewhere else."
        case .temperature:
            let since = typical.baselineStart.map {
                "Averaged from \(Calendar.current.component(.year, from: $0)) onward. "
            } ?? ""
            let shape = typical.days.isEmpty
                ? "This month's averages for this point"
                : "Day-by-day averages for this point"
            return "\(shape). \(since)\(common)"
        }
    }

    // MARK: The rows

    /// A day the card can draw: a band the normals put it in, and the point
    /// the forecast puts it at. The same shape for either measure, so the two
    /// read as one card with a switch rather than two cards sharing a border.
    private struct Row: Identifiable {
        let date: Date
        let bandLow: Double
        let bandHigh: Double
        let forecast: Double?
        var id: Date { date }
    }

    private var rows: [Row] {
        switch shown {
        case .wind:
            trimmed(wind.days.map { normal in
                let day = forecast.first { calendar.isDate($0.date, inSameDayAs: normal.date) }
                return Row(date: normal.date, bandLow: normal.lowKn,
                           bandHigh: normal.highKn, forecast: day?.windMaxKn)
            })
        case .temperature:
            trimmed(typical.days.map { normal in
                let day = forecast.first { calendar.isDate($0.date, inSameDayAs: normal.date) }
                return Row(date: normal.date, bandLow: normal.normalLowC,
                           bandHigh: normal.normalHighC, forecast: day?.highC)
            })
        }
    }

    /// Only as far as the forecast reaches.
    ///
    /// Normals exist for any date at all, the forecast for five days, and the
    /// rows past the handover were a bar with nothing on it and a dash where
    /// the number goes — which reads as data that failed to load rather than a
    /// week that has not been forecast yet. The card is a comparison; a row
    /// with nothing to compare is not a row.
    private func trimmed(_ all: [Row]) -> [Row] {
        guard let last = all.lastIndex(where: { $0.forecast != nil }) else { return [] }
        return Array(all.prefix(through: last))
    }

    /// Every row is drawn against the same axis — the point of the card is
    /// comparing days to each other as well as to normal, and a row that
    /// rescaled to its own range would make every week look identical.
    ///
    /// Wind starts its axis at zero. Temperature must not: a band from 12° to
    /// 24° plotted from absolute zero is a sliver at the far right of the row,
    /// and the whole week collapses into one indistinguishable smear.
    private var scale: ClosedRange<Double> {
        let values = rows.flatMap { row -> [Double] in
            [row.bandLow, row.bandHigh] + [row.forecast].compactMap { $0 }
        }
        let pad = shown == .wind ? 2.0 : 1.0
        let low = shown == .wind ? 0 : (values.min() ?? 0) - pad
        let high = (values.max() ?? 1) + pad
        // A degenerate range would divide by zero below.
        return low < high ? low...high : low...(low + 1)
    }

    private func position(_ value: Double, in width: CGFloat) -> CGFloat {
        let span = scale.upperBound - scale.lowerBound
        return width * CGFloat((value - scale.lowerBound) / span)
    }

    /// The number at the end of a row, in the shown measure's own words.
    private func label(_ value: Double) -> String {
        switch shown {
        case .wind: "\(Int(value.rounded()))"
        case .temperature: Format.temperature(value, unit: unit, includeSymbol: false)
        }
    }

    private func dayRow(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Text(weekday(row.date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                // Wide enough for "Today", which is the longest label here and
                // wrapped to two lines at the width the abbreviations needed.
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 40, alignment: .leading)

            GeometryReader { geometry in
                let width = geometry.size.width
                let start = position(row.bandLow, in: width)
                let end = position(row.bandHigh, in: width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: max(2, end - start), height: 8)
                        .offset(x: start)
                    if let value = row.forecast {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 9, height: 9)
                            .offset(x: position(value, in: width) - 4.5)
                    }
                }
                // The offsets above are measured from this frame's leading
                // edge, so the stack has to actually span the row — left to
                // itself a ZStack shrinks to its widest child and every day
                // would be plotted against a different axis.
                .frame(width: width, height: geometry.size.height, alignment: .leading)
            }
            .frame(height: 12)

            Text(row.forecast.map { label($0) } ?? "—")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                // Fifteen knots is the app's own firing line, called out the
                // same way here as on every other chart. Tested against the
                // rounded value, which is the one on the screen: 14.6 draws as
                // "15" and left one row plainly reading fifteen and plainly
                // not tinted, beside a sixteen that was.
                .foregroundStyle(shown == .wind && (row.forecast ?? 0).rounded() >= 15
                                 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 14, height: 7)
                Text(shown == .wind ? "usual range" : "normal low to high")
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                Text(shown == .wind ? "forecast peak, kn" : "forecast high")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.top, 1)
    }

    private func weekday(_ date: Date) -> String {
        calendar.isDateInToday(date)
            ? "Today"
            : date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated))
    }
}
