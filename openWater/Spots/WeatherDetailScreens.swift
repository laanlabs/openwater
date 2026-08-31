import OpenWaterCore
import OpenWaterSpots
import SwiftUI
import UIKit

// MARK: - Right now, in full

/// Everything the model says about this minute.
///
/// The card on the conditions sheet shows four numbers because that is what
/// fits and what usually decides the question. This is the rest: humidity and
/// dew point, pressure, cloud, UV, visibility — the readings that explain
/// *why* it feels how it feels, and that a rider checking whether to bring a
/// wetsuit or a hat actually wants.
struct CurrentConditionsScreen: View {

    let title: String
    let coordinate: Geo.Coordinate
    /// Passed in rather than refetched — the sheet already has it, and this
    /// screen should be instant.
    let detail: WeatherDetail
    var station: FreeStation?

    @Environment(AppSettings.self) private var settings

    private var now: WeatherDetail.Now? { detail.now }

    /// Times in the spot's timezone, with a note when that is not the phone's.
    private var zone: TimeZone { detail.timeZone ?? .current }

    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }

    private var zoneNote: String? {
        guard let named = detail.timeZone, named.identifier != TimeZone.current.identifier,
              named.secondsFromGMT() != TimeZone.current.secondsFromGMT()
        else { return nil }
        return "Times shown in \(named.localizedName(for: .shortGeneric, locale: .current) ?? named.identifier)."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let now {
                    ConditionsCard(weather: nil, windKn: now.windKn, gustKn: now.gustKn,
                                   directionDeg: now.directionDeg,
                                   temperatureC: now.temperatureC, pressureHPa: now.pressureHPa)
                }
                headline
                if let now { windCard(now) }
                if let now { grid(now) }
                if let station { comparison(station) }
                sunCard
                provenance
            }
            .padding(16)
        }
        .background(Color.deepSurface)
        .navigationTitle("Now")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Current conditions")
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .center, spacing: 16) {
                if let now {
                    Image(systemName: SpotWeather.symbol(for: now.code, isDay: now.isDay))
                        .font(.system(size: 46))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint(now.code, isDay: now.isDay))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(now.temperatureC.map { "\(Int($0.rounded()))°" } ?? "—")
                            .font(.system(size: 42, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text(SpotWeather.label(for: now.code))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let apparent = now?.apparentC, let actual = now?.temperatureC,
                   abs(apparent - actual) >= 1 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int(apparent.rounded()))°")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Text("FEELS LIKE")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func windCard(_ now: WeatherDetail.Now) -> some View {
        if let direction = now.directionDeg, let speed = now.windKn {
            HStack(alignment: .center, spacing: 18) {
                WindCompass(directionDeg: direction, speedKn: speed, gustKn: now.gustKn)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int(speed.rounded()))")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .foregroundStyle(speed >= 15 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .monospacedDigit()
                        Text("kn")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(Format.cardinal(direction))
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)

                    windRow("Gusting", now.gustKn.map { "to \(Int($0.rounded())) kn" } ?? "—",
                            "wind", divided: true)
                    windRow("Humidity", now.humidity.map { "\(Int($0.rounded()))%" } ?? "—",
                            "humidity", divided: true)
                    windRow("Pressure", now.pressureHPa.map { "\(Int($0.rounded())) hPa" } ?? "—",
                            "barometer", divided: false)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func windRow(_ label: String, _ value: String, _ symbol: String, divided: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
            }
            .padding(.vertical, 6)
            if divided { Divider() }
        }
    }

    private func grid(_ now: WeatherDetail.Now) -> some View {
        let cells: [(String, String, String)] = [
            ("Dew point", now.dewPointC.map { "\(Int($0.rounded()))°" } ?? "—", "drop"),
            ("Cloud", now.cloudCover.map { "\(Int($0.rounded()))%" } ?? "—", "cloud"),
            ("UV index", now.uvIndex.map { String(format: "%.1f", $0) } ?? "—", "sun.max"),
            ("Visibility", now.visibilityM.map { visibility($0) } ?? "—", "eye"),
            ("Rain now", now.precipitationMm.map { String(format: "%.1f mm", $0) } ?? "—", "cloud.rain"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(cells, id: \.0) { label, value, symbol in
                VStack(alignment: .leading, spacing: 3) {
                    Label(label.uppercased(), systemImage: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    /// The model against the nearest real sensor.
    ///
    /// This is the comparison the whole conditions sheet is built around, and
    /// on this screen it can be made explicit: here is what the grid says,
    /// here is what an anemometer some distance away says, and here is how far
    /// apart they are. A rider who sees them disagree by six knots has learned
    /// something no single number could tell them.
    @ViewBuilder
    private func comparison(_ station: FreeStation) -> some View {
        if let observed = station.observation?.windKn, let modelled = now?.windKn {
            let gap = abs(observed - modelled)
            VStack(alignment: .leading, spacing: 8) {
                Text("MODEL VERSUS THE NEAREST SENSOR")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                HStack {
                    figure("Model here", "\(Int(modelled.rounded())) kn")
                    Spacer()
                    figure(station.name, "\(Int(observed.rounded())) kn", trailing: true)
                }
                Text(gap < 3
                     ? "Within \(Int(gap.rounded())) kn of each other — the grid is reading this place well today."
                     : "\(Int(gap.rounded())) kn apart. The sensor is \(Format.distance(station.metres, unit: settings.units.distance)) away, and terrain between here and there will account for some of it — but trust the sensor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func figure(_ label: String, _ value: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var sunCard: some View {
        if let today = detail.days.first, today.sunrise != nil || today.sunset != nil {
            HStack(spacing: 0) {
                if let sunrise = today.sunrise {
                    sunFigure("Sunrise", sunrise, "sunrise.fill")
                }
                if let sunset = today.sunset {
                    sunFigure("Sunset", sunset, "sunset.fill")
                }
                if let uv = today.uvMax {
                    VStack(spacing: 3) {
                        Image(systemName: "sun.max.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(String(format: "%.0f", uv))
                            .font(.headline)
                            .monospacedDigit()
                        Text("UV MAX")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(14)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func sunFigure(_ label: String, _ at: Date, _ symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            Text(clock(at))
                .font(.headline)
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var provenance: some View {
        Text(([zoneNote, "Open-Meteo, free and worldwide. Everything here is a model reading for a grid cell, not a measurement at this exact point — which is why the sensor comparison above is worth more than any of it."]
            .compactMap { $0 }).joined(separator: " "))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func visibility(_ metres: Double) -> String {
        metres >= 10_000 ? "10+ km" : Format.distance(metres, unit: settings.units.distance)
    }

    private func tint(_ code: Int, isDay: Bool) -> Color {
        SpotWeather(temperatureC: 0, apparentC: nil, code: code, isDay: isDay, at: Date()).tint
    }
}

// MARK: - The forecast, in full

/// The next five days, and how much the models argue about them.
struct ForecastScreen: View {

    let title: String
    let coordinate: Geo.Coordinate
    let detail: WeatherDetail
    let outlook: WindOutlook
    var waves: [WaveHour] = []

    @Environment(AppSettings.self) private var settings
    @State private var day = 0
    @State private var span: Span = .day
    @AppStorage("spots.forecastDetailed") private var detailed = false

    private var zone: TimeZone { detail.timeZone ?? .current }

    /// A calendar in the spot's timezone, so "the hours of Saturday" means
    /// Saturday there rather than Saturday here.
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return calendar
    }

    private func hourLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: zone).hour())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                agreementCard
                modelLines
                spanPicker
                dayPicker
                hourlyTable
                dailyCard
            }
            .padding(16)
        }
        .background(Color.deepSurface)
        .navigationTitle("Forecast")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Forecast")
    }

    // MARK: Agreement

    @ViewBuilder
    private var agreementCard: some View {
        if !outlook.isEmpty {
            let agreement = outlook.agreement
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: outlook.spreadKn < 8 ? "checkmark.seal.fill" : "questionmark.circle.fill")
                        .foregroundStyle(outlook.spreadKn < 8 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.orange))
                    Text(agreement.label)
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                Text(agreement.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    /// Every model as its own line.
    ///
    /// The summary card averages them, which is the right default and hides
    /// the thing an experienced rider most wants to see: *which* model is the
    /// outlier. If three agree and GFS is alone at nineteen knots, that is a
    /// different decision from four models spread evenly.
    @ViewBuilder
    private var modelLines: some View {
        if !outlook.isEmpty {
            NavigationLink {
                ModelCompareScreen(title: title, coordinate: coordinate)
            } label: {
                modelLinesBody
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var modelLinesBody: some View {
        if !outlook.isEmpty {
            let peak = max(outlook.models.flatMap { $0.speeds.compactMap { $0 } }.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("EACH MODEL, NEXT 24 HOURS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Compare")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ZStack(alignment: .bottomLeading) {
                    ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                        ModelTrace(speeds: model.speeds, peak: peak)
                            .stroke(Self.palette[index % Self.palette.count],
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    // Over the traces, not under them. A rule you are reading
                    // a value against is useless the moment four lines are
                    // drawn across it.
                    ChartGrid(peak: peak, times: outlook.hours, timeZone: outlook.timeZone)
                }
                .frame(height: 110)

                HStack(spacing: 12) {
                    ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Self.palette[index % Self.palette.count])
                                .frame(width: 7, height: 7)
                            Text(model.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack {
                    Text("now")
                    Spacer()
                    if let last = outlook.hours.last {
                        Text(last.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).hour()))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // Kept in step with `ModelCompareScreen.palette` so a model wears the
    // same colour on the thumbnail and the compare screen it opens into.
    private static let palette: [Color] = ModelCompareScreen.palette

    // MARK: Hour by hour

    enum Span: String, CaseIterable { case day = "Day", week = "Week" }

    @ViewBuilder
    private var spanPicker: some View {
        HStack(spacing: 10) {
            Picker("Span", selection: $span) {
                ForEach(Span.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Detail", selection: $detailed) {
                Text("Basic").tag(false)
                Text("More").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var dayPicker: some View {
        if detail.days.count > 1, span == .day {
            Picker("Day", selection: $day) {
                ForEach(detail.days.indices.prefix(5), id: \.self) { index in
                    Text(label(for: detail.days[index].date)).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func label(for date: Date) -> String {
        calendar.isDateInToday(date) ? "Today"
            : date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))
    }

    /// The hours of the selected day, at three-hour steps.
    ///
    /// Every hour would be twenty-four rows of near-identical numbers; three
    /// hours is the resolution a day actually changes at, and it fits without
    /// scrolling past the point of usefulness.
    @ViewBuilder
    private var hourlyTable: some View {
        let rows = span == .day ? hours(for: day) : detail.hours
        if !rows.isEmpty {
            ForecastTable(hours: rows, waves: waves, zone: zone,
                          step: span == .day ? 1 : 3, detailed: detailed)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("").frame(width: 66, alignment: .leading)
            Text("WIND").frame(maxWidth: .infinity, alignment: .trailing)
            Text("GUST").frame(maxWidth: .infinity, alignment: .trailing)
            Text("DIR").frame(width: 46, alignment: .trailing)
            Text("TEMP").frame(width: 46, alignment: .trailing)
            Text("RAIN").frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func row(_ hour: WeatherDetail.Hour) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(hourLabel(hour.at))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: SpotWeather.symbol(for: hour.code, isDay: true))
                    .font(.caption2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 66, alignment: .leading)

            Text(hour.windKn.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle((hour.windKn ?? 0) >= 15 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(hour.gustKn.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(hour.directionDeg.map { Format.cardinal($0) } ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Text(hour.temperatureC.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Text(hour.precipitationChance.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle((hour.precipitationChance ?? 0) >= 50
                                 ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func hours(for index: Int) -> [WeatherDetail.Hour] {
        guard let date = detail.days[safe: index]?.date else { return [] }
        // Every hour. The three-hour thinning that used to live here is now
        // the table's job, and only in the week view.
        return detail.hours.filter { calendar.isDate($0.at, inSameDayAs: date) }
    }

    // MARK: The week

    @ViewBuilder
    private var dailyCard: some View {
        if detail.days.count > 1 {
            let peak = max(detail.days.compactMap(\.gustMaxKn).max() ?? 1, 1)
            VStack(spacing: 0) {
                ForEach(Array(detail.days.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 10) {
                        Text(label(for: entry.date))
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 52, alignment: .leading)

                        Image(systemName: SpotWeather.symbol(for: entry.code, isDay: true))
                            .font(.subheadline)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        // Wind is the headline on this screen, so the bar is
                        // wind rather than the temperature range every other
                        // weather app draws here.
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(.systemGray5))
                                    .frame(height: 6)
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.35))
                                    .frame(width: geometry.size.width * (entry.gustMaxKn ?? 0) / peak, height: 6)
                                Capsule()
                                    .fill((entry.windMaxKn ?? 0) >= 15 ? AnyShapeStyle(.tint)
                                          : AnyShapeStyle(Color.accentColor.opacity(0.7)))
                                    .frame(width: geometry.size.width * (entry.windMaxKn ?? 0) / peak, height: 6)
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 18)

                        Text(entry.windMaxKn.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .frame(width: 26, alignment: .trailing)

                        Text([entry.lowC, entry.highC]
                            .map { $0.map { "\(Int($0.rounded()))°" } ?? "—" }
                            .joined(separator: "–"))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if index < detail.days.count - 1 { Divider().padding(.leading, 14) }
                }

                Text("Peak wind each day, with gusts behind it in a lighter shade. Five days is as far as a free global model is worth reading.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

// MARK: - Reading a value off a chart

/// Horizontal reference lines behind a chart, labelled.
///
/// Without them these charts are shapes: you can see the wind rises at four
/// and drops after nine, but not whether it rises to twelve or to twenty —
/// which is the entire question. One rule per interval, labelled, and the
/// threshold this app cares about drawn heavier than the rest, so "is it
/// going to be on?" is answered by looking rather than by reading a caption.
struct ChartGrid: View {

    let peak: Double
    /// Nil picks an interval from the range — five knots for a normal day,
    /// wider once it is blowing hard enough that five-knot rules would be a
    /// stack of stripes.
    var step: Double?
    var unit: String = "kn"
    /// The line worth calling out. Fifteen knots is the app's own "firing"
    /// threshold, the same number the map pins and the wind cards use.
    var highlight: Double? = 15

    /// The hours the chart spans, for vertical rules. Empty draws none.
    ///
    /// Without them a wind line is a shape with no when: a rider can see the
    /// build but not whether it lands before or after they can get to the
    /// beach, which is the only question the chart is being asked.
    var times: [Date] = []
    var timeZone: TimeZone?

    private var interval: Double {
        if let step { return step }
        return switch peak {
        case ..<22: 5
        case ..<45: 10
        default: 20
        }
    }

    private var levels: [Double] { Self.levels(peak: peak, step: interval) }

    static func levels(peak: Double, step: Double) -> [Double] {
        guard peak > 0, step > 0 else { return [] }
        return Array(stride(from: step, through: peak, by: step))
    }

    static func interval(for peak: Double) -> Double {
        switch peak {
        case ..<22: 5
        case ..<45: 10
        default: 20
        }
    }

    var body: some View {
        GeometryReader { geometry in
            timeRules(in: geometry.size)

            ForEach(levels, id: \.self) { level in
                let isKey = highlight.map { abs($0 - level) < 0.01 } ?? false
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(isKey ? AnyShapeStyle(Color.accentColor.opacity(0.75))
                              : AnyShapeStyle(Color(.systemGray2).opacity(0.55)))
                        .frame(height: isKey ? 2 : 1)
                    // Below the rule rather than above it: the topmost line
                    // sits at y = 0 and a label above it would be clipped.
                    // On a chip, because the traces cross straight through
                    // where the label sits and bare text became unreadable
                    // wherever a line happened to pass.
                    Text(label(level))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isKey ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: 2, y: 2)
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .offset(y: geometry.size.height * (1 - level / peak))
            }
        }
        .allowsHitTesting(false)
    }

    /// Vertical rules every six hours, with the day called out at midnight.
    /// The spot's own calendar, so a rule labelled midnight is midnight
    /// where the rider is sailing rather than where their phone thinks it is.
    private var calendar: Calendar {
        var calendar = Calendar.current
        if let timeZone { calendar.timeZone = timeZone }
        return calendar
    }

    private var marks: [Int] {
        guard times.count > 1 else { return [] }
        return times.indices.filter { calendar.component(.hour, from: times[$0]) % 6 == 0 }
    }

    @ViewBuilder
    private func timeRules(in size: CGSize) -> some View {
        if times.count > 1 {
            ForEach(marks, id: \.self) { index in
                let x = size.width * Double(index) / Double(times.count - 1)
                let hour = calendar.component(.hour, from: times[index])
                let isMidnight = hour == 0

                Rectangle()
                    .fill(Color(.systemGray3).opacity(isMidnight ? 0.55 : 0.3))
                    .frame(width: isMidnight ? 1.5 : 1, height: size.height)
                    .offset(x: x)

                Text(stamp(times[index], midnight: isMidnight))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    // Offset back by half its own width would need a
                    // measurement; nudging right of the rule is enough and
                    // never clips at the left edge.
                    .offset(x: x + 3, y: size.height - 11)
            }
        }
    }

    private func stamp(_ date: Date, midnight: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(midnight ? "EEE" : "ha")
        return formatter.string(from: date)
    }

    private func label(_ level: Double) -> String {
        let value = level.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(level))"
            : String(format: "%.1f", level)
        return "\(value)\(unit.isEmpty ? "" : " \(unit)")"
    }
}

/// One model's wind as a line across the card.
private struct ModelTrace: Shape {
    let speeds: [Double?]
    let peak: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard speeds.count > 1 else { return path }
        let step = rect.width / CGFloat(speeds.count - 1)
        var started = false
        for (index, speed) in speeds.enumerated() {
            guard let speed else { continue }
            let point = CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - rect.height * CGFloat(speed / peak)
            )
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        return path
    }
}

/// A hairline, as a shape — the only way to dash a rule in SwiftUI.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// The blend, closed down to the floor.
///
/// The faint fill under the heavy line is what makes the blend read as one
/// body rather than as the thickest of five lines — mass, at five per cent,
/// which is enough to win a squint test and not enough to be mistaken for a
/// reading of its own.
private struct BlendArea: Shape {
    let speeds: [Double?]
    let peak: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard speeds.count > 1, peak > 0 else { return path }
        let step = rect.width / CGFloat(speeds.count - 1)
        var points: [CGPoint] = []
        for (index, speed) in speeds.enumerated() {
            guard let speed else { continue }
            points.append(CGPoint(x: rect.minX + CGFloat(index) * step,
                                  y: rect.maxY - rect.height * CGFloat(speed / peak)))
        }
        guard points.count > 1 else { return path }
        path.move(to: CGPoint(x: points[0].x, y: rect.maxY))
        points.forEach { path.addLine(to: $0) }
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Comparing the models properly

/// The models, full screen, scrollable and switchable.
///
/// The card version is a thumbnail: four lines over one day, enough to see
/// whether they agree. This is the version for actually deciding. It runs as
/// far forward as the models do, it lets a rider turn off the one they do not
/// trust at this spot — everybody who watches forecasts closely has an
/// opinion about that — and it redraws the blend from whatever is left, so
/// the answer visibly changes as you include and exclude.
struct ModelCompareScreen: View {

    let title: String
    let coordinate: Geo.Coordinate

    @Environment(AppSettings.self) private var settings
    @State private var outlook = WindOutlook(hours: [], models: [])
    @State private var ensemble = EnsembleOutlook(hours: [], members: [])
    @State private var steadiness = ModelSteadiness(rows: [])
    @State private var enabled: Set<String> = []
    @State private var isLoading = true
    /// The hour under the reading line.
    @State private var probe: Int?
    /// Everything derived from the forecast and the model switches.
    @State private var series = ModelSeries()

    /// The model hues, and the whole point of them: colour on this screen
    /// means "this is a model", and nothing else.
    ///
    /// Fully saturated blue, orange, green and magenta competed with the
    /// blend on equal terms, so five lines arrived at once and none of them
    /// read first. These are the same hues at a shared, lower chroma —
    /// traceable individually, never louder than the answer they support.
    /// Lifted in the dark field, where a mid-tone on navy loses the contrast
    /// it had on white.
    ///
    /// NBM is graphite on purpose: it is NOAA's own blend of the others
    /// rather than a fifth opinion, so it wears no hue of its own.
    static let palette: [Color] = [
        hue(0x6E92C4, dark: 0x8CB0E0),
        hue(0xC9924F, dark: 0xE0AC6B),
        hue(0x5FA37A, dark: 0x7CC298),
        hue(0xA277B4, dark: 0xBE96CE),
        hue(0x7A8391, dark: 0x9AA4B3),
    ]

    static func hue(_ light: Int, dark: Int) -> Color {
        func make(_ value: Int) -> UIColor {
            UIColor(red: Double((value >> 16) & 0xFF) / 255,
                    green: Double((value >> 8) & 0xFF) / 255,
                    blue: Double(value & 0xFF) / 255, alpha: 1)
        }
        let day = make(light), night = make(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? night : day })
    }

    /// Ten points an hour is roughly a day per screen — close enough to read
    /// a sea breeze, far enough that a week is a few flicks away.
    static let hourWidth: CGFloat = 10

    /// The card's shadow: a cool ink rather than black, so the lift reads as
    /// depth instead of as dirt on a white field.
    static let shadowInk = Color(red: 20 / 255, green: 30 / 255, blue: 45 / 255)

    private var zone: TimeZone { outlook.timeZone ?? .current }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ForecastLoadingPlaceholder()
            } else if outlook.isEmpty {
                ContentUnavailableView("No model data here",
                                       systemImage: "chart.xyaxis.line",
                                       description: Text("The global models returned nothing for this point."))
            } else {
                // Readout, plot and direction row are one object on a white
                // field. The plot used to be drawn straight onto the app's
                // pale blue surface, which cost contrast on every line laid
                // over it — five models, a blend and a gust band all paying
                // for a background nobody was reading.
                VStack(spacing: 0) {
                    readout
                    // Equatable, and deliberately: the reading line writes
                    // `probe` as the forecast slides under it, and without
                    // this the chart rebuilt — four full-width vector traces,
                    // a gust band and a hundred and thirty date labels — on
                    // every one of those writes. The chart depends on the
                    // forecast and the switches, neither of which a scroll
                    // touches.
                    ModelChart(outlook: outlook, series: series, enabled: enabled, zone: zone) { hour in
                        probe = hour
                    }
                    .equatable()
                    .frame(maxHeight: .infinity)
                }
                .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 26))
                .shadow(color: Self.shadowInk.opacity(0.06), radius: 1, y: 1)
                .shadow(color: Self.shadowInk.opacity(0.16), radius: 14, y: 9)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                toggles
            }
        }
        .background(Color.deepSurface)
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Models")
        .task {
            async let members = OpenMeteo.ensemble(at: coordinate)
            outlook = await OpenMeteo.outlook(at: coordinate, days: 16, pastDays: 1)
            // Composites start switched off: the NBM already contains the
            // other lines, and averaging it in with them counts the same
            // physics twice. Its chip is right there for anyone who wants
            // the comparison — or who trusts NOAA's blend over ours.
            enabled = Set(outlook.models.filter { !$0.isComposite }.map(\.id))
            recompute()
            withAnimation(.easeOut(duration: 0.25)) { isLoading = false }
            // After the main chart is up — the probability line and the
            // track record are bonuses, not something the screen waits on.
            async let record = OpenMeteo.modelRecord(near: coordinate)
            ensemble = await members
            steadiness = await record
        }
        .onChange(of: enabled) { _, _ in recompute() }
    }

    private func recompute() {
        series = ModelSeries(outlook: outlook, enabled: enabled, zone: zone)
    }

    // MARK: The value under the reading line

    /// What the models say at the hour being read, or at now when the rider
    /// has not moved the chart.
    ///
    /// One number, and what surrounds it. The row of coloured per-model
    /// figures that used to sit here was five competing accents in the
    /// header of a screen whose whole argument is that the blend is the
    /// answer; the spread underneath the direction says the same thing in
    /// one line — how far apart they are is what a rider needs, not which
    /// of them is which.
    private var readout: some View {
        let hour = probe ?? series.nowIndex ?? 0
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(outlook.hours[safe: hour].map {
                        $0.formatted(Date.FormatStyle(timeZone: zone)
                            .weekday(.abbreviated).month(.abbreviated).day().hour())
                    } ?? "—")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    // Grey, not orange: nothing on this screen wears a
                    // colour unless it is a model.
                    if probe == nil, series.nowIndex != nil {
                        Text("now")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let value = series.blend[safe: hour] ?? nil {
                        // The one colour that is not a model, and it earns
                        // it: fifteen knots is the app's firing line, the
                        // same threshold the map pins and the dashed rule on
                        // the plot are speaking about.
                        (Text("\(Int(value.rounded()))").font(.system(size: 34, weight: .bold))
                         + Text(" kn").font(.system(size: 15, weight: .semibold)))
                            .foregroundStyle(value >= 15 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .monospacedDigit()
                    }
                    if let gust = series.gusts[safe: hour] ?? nil {
                        Text("gusting \(Int(gust.rounded()))")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                if let direction = series.directions[safe: hour] ?? nil {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .rotationEffect(.degrees(direction + 180))
                        Text(Format.cardinal(direction))
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                if let spread = spread(at: hour) {
                    Text(spread)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let chances = chances(at: hour) {
                    Text(chances)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    /// How far apart the switched-on models are at this hour — the sentence
    /// the per-model figures used to spell out in five colours.
    private func spread(at hour: Int) -> String? {
        let values = outlook.models
            .filter { enabled.contains($0.id) && !$0.isComposite }
            .compactMap { $0.speeds[safe: hour] ?? nil }
        guard values.count > 1, let low = values.min(), let high = values.max() else { return nil }
        guard high - low >= 1 else { return "models agree" }
        return "spread \(Int(low.rounded()))–\(Int(high.rounded())) kn"
    }

    /// The hour as a distribution, when the ensemble covers it.
    ///
    /// The models above are four best guesses; this is one model's honest
    /// range — thirty-one runs from nudged starting points, read out as a
    /// show of hands over the bar a rider actually cares about.
    private func chances(at hour: Int) -> String? {
        guard let date = outlook.hours[safe: hour],
              let index = ensemble.hourIndex(of: date),
              let chance = ensemble.probabilityAtLeast(15, at: index),
              let low = ensemble.percentile(10, at: index),
              let high = ensemble.percentile(90, at: index)
        else { return nil }
        return "\(Int((chance * 100).rounded()))% over 15 kn · GEFS \(Int(low.rounded()))–\(Int(high.rounded()))"
    }

    // MARK: Switching models

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The blend, set apart from the models rather than listed
            // beside them — it is the answer, and the models are what it is
            // made of. A legend that ranked them equally was the same
            // mistake the chart used to make.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary)
                    .frame(width: 22, height: 3.5)
                Text("Blend")
                    .font(.system(size: 13, weight: .semibold))
                Text("average of the \(enabled.count) model\(enabled.count == 1 ? "" : "s") switched on")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 14))

            FlowLayout(spacing: 6) {
                ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                    let on = enabled.contains(model.id)
                    Button {
                        // Never all off — an empty blend is a blank screen
                        // with no way back except guessing.
                        if on, enabled.count > 1 { enabled.remove(model.id) }
                        else { enabled.insert(model.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                // A neutral grey turns warm against this
                                // app's navy — the off state borrows the
                                // chart's own cool slate instead.
                                .fill(on ? Self.palette[index % Self.palette.count]
                                      : ModelChart.dayRule)
                                .frame(width: 6, height: 6)
                            Text(model.label)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                // A pill that wraps its own label is a
                                // two-line pill; the row wraps instead.
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background {
                            if on {
                                Capsule().fill(Color.deepCard)
                            } else {
                                Capsule().strokeBorder(ModelChart.dayRule, lineWidth: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !steadiness.isEmpty {
                steadinessRows
            }

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Each model's recent record at this point — how far its two-day-ahead
    /// call has typically drifted from its own final hour.
    ///
    /// Everybody who watches forecasts closely has an opinion about which
    /// model to trust at their spot; this is that opinion, measured. Said
    /// plainly as steadiness rather than accuracy, because the reference is
    /// the model's freshest run and not an anemometer — a steady model can
    /// still be steadily wrong, and the caption owns that.
    private var steadinessRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(steadiness.verifiedAgainst == nil
                 ? "TWO DAYS OUT, PAST TWO WEEKS"
                 : "AGAINST A REAL ANEMOMETER, TWO DAYS OUT")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(steadiness.rows) { row in
                    if let drift = row.twoDaysOutKn {
                        HStack(spacing: 3) {
                            if row.id == steadiness.steadiest?.id {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tint)
                            }
                            Text(row.label)
                                .font(.caption2.weight(.semibold))
                            Text("±\(drift, specifier: "%.1f") kn")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            Text(steadinessCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steadinessCaption: String {
        if let buoy = steadiness.verifiedAgainst {
            return "Each model's two-day-ahead call scored against what the \(buoy.name) buoy"
                + " (\(Format.distance(buoy.metres, unit: settings.units.distance)) from here)"
                + " actually measured over the past two weeks. Real verification, not model self-agreement."
        }
        return "How far each model's two-day-ahead call here has drifted from its own final hour. Steadiness, not verified truth — but the one that keeps changing its story has told you something."
    }

    private var footnote: String {
        let horizons = outlook.models.compactMap { model -> String? in
            guard enabled.contains(model.id), let end = outlook.horizon(of: model) else { return nil }
            return "\(model.label) to \(end.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated)))"
        }
        let nbm = outlook.models.contains { $0.isComposite }
            ? " NBM is NOAA's own blend of dozens of models corrected against real stations — a benchmark line, off by default so it is not averaged in beside its own ingredients."
            : ""
        return "The heavy line is the blend of whatever is switched on. Models run to different horizons — "
            + horizons.joined(separator: ", ")
            + ". Free from Open-Meteo." + nbm
    }
}

// MARK: - What the chart is drawn from

/// The forecast, reduced to exactly what the chart draws.
///
/// Every field here was a computed property on the screen, and the screen's
/// body ran on every frame of a horizontal drag. That meant re-blending four
/// models across four hundred hours several times over, asking `Calendar` for
/// the hour of each of those four hundred dates to find the midnights, and
/// formatting a hundred and thirty date labels — sixty times a second, to
/// answer a question whose answer had not changed. None of it depends on where
/// the chart is scrolled to; all of it depends on which models are switched
/// on. So it is worked out when that changes, and not otherwise.
struct ModelSeries {

    var blend: [Double?] = []
    var gusts: [Double?] = []
    var directions: [Double?] = []
    var peak: Double = 1
    var levels: [Double] = []
    /// Every sixth hour carries a label and an arrow. Denser than that and
    /// they collide at ten points an hour.
    var ticks: [Int] = []
    var arrowTicks: [Int] = []
    var midnights: Set<Int> = []
    /// The hour we are actually in — where the greyed hindcast stops and
    /// the forecast starts.
    var nowIndex: Int?
    /// The header, already formatted.
    var headings: [Heading] = []
    /// One row of arrows per switched-on model, under the blend's own row.
    ///
    /// The blend's direction is a vector average, and an average hides the
    /// argument: four models at 6 kn from the west and one at 6 kn from the
    /// south still average to something west-ish, and the rider never learns
    /// that a model they trust is calling a different wind entirely. The
    /// speed lines have always been shown model by model for exactly that
    /// reason; the direction had no such row until now.
    var directionRows: [DirectionRow] = []

    struct Heading: Identifiable {
        let id: Int
        let text: String
        let isMidnight: Bool
    }

    /// A model's directions, and the hue its trace already wears.
    struct DirectionRow: Identifiable {
        let id: String
        let label: String
        let tint: Color
        let directions: [Double?]
    }

    init() {}

    init(outlook: WindOutlook, enabled: Set<String>, zone: TimeZone) {
        blend = outlook.blend(of: enabled)
        gusts = outlook.blendGusts(of: enabled)
        directions = outlook.blendDirections(of: enabled)

        // Gusts set the ceiling as well as the speeds, and the ceiling is
        // then rounded up to a whole gridline: the band drawn from the blend
        // up to the gust used to run off the top of the plot on any day
        // gustier than it was windy, which is most of them. The floor of
        // four steps keeps a calm day's axis at twenty knots rather than
        // magnifying a two-knot afternoon into a mountain range.
        let shown = outlook.models.filter { enabled.contains($0.id) }
        let highest = max(shown.flatMap { $0.speeds.compactMap { $0 } }.max() ?? 1,
                          outlook.consensusGusts.compactMap { $0 }.max() ?? 1)
        let step = ChartGrid.interval(for: highest)
        peak = max((highest / step).rounded(.up) * step, step * 4)
        levels = ChartGrid.levels(peak: peak, step: step)

        // Six-hourly, not three: at ten points an hour a three-hourly label
        // is thirty points from its neighbour, which is not enough for
        // "12 PM" and was never enough for a weekday.
        ticks = outlook.hours.indices.filter { $0 % 6 == 0 }
        arrowTicks = outlook.hours.indices.filter { $0 % 6 == 0 }

        // In the order the plot draws them, wearing the same hues, so a row
        // of arrows and the line above it are obviously the same model. A
        // model that reports no direction at all — some regional runs only
        // carry speed — gets no row rather than an empty lane.
        directionRows = outlook.models.enumerated().compactMap { index, model in
            guard enabled.contains(model.id),
                  model.directions.contains(where: { $0 != nil })
            else { return nil }
            return DirectionRow(id: model.id,
                                label: model.label,
                                tint: ModelCompareScreen.palette[index % ModelCompareScreen.palette.count],
                                directions: model.directions)
        }

        var calendar = Calendar.current
        calendar.timeZone = zone
        midnights = Set(outlook.hours.indices.filter {
            calendar.component(.hour, from: outlook.hours[$0]) == 0
        })

        let now = Date()
        nowIndex = outlook.hours.lastIndex { $0 <= now }

        let dayStyle = Date.FormatStyle(timeZone: zone).weekday(.abbreviated)
        let hourStyle = Date.FormatStyle(timeZone: zone).hour()
        headings = ticks.map { hour in
            let isMidnight = midnights.contains(hour)
            return Heading(id: hour,
                           text: outlook.hours[hour].formatted(isMidnight ? dayStyle : hourStyle),
                           isMidnight: isMidnight)
        }
    }
}

// MARK: - The chart

/// A proper plot: labelled axis down the left, hours across the top, rules
/// both ways, and the wind's direction under every few columns.
///
/// The axis and the rules sit outside the scroll view. Only the data moves —
/// a scale that slides away with its own traces is decoration.
private struct ModelChart: View, Equatable {

    let outlook: WindOutlook
    let series: ModelSeries
    let enabled: Set<String>
    let zone: TimeZone
    /// Called when the hour under the reading line changes — whole hours, so
    /// a drag reports thirty times rather than three thousand.
    let onProbe: (Int) -> Void

    /// Everything this draws comes from the forecast and the switches. The
    /// closure is deliberately not compared: it writes the reading out, and
    /// comparing it would defeat the point of being equatable at all.
    static func == (lhs: ModelChart, rhs: ModelChart) -> Bool {
        lhs.enabled == rhs.enabled
            && lhs.series.peak == rhs.series.peak
            && lhs.series.blend.count == rhs.series.blend.count
            && lhs.series.nowIndex == rhs.series.nowIndex
            && lhs.series.directionRows.count == rhs.series.directionRows.count
    }

    /// Drives the initial scroll. Anchor views cannot do it here: the ticks
    /// are positioned with `.offset`, which moves them visually without moving
    /// them in layout, so `scrollTo` saw every one of them at zero and could
    /// only ever land on the first hour.
    @State private var scroll = ScrollPosition()
    @State private var hasLanded = false
    /// The hour under the reading line, kept here as well as reported out —
    /// the knob has to know where the blend is to sit on it.
    @State private var probe: Int?

    static let headerHeight: CGFloat = 24
    /// The blend's arrow band, plus the gap that keeps it off the plot floor.
    /// They were sitting directly on the axis, which read as part of the
    /// chart rather than as its own row.
    static let arrowsHeight: CGFloat = 46
    /// One lane per model beneath it. Fourteen points is an eleven-point
    /// glyph with air around it — enough that five lanes still fit under a
    /// plot worth reading, and the whole point of the lanes is the moment
    /// one of them disagrees, which is legible at any size.
    static let modelArrowsHeight: CGFloat = 14
    static let arrowsGap: CGFloat = 10
    private static let axisWidth: CGFloat = 32

    /// The band grows with the switches, so the plot has to be measured
    /// against however many lanes are showing rather than a fixed footer.
    var footerHeight: CGFloat {
        Self.arrowsGap + Self.arrowsHeight
            + CGFloat(series.directionRows.count) * Self.modelArrowsHeight
    }

    /// The chart's own greys. Named rather than sprinkled, because the whole
    /// argument of this screen is that chrome is grey and data is coloured —
    /// the moment a rule picks up a hue it starts competing for the eye.
    static let rule = ModelCompareScreen.hue(0xE6EAEF, dark: 0x1E4462)
    static let dayRule = ModelCompareScreen.hue(0xC8D0DA, dark: 0x2C5A7C)
    static let reference = ModelCompareScreen.hue(0xC8D0DA, dark: 0x33627F)
    /// The gust band's blue — the one non-model colour on the plot, and it
    /// is a fill at fourteen per cent rather than a line, so it never reads
    /// as a series.
    static let gust = ModelCompareScreen.hue(0x5B8FD6, dark: 0x7FB0EE)

    private var hourWidth: CGFloat { ModelCompareScreen.hourWidth }
    private var palette: [Color] { ModelCompareScreen.palette }

    var body: some View {
        // A horizontal ScrollView gives its content unbounded vertical space,
        // so `maxHeight: .infinity` on the plot expanded past the viewport and
        // pushed the arrow row off the bottom. The height has to be measured
        // here and handed down.
        GeometryReader { outer in
            chartBody(plotHeight: max(80, outer.size.height
                                      - Self.headerHeight - footerHeight - 20))
        }
    }

    private func chartBody(plotHeight: CGFloat) -> some View {
        let width = CGFloat(outlook.hours.count) * hourWidth

        return HStack(spacing: 0) {
            axisGutter(plotHeight: plotHeight)
            ZStack(alignment: .topLeading) {
                horizontalRules(plotHeight: plotHeight)
                GeometryReader { viewport in
                    let half = viewport.size.width / 2
                    ScrollView(.horizontal, showsIndicators: true) {
                        // Held apart from this view and compared by value:
                        // the knob below rides the blend as the chart
                        // scrolls, which re-runs this body on every hour it
                        // passes, and rebuilding four full-width traces and
                        // a hundred and thirty labels at that rate is what
                        // used to make the drag stutter. Nothing in here
                        // depends on where the chart is scrolled to.
                        ChartContent(outlook: outlook, series: series, enabled: enabled,
                                     width: width, plotHeight: plotHeight)
                            .equatable()
                            // Half a viewport either side, so the first hour
                            // and the last can both be brought to the middle.
                            // Without it the ends of the forecast are
                            // unreadable — the reading line can never reach
                            // them.
                            .padding(.horizontal, half)
                    }
                    .scrollPosition($scroll)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    // Whatever sits under the middle of the screen is what the
                    // header reads out. The line does not move; the forecast
                    // does, which makes the whole chart the control rather
                    // than a hairline somebody has to catch with a fingertip.
                    //
                    // Transformed to a whole hour rather than to the raw
                    // offset: the action only runs when the value it is given
                    // changes, and the readout can only say one hour at a
                    // time. At ten points an hour that is one update per ten
                    // points of travel instead of one per pixel.
                    .onScrollGeometryChange(for: Int.self) { geometry in
                        // The centre sits at `offset + half` on screen, and
                        // the content's leading padding is also `half`, so in
                        // data coordinates the two cancel to the offset itself.
                        let hour = Int(geometry.contentOffset.x / hourWidth + 0.5)
                        return min(max(0, hour), max(0, outlook.hours.count - 1))
                    } action: { _, hour in
                        probe = hour
                        onProbe(hour)
                    }
                    .overlay(alignment: .top) {
                        // Fixed to the screen, not to the data — and chrome,
                        // not a series. A hairline through the plot *and*
                        // the direction row underneath, so the two read as
                        // one crosshair, with a knob where it crosses the
                        // blend. The knob is what makes a line this faint
                        // findable: it is the reading, sitting on the answer.
                        ZStack(alignment: .top) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.18))
                                .frame(width: 1)

                            if let hour = probe ?? series.nowIndex,
                               let value = series.blend[safe: hour] ?? nil {
                                Circle()
                                    .fill(Color.deepCard)
                                    .stroke(Color.primary, lineWidth: 2.5)
                                    .frame(width: 10, height: 10)
                                    .offset(y: Self.headerHeight
                                            + plotHeight * (1 - value / series.peak) - 5)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .onChange(of: outlook.hours.count, initial: true) { _, _ in
                        // Open with now under the reading line. A day of
                        // history stays to the left for anyone who wants to
                        // scroll back into it, but nobody opens a forecast to
                        // look at yesterday.
                        //
                        // The probe reads `offset / hourWidth`, so the offset
                        // that puts an hour under the line is simply that hour
                        // times the column width — no anchor needed.
                        guard !hasLanded, let now = series.nowIndex else { return }
                        hasLanded = true
                        scroll.scrollTo(x: CGFloat(now) * hourWidth)
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    /// The scale, and only the scale. The "kn" caption that used to sit at
    /// the top of it is gone: the unit is already stated beside the number
    /// in the readout, and repeating it in the plot spent ink on something
    /// nobody was going to misread.
    private func axisGutter(plotHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(series.levels, id: \.self) { level in
                Text("\(Int(level))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: Self.axisWidth - 6, alignment: .trailing)
                    .offset(y: Self.headerHeight + plotHeight * (1 - level / series.peak) - 7)
            }
            directionKey(plotHeight: plotHeight)
        }
        .frame(width: Self.axisWidth)
    }

    /// Which lane of arrows belongs to which model, in the gutter.
    ///
    /// The lanes themselves scroll, so anything naming them has to live out
    /// here beside the scale or it slides away with the forecast. A dot in
    /// the model's hue is enough: the chips below and the traces above
    /// already spend that colour on the same claim.
    private func directionKey(plotHeight: CGFloat) -> some View {
        let top = Self.headerHeight + plotHeight + Self.arrowsGap
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.primary)
                .frame(width: 12, height: 3)
                .frame(width: Self.axisWidth - 6, alignment: .trailing)
                .offset(y: top + 8)
            ForEach(Array(series.directionRows.enumerated()), id: \.element.id) { index, row in
                Circle()
                    .fill(row.tint)
                    .frame(width: 6, height: 6)
                    .frame(width: Self.axisWidth - 6, alignment: .trailing)
                    .offset(y: top + Self.arrowsHeight
                            + CGFloat(index) * Self.modelArrowsHeight
                            + Self.modelArrowsHeight / 2 - 3)
            }
        }
    }

    /// Horizontal rules only, one per five knots, quiet enough that four
    /// lines drawn across them still win.
    ///
    /// Fifteen knots is dashed rather than tinted: it is a reference a rider
    /// measures against, not a reading, and it was wearing the accent colour
    /// on a screen where colour is supposed to mean "this is a model".
    private func horizontalRules(plotHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(series.levels, id: \.self) { level in
                let isKey = abs(level - 15) < 0.01
                Group {
                    if isKey {
                        Line()
                            .stroke(Self.reference,
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            .frame(height: 1)
                    } else {
                        Rectangle()
                            .fill(Self.rule)
                            .frame(height: 1)
                    }
                }
                .offset(y: Self.headerHeight + plotHeight * (1 - level / series.peak))
            }
            // The floor, so the traces have something to stand on.
            Rectangle()
                .fill(Self.rule)
                .frame(height: 1)
                .offset(y: Self.headerHeight + plotHeight)
        }
        .allowsHitTesting(false)
    }

}

/// Everything that scrolls: the hours, the plot, the arrows.
///
/// Split from `ModelChart` for one reason. The reading line's knob rides the
/// blend as the chart moves, so the chart's body now runs on every hour that
/// passes under it — and rebuilding four full-width vector traces, a gust
/// band and a hundred and thirty date labels at that rate is exactly the
/// stutter the old `Equatable` guard existed to prevent. Nothing in here
/// depends on where the chart is scrolled to, so it is compared by value and
/// skipped.
private struct ChartContent: View, Equatable {

    let outlook: WindOutlook
    let series: ModelSeries
    let enabled: Set<String>
    let width: CGFloat
    let plotHeight: CGFloat

    static func == (lhs: ChartContent, rhs: ChartContent) -> Bool {
        lhs.enabled == rhs.enabled
            && lhs.width == rhs.width
            && lhs.plotHeight == rhs.plotHeight
            && lhs.series.peak == rhs.series.peak
            && lhs.series.blend.count == rhs.series.blend.count
            && lhs.series.nowIndex == rhs.series.nowIndex
            && lhs.series.directionRows.count == rhs.series.directionRows.count
    }

    private var hourWidth: CGFloat { ModelCompareScreen.hourWidth }
    private var palette: [Color] { ModelCompareScreen.palette }

    var body: some View {
        VStack(spacing: 0) {
            hourHeader(width: width)
            plot(width: width, height: plotHeight)
            arrowRow(width: width)
        }
    }

    /// Hours across the top, with the day named where it turns over.
    private func hourHeader(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(series.headings) { heading in
                Text(heading.text)
                    .font(.system(size: 11, weight: heading.isMidnight ? .semibold : .regular))
                    .foregroundStyle(heading.isMidnight ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .fixedSize()
                    .offset(x: CGFloat(heading.id) * hourWidth + 3, y: 3)
            }
        }
        .frame(width: width, height: ModelChart.headerHeight, alignment: .topLeading)
    }

    private func plot(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Everything left of now, greyed. The models are hindcasting
            // there rather than forecasting, and it should not read as part
            // of the decision.
            if let now = series.nowIndex, now > 0 {
                Rectangle()
                    .fill(Color(.systemGray5).opacity(0.35))
                    .frame(width: CGFloat(now) * hourWidth)
                    .frame(maxHeight: .infinity)
            }

            // Only where the day turns over. A rule every three hours put
            // more lines on the field than the forecast had, and the eye
            // has to get past all of them to reach the data.
            ForEach(series.ticks.filter { series.midnights.contains($0) }, id: \.self) { hour in
                Rectangle()
                    .fill(ModelChart.dayRule)
                    .frame(width: 1)
                    .offset(x: CGFloat(hour) * hourWidth)
            }

            // Gusts behind everything, as a filled band up from the blend —
            // the headroom above the average is the part that knocks you
            // over. Faint on purpose: it is a range, and a range drawn as a
            // slab reads as a reading.
            GustBand(speeds: series.blend, gusts: series.gusts, peak: series.peak)
                .fill(ModelChart.gust.opacity(0.14))

            ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                if enabled.contains(model.id) {
                    ModelTrace(speeds: model.speeds, peak: series.peak)
                        .stroke(palette[index % palette.count].opacity(0.5),
                                style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
                }
            }

            // The blend, twice: a faint fill down to the floor that gives it
            // mass, then the line itself at nearly four times a model's
            // weight. Squint at the chart and this is the only thing you
            // see — which is the point, because it is the only line that is
            // an answer rather than an opinion.
            BlendArea(speeds: series.blend, peak: series.peak)
                .fill(Color.primary.opacity(0.05))

            ModelTrace(speeds: series.blend, peak: series.peak)
                .stroke(Color.primary,
                        style: StrokeStyle(lineWidth: 3.8, lineCap: .round, lineJoin: .round))

            // Where each run stops. A line that simply ends looks like a
            // bug or like calm; a labelled cap says the model ran out, which
            // is the honest reading and the reason the blend thins there.
            GeometryReader { geometry in
                ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                    if enabled.contains(model.id),
                       let last = model.speeds.lastIndex(where: { $0 != nil }),
                       let value = model.speeds[last],
                       last < outlook.hours.count - 2 {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(palette[index % palette.count])
                                .frame(width: 6, height: 6)
                            Text("\(model.label) ends")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette[index % palette.count])
                                .fixedSize()
                        }
                        .offset(x: CGFloat(last) * hourWidth + 4,
                                y: geometry.size.height * (1 - value / series.peak) - 5)
                    }
                }
            }

            // Where the hindcast stops. It was a saturated orange rule,
            // which read as a sixth model; the greyed field to its left
            // already says which side of it you are on, so the edge only has
            // to be visible, not loud.
            if let now = series.nowIndex {
                Rectangle()
                    .fill(ModelChart.dayRule)
                    .frame(width: 1)
                    .offset(x: CGFloat(now) * hourWidth)
            }
        }
        .frame(width: width, height: height)
        // Rasterised once instead of re-rasterising four full-width vector
        // traces, a gust band and the rule set on every frame of a scroll.
        // The plot only changes when a model is switched on or off, and a
        // three-day forecast is three thousand points wide — redrawing that
        // as paths at sixty frames a second is what made the drag stutter.
        .drawingGroup()
    }

    /// The direction band: the blend's arrows, then a lane per model.
    ///
    /// Speed alone decides whether you go; direction decides whether the spot
    /// works at all, and reading it off a table while looking at a chart is
    /// the split every wind site closes by putting the arrows under the plot.
    /// The lanes are the same argument one level down — the blend's arrow is
    /// an average, and an average of a westerly and a southerly is a
    /// direction no model forecast. Stacked, a disagreement is a kink in one
    /// row against four that stay in line, which is the shape of it a rider
    /// can actually see.
    private func arrowRow(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            blendArrows(width: width)
            ForEach(series.directionRows) { row in
                modelArrows(row, width: width)
            }
        }
        .padding(.top, ModelChart.arrowsGap)
    }

    /// The answer's own arrows, and the only ones that get a cardinal under
    /// them — five rows of "WSW" is a wall of text where four of the rows
    /// are agreeing with the fifth.
    private func blendArrows(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(series.arrowTicks, id: \.self) { hour in
                if let direction = series.directions[safe: hour] ?? nil {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .rotationEffect(.degrees(direction + 180))
                            .foregroundStyle(.secondary)
                        Text(Format.cardinal(direction))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: hourWidth * 3)
                    .offset(x: CGFloat(hour) * hourWidth - hourWidth)
                }
            }
        }
        // Leading, not centre: the children are placed by `offset` from the
        // origin, so a centred frame shifts every arrow by half the chart's
        // width — which on a sixteen-day chart is a long way off screen.
        .frame(width: width, height: ModelChart.arrowsHeight, alignment: .topLeading)
    }

    /// One model's lane. Smaller than the blend's arrows and no cardinal
    /// beneath them: these are for comparing against each other and against
    /// the row above, not for reading a direction off.
    ///
    /// Drawn into a `Canvas` rather than as a row of rotated images. A
    /// sixteen-day forecast is around seventy arrows a lane, and five lanes
    /// of that is three hundred and fifty views laid out and composited over
    /// a chart whose whole performance story is about not doing exactly
    /// this. One glyph is resolved and stamped seventy times instead.
    private func modelArrows(_ row: ModelSeries.DirectionRow, width: CGFloat) -> some View {
        Canvas { context, size in
            guard let arrow = context.resolveSymbol(id: row.id) else { return }
            for hour in series.arrowTicks {
                guard let direction = row.directions[safe: hour] ?? nil else { continue }
                context.drawLayer { layer in
                    layer.translateBy(x: CGFloat(hour) * hourWidth + hourWidth / 2,
                                      y: size.height / 2)
                    // The glyph points up and the wind is named for where it
                    // comes from, so it is turned to face the way the wind
                    // is going — the same half-turn the readout makes.
                    layer.rotate(by: .degrees(direction + 180))
                    layer.draw(arrow, at: .zero)
                }
            }
        } symbols: {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(row.tint)
                .tag(row.id)
        }
        .frame(width: width, height: ModelChart.modelArrowsHeight)
        // A canvas is a picture as far as VoiceOver is concerned, and a
        // lane of arrows with no name is a picture of nothing. The reading
        // at the top of the screen is what actually speaks the direction;
        // this only has to say whose row was just passed over.
        .accessibilityLabel(Text("\(row.label) wind direction"))
    }
}

// MARK: - Which way it is blowing

/// A compass dial for the wind.
///
/// A bearing in degrees is precise and almost nobody reads it as a direction
/// — "315°" needs a moment's arithmetic that "NW, and the arrow points at the
/// far shore" does not. The dart points the way the wind is *going*, which is
/// the way you will drift; the label says where it is coming *from*, which is
/// how every forecast states it. Both, because riders think in both and
/// conflating them is how people end up downwind of the car.
struct WindCompass: View {

    /// Meteorological convention: the direction the wind blows *from*.
    let directionDeg: Double
    let speedKn: Double
    var gustKn: Double?
    var diameter: CGFloat = 128

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color(.systemGray6))
                Circle()
                    .strokeBorder(Color(.systemGray3), lineWidth: 5)

                ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, letter in
                    Text(letter)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        // Counter-rotated so the glyph stays upright: the
                        // outer rotation is what puts it at its point of the
                        // compass, and without this E and W lie on their side.
                        .rotationEffect(.degrees(Double(index) * -90))
                        .offset(y: -diameter / 2 + 13)
                        .rotationEffect(.degrees(Double(index) * 90))
                }

                // Drawn pointing down, so a wind *from* north (0°) needs no
                // rotation to point south, which is where it is going.
                Dart()
                    .fill(speedKn >= 15 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.8)))
                    .frame(width: diameter * 0.52, height: diameter * 0.72)
                    .rotationEffect(.degrees(directionDeg))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            }
            .frame(width: diameter, height: diameter)

            Text("from \(Format.cardinal(directionDeg)) · \(Int(directionDeg.rounded()))°")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The pointer: a long head with a swallowed tail, pointing down.
private struct Dart: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.5, 1))
        path.addLine(to: point(0.94, 0.10))
        path.addLine(to: point(0.5, 0.34))
        path.addLine(to: point(0.06, 0.10))
        path.closeSubpath()
        return path
    }
}

// MARK: - The forecast table

/// The grid every wind forecast site converged on, because it works.
///
/// A row per quantity, a column per hour, colour carrying the magnitude so
/// the eye finds the windy afternoon before it reads a single number. It is
/// dense on purpose: a rider planning a week wants to compare Tuesday
/// afternoon against Saturday morning, and a chart makes that a memory test
/// while a table makes it a glance.
///
/// The labels stay pinned while the hours scroll — a table whose row names
/// slide off is a wall of numbers.
struct ForecastTable: View {

    @Environment(AppSettings.self) private var settings

    let hours: [WeatherDetail.Hour]
    let waves: [WaveHour]
    var zone: TimeZone = .current
    /// Hours between columns. Every hour for a day, every three for a week.
    var step: Int = 1
    /// Pressure and cloud, which matter to some riders and are clutter to the
    /// rest — the same Basic/Detailed split iKitesurf offers.
    var detailed: Bool = false

    private static let columnWidth: CGFloat = 46
    private static let labelWidth: CGFloat = 64
    private static let rowHeight: CGFloat = 26
    private static let windHeight: CGFloat = 74

    private var columns: [WeatherDetail.Hour] {
        stride(from: 0, to: hours.count, by: max(1, step)).compactMap { hours[safe: $0] }
    }

    private var wavesByHour: [Date: WaveHour] {
        Dictionary(waves.map { ($0.at, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var hasWaves: Bool { !waves.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            labels
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, hour in
                        column(hour, isDayStart: isDayStart(index))
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 14))
    }

    private func isDayStart(_ index: Int) -> Bool {
        guard index > 0, let current = columns[safe: index], let previous = columns[safe: index - 1]
        else { return false }
        var calendar = Calendar.current
        calendar.timeZone = zone
        return !calendar.isDate(current.at, inSameDayAs: previous.at)
    }

    // MARK: Row names

    /// Left-aligned and in words, the way a table of numbers wants them —
    /// tiny uppercase reads as a header, and these are labels.
    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("", height: 20)                       // day
            label("Hour")
            label("Wind\n(kn)", height: Self.windHeight)
            label("Gust")
            label("Sky")
            label(settings.units.temperatureUnit.symbol)
            if hasWaves {
                label("Wave\n(m)", height: Self.rowHeight * 2)
            }
            if detailed {
                label("Cloud")
                label("Rain")
                label("Pressure")
            } else {
                label("Rain")
            }
        }
        .frame(width: Self.labelWidth, alignment: .leading)
        .padding(.leading, 12)
    }

    private func label(_ text: String, height: CGFloat? = nil) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineSpacing(-2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height ?? Self.rowHeight)
    }

    // MARK: One hour

    private func column(_ hour: WeatherDetail.Hour, isDayStart: Bool) -> some View {
        let wave = wavesByHour[hour.at]
        return VStack(spacing: 0) {
            Text(isDayStart || hour.at == columns.first?.at
                 ? hour.at.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))
                 : "")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(height: 20)

            Text(hour.at.formatted(Date.FormatStyle(timeZone: zone).hour()))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.rowHeight)
                .background(Color(.systemGray6))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            windCell(hour)
            fill(hour.gustKn, tint: Self.windColour(hour.gustKn ?? 0))
            skyCell(hour)
            fill(hour.temperatureC, suffix: "°", tint: Self.temperatureColour(hour.temperatureC),
                 onColour: true)

            if hasWaves {
                // Height above the bar, the way the wind number sits above
                // its block — the eye reads the numbers in one column.
                Text(wave?.heightM.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.rowHeight)
                fill(wave?.periodS, suffix: "s", tint: Color.blue.opacity(0.75), onColour: true)
            }

            if detailed {
                fill(hour.precipitationChance, suffix: "%",
                     tint: Color.blue.opacity(min(0.55, (hour.precipitationChance ?? 0) / 150)))
                fill(hour.uvIndex, tint: Color.yellow.opacity(min(0.5, (hour.uvIndex ?? 0) / 14)))
                fill(hour.visibilityM.map { $0 / 1000 }, tint: Color(.systemGray6))
            } else {
                fill(hour.precipitationChance, suffix: "%",
                     tint: Color.blue.opacity(min(0.55, (hour.precipitationChance ?? 0) / 150)))
            }
        }
        .frame(width: Self.columnWidth)
        .overlay(alignment: .leading) {
            if isDayStart {
                Rectangle().fill(Color(.label).opacity(0.55)).frame(width: 1)
            }
        }
    }

    /// The cell iKitesurf riders read first: speed above, then a block of
    /// colour carrying the arrow, with the bearing along the bottom.
    private func windCell(_ hour: WeatherDetail.Hour) -> some View {
        VStack(spacing: 0) {
            Text(hour.windKn.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .frame(height: 20)

            VStack(spacing: 1) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .rotationEffect(.degrees((hour.directionDeg ?? 0) + 180))
                Text(hour.directionDeg.map { "\(Int($0.rounded()))" } ?? "")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.windHeight - 20)
            .background(Self.windColour(hour.windKn ?? 0))
        }
    }

    private func skyCell(_ hour: WeatherDetail.Hour) -> some View {
        Image(systemName: SpotWeather.symbol(for: hour.code, isDay: true))
            .font(.system(size: 13))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Self.rowHeight)
            .background(Color(.systemGray))
    }

    private func fill(_ number: Double?, suffix: String = "", tint: Color,
                      onColour: Bool = false) -> some View {
        Text(number.map { "\(Int($0.rounded()))" + suffix } ?? "—")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(onColour ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .frame(height: Self.rowHeight)
            .background(tint)
    }

    // MARK: Colour

    /// The wind ramp, in the units this sport argues in.
    ///
    /// Deliberately not a smooth gradient: the steps are where the decisions
    /// are. Under 8 is not happening, 12 is the small-gear line, 18 is
    /// getting serious, 25+ is a different day entirely.
    static func windColour(_ knots: Double) -> Color {
        switch knots {
        case ..<5: Color(.systemGray6)
        case ..<8: Color.cyan.opacity(0.30)
        case ..<12: Color.green.opacity(0.35)
        case ..<15: Color.green.opacity(0.65)
        case ..<18: Color.yellow.opacity(0.75)
        case ..<22: Color.orange.opacity(0.80)
        case ..<28: Color.red.opacity(0.75)
        default: Color.purple.opacity(0.70)
        }
    }

    static func temperatureColour(_ celsius: Double?) -> Color {
        guard let celsius else { return Color(.systemGray4) }
        return switch celsius {
        case ..<0: Color.indigo.opacity(0.75)
        case ..<10: Color.blue.opacity(0.65)
        case ..<18: Color.teal.opacity(0.70)
        case ..<25: Color.orange.opacity(0.80)
        default: Color.red.opacity(0.80)
        }
    }
}

// MARK: - Current conditions, the shape riders already know

/// The conditions card, laid out the way iKitesurf lays it out.
///
/// Not imitation for its own sake: this is the card our users have read
/// before every session for years, and the muscle memory is worth more than
/// any improvement we might invent. Speed on the left behind a direction
/// badge, cardinal and bearing on the right, and the three supporting numbers
/// as chips underneath.
struct ConditionsCard: View {

    @Environment(AppSettings.self) private var settings

    let weather: SpotWeather?
    let windKn: Double?
    let gustKn: Double?
    let directionDeg: Double?
    let temperatureC: Double?
    let pressureHPa: Double?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                badge

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(windKn.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("kts")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let directionDeg {
                    HStack(spacing: 8) {
                        Text(Format.cardinal(directionDeg))
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                        Rectangle()
                            .fill(Color(.systemGray3))
                            .frame(width: 1, height: 24)
                        Text("\(Int(directionDeg.rounded()))°")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            HStack(spacing: 8) {
                chip("wind", gustKn.map { "to \(Int($0.rounded())) kts" } ?? "—")
                chip("thermometer.medium", temperatureC.map {
                    Format.temperature($0, unit: settings.units.temperatureUnit)
                } ?? "—")
                chip("barometer", pressureHPa.map { "\(Int($0.rounded())) mb" } ?? "—")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    /// The direction badge: a filled disc with the arrow, which is what makes
    /// the card readable at a glance from a car park.
    private var badge: some View {
        ZStack {
            Circle()
                .fill(((windKn ?? 0) >= 15 ? Color.accentColor : Color(.systemGray4)).opacity(0.28))
            Circle()
                .strokeBorder((windKn ?? 0) >= 15 ? Color.accentColor : Color(.systemGray2), lineWidth: 2)
            if let directionDeg {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle((windKn ?? 0) >= 15 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    // `location.north` points up; the wind from north blows
                    // south, so it needs half a turn before the bearing.
                    .rotationEffect(.degrees(directionDeg + 180))
            }
        }
        .frame(width: 46, height: 46)
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(Color.deepSurface, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The band between the average and the gust.
///
/// Drawn rather than a second line because the gap is the point: a steady
/// twelve is a different day from twelve gusting twenty-five, and a thin band
/// versus a fat one says that faster than two lines to be compared.
struct GustBand: Shape {
    let speeds: [Double?]
    let gusts: [Double?]
    let peak: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard speeds.count > 1, !gusts.isEmpty, peak > 0 else { return path }
        let step = rect.width / CGFloat(speeds.count - 1)

        func y(_ value: Double) -> CGFloat { rect.maxY - rect.height * CGFloat(value / peak) }

        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        for index in speeds.indices {
            guard let speed = speeds[safe: index] ?? nil,
                  let gust = gusts[safe: index] ?? nil, gust > speed else { continue }
            let x = rect.minX + CGFloat(index) * step
            top.append(CGPoint(x: x, y: y(gust)))
            bottom.append(CGPoint(x: x, y: y(speed)))
        }
        guard top.count > 1 else { return path }
        path.move(to: top[0])
        top.dropFirst().forEach { path.addLine(to: $0) }
        bottom.reversed().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        return path
    }
}

// MARK: - Surf and swell

/// Surf height, the swell trains, and the rose — laid out the way the surf
/// apps lay it out, for the same reason the conditions card is: riders have
/// read this arrangement a thousand times.
struct SurfCard: View {

    @Environment(AppSettings.self) private var settings

    let surf: SurfConditions
    var windDirectionDeg: Double?

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                heightCard
                roseCard
            }
            swellCard
        }
    }

    // MARK: Height

    private var heightCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            // "EST." is load-bearing: this is a range derived from an
            // offshore grid point, not a reading from the beach.
            Text("SURF, EST.")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            if let range = surf.faceRangeM {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(faceRange(range))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(settings.units.distance == .imperial ? "ft" : "m")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let description = surf.sizeDescription {
                Text(description)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Where the estimate came from, so the range above is never
            // mistaken for a measurement.
            if let offshore = surf.waveHeightM {
                Text("faces, from \(Format.height(offshore, unit: settings.units.distance))"
                     + (surf.wavePeriodS.map { " @ \(Int($0.rounded()))s" } ?? "")
                     + " offshore sea")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 148)
        .padding(14)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    /// The face range in the rider's unit — whole feet, because surf is
    /// quoted in whole feet, and tenths of a metre for everyone else.
    private func faceRange(_ range: ClosedRange<Double>) -> String {
        switch settings.units.distance {
        case .imperial:
            let low = max(0, Int((range.lowerBound / DistanceUnit.metresPerFoot).rounded(.down)))
            let high = max(low + 1, Int((range.upperBound / DistanceUnit.metresPerFoot).rounded(.up)))
            return "\(low)-\(high)"
        case .metric, .nautical:
            return String(format: "%.1f–%.1f", range.lowerBound, range.upperBound)
        }
    }

    // MARK: Rose

    /// Every train on one compass, arrow length by height.
    ///
    /// Two swells at ten degrees apart behave completely differently from two
    /// ninety degrees apart, and no list of numbers shows that as fast as
    /// putting them on the same circle.
    private var roseCard: some View {
        VStack(spacing: 6) {
            ZStack {
                ForEach([1.0, 0.66, 0.33], id: \.self) { ring in
                    Circle()
                        .strokeBorder(Color(.systemGray4), lineWidth: ring == 1 ? 1 : 0.5)
                        .frame(width: 104 * ring, height: 104 * ring)
                }
                ForEach(Array(["0°", "90°", "180°", "270°"].enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(Double(index) * -90))
                        .offset(y: -60)
                        .rotationEffect(.degrees(Double(index) * 90))
                }

                if let primary = surf.primarySwell {
                    ray(primary, colour: .orange, scale: 1)
                }
                if let secondary = surf.secondarySwell {
                    ray(secondary, colour: .yellow, scale: 0.9)
                }
                // The wind, so a rider can see at once whether it is blowing
                // into the swell or with it.
                if let windDirectionDeg {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .offset(y: -62)
                        .rotationEffect(.degrees(windDirectionDeg + 180))
                }

                Circle()
                    .fill(Color(.systemBackground))
                    .frame(width: 7, height: 7)
            }
            .frame(width: 128, height: 128)

            Text("swell · wind")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .padding(.vertical, 8)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    /// An arrow from the centre pointing the way the swell is travelling,
    /// scaled by height against the biggest train on the rose.
    private func ray(_ train: SurfConditions.Train, colour: Color, scale: Double) -> some View {
        let biggest = max(surf.primarySwell?.heightM ?? 0, surf.secondarySwell?.heightM ?? 0, 0.1)
        let length = 20 + 32 * min(1, train.heightM / biggest)
        return Triangle()
            .fill(colour)
            .frame(width: 11, height: length * scale)
            .offset(y: -length * scale / 2)
            .rotationEffect(.degrees((train.directionDeg ?? 0) + 180))
    }

    // MARK: Trains

    private var swellCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SWELL")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            if let primary = surf.primarySwell {
                trainRow(primary, colour: .orange)
            }
            if let secondary = surf.secondarySwell {
                trainRow(secondary, colour: .yellow)
            }
            if let wind = surf.windWave, wind.heightM > 0.05 {
                trainRow(wind, colour: .secondary, label: "wind chop")
            }
            if surf.primarySwell == nil && surf.secondarySwell == nil {
                Text("No organised swell — what is out there is wind chop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                if let temperature = surf.seaTemperatureC {
                    Label("\(Format.temperature(temperature, unit: settings.units.temperatureUnit)) water",
                          systemImage: "thermometer.medium")
                        .font(.caption.weight(.medium))
                }
                if let suit = surf.wetsuit {
                    Text(suit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            if let current = surf.currentKn, current > 0.1 {
                Text("Current \(String(format: "%.1f", current)) kn"
                     + (surf.currentDirectionDeg.map { " setting \(Format.cardinal($0))" } ?? "")
                     + " — worth knowing on a downwinder.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private func trainRow(_ train: SurfConditions.Train, colour: Color, label: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(Format.height(train.heightM, unit: settings.units.distance))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .frame(width: 58, alignment: .leading)

            Text(train.periodS.map { "\(Int($0.rounded()))s" } ?? "—")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .leading)

            if let direction = train.directionDeg {
                Triangle()
                    .fill(colour)
                    .frame(width: 9, height: 14)
                    .rotationEffect(.degrees(direction + 180))
                Text("\(Format.cardinal(direction)) \(Int(direction.rounded()))°")
                    .font(.subheadline.weight(.medium))
            }
            if let label {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The app's call on the surf, worn openly as an opinion.
///
/// The strip's colours are facts about the wind; this is the opinion
/// `docs/OPEN.md` asked for — "worth doing; worth labelling as ours" — and
/// the label does half the work: a rating without its reasons is an oracle,
/// and oracles are exactly what this app is against. Every point earned or
/// lost is printed beside the number, in the words core's `SurfRating`
/// computed them from.
struct SurfRatingCard: View {

    let rating: SurfRating

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("OUR CALL")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("an opinion, not a measurement")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(rating.score)")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("/5")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { index in
                        Circle()
                            .fill(index < rating.score
                                  ? AnyShapeStyle(.tint)
                                  : AnyShapeStyle(Color(.systemGray4)))
                            .frame(width: 8, height: 8)
                    }
                }
            }

            Text(rating.reasons.map(\.words).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// A narrow triangle pointing up — the swell arrow.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Tide

/// The tide, drawn.
///
/// A pair of times is the usual answer and it is the wrong shape: what a
/// rider needs is where the water is *now* and which way it is going, which a
/// curve says in one look and a table makes you work out. The turns are
/// labelled on the curve rather than listed beside it, so "two hours to low"
/// is a distance rather than a subtraction.
struct TideChart: View {

    let curve: TideCurve
    var zone: TimeZone { curve.timeZone ?? .current }

    private var span: (low: Double, high: Double) {
        let low = curve.low, high = curve.high
        let pad = max(0.1, (high - low) * 0.18)
        return (low - pad, high + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            chart
            // The datum matters: the two sources measure from different
            // zeroes (MSL against MLLW), so the caption must say whose
            // curve this is — a rider comparing mismatched numbers deserves
            // the why before they conclude one of us is broken.
            Group {
                switch curve.source {
                case .model:
                    Text("Sea level against MSL, from Open-Meteo's marine model — worldwide, and a model rather than a harmonic prediction. NOAA's stations below are measured against MLLW, so their heights read differently and their times are the authority.")
                case .station(let name, let metres):
                    Text("Predicted water level against MLLW — NOAA CO-OPS harmonics for \(name), \(Format.distance(metres, unit: .metric)) from here. The authority on times and heights; still a prediction, not a gauge.")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            if let age = curve.staleAge {
                Label {
                    Text("No network right now — this curve is the model from \(Format.duration(age)) ago.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.harbourNavy)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("TIDE")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            if let now = curve.now {
                Text(String(format: "%.1f m", now.metres))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                if let rising = curve.isRising {
                    Image(systemName: rising ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(rising ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }

            Spacer(minLength: 0)

            if let next = curve.nextTurn {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(next.isHigh ? "NEXT HIGH" : "NEXT LOW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(next.at.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                            timeZone: zone)))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                }
            }
        }
    }

    /// Horizontal position of a moment across the whole curve.
    private func x(_ date: Date, width: CGFloat) -> CGFloat {
        guard let first = curve.points.first?.at, let last = curve.points.last?.at,
              last > first else { return 0 }
        return width * CGFloat(date.timeIntervalSince(first) / last.timeIntervalSince(first))
    }

    private func y(_ metres: Double, height: CGFloat) -> CGFloat {
        let range = span
        return height * (1 - CGFloat((metres - range.low) / max(0.01, range.high - range.low)))
    }

    private var chart: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = geometry.size.width

            ZStack(alignment: .topLeading) {
                // Water, filled — the shape reads as sea rather than as a
                // line chart that happens to be about the sea.
                Path { path in
                    guard let first = curve.points.first else { return }
                    path.move(to: CGPoint(x: x(first.at, width: width), y: height))
                    for point in curve.points {
                        path.addLine(to: CGPoint(x: x(point.at, width: width),
                                                 y: y(point.metres, height: height)))
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.08)],
                                     startPoint: .top, endPoint: .bottom))

                Path { path in
                    for (index, point) in curve.points.enumerated() {
                        let spot = CGPoint(x: x(point.at, width: width),
                                           y: y(point.metres, height: height))
                        if index == 0 { path.move(to: spot) } else { path.addLine(to: spot) }
                    }
                }
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                ForEach(curve.turns) { turn in
                    VStack(spacing: 1) {
                        Text(turn.at.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                                timeZone: zone)))
                            .font(.system(size: 8, weight: .bold))
                        Text(String(format: "%.1f", turn.metres))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .fixedSize()
                    .offset(x: x(turn.at, width: width) - 16,
                            y: turn.isHigh ? y(turn.metres, height: height) - 26
                                           : y(turn.metres, height: height) + 4)
                }

                if let now = curve.now {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2, height: height)
                        .offset(x: x(now.at, width: width))
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .offset(x: x(now.at, width: width) - 4,
                                y: y(now.metres, height: height) - 4)
                }
            }
        }
        .frame(height: 96)
    }
}
