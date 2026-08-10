import OpenWaterCore
import SwiftUI

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
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Now")
        .navigationBarTitleDisplayMode(.inline)
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Forecast")
        .navigationBarTitleDisplayMode(.inline)
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private static let palette: [Color] = [.blue, .orange, .green, .purple]

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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
    @State private var enabled: Set<String> = []
    @State private var isLoading = true
    /// The hour under the finger, when there is one.
    @State private var probe: Int?

    private static let palette: [Color] = [.blue, .orange, .green, .purple]
    /// Ten points an hour is roughly a day per screen — close enough to read
    /// a sea breeze, far enough that a week is a few flicks away.
    private static let hourWidth: CGFloat = 10

    private var zone: TimeZone { outlook.timeZone ?? .current }

    private var blend: [Double?] { outlook.blend(of: enabled) }

    private var peak: Double {
        let shown = outlook.models.filter { enabled.contains($0.id) }
        return max(shown.flatMap { $0.speeds.compactMap { $0 } }.max() ?? 1, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ForecastLoadingPlaceholder()
            } else if outlook.isEmpty {
                ContentUnavailableView("No model data here",
                                       systemImage: "chart.xyaxis.line",
                                       description: Text("The global models returned nothing for this point."))
            } else {
                readout
                chart
                    .frame(maxHeight: .infinity)
                toggles
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            outlook = await OpenMeteo.outlook(at: coordinate, days: 16, pastDays: 1)
            enabled = Set(outlook.models.map(\.id))
            withAnimation(.easeOut(duration: 0.25)) { isLoading = false }
        }
    }

    // MARK: The value under the finger

    /// What the models say at the hour being touched, or at the start when
    /// nothing is.
    private var readout: some View {
        let hour = probe ?? nowIndex ?? 0
        let gusts = outlook.blendGusts(of: enabled)
        let directions = outlook.blendDirections(of: enabled)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(outlook.hours[safe: hour].map {
                    $0.formatted(Date.FormatStyle(timeZone: zone)
                        .weekday(.abbreviated).month(.abbreviated).day().hour())
                } ?? "—")
                    .font(.subheadline.weight(.bold))

                if probe == nil, nowIndex != nil {
                    Text("now")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                }

                Spacer(minLength: 0)

                if let direction = directions[safe: hour] ?? nil {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(direction + 180))
                        Text(Format.cardinal(direction))
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let value = blend[safe: hour] ?? nil {
                    (Text("\(Int(value.rounded()))").font(.system(size: 28, weight: .heavy, design: .rounded))
                     + Text(" kn").font(.subheadline.weight(.semibold)))
                        .foregroundStyle(value >= 15 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .monospacedDigit()
                }
                if let gust = gusts[safe: hour] ?? nil {
                    Text("gusting \(Int(gust.rounded()))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)

                // Per model, named — a bare row of coloured numbers made you
                // match them back to the chips at the bottom of the screen.
                HStack(spacing: 10) {
                    ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                        if enabled.contains(model.id) {
                            VStack(spacing: 0) {
                                Text((model.speeds[safe: hour] ?? nil).map { "\(Int($0.rounded()))" } ?? "—")
                                    .font(.caption.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Self.palette[index % Self.palette.count])
                                Text(model.label)
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: The chart

    private static let headerHeight: CGFloat = 24
    /// The arrow band, plus the gap that keeps it off the plot floor. They
    /// were sitting directly on the axis, which read as part of the chart
    /// rather than as its own row.
    private static let arrowsHeight: CGFloat = 46
    private static let arrowsGap: CGFloat = 10
    private static let axisWidth: CGFloat = 32

    private static var footerHeight: CGFloat { arrowsHeight + arrowsGap }

    private var step: Double { ChartGrid.interval(for: peak) }
    private var levels: [Double] { ChartGrid.levels(peak: peak, step: step) }

    /// A proper plot: labelled axis down the left, hours across the top,
    /// rules both ways, and the wind's direction under every few columns.
    ///
    /// The axis and the rules sit outside the scroll view. Only the data
    /// moves — a scale that slides away with its own traces is decoration.
    private var chart: some View {
        // A horizontal ScrollView gives its content unbounded vertical space,
        // so `maxHeight: .infinity` on the plot expanded past the viewport and
        // pushed the arrow row off the bottom. The height has to be measured
        // here and handed down.
        GeometryReader { outer in
            chartBody(plotHeight: max(80, outer.size.height
                                      - Self.headerHeight - Self.footerHeight - 20))
        }
    }

    private func chartBody(plotHeight: CGFloat) -> some View {
        let width = CGFloat(outlook.hours.count) * Self.hourWidth

        return HStack(spacing: 0) {
            axisGutter
            ZStack(alignment: .topLeading) {
                horizontalRules
                ScrollViewReader { scroller in
                    GeometryReader { viewport in
                    let half = viewport.size.width / 2
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 0) {
                            hourHeader(width: width)
                            plot(width: width, height: plotHeight)
                            arrowRow(width: width)
                        }
                        // Half a viewport either side, so the first hour and
                        // the last can both be brought to the middle. Without
                        // it the ends of the forecast are unreadable — the
                        // reading line can never reach them.
                        .padding(.horizontal, half)
                        // Anchors every few hours, so the view can be sent to
                        // "now" without scrolling by raw offset.
                        .overlay(alignment: .leading) {
                            ForEach(ticks, id: \.self) { hour in
                                Color.clear
                                    .frame(width: 1)
                                    .id(hour)
                                    .offset(x: CGFloat(hour) * Self.hourWidth)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    // Whatever sits under the middle of the screen is what the
                    // header reads out. The line does not move; the forecast
                    // does, which makes the whole chart the control rather
                    // than a hairline somebody has to catch with a fingertip.
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentOffset.x
                    } action: { _, offset in
                        // The centre sits at `offset + half` on screen, and
                        // the content's leading padding is also `half`, so in
                        // data coordinates the two cancel to the offset itself.
                        let hour = Int(offset / Self.hourWidth + 0.5)
                        probe = min(max(0, hour), max(0, outlook.hours.count - 1))
                    }
                    .overlay {
                        // Fixed to the screen, not to the data.
                        Rectangle()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 1)
                            .allowsHitTesting(false)
                    }
                    .onChange(of: outlook.hours.count) { _, _ in
                        // Open on now, under the reading line. A day of
                        // history stays to the left for anyone who wants to
                        // scroll back into it, but nobody opens a forecast to
                        // look at yesterday.
                        guard let now = nowIndex else { return }
                        let anchor = ticks.min {
                            abs($0 - now) < abs($1 - now)
                        } ?? 0
                        scroller.scrollTo(anchor, anchor: .center)
                    }
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var axisGutter: some View {
        GeometryReader { geometry in
            let plotHeight = max(1, geometry.size.height - Self.headerHeight - Self.footerHeight - 20)
            ForEach(levels, id: \.self) { level in
                Text("\(Int(level))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: Self.axisWidth - 5, alignment: .trailing)
                    .offset(y: Self.headerHeight + plotHeight * (1 - level / peak) - 6)
            }
            Text("kn")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: Self.axisWidth - 5, alignment: .trailing)
                .offset(y: Self.headerHeight - 14)
        }
        .frame(width: Self.axisWidth)
    }

    private var horizontalRules: some View {
        GeometryReader { geometry in
            let plotHeight = max(1, geometry.size.height - Self.headerHeight - Self.footerHeight - 20)
            ForEach(levels, id: \.self) { level in
                let isKey = abs(level - 15) < 0.01
                Rectangle()
                    .fill(isKey ? AnyShapeStyle(Color.accentColor.opacity(0.5))
                          : AnyShapeStyle(Color(.systemGray3).opacity(0.7)))
                    .frame(height: isKey ? 1.5 : 0.75)
                    .offset(y: Self.headerHeight + plotHeight * (1 - level / peak))
            }
            // The floor, so the traces have something to stand on.
            Rectangle()
                .fill(Color(.systemGray2))
                .frame(height: 1)
                .offset(y: geometry.size.height - Self.footerHeight - 20)
        }
        .allowsHitTesting(false)
    }

    /// Hours across the top, with the day named where it turns over.
    private func hourHeader(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { hour in
                let isMidnight = midnights.contains(hour)
                Text(outlook.hours[hour].formatted(
                    isMidnight
                    ? Date.FormatStyle(timeZone: zone).weekday(.abbreviated)
                    : Date.FormatStyle(timeZone: zone).hour()))
                    .font(.system(size: 9, weight: isMidnight ? .bold : .regular))
                    .foregroundStyle(isMidnight ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .fixedSize()
                    .offset(x: CGFloat(hour) * Self.hourWidth + 3, y: 4)
            }
        }
        .frame(width: width, height: Self.headerHeight, alignment: .topLeading)
    }

    private func plot(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Everything left of now, greyed. The models are hindcasting
            // there rather than forecasting, and it should not read as part
            // of the decision.
            if let now = nowIndex, now > 0 {
                Rectangle()
                    .fill(Color(.systemGray5).opacity(0.55))
                    .frame(width: CGFloat(now) * Self.hourWidth)
                    .frame(maxHeight: .infinity)
            }

            ForEach(ticks, id: \.self) { hour in
                Rectangle()
                    .fill(midnights.contains(hour)
                          ? Color(.systemGray2) : Color(.systemGray4).opacity(0.5))
                    .frame(width: midnights.contains(hour) ? 1 : 0.5)
                    .offset(x: CGFloat(hour) * Self.hourWidth)
            }

            // Gusts behind everything, as a filled band up from the blend —
            // the headroom above the average is the part that knocks you over.
            GustBand(speeds: blend, gusts: outlook.blendGusts(of: enabled), peak: peak)
                .fill(Color.orange.opacity(0.16))

            ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                if enabled.contains(model.id) {
                    ModelTrace(speeds: model.speeds, peak: peak)
                        .stroke(Self.palette[index % Self.palette.count].opacity(0.7),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }

            ModelTrace(speeds: blend, peak: peak)
                .stroke(Color.primary,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

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
                                .fill(Self.palette[index % Self.palette.count])
                                .frame(width: 6, height: 6)
                            Text("\(model.label) ends")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Self.palette[index % Self.palette.count])
                                .fixedSize()
                        }
                        .offset(x: CGFloat(last) * Self.hourWidth + 4,
                                y: geometry.size.height * (1 - value / peak) - 5)
                    }
                }
            }

            if let now = nowIndex {
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2)
                    .offset(x: CGFloat(now) * Self.hourWidth)
            }


        }
        .frame(width: width, height: height)
    }

    /// The direction row.
    ///
    /// Speed alone decides whether you go; direction decides whether the spot
    /// works at all, and reading it off a table while looking at a chart is
    /// the split every wind site closes by putting the arrows under the plot.
    private func arrowRow(width: CGFloat) -> some View {
        let directions = outlook.blendDirections(of: enabled)
        return ZStack(alignment: .topLeading) {
            ForEach(arrowTicks, id: \.self) { hour in
                if let direction = directions[safe: hour] ?? nil {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .rotationEffect(.degrees(direction + 180))
                            .foregroundStyle((blend[safe: hour] ?? nil).map { $0 >= 15 }
                                             == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(Format.cardinal(direction))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: Self.hourWidth * 3)
                    .offset(x: CGFloat(hour) * Self.hourWidth - Self.hourWidth)
                }
            }
        }
        // Leading, not centre: the children are placed by `offset` from the
        // origin, so a centred frame shifts every arrow by half the chart's
        // width — which on a sixteen-day chart is a long way off screen.
        .frame(width: width, height: Self.arrowsHeight, alignment: .topLeading)
        .padding(.top, Self.arrowsGap)
    }

    /// Every third hour carries a label and a rule; every sixth an arrow.
    /// Denser than that and they collide at ten points an hour.
    private var ticks: [Int] {
        outlook.hours.indices.filter { $0 % 3 == 0 }
    }

    private var arrowTicks: [Int] {
        outlook.hours.indices.filter { $0 % 6 == 0 }
    }

    /// The hour we are actually in — the orange rule that separates what has
    /// happened from what is guessed.
    private var nowIndex: Int? {
        let now = Date()
        return outlook.hours.lastIndex { $0 <= now }
    }

    /// Where the day turns over, in the spot's timezone — the rules and
    /// labels that make a week read as days rather than one long wobble.
    private var midnights: [Int] {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return outlook.hours.indices.filter {
            calendar.component(.hour, from: outlook.hours[$0]) == 0
        }
    }

    // MARK: Switching models

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                    let on = enabled.contains(model.id)
                    Button {
                        // Never all off — an empty blend is a blank screen
                        // with no way back except guessing.
                        if on, enabled.count > 1 { enabled.remove(model.id) }
                        else { enabled.insert(model.id) }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(on ? Self.palette[index % Self.palette.count]
                                      : Color(.systemGray3))
                                .frame(width: 8, height: 8)
                            Text(model.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(on ? AnyShapeStyle(Color(.secondarySystemGroupedBackground))
                                    : AnyShapeStyle(Color(.systemGray6)),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                key(Color.primary, "Blend", line: true)
                key(Color.orange.opacity(0.35), "Gust range")
                key(Color.orange, "Now", line: true)
                Spacer(minLength: 0)
            }

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGroupedBackground))
    }

    private func key(_ colour: Color, _ label: String, line: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(colour)
                .frame(width: line ? 14 : 12, height: line ? 2.5 : 9)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var footnote: String {
        let horizons = outlook.models.compactMap { model -> String? in
            guard enabled.contains(model.id), let end = outlook.horizon(of: model) else { return nil }
            return "\(model.label) to \(end.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated)))"
        }
        return "The heavy line is the blend of whatever is switched on. Models run to different horizons — "
            + horizons.joined(separator: ", ")
            + ". Free from Open-Meteo."
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
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
            label("°C")
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
                chip("thermometer.medium", temperatureC.map { "\(Int($0.rounded()))°C" } ?? "—")
                chip("barometer", pressureHPa.map { "\(Int($0.rounded())) mb" } ?? "—")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
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
            Text("SURF HEIGHT")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            if let range = surf.surfRangeFt {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(range.low)-\(range.high)")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("ft")
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
            if let period = surf.wavePeriodS {
                Text("\(Int(period.rounded()))s combined sea")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 148)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
                    Label("\(Int(temperature.rounded()))°C water", systemImage: "thermometer.medium")
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func trainRow(_ train: SurfConditions.Train, colour: Color, label: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(String(format: "%.1f ft", train.heightFt))
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
            // The datum matters: heights here are against mean sea level and
            // NOAA's are against mean lower low water, so the two sets of
            // numbers will not match and a rider comparing them deserves to
            // know why before they conclude one of us is broken.
            Text("Sea level against MSL, from Open-Meteo's marine model — worldwide, and a model rather than a harmonic prediction. NOAA's stations below are measured against MLLW, so their heights read differently and their times are the authority.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
