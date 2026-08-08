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
                if let wind = now?.windKn {
                    VStack(alignment: .trailing, spacing: 2) {
                        (Text("\(Int(wind.rounded()))").font(.system(size: 30, weight: .heavy, design: .rounded))
                         + Text(" kn").font(.subheadline.weight(.semibold)))
                            .foregroundStyle(wind >= 15 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        if let direction = now?.directionDeg {
                            Text("from \(Format.cardinal(direction)) · \(Int(direction))°")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let gust = now?.gustKn {
                            Text("gusting \(Int(gust.rounded()))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func grid(_ now: WeatherDetail.Now) -> some View {
        let cells: [(String, String, String)] = [
            ("Feels like", now.apparentC.map { "\(Int($0.rounded()))°" } ?? "—", "thermometer.medium"),
            ("Humidity", now.humidity.map { "\(Int($0.rounded()))%" } ?? "—", "humidity"),
            ("Dew point", now.dewPointC.map { "\(Int($0.rounded()))°" } ?? "—", "drop"),
            ("Pressure", now.pressureHPa.map { "\(Int($0.rounded())) hPa" } ?? "—", "barometer"),
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

    @ViewBuilder
    private var dayPicker: some View {
        if detail.days.count > 1 {
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
        let rows = hours(for: day)
        if !rows.isEmpty {
            VStack(spacing: 0) {
                header
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, hour in
                    row(hour)
                    if index < rows.count - 1 { Divider() }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
        return detail.hours
            .filter { calendar.isDate($0.at, inSameDayAs: date) }
            .enumerated()
            .filter { $0.offset % 3 == 0 }
            .map(\.element)
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
                        .fill(isKey ? AnyShapeStyle(Color.accentColor.opacity(0.4))
                              : AnyShapeStyle(Color(.systemGray4).opacity(0.6)))
                        .frame(height: isKey ? 1 : 0.5)
                    // Below the rule rather than above it: the topmost line
                    // sits at y = 0 and a label above it would be clipped.
                    Text(label(level))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isKey ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .offset(y: 1)
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
        ScrollView(.horizontal, showsIndicators: true) {
            let width = CGFloat(outlook.hours.count) * Self.hourWidth

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ChartGrid(peak: peak)

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
