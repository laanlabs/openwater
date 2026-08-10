import OpenWaterCore
import SwiftUI

/// The swell for the next few days, in the parts of the day people go out in.
///
/// Deliberately not a single wave height per day. What decides a session is
/// the combination — how big, how long the period, which way it is coming
/// from, and what the wind is doing to it — and the whole point of a
/// multi-day view is watching that combination change. A day that is 4 ft at
/// 14 s offshore in the morning and 4 ft at 14 s onshore by noon is two
/// different days, and one number cannot say so.
struct SurfForecastScreen: View {

    let coordinate: Geo.Coordinate
    let title: String

    @Environment(AppSettings.self) private var settings

    @State private var outlook = SurfOutlook()
    @State private var isLoading = true

    private var units: UnitPreferences { settings.units }

    var body: some View {
        ScrollView {
            if isLoading {
                loading
            } else if outlook.isEmpty {
                unavailable
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    hourlyChart
                    ForEach(outlook.days) { day in
                        dayCard(day).padding(.horizontal)
                    }
                    provenance
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Surf forecast")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            outlook = await OpenMeteo.surfOutlook(at: coordinate)
            withAnimation(.easeOut(duration: 0.25)) { isLoading = false }
        }
    }

    // MARK: The hourly chart

    /// Swell and wind against one time axis, scrolling together.
    ///
    /// The shape is the point. A swell filling in over six hours and dropping
    /// out overnight is a picture, and four rows a day cannot draw it — this
    /// is the view somebody actually reads to pick a window, with the bands
    /// below as the summary of what it says.
    private var hourlyChart: some View {
        let width = CGFloat(outlook.hours.count) * Self.hourWidth
        let peakSwell = max(0.2, outlook.swellM.compactMap { $0 }.max() ?? 1)
        let peakWind = max(5, outlook.windKn.compactMap { $0 }.max() ?? 15)

        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                dayHeaders(width: width)
                bars(width: width, peak: peakSwell, series: outlook.swellM,
                     tint: .teal, height: 92, label: swellLabel)
                hourTicks(width: width)
                bars(width: width, peak: peakWind, series: outlook.windKn,
                     tint: Color(.systemBlue).opacity(0.55), height: 56, label: windLabel)
                windArrows(width: width)
            }
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .leading) {
                if let now = outlook.nowIndex {
                    Rectangle()
                        .fill(.orange)
                        .frame(width: 2)
                        .offset(x: CGFloat(now) * Self.hourWidth)
                }
            }
            .drawingGroup()
        }
        .frame(height: 250)
    }

    private static let hourWidth: CGFloat = 9

    private func dayHeaders(width: CGFloat) -> some View {
        var calendar = Calendar.current
        if let zone = outlook.timeZone { calendar.timeZone = zone }
        let starts = outlook.hours.indices.filter {
            $0 == 0 || !calendar.isDate(outlook.hours[$0],
                                        inSameDayAs: outlook.hours[$0 - 1])
        }
        return ZStack(alignment: .topLeading) {
            ForEach(starts, id: \.self) { index in
                let x = CGFloat(index) * Self.hourWidth
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 18)
                    .offset(x: x)
                Text(dayName(outlook.hours[index]))
                    .font(.caption.weight(.bold))
                    .offset(x: x + 6)
            }
        }
        .frame(height: 22, alignment: .topLeading)
    }

    /// A column per hour, with the value called out where it peaks.
    private func bars(width: CGFloat, peak: Double, series: [Double?],
                      tint: Color, height: CGFloat,
                      label: @escaping (Int) -> String?) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(outlook.hours.indices, id: \.self) { index in
                let value = series[safe: index] ?? nil
                Capsule()
                    .fill(tint)
                    .frame(width: Self.hourWidth - 3,
                           height: max(1, height * (value ?? 0) / peak))
                    .offset(x: CGFloat(index) * Self.hourWidth)
            }
            // Every sixth hour carries its number, which is enough to read a
            // scale off without a stack of labels.
            ForEach(Array(stride(from: 0, to: outlook.hours.count, by: 6)), id: \.self) { index in
                if let text = label(index) {
                    Text(text)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(index) * Self.hourWidth,
                                y: -height * ((series[safe: index] ?? nil) ?? 0) / peak - 10)
                }
            }
        }
        .frame(height: height + 12, alignment: .bottomLeading)
    }

    private func hourTicks(width: CGFloat) -> some View {
        var calendar = Calendar.current
        if let zone = outlook.timeZone { calendar.timeZone = zone }
        let ticks = outlook.hours.indices.filter {
            calendar.component(.hour, from: outlook.hours[$0]) % 6 == 0
        }
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { index in
                Text("\(calendar.component(.hour, from: outlook.hours[index]))")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .offset(x: CGFloat(index) * Self.hourWidth - 2)
            }
        }
        .frame(height: 12, alignment: .topLeading)
    }

    private func windArrows(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: 0, to: outlook.hours.count, by: 6)), id: \.self) { index in
                if let from = outlook.windFromDeg[safe: index] ?? nil {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(from + 180))
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(index) * Self.hourWidth - 3)
                }
            }
        }
        .frame(height: 16, alignment: .topLeading)
    }

    private func swellLabel(_ index: Int) -> String? {
        guard let value = outlook.swellM[safe: index] ?? nil else { return nil }
        return Format.height(value, unit: units.distance)
    }

    private func windLabel(_ index: Int) -> String? {
        guard let value = outlook.windKn[safe: index] ?? nil else { return nil }
        return "\(Int(value.rounded()))"
    }

    private func dayName(_ date: Date) -> String {
        var calendar = Calendar.current
        if let zone = outlook.timeZone { calendar.timeZone = zone }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.defaultDigits).day())
    }

    // MARK: A day

    private func dayCard(_ day: SurfOutlook.Day) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayName(day.date))
                    .font(.headline)
                Spacer()
                if let biggest = day.biggest {
                    Text(Format.height(biggest, unit: units.distance))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    if let period = day.longestPeriod {
                        Text("@ \(Int(period.rounded())) s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.bottom, 8)

            ForEach(Array(day.bands.enumerated()), id: \.element.id) { index, band in
                bandRow(band)
                if index < day.bands.count - 1 {
                    Divider().padding(.leading, 74)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func bandRow(_ band: SurfOutlook.Band) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(band.label)
                    .font(.caption.weight(.semibold))
                Text(band.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if let primary = band.primary {
                    HStack(spacing: 6) {
                        arrow(primary.directionDeg)
                        Text(Format.height(primary.heightM, unit: units.distance))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                        if let period = primary.periodS {
                            Text("@ \(Int(period.rounded())) s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    // Only when it is worth knowing about: a second train
                    // half the size of the first changes how a break works,
                    // a ripple behind it does not.
                    if let secondary = band.secondary,
                       secondary.heightM > primary.heightM * 0.4 {
                        HStack(spacing: 6) {
                            arrow(secondary.directionDeg, secondary: true)
                            Text("+ \(Format.height(secondary.heightM, unit: units.distance))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if let period = secondary.periodS {
                                Text("@ \(Int(period.rounded())) s")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } else {
                    Text("flat")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                if let wind = band.windKn {
                    HStack(spacing: 4) {
                        arrow(band.windFromDeg, wind: true)
                        Text(Format.speed(wind / 1.94384, unit: units.speed, decimals: 0))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                if let effect = band.windEffect {
                    Text(effect.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(effect.isFavourable ? .green : .secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// Direction the swell or wind is coming *from*, drawn pointing the way it
    /// travels — which is how everybody reads an arrow on a surf forecast.
    private func arrow(_ fromDegrees: Double?, secondary: Bool = false,
                       wind: Bool = false) -> some View {
        Image(systemName: "arrow.up")
            .font(.system(size: secondary ? 9 : 11, weight: .bold))
            .rotationEffect(.degrees((fromDegrees ?? 0) + 180))
            .foregroundStyle(wind ? AnyShapeStyle(.secondary)
                             : AnyShapeStyle(secondary ? Color.teal.opacity(0.6) : Color.teal))
            .opacity(fromDegrees == nil ? 0.25 : 1)
    }

    // MARK: States

    private var loading: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<4, id: \.self) { _ in
                LoadingPlaceholder(height: 160, corner: 16)
            }
        }
        .padding()
    }

    private var unavailable: some View {
        Text("No wave model for this stretch of water. Open-Meteo's marine grid covers "
             + "the open ocean and the coast, and stops at inland water.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding()
    }

    private var provenance: some View {
        Text("Open-Meteo's global wave model, free and worldwide. It is deep-water swell "
             + "at a grid point, not a break-by-break forecast: the size and timing of a "
             + "swell filling in will be about right, the face height at any particular "
             + "reef or sandbar will not. Wind is the same model that drives the wind "
             + "screens.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
