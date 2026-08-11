import Foundation
import OpenWaterCore
import SwiftUI

// MARK: - The sea according to several models at once

/// Wave forecasts from four agencies side by side — the wave twin of
/// `WindOutlook`, and it exists for the same reason: one forecast line is a
/// number with no error bar, and wave models disagree about a building
/// swell at least as much as wind models disagree about a front.
///
/// Total sea only. ECMWF's wave model publishes no swell partitions, so the
/// honest common ground across models is significant height, period and
/// direction of the combined sea — the partitioned view stays on the surf
/// screens, from one model, rather than mixing partition sets across
/// models, which the research guide ranks among the classic mistakes.
struct SwellOutlook {

    struct Model: Identifiable {
        let id: String
        let label: String
        /// Hourly significant height of the total sea, metres.
        let heightsM: [Double?]
        var periodsS: [Double?] = []
        /// Degrees the waves come from.
        var directions: [Double?] = []
    }

    let hours: [Date]
    /// The models that answered with a real sea, in fetch order.
    let models: [Model]
    /// Labels of models whose nearest grid cell is dry land here — they
    /// answered flat zero while a sibling showed real sea, and averaging
    /// them in would have halved the swell. Kept by name so the screen can
    /// say why a line is missing rather than silently showing fewer.
    var landMasked: [String] = []
    var timeZone: TimeZone?
    var staleAge: TimeInterval?

    /// The mean of the models a rider has left switched on.
    func blend(of enabled: Set<String>) -> [Double?] {
        let chosen = models.filter { enabled.contains($0.id) }
        guard !chosen.isEmpty else { return [] }
        return hours.indices.map { hour in
            let values = chosen.compactMap { $0.heightsM[safe: hour] ?? nil }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
    }

    /// Direction, averaged as vectors and weighted by each model's height —
    /// the same rule as `WindOutlook.blendDirections`, for the same reason:
    /// a model calling two metres should out-vote one calling twenty
    /// centimetres about where the sea is from.
    func blendDirections(of enabled: Set<String>) -> [Double?] {
        let chosen = models.filter { enabled.contains($0.id) }
        guard !chosen.isEmpty else { return [] }
        return hours.indices.map { hour in
            var x = 0.0, y = 0.0
            for model in chosen {
                guard let direction = model.directions[safe: hour] ?? nil else { continue }
                let weight = max((model.heightsM[safe: hour] ?? nil) ?? 0.1, 0.0)
                x += weight * sin(direction * .pi / 180)
                y += weight * cos(direction * .pi / 180)
            }
            guard x != 0 || y != 0 else { return nil }
            return Geo.normalizeDegrees(atan2(x, y) * 180 / .pi)
        }
    }

    /// The widest disagreement over the next two days, metres. Two days
    /// rather than the wind's twelve hours because swell is the slower
    /// story — the question is whether Thursday's swell arrives, not
    /// whether the next tide's breeze does.
    var spreadM: Double {
        let window = min(48, hours.count)
        return (0..<window).compactMap { hour -> Double? in
            let values = models.compactMap { $0.heightsM[safe: hour] ?? nil }
            guard values.count > 1, let low = values.min(), let high = values.max()
            else { return nil }
            return high - low
        }
        .max() ?? 0
    }

    /// The spread in words a rider can act on.
    var agreement: (label: String, detail: String) {
        switch spreadM {
        case ..<0.3:
            ("Wave models agree",
             String(format: "Within %.1f m of each other for the next two days. As settled as a swell forecast gets.", spreadM))
        case ..<0.7:
            ("Wave models roughly agree",
             String(format: "Up to %.1f m apart. The swell's timing is probably right, its size is a guess.", spreadM))
        default:
            ("Wave models disagree",
             String(format: "As much as %.1f m apart over the next two days. Nobody knows yet — check a buoy.", spreadM))
        }
    }

    var isEmpty: Bool { models.isEmpty || hours.isEmpty }
}

extension OpenMeteo {

    /// The wave models worth comparing — each a different agency's physics
    /// on a different grid. GFS Wave runs to sixteen days, ECMWF and MFWAM
    /// to ten, GWAM to about eight; lines that just end are explained by
    /// the footnote rather than hidden.
    private static let waveModels: [(id: String, label: String)] = [
        ("ncep_gfswave025", "GFS Wave"),
        ("ecmwf_wam025", "ECMWF WAM"),
        ("meteofrance_wave", "MFWAM"),
        ("dwd_gwam", "GWAM"),
    ]

    /// Four wave models in one request, on suffixed keys like the wind path.
    static func swellOutlook(at coordinate: Geo.Coordinate, days: Int = 10) async -> SwellOutlook {
        var components = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: "wave_height,wave_period,wave_direction"),
            .init(name: "models", value: waveModels.map(\.id).joined(separator: ",")),
            .init(name: "forecast_days", value: String(days)),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = components.url,
              let served = await ForecastCache.serve(from: url, ttl: 3600),
              let root = try? JSONSerialization.jsonObject(with: served.data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Double]
        else { return SwellOutlook(hours: [], models: []) }

        func series(_ field: String, _ model: String) -> [Double?] {
            (hourly["\(field)_\(model)"] as? [Any])?.map { $0 as? Double } ?? []
        }
        // Models with no data at all simply vanish; models whose cell is
        // dry land answer zeros and are caught by the guard below.
        let answered = waveModels.compactMap { model -> SwellOutlook.Model? in
            let heights = series("wave_height", model.id)
            guard heights.contains(where: { $0 != nil }) else { return nil }
            return SwellOutlook.Model(
                id: model.id, label: model.label, heightsM: heights,
                periodsS: series("wave_period", model.id),
                directions: series("wave_direction", model.id)
            )
        }
        let masked = SwellBlend.landMaskedSeries(answered.map(\.heightsM))
        return SwellOutlook(
            hours: times.map { Date(timeIntervalSince1970: $0) },
            models: answered.indices.filter { !masked.contains($0) }.map { answered[$0] },
            landMasked: masked.map { answered[$0].label },
            timeZone: (root["timezone"] as? String).flatMap(TimeZone.init(identifier:)),
            staleAge: served.staleAge
        )
    }
}

// MARK: - How the wave models have been landing here

/// Each wave model's recent record at one point — the wave twin of
/// `ModelSteadiness`, with the same two flavours said out loud. Where a
/// wave buoy sits within thirty kilometres, the reference is what it
/// actually measured over the past two weeks; elsewhere the reference is
/// each model's own freshest run, which is steadiness rather than accuracy.
///
/// Plus the number the wind version never had: the persistence baseline.
/// "Tomorrow's sea is today's sea" is embarrassingly hard to beat at short
/// leads, and a model that cannot beat it is not forecasting.
struct WaveModelRecord {

    struct Row: Identifiable {
        let id: String
        let label: String
        /// Mean absolute error, metres, by days of lead — against the buoy
        /// when verified, against the model's own final run when not.
        let errorM: [Int: Double]

        var twoDaysOutM: Double? { errorM[2] }
    }

    let rows: [Row]
    var verifiedAgainst: (name: String, metres: Double)? = nil
    /// Persistence's own day-ahead error at this buoy, metres. Only
    /// meaningful in the verified flavour.
    var persistenceDayAheadM: Double? = nil
    var isEmpty: Bool { rows.isEmpty }

    var best: Row? {
        rows.filter { $0.twoDaysOutM != nil }
            .min { ($0.twoDaysOutM ?? .infinity) < ($1.twoDaysOutM ?? .infinity) }
    }
}

extension OpenMeteo {

    /// Every wave model's recent record near a point.
    static func waveModelRecord(near coordinate: Geo.Coordinate) async -> WaveModelRecord {
        // Thirty kilometres, same bar as the wind version: past that the
        // buoy is measuring a different sea.
        if let buoy = await DataBuoyCenter.buoys(near: coordinate, limit: 1,
                                                radius: 30_000).first {
            let history = await DataBuoyCenter.waveHistory(for: buoy.id)
            if history.count >= 150 {
                let observed = SwellBlend.hourBuckets(history)
                var verified = await waveRecord(at: buoy.coordinate, against: observed)
                if !verified.isEmpty {
                    verified.verifiedAgainst = (buoy.name, buoy.metres)
                    verified.persistenceDayAheadM = SwellBlend.persistenceError(
                        observedByHour: observed, leadHours: 24)
                    return verified
                }
            }
        }
        return await waveRecord(at: coordinate, against: nil)
    }

    /// Two weeks of each wave model's previous-day calls at one point,
    /// scored — the marine API carries its own `_previous_dayN` fields, so
    /// this works exactly like the wind steadiness request.
    private static func waveRecord(
        at coordinate: Geo.Coordinate,
        against observed: [Int: Double]?
    ) async -> WaveModelRecord {
        let leads = [0, 1, 2, 3]
        var components = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            .init(name: "hourly", value: leads.map { "wave_height_previous_day\($0)" }
                .joined(separator: ",")),
            .init(name: "models", value: waveModels.map(\.id).joined(separator: ",")),
            .init(name: "past_days", value: "14"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        guard let url = components.url,
              let data = await ForecastCache.data(from: url, ttl: 21_600),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let stamps = hourly["time"] as? [Double]
        else { return WaveModelRecord(rows: []) }

        let times = stamps.map { Date(timeIntervalSince1970: $0) }
        let now = Date()
        func series(_ lead: Int, _ model: String) -> [Double?] {
            // The marine API answers `previous_day0` on the bare field name
            // rather than a `_previous_day0` suffix — the freshest run is
            // just the field itself.
            let field = lead == 0 ? "wave_height" : "wave_height_previous_day\(lead)"
            return (hourly["\(field)_\(model)"] as? [Any])?
                .map { $0 as? Double } ?? []
        }

        // Without a buoy the reference is the model's own final run — a
        // steadiness measure, so lead 0 (the final run against itself)
        // would be a meaningless zero and is skipped.
        let scoredLeads = observed == nil ? Array(leads.dropFirst()) : leads
        let rows = waveModels.compactMap { model -> WaveModelRecord.Row? in
            let final = series(0, model.id)
            guard final.contains(where: { $0 != nil }) else { return nil }
            let reference = observed ?? SwellBlend.hourBuckets(
                times.indices.compactMap { index in
                    (final[safe: index] ?? nil).map { (at: times[index], value: $0) }
                })
            var errors: [Int: Double] = [:]
            for lead in scoredLeads {
                let forecast = lead == 0 ? final : series(lead, model.id)
                if let mae = SwellBlend.meanAbsoluteError(
                    times: times, forecast: forecast,
                    observedByHour: reference, upTo: now) {
                    errors[lead] = mae
                }
            }
            guard !errors.isEmpty else { return nil }
            return WaveModelRecord.Row(id: model.id, label: model.label, errorM: errors)
        }
        return WaveModelRecord(rows: rows)
    }
}

extension DataBuoyCenter {

    /// Every wave-height reading in the station's realtime file — about 45
    /// days, the sea's recent truth. Same file and same caching exception
    /// as `windHistory`, and the same rationale: nothing here is presented
    /// as a current reading, it feeds a two-week score.
    static func waveHistory(for stationId: String) async -> [(at: Date, value: Double)] {
        guard let url = URL(string: "https://www.ndbc.noaa.gov/data/realtime2/\(stationId.uppercased()).txt"),
              let data = await ForecastCache.data(from: url, ttl: 3600),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        return text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { row -> (at: Date, value: Double)? in
                let columns = row.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard columns.count >= 9 else { return nil }
                func value(_ index: Int) -> Double? {
                    guard let raw = columns[safe: index], raw != "MM" else { return nil }
                    return Double(raw)
                }
                // YY MM DD hh mm WDIR WSPD GST WVHT — same columns as `latest`.
                guard let height = value(8) else { return nil }
                var stamp = DateComponents()
                stamp.year = value(0).map(Int.init)
                stamp.month = value(1).map(Int.init)
                stamp.day = value(2).map(Int.init)
                stamp.hour = value(3).map(Int.init)
                stamp.minute = value(4).map(Int.init)
                guard let at = utc.date(from: stamp) else { return nil }
                return (at, height)
            }
    }
}

// MARK: - The forecast, nudged by a real wave buoy

/// The surf tab's version of `NowcastAdjustment`: when a wave buoy nearby
/// has just measured the sea, its disagreement with the model corrects the
/// next hours — core's `SwellNowcast` does the arithmetic, this picks the
/// buoy and says the result in a sentence.
struct SwellNowcastAdjustment {

    let buoyName: String
    let ageMinutes: Int
    /// Observed minus modelled at the reading's moment, metres. Positive
    /// means more sea on the water than in the model.
    let deltaM: Double
    let corrected: [SwellNowcast.Sample]

    /// The corrected sea this far ahead of now — nearest corrected hour.
    func correctedM(hoursAhead: Double, from now: Date = Date()) -> Double? {
        let target = now.addingTimeInterval(hoursAhead * 3600)
        return corrected.min {
            abs($0.at.timeIntervalSince(target)) < abs($1.at.timeIntervalSince(target))
        }?.heightM
    }

    /// The whole thing as one sentence, in the rider's unit.
    func line(unit: DistanceUnit) -> String {
        let age = ageMinutes <= 1 ? "just now" : "\(ageMinutes) min ago"
        guard abs(deltaM) >= 0.15 else {
            return "\(buoyName) measured the sea \(age) and agrees with the wave model."
        }
        let sense = deltaM > 0 ? "above" : "below"
        var text = "\(buoyName) read \(Format.height(abs(deltaM), unit: unit)) \(sense) the wave model \(age)."
        if let soon = correctedM(hoursAhead: 2), let later = correctedM(hoursAhead: 6) {
            text += " Next hours corrected to \(Format.height(soon, unit: unit)),"
                + " then \(Format.height(later, unit: unit))."
        }
        return text
    }

    /// Pick the buoy, form the ratio, decay it. Nearest first, because the
    /// question is what this water is doing — and thirty kilometres is the
    /// same bar the verification uses, for the same reason.
    static func make(outlook: SurfOutlook, buoys: [Buoy],
                     at now: Date = Date()) -> SwellNowcastAdjustment? {
        let series = outlook.hours.indices.compactMap { index -> SwellNowcast.Sample? in
            guard let height = outlook.totalM[safe: index] ?? nil else { return nil }
            return SwellNowcast.Sample(at: outlook.hours[index], heightM: height)
        }
        guard !series.isEmpty else { return nil }

        for buoy in buoys.filter({ $0.metres < 30_000 }).sorted(by: { $0.metres < $1.metres }) {
            guard let reading = buoy.reading,
                  let observed = reading.waveHeightM,
                  let read = reading.at, now.timeIntervalSince(read) < 2 * 3600,
                  let correction = SwellNowcast()
                      .corrected(series, byObservedHeight: observed, at: read)
            else { continue }
            return SwellNowcastAdjustment(
                buoyName: buoy.name,
                ageMinutes: max(0, Int(now.timeIntervalSince(read) / 60)),
                deltaM: observed - correction.modelAtObservation,
                corrected: correction.samples
            )
        }
        return nil
    }
}

// MARK: - The compare screen

/// The wave models drawn against each other — a deliberately thinner
/// `ModelCompareScreen`: no probe line, no gust band, just each agency's
/// line, the blend, the agreement sentence, and the scorecard.
struct SwellCompareScreen: View {

    let title: String
    let coordinate: Geo.Coordinate

    @Environment(AppSettings.self) private var settings
    @State private var outlook = SwellOutlook(hours: [], models: [])
    @State private var record = WaveModelRecord(rows: [])
    @State private var enabled: Set<String> = []
    @State private var isLoading = true

    private static let hourWidth: CGFloat = 6

    private var units: UnitPreferences { settings.units }
    private var zone: TimeZone { outlook.timeZone ?? .current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    LoadingPlaceholder(height: 220, corner: 16)
                    LoadingPlaceholder(height: 120, corner: 16)
                } else if outlook.isEmpty {
                    ContentUnavailableView("No wave model here",
                                           systemImage: "water.waves",
                                           description: Text("The marine grid covers the ocean and the coast, and stops at inland water."))
                } else {
                    readout
                    chart
                    toggles
                    if !record.isEmpty { recordRows }
                    footnote
                }
            }
            .padding(16)
            // Only the chart pans sideways, inside its own scroll view —
            // the page itself must not. Same guard as the conditions sheet.
            .containerRelativeFrame(.horizontal)
        }
        .background(Color.deepSurface)
        .navigationTitle("Wave models")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Wave models")
        .task {
            outlook = await OpenMeteo.swellOutlook(at: coordinate)
            enabled = Set(outlook.models.map(\.id))
            withAnimation(.easeOut(duration: 0.25)) { isLoading = false }
            // The scorecard is a bonus, not something the chart waits on.
            record = await OpenMeteo.waveModelRecord(near: coordinate)
        }
    }

    // MARK: What the models say

    private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(outlook.agreement.label)
                .font(.headline)
            Text(outlook.agreement.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let age = outlook.staleAge {
                Label {
                    Text("No network right now — these are the models from \(Format.duration(age)) ago.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.harbourNavy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: The lines

    private var chart: some View {
        let width = CGFloat(outlook.hours.count) * Self.hourWidth
        let blend = outlook.blend(of: enabled)
        let peak = max(0.5, outlook.models
            .filter { enabled.contains($0.id) }
            .flatMap { $0.heightsM.compactMap { $0 } }
            .max() ?? 1)

        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                dayHeaders(width: width)

                ZStack(alignment: .topLeading) {
                    ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                        if enabled.contains(model.id) {
                            SeriesLine(values: model.heightsM, peak: peak,
                                       hourWidth: Self.hourWidth)
                                .stroke(ModelCompareScreen.palette[index % ModelCompareScreen.palette.count]
                                    .opacity(0.75), lineWidth: 1.5)
                        }
                    }
                    SeriesLine(values: blend, peak: peak, hourWidth: Self.hourWidth)
                        .stroke(Color.primary, lineWidth: 2.5)

                    if let now = nowIndex {
                        Rectangle()
                            .fill(.orange)
                            .frame(width: 2)
                            .offset(x: CGFloat(now) * Self.hourWidth)
                    }
                }
                .frame(width: width, height: 170)
            }
            .padding(.vertical, 4)
        }
        .padding(14)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 16))
    }

    private var nowIndex: Int? {
        let moment = Date()
        return outlook.hours.indices.min {
            abs(outlook.hours[$0].timeIntervalSince(moment)) < abs(outlook.hours[$1].timeIntervalSince(moment))
        }
    }

    private func dayHeaders(width: CGFloat) -> some View {
        var calendar = Calendar.current
        calendar.timeZone = zone
        let starts = outlook.hours.indices.filter {
            $0 == 0 || !calendar.isDate(outlook.hours[$0],
                                        inSameDayAs: outlook.hours[$0 - 1])
        }
        return ZStack(alignment: .topLeading) {
            ForEach(starts, id: \.self) { index in
                let x = CGFloat(index) * Self.hourWidth
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 16)
                    .offset(x: x)
                Text(outlook.hours[index].formatted(
                    Date.FormatStyle(timeZone: zone).weekday(.abbreviated)))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .offset(x: x + 5)
            }
        }
        .frame(height: 18, alignment: .topLeading)
    }

    // MARK: Switching models

    private var toggles: some View {
        HStack(spacing: 8) {
            ForEach(Array(outlook.models.enumerated()), id: \.element.id) { index, model in
                let on = enabled.contains(model.id)
                Button {
                    if on, enabled.count > 1 { enabled.remove(model.id) }
                    else { enabled.insert(model.id) }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(on ? ModelCompareScreen.palette[index % ModelCompareScreen.palette.count]
                                  : Color(.systemGray3))
                            .frame(width: 8, height: 8)
                        Text(model.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(on ? AnyShapeStyle(Color.deepCard)
                                : AnyShapeStyle(Color(.systemGray6)),
                                in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: The scorecard

    private var recordRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.verifiedAgainst == nil
                 ? "TWO DAYS OUT, PAST TWO WEEKS"
                 : "AGAINST A REAL WAVE BUOY, TWO DAYS OUT")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(record.rows) { row in
                    if let error = row.twoDaysOutM {
                        HStack(spacing: 3) {
                            if row.id == record.best?.id {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tint)
                            }
                            Text(row.label)
                                .font(.caption2.weight(.semibold))
                            Text("±\(error, specifier: "%.1f") m")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            Text(recordCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 16))
    }

    private var recordCaption: String {
        if let buoy = record.verifiedAgainst {
            var caption = "Each model's two-day-ahead call scored against what the \(buoy.name) buoy"
                + " (\(Format.distance(buoy.metres, unit: units.distance)) from here)"
                + " actually measured over the past two weeks."
            if let persistence = record.persistenceDayAheadM {
                caption += String(format: " The bar to clear: \"tomorrow = today\" is off by ±%.1f m at this buoy — a model that cannot beat persistence is not forecasting.", persistence)
            }
            return caption
        }
        return "How far each model's two-day-ahead call here has drifted from its own final run. Steadiness, not verified truth — no wave buoy sits close enough to score them against."
    }

    private var footnote: some View {
        var text = "Total sea — swell and wind waves together — because it is the one "
            + "quantity every wave model publishes. The heavy line is the blend of "
            + "whatever is switched on. Free from Open-Meteo."
        if !outlook.landMasked.isEmpty {
            text += " \(outlook.landMasked.joined(separator: " and "))'s nearest grid cell"
                + " here is dry land, so it sat this one out rather than voting zero."
        }
        return Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A model's hourly series as one line, gaps skipped rather than dropped to
/// zero — the 3-hourly models interleave nulls on the hourly grid, and a
/// line that plunges to the floor every other hour would read as surf that
/// is not there.
private struct SeriesLine: Shape {
    let values: [Double?]
    let peak: Double
    let hourWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var started = false
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            let point = CGPoint(x: CGFloat(index) * hourWidth,
                                y: rect.height * (1 - min(1, value / peak)))
            if started {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                started = true
            }
        }
        return path
    }
}
