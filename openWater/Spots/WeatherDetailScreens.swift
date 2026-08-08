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
                    ChartGrid(peak: peak)
                    ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                        ModelTrace(speeds: model.speeds, peak: peak)
                            .stroke(Self.palette[index % Self.palette.count],
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
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
        Picker("Span", selection: $span) {
            ForEach(Span.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
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
                          step: span == .day ? 1 : 3)
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

    private var interval: Double {
        if let step { return step }
        return switch peak {
        case ..<22: 5
        case ..<45: 10
        default: 20
        }
    }

    private var levels: [Double] {
        guard peak > 0, interval > 0 else { return [] }
        return Array(stride(from: interval, through: peak, by: interval))
    }

    var body: some View {
        GeometryReader { geometry in
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
                ProgressView().frame(maxHeight: .infinity)
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
            outlook = await OpenMeteo.outlook(at: coordinate, days: 10)
            enabled = Set(outlook.models.map(\.id))
            isLoading = false
        }
    }

    // MARK: The value under the finger

    /// What the models say at the hour being touched, or at the start when
    /// nothing is.
    private var readout: some View {
        let hour = probe ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(outlook.hours[safe: hour].map {
                    $0.formatted(Date.FormatStyle(timeZone: zone)
                        .weekday(.abbreviated).hour().minute())
                } ?? "—")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if let value = blend[safe: hour] ?? nil {
                    (Text("\(Int(value.rounded()))").font(.title3.weight(.heavy))
                     + Text(" kn blend").font(.caption.weight(.semibold)))
                        .foregroundStyle(value >= 15 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .monospacedDigit()
                }
            }
            HStack(spacing: 14) {
                ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                    if enabled.contains(model.id) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Self.palette[index % Self.palette.count])
                                .frame(width: 7, height: 7)
                            Text((model.speeds[safe: hour] ?? nil).map { "\(Int($0.rounded()))" } ?? "—")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 0)
                Text(probe == nil ? "Drag the chart to read a time" : "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: The chart

    private var chart: some View {
        let width = CGFloat(outlook.hours.count) * Self.hourWidth

        // The grid sits outside the scroll view: a y-axis that slides off the
        // left edge with the traces labels nothing. Its bottom padding clears
        // the weekday strip so the rules line up with the plot, not the axis.
        return ZStack(alignment: .topLeading) {
            ChartGrid(peak: peak)
                .padding(.top, 12)
                .padding(.bottom, 28)

            ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    // Midnight rules, so a week of wind reads as days rather
                    // than as one long wobble.
                    ForEach(midnights, id: \.self) { hour in
                        Rectangle()
                            .fill(Color(.systemGray4).opacity(0.7))
                            .frame(width: 0.5)
                            .offset(x: CGFloat(hour) * Self.hourWidth)
                    }

                    ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                        if enabled.contains(model.id) {
                            ModelTrace(speeds: model.speeds, peak: peak)
                                .stroke(Self.palette[index % Self.palette.count].opacity(0.75),
                                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        }
                    }

                    // The blend last and heaviest — it is the answer, the
                    // others are the working.
                    ModelTrace(speeds: blend, peak: peak)
                        .stroke(Color.primary,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    if let probe {
                        Rectangle()
                            .fill(Color.primary.opacity(0.35))
                            .frame(width: 1)
                            .offset(x: CGFloat(probe) * Self.hourWidth)
                    }
                }
                // Fills whatever height is left rather than a fixed 260 —
                // on a tall phone that was a small chart floating in a screen
                // of nothing.
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            probe = min(max(0, Int(value.location.x / Self.hourWidth)),
                                        outlook.hours.count - 1)
                        }
                )

                axis(width: width)
            }
            .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    private var midnights: [Int] {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return outlook.hours.indices.filter { index in
            calendar.component(.hour, from: outlook.hours[index]) == 0
        }
    }

    private func axis(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(midnights, id: \.self) { hour in
                Text(outlook.hours[hour].formatted(
                    Date.FormatStyle(timeZone: zone).weekday(.abbreviated)))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(hour) * Self.hourWidth + 3)
            }
        }
        .frame(width: width, height: 16, alignment: .topLeading)
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

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGroupedBackground))
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

    private static let columnWidth: CGFloat = 44
    private static let labelWidth: CGFloat = 62

    private var columns: [WeatherDetail.Hour] {
        stride(from: 0, to: hours.count, by: max(1, step)).compactMap { hours[safe: $0] }
    }

    private var wavesByHour: [Date: WaveHour] {
        Dictionary(waves.map { ($0.at, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var hasWaves: Bool { !waves.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            labels
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, hour in
                        column(hour, isDayStart: isDayStart(index))
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func isDayStart(_ index: Int) -> Bool {
        guard index > 0, let current = columns[safe: index], let previous = columns[safe: index - 1]
        else { return false }
        var calendar = Calendar.current
        calendar.timeZone = zone
        return !calendar.isDate(current.at, inSameDayAs: previous.at)
    }

    // MARK: Rows

    private var labels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            cell("") // day
            cell("")  // hour
            cell("WIND", tall: true)
            cell("GUST")
            cell("SKY")
            cell("TEMP")
            if hasWaves {
                cell("WAVE")
                cell("PERIOD")
            }
            cell("RAIN")
        }
        .frame(width: Self.labelWidth)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func cell(_ text: String, tall: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: tall ? 58 : 24)
            .padding(.trailing, 8)
    }

    private func column(_ hour: WeatherDetail.Hour, isDayStart: Bool) -> some View {
        let wave = wavesByHour[hour.at]
        return VStack(spacing: 0) {
            Text(isDayStart || hour.at == columns.first?.at
                 ? hour.at.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated))
                 : "")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(height: 24)

            Text(hour.at.formatted(Date.FormatStyle(timeZone: zone).hour()))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(height: 24)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            windCell(hour)
            value(hour.gustKn, tint: Self.windColour(hour.gustKn ?? 0))
            skyCell(hour)
            value(hour.temperatureC, suffix: "°", tint: Self.temperatureColour(hour.temperatureC))

            if hasWaves {
                value(wave?.heightM, decimals: 1, tint: Color.blue.opacity(0.45))
                value(wave?.periodS, tint: Color.blue.opacity(0.28))
            }

            value(hour.precipitationChance, suffix: "%",
                  tint: Color.blue.opacity(min(0.6, (hour.precipitationChance ?? 0) / 140)))
        }
        .frame(width: Self.columnWidth)
        .overlay(alignment: .leading) {
            // A heavier rule where the day turns over.
            if isDayStart {
                Rectangle().fill(Color(.systemGray2)).frame(width: 1)
            }
        }
    }

    /// Speed, an arrow for direction, and the bearing — the three things the
    /// iKitesurf grid gets right and a bar chart cannot say at once.
    private func windCell(_ hour: WeatherDetail.Hour) -> some View {
        VStack(spacing: 1) {
            Text(hour.windKn.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
            if let direction = hour.directionDeg {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(direction))
                Text("\(Int(direction.rounded()))")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(Self.windColour(hour.windKn ?? 0))
    }

    private func skyCell(_ hour: WeatherDetail.Hour) -> some View {
        Image(systemName: SpotWeather.symbol(for: hour.code, isDay: true))
            .font(.system(size: 11))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(Color(.systemGray6))
    }

    private func value(_ number: Double?, suffix: String = "", decimals: Int = 0,
                       tint: Color) -> some View {
        Text(number.map { decimals > 0 ? String(format: "%.\(decimals)f", $0)
                          : "\(Int($0.rounded()))" }.map { $0 + suffix } ?? "—")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .frame(height: 24)
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
        case ..<8: Color.cyan.opacity(0.22)
        case ..<12: Color.green.opacity(0.30)
        case ..<15: Color.green.opacity(0.55)
        case ..<18: Color.yellow.opacity(0.65)
        case ..<22: Color.orange.opacity(0.70)
        case ..<28: Color.red.opacity(0.65)
        default: Color.purple.opacity(0.60)
        }
    }

    static func temperatureColour(_ celsius: Double?) -> Color {
        guard let celsius else { return Color(.systemGray6) }
        return switch celsius {
        case ..<0: Color.indigo.opacity(0.30)
        case ..<10: Color.blue.opacity(0.22)
        case ..<18: Color.teal.opacity(0.20)
        case ..<25: Color.orange.opacity(0.25)
        default: Color.red.opacity(0.35)
        }
    }
}
