import Charts
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The weather over the point, in the phone's own terms.
///
/// Two charts rather than one, and deliberately. Chance of rain runs 0–100
/// and temperature runs wherever the season puts it; drawn on a shared axis
/// one of them is always a flat line at the bottom, which is the classic way
/// a combined weather chart manages to show two things and communicate
/// neither. Stacked, both are readable, and they share an x-axis so a wet
/// afternoon and a cold one line up by eye.
///
/// The numbers are Open-Meteo's `precipitation_probability`, which is what the
/// phone's conditions screens already draw — the two apps agreeing matters
/// more here than any one source being marginally better, because a household
/// checks one and then the other.
struct WeatherDetailScreen: View {

    let here: Geo.Coordinate
    let placeName: String

    @State private var detail = WeatherDetail()
    @State private var isLoading = true

    @Namespace private var page

    private var unit: TemperatureUnit { UnitPreferences.forThisDevice.temperatureUnit }

    /// Two days of hours. Past that the hourly resolution is pretending, and
    /// the day rows below carry the rest of the week.
    private var hours: [WeatherDetail.Hour] {
        let horizon = Date().addingTimeInterval(48 * 3600)
        return detail.hours.filter { $0.at >= Date().addingTimeInterval(-3600) && $0.at <= horizon }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                ScrollStop { header }
                    .prefersDefaultFocus(in: page)
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else if detail.isEmpty {
                    ScrollStop {
                        Text("No weather model for this point.")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !hours.isEmpty {
                        ScrollStop { rainChart }
                        ScrollStop { temperatureChart }
                    }
                    ForEach(detail.days) { day in
                        ScrollStop { DayRow(day: day, unit: unit) }
                    }
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
            detail = await OpenMeteo.detail(at: here)
            isLoading = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weather")
                .font(.system(size: 56, weight: .bold))
            Text(placeName)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            if let now = detail.now {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Image(systemName: SpotWeather.symbol(for: now.code, isDay: now.isDay))
                        .font(.system(size: 56))
                        .foregroundStyle(.white)
                    if let temperature = now.temperatureC {
                        Text(Format.temperature(temperature, unit: unit))
                            .font(.system(size: 100, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SpotWeather.label(for: now.code))
                            .font(.system(size: 32, weight: .semibold))
                        if let apparent = now.apparentC {
                            Text("feels like \(Format.temperature(apparent, unit: unit))")
                                .font(.system(size: 26))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
                supporting(now)
            }
        }
    }

    /// The second rank of numbers, on one line. Humidity and dew point are
    /// here rather than in the headline because nobody turns a television on
    /// to read them, and a reader who wants them knows where to look.
    private func supporting(_ now: WeatherDetail.Now) -> some View {
        HStack(spacing: 40) {
            if let humidity = now.humidity {
                Reading(label: "HUMIDITY", value: "\(Int(humidity.rounded()))%")
            }
            if let dew = now.dewPointC {
                Reading(label: "DEW POINT", value: Format.temperature(dew, unit: unit))
            }
            if let cloud = now.cloudCover {
                Reading(label: "CLOUD", value: "\(Int(cloud.rounded()))%")
            }
            if let uv = now.uvIndex {
                Reading(label: "UV", value: "\(Int(uv.rounded()))")
            }
            if let visibility = now.visibilityM {
                Reading(label: "VISIBILITY",
                        value: Format.distance(visibility, unit: UnitPreferences.forThisDevice.distance))
            }
            Spacer()
        }
        .padding(.top, 18)
    }

    /// Chance of rain, hour by hour, on a fixed 0–100 axis.
    ///
    /// Fixed on purpose: an auto-scaled axis makes a day topping out at 12%
    /// look identical to one topping out at 90%, which is the opposite of
    /// what somebody deciding whether to drive needs.
    private var rainChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CHANCE OF RAIN")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(hours) { hour in
                    BarMark(
                        x: .value("Hour", hour.at),
                        y: .value("Chance", hour.precipitationChance ?? 0)
                    )
                    .foregroundStyle(Color.blue.opacity(0.85))
                }
                RuleMark(x: .value("Now", Date()))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
            .chartYScale(domain: 0 ... 100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent))%")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis { dayAxis }
            .frame(height: 260)
        }
    }

    private var temperatureChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TEMPERATURE")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(hours) { hour in
                    if let temperature = hour.temperatureC {
                        LineMark(
                            x: .value("Hour", hour.at),
                            y: .value("Degrees", unit.convert(fromCelsius: temperature))
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                }
                RuleMark(x: .value("Now", Date()))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                    AxisValueLabel {
                        if let degrees = value.as(Double.self) {
                            Text("\(Int(degrees))°")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis { dayAxis }
            .frame(height: 260)
        }
    }

    private var dayAxis: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 12)) { value in
            AxisGridLine().foregroundStyle(.white.opacity(0.15))
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(date, format: .dateTime.weekday(.abbreviated).hour())
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct Reading: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

/// One day of the week ahead.
private struct DayRow: View {

    let day: WeatherDetail.Day
    let unit: TemperatureUnit

    var body: some View {
        HStack(spacing: 30) {
            Text(day.date, format: .dateTime.weekday(.abbreviated))
                .font(.system(size: 30, weight: .medium))
                .frame(width: 110, alignment: .leading)
            Image(systemName: SpotWeather.symbol(for: day.code, isDay: true))
                .font(.system(size: 30))
                .frame(width: 60)
            if let chance = day.precipitationChance {
                HStack(spacing: 8) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 20))
                    Text("\(Int(chance.rounded()))%")
                        .font(.system(size: 26))
                        .monospacedDigit()
                }
                // Blue only once it is worth a coat. A percentage tinted at
                // every value reads as a warning about a dry day.
                .foregroundStyle(chance >= 40 ? Color.blue : Color.secondary)
                .frame(width: 130, alignment: .leading)
            } else {
                Spacer().frame(width: 130)
            }
            if let wind = day.windMaxKn {
                Text("\(Int(wind.rounded())) kn")
                    .font(.system(size: 26))
                    .monospacedDigit()
                    .foregroundStyle(wind >= 15 ? Color.accentColor : Color.secondary)
                    .frame(width: 110, alignment: .leading)
            }
            Spacer()
            if let low = day.lowC {
                Text(Format.temperature(low, unit: unit, includeSymbol: false))
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let high = day.highC {
                Text(Format.temperature(high, unit: unit, includeSymbol: false))
                    .font(.system(size: 30, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
            }
        }
    }
}
