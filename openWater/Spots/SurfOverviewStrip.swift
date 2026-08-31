import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// A fortnight of surf at a glance, one column per day.
///
/// The question this answers is not "how big is it" but "which day should I
/// pay attention to" — so a day is three things and no more: how big, which
/// way the wind blows across the morning, midday and afternoon, and whether
/// the wind is helping. Anything else belongs on the forecast screen.
struct SurfOverviewStrip: View {

    let outlook: SurfOutlook

    @Environment(AppSettings.self) private var settings
    private var units: UnitPreferences { settings.units }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(outlook.days) { day in
                    column(day)
                    if day.id != outlook.days.last?.id {
                        Divider().frame(height: 62)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func column(_ day: SurfOutlook.Day) -> some View {
        VStack(spacing: 7) {
            Text(dayName(day.date))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            // The number carries the weight; the unit gets out of its way.
            // Repeating "ft" five times across a strip is five words nobody
            // needs to read twice.
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(size(day))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if day.biggest.map({ $0 > 0.05 }) == true {
                    Text(unitSuffix)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            // One arrow per part of the day. Three is enough to see the wind
            // swing that decides a session and few enough to read at a glance.
            HStack(spacing: 6) {
                ForEach(day.bands.prefix(3)) { band in
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees((band.windFromDeg ?? 0) + 180))
                        .foregroundStyle(band.windFromDeg == nil ? .tertiary : .secondary)
                }
            }

            // A bar per band, coloured by whether the wind is spoiling it.
            // Deliberately not a quality score: this says what the wind is
            // doing to the swell, which is a fact, rather than rating the
            // surf, which would be our opinion dressed as one.
            HStack(spacing: 3) {
                ForEach(day.bands.prefix(4)) { band in
                    Capsule()
                        .fill(colour(band))
                        .frame(width: 13, height: 4)
                }
            }
        }
        .frame(width: 86)
        .padding(.vertical, 10)
    }

    private func colour(_ band: SurfOutlook.Band) -> Color {
        guard band.primary != nil else { return Color(.systemGray4) }
        switch band.windEffect {
        case .offshore: return .green
        case .crossShore: return .orange
        case .onshore: return .pink
        case nil: return Color(.systemGray3)
        }
    }

    /// The day's size, as a range only when the range says something.
    ///
    /// "0.9–1.0 ft" is false precision dressed as detail: the model does not
    /// resolve a tenth of a foot and nobody plans around one. A range earns
    /// its dash when the day actually changes.
    private func size(_ day: SurfOutlook.Day) -> String {
        let heights = day.bands.compactMap { $0.primary?.heightM }
        guard let low = heights.min(), let high = heights.max(), high > 0.05 else {
            return "Flat"
        }
        let lowText = number(low), highText = number(high)
        return lowText == highText ? highText : "\(lowText)–\(highText)"
    }

    /// The figure alone, at the precision the unit deserves — a tenth of a
    /// metre, a whole foot.
    private func number(_ metres: Double) -> String {
        switch units.distance {
        case .imperial:
            return "\(Int((metres / DistanceUnit.metresPerFoot).rounded()))"
        case .metric, .nautical:
            return String(format: "%.1f", metres)
        }
    }

    private var unitSuffix: String {
        units.distance == .imperial ? "ft" : "m"
    }

    private func dayName(_ date: Date) -> String {
        var calendar = Calendar.current
        if let zone = outlook.timeZone { calendar.timeZone = zone }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.defaultDigits).day())
    }
}
