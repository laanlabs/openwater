import Charts
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// Five days of sea, and what the wind is doing to it.
///
/// Height alone is the number people quote and the least useful one on this
/// screen. Four feet at six seconds is wind slop; four feet at fourteen is a
/// groundswell that has crossed an ocean, and the two are different sports. So
/// the chart carries the swell against the combined sea, and every band under
/// it leads with the period.
///
/// The wind matters as much as either. The same four feet is clean at dawn and
/// unrideable by noon, which is why each band says what the wind is doing to
/// it rather than only how hard it is blowing — judged against the beach's own
/// facing where the guide knows which way the spot looks.
struct WaveDetailScreen: View {

    let here: Geo.Coordinate
    let placeName: String

    @State private var outlook = SurfOutlook()
    @State private var isLoading = true
    /// Real buoys, because everything above them is a model.
    @State private var buoys: [Buoy] = []

    @Namespace private var page

    private var unit: DistanceUnit { UnitPreferences.forThisDevice.distance }

    /// Five days, the same horizon the wind screen draws, and for the same
    /// reason: past that the models are guessing and drawing them at equal
    /// weight would say otherwise.
    private static let days = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                ScrollStop { header }
                    .prefersDefaultFocus(in: page)
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else if outlook.hours.isEmpty {
                    ScrollStop {
                        Text("No marine model for this point. Inland water and some enclosed seas have no wave grid at all.")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ScrollStop { chart }
                    ForEach(outlook.days) { day in
                        ScrollStop { DayRow(day: day, unit: unit) }
                    }
                    if !reportingBuoys.isEmpty {
                        ScrollStop {
                            Text("MEASURED AT SEA")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(reportingBuoys) { buoy in
                            ScrollStop { BuoyRow(buoy: buoy, unit: unit) }
                        }
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
            async let modelled = OpenMeteo.surfOutlook(at: here, days: Self.days)
            async let moored = DataBuoyCenter.buoys(near: here, limit: 3, radius: 150_000)
            outlook = await modelled
            isLoading = false
            // After the charts, like the conditions screen loads its
            // stations: the model is the page, and the buoys confirm it.
            buoys = await moored
        }
    }

    /// Only buoys with a wave reading. A moored station that answered with
    /// nothing is a fact about its telemetry, not about the sea, and the map
    /// rules' first rule applies at sea as much as it does on a beach: a
    /// number here is a measurement or there is no row.
    private var reportingBuoys: [Buoy] {
        buoys.filter { $0.reading?.waveHeightM != nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waves and swell")
                .font(.system(size: 56, weight: .bold))
            Text(placeName)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            if let stale = outlook.staleAge {
                Label("Last good answer, \(Int(stale / 3600)) h old — the network did not reply",
                      systemImage: "wifi.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Combined sea as an area, the ground swell as a line on top of it.
    ///
    /// The gap between the two is the wind wave — the chop the model is
    /// adding on top of the swell — and reading that gap is the fastest way
    /// to tell a clean morning from a blown-out afternoon without looking at
    /// a single wind number.
    private var chart: some View {
        Chart {
            ForEach(Array(outlook.hours.enumerated()), id: \.offset) { index, hour in
                if index < outlook.totalM.count, let total = outlook.totalM[index] {
                    AreaMark(
                        x: .value("Time", hour),
                        y: .value("Height", unit.heightValue(fromMetres: total)),
                        series: .value("Series", "Sea")
                    )
                    .foregroundStyle(.linearGradient(
                        colors: [Color.cyan.opacity(0.45), Color.cyan.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom))
                }
            }
            ForEach(Array(outlook.hours.enumerated()), id: \.offset) { index, hour in
                if index < outlook.swellM.count, let swell = outlook.swellM[index] {
                    LineMark(
                        x: .value("Time", hour),
                        y: .value("Height", unit.heightValue(fromMetres: swell)),
                        series: .value("Series", "Swell")
                    )
                    .foregroundStyle(.white)
                    .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.12))
                AxisValueLabel {
                    if let height = value.as(Double.self) {
                        Text(String(format: "%.1f", height))
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.25))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.weekday(.abbreviated))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 400)
        .overlay(alignment: .topTrailing) { chartLegend }
    }

    private var chartLegend: some View {
        HStack(spacing: 24) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 36, height: 6)
                Text("Ground swell").font(.system(size: 20))
            }
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(Color.cyan.opacity(0.45))
                    .frame(width: 36, height: 18)
                Text("Combined sea").font(.system(size: 20))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.black.opacity(0.5), in: Capsule())
    }
}

/// One forecast day, as its four bands.
private struct DayRow: View {

    let day: SurfOutlook.Day
    let unit: DistanceUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(day.date, format: .dateTime.weekday(.wide))
                    .font(.system(size: 32, weight: .semibold))
                if let biggest = day.biggest {
                    Text("up to \(Format.height(biggest, unit: unit))")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                if let period = day.longestPeriod {
                    Text("\(Int(period.rounded())) s")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                ForEach(day.bands) { band in
                    BandCell(band: band, unit: unit)
                }
            }
        }
    }
}

/// A quarter of a day: dawn, morning, afternoon, evening.
private struct BandCell: View {

    let band: SurfOutlook.Band
    let unit: DistanceUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(band.label.uppercased())
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            if let primary = band.primary {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.height(primary.heightM, unit: unit))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    if let period = primary.periodS {
                        // The period leads the secondary line because it is
                        // what separates a swell from chop, and a height
                        // without it says almost nothing.
                        Text("\(Int(period.rounded())) s")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let direction = primary.directionDeg {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16))
                            .rotationEffect(.degrees(direction))
                        Text(Format.cardinal(direction))
                            .font(.system(size: 20))
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if let effect = band.windEffect, let knots = band.windKn {
                // Green is not "good surf" — it is "the wind is not spoiling
                // it", which is the only claim this app is willing to make
                // about somebody else's beach.
                Text("\(Int(knots.rounded())) kn \(effect.rawValue)")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(effect.isFavourable ? Color.green : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}


/// One buoy, and what it is actually measuring.
///
/// The charts above are a model's opinion of the sea; this is a hull in the
/// water reporting what reached it. Height and period lead, because they are
/// the two numbers the model can be wrong about in ways that matter, and the
/// age is shown because a six-hour-old buoy reading is a different claim from
/// a fresh one.
private struct BuoyRow: View {

    let buoy: Buoy
    let unit: DistanceUnit

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(buoy.name)
                    .font(.system(size: 28))
                    .lineLimit(1)
                Text(Format.distance(buoy.metres, unit: unit) + " away")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
            if let reading = buoy.reading {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let height = reading.waveHeightM {
                        Text(Format.height(height, unit: unit))
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                    }
                    if let period = reading.dominantPeriodS {
                        Text("at \(Int(period.rounded())) s")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let at = reading.at {
                    Text(at, style: .relative)
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                        .frame(width: 190, alignment: .trailing)
                }
            }
        }
    }
}
