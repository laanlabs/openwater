import CoreLocation
import OpenWaterCore
import SwiftUI
import WeatherKit

// MARK: - The next hour

/// Rain at this point, minute by minute, for the next two hours.
///
/// Every other forecast on this sheet is a grid: a model cell a few kilometres
/// across, published on the hour. Asked "is it about to rain at the launch",
/// the honest answer from a grid is that it does not know — it knows what the
/// cell will average over the hour, which is a different question and the
/// wrong one when you are standing on the beach deciding whether to rig.
///
/// Apple's minute forecast is a different instrument. It is machine learning
/// run over live Doppler radar rather than a physics model stepped forward, so
/// it can say "in twelve minutes" and mean it. It runs for an hour, which is
/// not long enough on its own: this card only appears when there is rain to
/// announce, and an hour of warning arrives about when you have finished
/// rigging. So the second hour is filled from Apple's hourly forecast — a
/// weaker claim, carried at a higher bar and drawn as its own stretch of the
/// strip rather than passed off as radar.
///
/// The radar half exists only where there is radar to derive it from. Outside
/// those regions WeatherKit returns nil rather than an error and the whole
/// window falls back to the hourly model, which is worldwide — so the card
/// still answers, less sharply, everywhere the service works at all.
struct MinuteRain {

    /// One minute of it.
    struct Minute: Identifiable, Equatable {
        let at: Date
        /// How likely, 0…1.
        let chance: Double
        /// How hard, in millimetres an hour.
        let intensityMmH: Double
        /// What is falling, or nil for a dry minute.
        let kind: Kind?
        /// Read off radar, rather than spread out of an hourly model figure.
        let isRadar: Bool

        var id: Date { at }

        /// Whether this minute counts as wet.
        ///
        /// Apple types the precipitation *and* rates it, and the two do not
        /// always agree: some regions carry a type with a zero rate for a
        /// minute that is really only a possibility. Both have to say
        /// something before a minute is called wet, or a card announcing
        /// "rain in 4 minutes" fires on a 5% chance of nothing.
        ///
        /// A model minute clears a higher bar than a radar one. Radar has seen
        /// the thing; the model is guessing at an hour that has not started,
        /// and a card that shouts about a coin flip ninety minutes out teaches
        /// a rider to ignore it — which costs them the one that is real.
        var isWet: Bool {
            guard kind != nil else { return false }
            return isRadar
                ? (intensityMmH > 0 || chance >= 0.3)
                : (intensityMmH > 0.2 || chance >= 0.5)
        }
    }

    enum Kind: String, Equatable {
        case rain, snow, sleet, hail, mixed

        /// The subject of the headline sentence, capitalised to start it.
        var noun: String {
            switch self {
            case .rain: "Rain"
            case .snow: "Snow"
            case .sleet: "Sleet"
            case .hail: "Hail"
            case .mixed: "Wintry mix"
            }
        }

        var tint: Color {
            switch self {
            case .rain: .blue
            case .snow, .sleet: .cyan
            case .hail: .orange
            case .mixed: .purple
            }
        }

        var symbol: String {
            switch self {
            case .rain: "cloud.rain.fill"
            case .snow: "cloud.snow.fill"
            case .sleet: "cloud.sleet.fill"
            case .hail: "cloud.hail.fill"
            case .mixed: "cloud.sleet.fill"
            }
        }
    }

    /// One precipitation reading at an instant, lifted out of its WeatherKit
    /// type.
    ///
    /// Both feeds carry the same four facts in different shapes, and neither
    /// shape can be built in a test — WeatherKit's structs have no public
    /// initialiser. Converting at the boundary buys a stitching function that
    /// a fixture can drive, which matters because the handover is where all
    /// the edges live.
    struct Sample {
        let at: Date
        let chance: Double
        let intensityMmH: Double
        let kind: Kind?
    }

    var minutes: [Minute] = []
    /// What the minutes add up to, in a sentence. Nil when there are none.
    var summary: Summary?

    var isEmpty: Bool { minutes.isEmpty }

    /// Whether there is anything here worth putting on the screen.
    ///
    /// The card shows up only when rain is coming. A standing row that says
    /// "no rain" every dry day is a row a rider learns to skip, and by the
    /// time it has something to say they are no longer reading it.
    var isWorthShowing: Bool { summary.map { !$0.isDry } ?? false }

    /// The stretch read off radar, which leads the strip.
    var radarMinutes: [Minute] { minutes.filter(\.isRadar) }

    /// The stretch spread out of the hourly model, which follows it.
    var modelMinutes: [Minute] { minutes.filter { !$0.isRadar } }

    // MARK: What it adds up to

    /// The one thing a rider wants off this card, worked out once.
    struct Summary: Equatable {

        /// What is about to change, and when.
        enum Change: Equatable {
            case dry
            case starting(minutesAway: Int)
            /// Falling now, and stopping. `minutesAway` is how much longer.
            case stopping(minutesAway: Int)
            /// Falling now and still falling at the end of the hour.
            case throughout
        }

        let change: Change
        let kind: Kind
        /// Millimetres an hour at the worst minute in the window.
        let peakMmH: Double
        /// The highest probability in the window, 0…1.
        let peakChance: Double
        /// How many of the window's minutes are wet.
        let wetMinutes: Int
        /// How long the window is, which is not always sixty.
        let totalMinutes: Int

        var isDry: Bool { change == .dry }

        var headline: String {
            let noun = kind.noun
            switch change {
            case .dry:
                return "No \(noun.lowercased()) in the next \(Self.window(totalMinutes))"
            case .starting(let away):
                return away <= 1 ? "\(noun) starting now" : "\(noun) starting in \(Self.spell(away))"
            case .stopping(let away):
                return away <= 1 ? "\(noun) stopping now" : "\(noun) for another \(Self.spell(away))"
            case .throughout:
                return "\(noun) for the next \(Self.window(totalMinutes))"
            }
        }

        /// Minutes as a rider would say them. Past the hour "80 min" is
        /// arithmetic the reader has to do standing on a beach; "1 hr 20 min"
        /// is the same fact already done.
        static func spell(_ minutes: Int) -> String {
            guard minutes >= 60 else { return "\(minutes) min" }
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
        }

        /// How long the window is, in the words a headline wants.
        static func window(_ minutes: Int) -> String {
            switch minutes {
            case ..<90: "hour"
            case ..<150: "two hours"
            default: "\(Int((Double(minutes) / 60).rounded())) hours"
            }
        }

        /// The word for how hard it is coming down at its worst.
        ///
        /// The millimetre-an-hour bands meteorology uses, which are also the
        /// ones that match what it feels like on the water: under 2.5 you
        /// keep going, over 7.6 you are getting off.
        var band: String {
            switch peakMmH {
            case ..<0.1: "Barely measurable"
            case ..<2.5: "Light"
            case ..<7.6: "Moderate"
            default: "Heavy"
            }
        }

        /// The second line — how hard, how long, how sure.
        var detail: String? {
            guard !isDry else { return nil }
            let span = "\(wetMinutes) of the next \(totalMinutes) minutes are wet, \(Int((peakChance * 100).rounded()))% at the likeliest."
            // Some regions publish the odds without the millimetres. There the
            // rate sentence would read "Barely measurable at its worst, barely
            // measurable", which is not a sentence — the probability is the
            // only real number there is, so it carries the line alone.
            guard peakMmH >= 0.1 else { return span }
            return "\(band) at its worst, \(String(format: "%.1f mm an hour", peakMmH)). \(span)"
        }
    }

    /// Read a summary out of the minutes.
    ///
    /// Split from the fetch so a fixture can exercise it — WeatherKit hands
    /// back objects rather than bytes, so the seam that would be a parser
    /// anywhere else in this layer has to be this instead.
    ///
    /// The runs matter more than the individual minutes. Radar flickers, and
    /// a nowcast that announced every isolated wet minute as "rain starting"
    /// would cry wolf all afternoon — so a shower has to hold for a couple of
    /// minutes before it counts as starting, and a gap has to hold for ten
    /// before it counts as stopping rather than easing.
    static func summarise(_ minutes: [Minute], now: Date = Date()) -> Summary? {
        // A minute already gone is not part of "the next hour". Apple opens
        // the run at the current minute, so this normally drops nothing.
        let ahead = minutes.filter { $0.at.timeIntervalSince(now) > -60 }
        guard !ahead.isEmpty else { return nil }

        let wet = ahead.map(\.isWet)
        let peakMmH = ahead.map(\.intensityMmH).max() ?? 0
        let peakChance = ahead.map(\.chance).max() ?? 0
        let wetCount = wet.filter { $0 }.count

        // Whatever is falling most of the time it falls. A shower that turns
        // from sleet to rain should be announced as the rain it becomes.
        let kind = Self.dominantKind(ahead) ?? .rain

        func summary(_ change: Summary.Change) -> Summary {
            Summary(change: change, kind: kind, peakMmH: peakMmH, peakChance: peakChance,
                    wetMinutes: wetCount, totalMinutes: ahead.count)
        }

        func minutesAway(_ index: Int) -> Int {
            max(0, Int((ahead[index].at.timeIntervalSince(now) / 60).rounded()))
        }

        guard wetCount > 0 else { return summary(.dry) }

        // Falling now, or about to? Decided over the first few minutes rather
        // than the first one, so a single radar speck at the head of the run
        // does not read as a downpour in progress.
        let isFallingNow = wet.prefix(3).filter { $0 }.count >= 2

        if isFallingNow {
            // The first gap long enough to be an end rather than a lull.
            guard let stops = Self.firstRun(in: wet, of: false, lasting: 10) else {
                return summary(.throughout)
            }
            return summary(.stopping(minutesAway: minutesAway(stops)))
        }

        // The first shower substantial enough to be worth announcing. If
        // nothing on the strip clears that bar, the hour is dry in every
        // sense a rider cares about, whatever the odd flickering minute says.
        guard let starts = Self.firstRun(in: wet, of: true, lasting: 2) else {
            return summary(.dry)
        }
        return summary(.starting(minutesAway: minutesAway(starts)))
    }

    /// Radar for as far as it runs, then the hourly model spread across the
    /// minutes it did not reach.
    ///
    /// Split from the fetch so a fixture can exercise the handover, which is
    /// where all the edges are: a radar run that opens a minute in the past, an
    /// hourly array whose first entry is the hour already under way, and the
    /// case where there is no radar at all and the model carries the lot.
    static func stitch(radar: [Sample], hourly: [Sample],
                       hours: Int, from now: Date) -> [Minute] {
        // The window opens on the minute now falls inside, not on now itself.
        // A minute already finished is not part of it, but the one in progress
        // is — it is this minute, and the strip has to start at "now" rather
        // than at "now plus a bit". Pinning to the minute boundary is also what
        // keeps the count exactly the two hours asked for: measuring from a
        // ragged instant and still allowing the minute in progress produced a
        // hundred and twenty-one columns.
        let opens = Date(timeIntervalSince1970:
                            (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let end = opens.addingTimeInterval(Double(hours) * 3600)

        var minutes = radar
            .filter { $0.at >= opens && $0.at < end }
            .map {
                Minute(at: $0.at, chance: $0.chance, intensityMmH: $0.intensityMmH,
                       kind: $0.kind, isRadar: true)
            }

        // Where the model has to take over. With no radar at all that is the
        // top of the window, and the whole strip comes from the hourly run.
        var cursor = minutes.last.map { $0.at.addingTimeInterval(60) } ?? opens
        while cursor < end {
            defer { cursor.addTimeInterval(60) }
            // The hour this minute falls inside. `hourly` opens on the hour
            // already under way, so the match is the last one that has begun.
            guard let hour = hourly.last(where: { $0.at <= cursor }),
                  cursor < hour.at.addingTimeInterval(3600)
            else { continue }
            minutes.append(
                Minute(at: cursor, chance: hour.chance, intensityMmH: hour.intensityMmH,
                       kind: hour.kind, isRadar: false)
            )
        }
        return minutes
    }

    /// Where the first run of `value` at least `lasting` long begins, ignoring
    /// any run already in progress at index zero — a shower that is already
    /// falling has no start to report.
    private static func firstRun(in flags: [Bool], of value: Bool, lasting: Int) -> Int? {
        var index = 0
        // A run already under way at the start has no beginning to report;
        // step over it before looking for one.
        while index < flags.count, flags[index] == value { index += 1 }
        while index < flags.count {
            guard flags[index] == value else { index += 1; continue }
            let start = index
            while index < flags.count, flags[index] == value { index += 1 }
            // A run that reaches the end of the window counts however short
            // it is: the data stopped, the weather did not.
            if index - start >= lasting || index == flags.count { return start }
        }
        return nil
    }

    private static func dominantKind(_ minutes: [Minute]) -> Kind? {
        var tally: [Kind: Int] = [:]
        for minute in minutes where minute.isWet {
            guard let kind = minute.kind else { continue }
            tally[kind, default: 0] += 1
        }
        // Ties break on the name rather than on whatever order the dictionary
        // happened to hash into. An even split of rain and sleet is rare, and
        // a headline that changed word every time the sheet refreshed —
        // without the weather having changed at all — reads as a bug.
        return tally.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }?.key
    }
}

// MARK: - Fetching it

/// The two things Apple's weather service knows that a public forecast grid
/// does not: what radar is about to do in the next hour, and what a normal
/// week here looks like.
///
/// Deliberately narrow. Everything else on this sheet comes from Open-Meteo
/// and NOAA because those are free, worldwide, and answerable without an
/// Apple developer account — and none of that changes. This namespace is only
/// for the questions those sources genuinely cannot answer, so that an app
/// running without the WeatherKit entitlement loses two cards rather than a
/// screen.
///
/// See `openWater.entitlements` for what has to be switched on, and where.
enum AppleWeather {}

extension AppleWeather {

    /// Millimetres an hour, which is what Apple's intensity means and not
    /// what `UnitSpeed` defaults to. Written out because the conversion —
    /// a millimetre in an hour is 1/3,600,000 of a metre a second — is
    /// exactly the kind of arithmetic that goes wrong silently.
    private static let millimetresPerHour = UnitSpeed(
        symbol: "mm/h",
        converter: UnitConverterLinear(coefficient: 1.0 / 3_600_000.0)
    )

    /// The next two hours of precipitation at a point, or nothing.
    ///
    /// One request for both datasets: WeatherKit bills by the call, not by the
    /// dataset, and asking for radar and the hourly model separately would
    /// double the cost of a card that is usually not even shown.
    ///
    /// Non-throwing like every other fetcher on this sheet. A missing
    /// entitlement and a dead network mean the same thing to the card, which
    /// is that there is no card — but a region with no radar does *not*: the
    /// hourly half is worldwide and carries the window on its own.
    ///
    /// Not run through `ForecastCache` — that keys on a URL and WeatherKit
    /// never exposes one. Apple's own daemon caches the response, and a
    /// nowcast is stale within minutes anyway, so there is nothing here worth
    /// keeping on disk.
    static func minuteRain(at coordinate: Geo.Coordinate, hours: Int = 2,
                           from now: Date = Date()) async -> MinuteRain {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let (radar, hourly) = try? await WeatherService.shared.weather(
            for: location, including: .minute, .hourly
        ) else { return MinuteRain() }

        let minutes = MinuteRain.stitch(
            radar: (radar?.forecast ?? []).map {
                MinuteRain.Sample(at: $0.date, chance: $0.precipitationChance,
                                  intensityMmH: $0.precipitationIntensity
                                      .converted(to: Self.millimetresPerHour).value,
                                  kind: Self.kind($0.precipitation))
            },
            hourly: hourly.forecast.map {
                MinuteRain.Sample(at: $0.date, chance: $0.precipitationChance,
                                  // Millimetres across the hour, which is
                                  // millimetres an hour — the same number the
                                  // radar side reports as a rate.
                                  intensityMmH: $0.precipitationAmount
                                      .converted(to: .millimeters).value,
                                  kind: Self.kind($0.precipitation))
            },
            hours: hours, from: now)
        return MinuteRain(minutes: minutes, summary: MinuteRain.summarise(minutes, now: now))
    }

    private static func kind(_ precipitation: WeatherKit.Precipitation) -> MinuteRain.Kind? {
        switch precipitation {
        case .none: nil
        case .rain: .rain
        case .snow: .snow
        case .sleet: .sleet
        case .hail: .hail
        case .mixed: .mixed
        @unknown default: .rain
        }
    }
}

// MARK: - The card

/// The next two hours of rain as one strip, with the sentence that matters
/// over it.
///
/// Present only when there is rain to announce. A card that stands there
/// saying "no rain" on every dry day is one a rider learns to scroll past, and
/// the day it finally has something to say it has already trained them not to
/// look. Its absence is the good news; its presence is the message.
struct MinuteRainCard: View {

    let rain: MinuteRain

    private static let plotHeight: CGFloat = 54

    var body: some View {
        if let summary = rain.summary, !summary.isDry {
            full(summary)
        }
    }

    private func full(_ summary: MinuteRain.Summary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("NEXT \(MinuteRain.Summary.window(summary.totalMinutes).uppercased()), MINUTE BY MINUTE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Image(systemName: summary.kind.symbol)
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(summary.kind.tint)
            }

            Text(summary.headline)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(summary.kind.tint)
                .fixedSize(horizontal: false, vertical: true)

            strip(summary)

            if let detail = summary.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(provenance)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            AppleWeatherAttribution(showsLegalLabel: true, prefix: "Nowcast from")
                .font(.caption2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deepCard, in: RoundedRectangle(cornerRadius: 18))
    }

    /// The window as a profile: one column a minute, height for how hard,
    /// opacity for how sure.
    ///
    /// Drawn edge to edge rather than as separated bars. A hundred and twenty
    /// gaps across a phone leaves each column about two points wide, and a
    /// comb of hairlines reads as a texture; a solid shape reads as weather
    /// arriving, which is what it is.
    ///
    /// The rule between the halves is a real child of the stack rather than an
    /// overlay positioned by a fraction — the columns divide the width evenly
    /// between themselves, so a divider laid *in* the row lands exactly on the
    /// handover by construction and cannot drift away from it.
    private func strip(_ summary: MinuteRain.Summary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(rain.radarMinutes) { column($0, kind: summary.kind) }
                if !rain.radarMinutes.isEmpty, !rain.modelMinutes.isEmpty {
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1, height: Self.plotHeight)
                }
                ForEach(rain.modelMinutes) { column($0, kind: summary.kind) }
            }
            .frame(height: Self.plotHeight, alignment: .bottom)
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
            }

            HStack(spacing: 0) {
                axisLabel("NOW", alignment: .leading)
                if rain.minutes.count > 90 {
                    axisLabel("1 HR", alignment: .center)
                    axisLabel("2 HR", alignment: .trailing)
                } else {
                    axisLabel("30 MIN", alignment: .center)
                    axisLabel("1 HR", alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.headline)
        .accessibilityValue(summary.detail ?? "")
    }

    private func column(_ minute: MinuteRain.Minute, kind: MinuteRain.Kind) -> some View {
        Rectangle()
            .fill(kind.tint.opacity(opacity(minute)))
            .frame(height: max(1, Self.plotHeight * fraction(minute)))
            .frame(maxWidth: .infinity, alignment: .bottom)
    }

    /// Where the strip's halves come from, said once and only about the halves
    /// that are actually on it.
    private var provenance: String {
        let radar = "The first hour is machine learning over live radar, which is why it can name the minute."
        let model = "The stretch past the rule is Apple's hourly forecast spread across its minutes — the same rain, guessed rather than seen, and a looser claim."
        switch (rain.radarMinutes.isEmpty, rain.modelMinutes.isEmpty) {
        case (false, false): return "\(radar) \(model)"
        case (false, true): return radar
        default:
            return "Apple's hourly forecast for this point, spread across its minutes. No radar nowcast reaches here, so this is the hour's own odds rather than a minute-by-minute read of what is actually falling."
        }
    }

    private func axisLabel(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// How tall a minute's column stands.
    ///
    /// Square-rooted against a floored peak. Rain rates are wildly skewed — a
    /// downpour is fifty times drizzle — and on a linear scale against the
    /// hour's own maximum, every minute of a squall's approach draws as a flat
    /// line until the squall lands. The floor stops a drizzle-only hour
    /// magnifying 0.2 mm into a wall.
    private func fraction(_ minute: MinuteRain.Minute) -> Double {
        guard minute.isWet, minute.intensityMmH > 0 else { return 0 }
        return min(1, (minute.intensityMmH / peak).squareRoot())
    }

    private var peak: Double {
        max(rain.minutes.map(\.intensityMmH).max() ?? 0, 0.6)
    }

    private func opacity(_ minute: MinuteRain.Minute) -> Double {
        guard minute.isWet else { return 0 }
        return 0.45 + 0.55 * min(1, max(0, minute.chance))
    }
}
