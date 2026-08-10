import OpenWaterCore
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
        VStack(spacing: 6) {
            Text(dayName(day.date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(size(day))
                .font(.subheadline.weight(.heavy))
                .monospacedDigit()

            // One arrow per part of the day. Three is enough to see the wind
            // swing that decides a session and few enough to read at a glance.
            HStack(spacing: 5) {
                ForEach(day.bands.prefix(3)) { band in
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
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
                        .frame(width: 12, height: 4)
                }
            }
        }
        .frame(width: 78)
        .padding(.vertical, 8)
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

    private func size(_ day: SurfOutlook.Day) -> String {
        let heights = day.bands.compactMap { $0.primary?.heightM }
        guard let low = heights.min(), let high = heights.max(), high > 0.05 else {
            return "Flat"
        }
        // The low without its unit, the high with it — "1–3 ft" rather than
        // "1 ft–3 ft", which is how a range is spoken.
        let highText = Format.height(high, unit: units.distance)
        let lowNumber = Format.height(low, unit: units.distance)
            .split(separator: " ").first.map(String.init) ?? ""
        return "\(lowNumber)–\(highText)"
    }

    private func dayName(_ date: Date) -> String {
        var calendar = Calendar.current
        if let zone = outlook.timeZone { calendar.timeZone = zone }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.defaultDigits).day())
    }
}
