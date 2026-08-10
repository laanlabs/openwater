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
        .feedbackButton("Surf forecast")
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

                track("SURF") {
                    bars(peak: peakSwell, series: outlook.swellM,
                         tint: Color.teal, height: 86, label: swellLabel)
                }

                track("WIND") {
                    VStack(alignment: .leading, spacing: 0) {
                        bars(peak: peakWind, series: outlook.windKn,
                             tint: Color(.systemBlue).opacity(0.5), height: 54, label: nil)
                        windRow()
                    }
                }

                if outlook.tideM.contains(where: { $0 != nil }) {
                    track("TIDE") { tideTrack(height: 62) }
                }

                hourTicks()
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
            .padding(.vertical, 4)
        }
    }

    /// A labelled band of the chart.
    ///
    /// The label rides in the track's own top-left rather than in a fixed
    /// gutter: a gutter would sit still while the data scrolled under it,
    /// which is right for an axis and wrong for a name.
    private func track<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
            content()
        }
        .padding(.bottom, 10)
    }

    /// Wind arrows with their speed underneath, every third hour.
    private func windRow() -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: 0, to: outlook.hours.count, by: 3)), id: \.self) { index in
                VStack(spacing: 1) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees((outlook.windFromDeg[safe: index] ?? nil) ?? 0))
                        .foregroundStyle((outlook.windFromDeg[safe: index] ?? nil) == nil
                                         ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    if let speed = outlook.windKn[safe: index] ?? nil {
                        Text("\(Int(speed.rounded()))")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(width: Self.hourWidth * 3)
                .offset(x: CGFloat(index) * Self.hourWidth)
            }
        }
        .frame(height: 26, alignment: .topLeading)
    }

    /// The tide as a filled curve on the same axis as everything above it.
    private func tideTrack(height: CGFloat) -> some View {
        let values = outlook.tideM
        let known = values.compactMap { $0 }
        let low = known.min() ?? 0, high = known.max() ?? 1
        let range = max(0.05, high - low)

        return ZStack(alignment: .topLeading) {
            TideTrackShape(values: values, low: low, range: range)
                .fill(LinearGradient(colors: [.teal.opacity(0.35), .teal.opacity(0.04)],
                                     startPoint: .top, endPoint: .bottom))
            TideTrackShape(values: values, low: low, range: range, lineOnly: true)
                .stroke(.teal.opacity(0.8), lineWidth: 1.5)

            // The turns, which is all anybody reads off a tide track.
            ForEach(turningPoints, id: \.self) { index in
                if let value = values[safe: index] ?? nil {
                    Text(Format.height(value, unit: units.distance))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(index) * Self.hourWidth - 10,
                                y: height * (1 - (value - low) / range) - 12)
                }
            }
        }
        .frame(height: height)
    }

    /// Local highs and lows in the tide.
    private var turningPoints: [Int] {
        let v = outlook.tideM
        return v.indices.filter { index in
            guard index > 0, index < v.count - 1,
                  let here = v[index] ?? nil,
                  let before = v[index - 1] ?? nil,
                  let after = v[index + 1] ?? nil else { return false }
            return (here >= before && here >= after) || (here <= before && here <= after)
        }
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
    private func bars(peak: Double, series: [Double?],
                      tint: Color, height: CGFloat,
                      label: ((Int) -> String?)?) -> some View {
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
                if let text = label?(index) {
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

    private func hourTicks() -> some View {
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

/// The tide series as a shape across the chart's own width.
private struct TideTrackShape: Shape {
    let values: [Double?]
    let low: Double
    let range: Double
    var lineOnly = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = values.enumerated().compactMap { index, value -> CGPoint? in
            guard let value else { return nil }
            let x = rect.width * Double(index) / Double(max(1, values.count - 1))
            return CGPoint(x: x, y: rect.height * (1 - (value - low) / range))
        }
        guard let first = points.first else { return path }

        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        guard !lineOnly else { return path }

        path.addLine(to: CGPoint(x: points.last?.x ?? rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: first.x, y: rect.height))
        path.closeSubpath()
        return path
    }
}
