import OpenWaterCore
import SwiftUI
import WatchKit

/// The live session: swipeable pages, each answering one question.
///
/// Page order is deliberate. Speed is first because it is what you glance at
/// mid-run. Splits is second because it is what you check between runs. The
/// controls page is last-but-one so it is reachable but never accidental, and
/// the countdown lives past it because it is a pre-start tool.
struct LiveSessionView: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings
    @Environment(WatchSyncClient.self) private var sync

    @State private var page: Page = .speed
    @State private var showingEndConfirmation = false

    enum Page: Int, CaseIterable, Hashable {
        case speed, splits, session, angles, foil, controls, countdown
    }

    var body: some View {
        TabView(selection: $page) {
            SpeedPage().tag(Page.speed)
            SplitsPage().tag(Page.splits)
            SessionPage().tag(Page.session)
            if recorder.sport.isWindPowered {
                AnglesPage().tag(Page.angles)
            }
            if recorder.sport.isFoiling {
                FoilPage().tag(Page.foil)
            }
            ControlsPage(showingEndConfirmation: $showingEndConfirmation).tag(Page.controls)
            CountdownPage().tag(Page.countdown)
        }
        .tabViewStyle(.verticalPage)
        .confirmationDialog("End session?", isPresented: $showingEndConfirmation) {
            Button("End & Save") { Task { await end() } }
            Button("Discard", role: .destructive) { recorder.discard() }
            Button("Keep Recording", role: .cancel) {}
        }
    }

    private func end() async {
        if let session = await recorder.finish() {
            sync.send(session)
        }
    }
}

// MARK: - Speed

/// The glanceable page. One enormous number and nothing that competes with it.
struct SpeedPage: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(spacing: 0) {
            Text(Format.speed(
                recorder.metrics.currentSpeed,
                unit: settings.units.speed,
                decimals: 1,
                includeSymbol: false
            ))
            // Rounded, monospaced digits: rounded reads at a glance in spray,
            // monospaced stops the layout jittering as digits change at 1 Hz.
            .font(.system(size: 62, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(recorder.state == .paused ? .secondary : .primary)

            Text(settings.units.speed.symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Always-on dimming strips everything but the essentials, which is
            // what makes a three-hour session survivable on one charge.
            if !isLuminanceReduced {
                HStack(spacing: 12) {
                    MetricPair(
                        label: "MAX",
                        value: Format.speed(recorder.metrics.maxSpeed, unit: settings.units.speed,
                                            decimals: 1, includeSymbol: false)
                    )
                    MetricPair(
                        label: "AVG",
                        value: Format.speed(recorder.metrics.averageMovingSpeed, unit: settings.units.speed,
                                            decimals: 1, includeSymbol: false)
                    )
                    MetricPair(
                        label: "10s",
                        value: Format.speed(recorder.metrics.current10s, unit: settings.units.speed,
                                            decimals: 1, includeSymbol: false)
                    )
                }
                .padding(.top, 4)
            }

            if recorder.state == .paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
        .containerBackground(.green.gradient.opacity(0.18), for: .tabView)
    }
}

// MARK: - Splits

/// Every headline category, live. This is the page riders stare at between runs.
struct SplitsPage: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings

    private let categories: [SpeedCategory] = [
        .time(seconds: 2),
        .time(seconds: 10),
        .multiTime(count: 5, seconds: 10),
        .distance(metres: 100),
        .distance(metres: 500),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                Text("BEST THIS SESSION")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(categories) { category in
                    SplitRow(
                        label: category.shortName,
                        value: value(for: category),
                        unit: settings.units.speed,
                        isRecord: isAllTimeBest(category)
                    )
                }
            }
            .padding(.horizontal, 2)
        }
        .containerBackground(.blue.gradient.opacity(0.18), for: .tabView)
    }

    private func value(for category: SpeedCategory) -> Double {
        if case .multiTime = category { return recorder.metrics.fiveByTen }
        return recorder.metrics.best(category)
    }

    private func isAllTimeBest(_ category: SpeedCategory) -> Bool {
        let current = value(for: category)
        guard current > 0, let all = recorder.allTimeBests[category], all > 0 else { return false }
        return current > all
    }
}

struct SplitRow: View {
    let label: String
    let value: Double
    let unit: SpeedUnit
    var isRecord: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            if isRecord {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
            }
            Spacer(minLength: 0)
            Text(value > 0
                 ? Format.speed(value, unit: unit, decimals: 2, includeSymbol: false)
                 : "—")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}

// MARK: - Session

struct SessionPage: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                BigStat(
                    label: "TIME",
                    value: Format.duration(recorder.metrics.duration)
                )
                BigStat(
                    label: "DISTANCE",
                    value: Format.distance(recorder.metrics.distance, unit: settings.units.distance)
                )
                HStack(spacing: 12) {
                    MetricPair(label: "RUNS", value: "\(recorder.metrics.runCount)")
                    MetricPair(
                        label: "MOVING",
                        value: Format.duration(recorder.metrics.movingTime)
                    )
                }
                if let heartRate = recorder.metrics.heartRate {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 11))
                        Text("\(Int(heartRate)) bpm")
                            .font(.system(size: 15, design: .rounded))
                            .monospacedDigit()
                    }
                }
                accuracyRow
            }
            .padding(.horizontal, 2)
        }
        .containerBackground(.orange.gradient.opacity(0.18), for: .tabView)
    }

    /// GPS quality stays visible during the session, not just before it — if the
    /// signal degrades mid-session the rider should be able to see why their
    /// numbers went strange.
    private var accuracyRow: some View {
        let accuracy = recorder.metrics.horizontalAccuracy
        return HStack(spacing: 4) {
            Image(systemName: accuracy >= 0 && accuracy <= 10 ? "location.fill" : "location.slash")
                .font(.system(size: 10))
                .foregroundStyle(accuracy >= 0 && accuracy <= 10 ? .green : .orange)
            Text(accuracy >= 0 ? String(format: "±%.0f m", accuracy) : "no fix")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Angles

/// Wind angle, VMG and heading — the page that makes this a wing app rather
/// than a generic speed app.
struct AnglesPage: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                if let twa = recorder.metrics.trueWindAngle {
                    WindRose(
                        heading: recorder.metrics.heading,
                        windFrom: recorder.wind?.directionFrom ?? 0
                    )
                    .frame(height: 74)

                    HStack(spacing: 12) {
                        MetricPair(
                            label: twa > 0 ? "PORT" : "STBD",
                            value: String(format: "%.0f°", abs(twa))
                        )
                        MetricPair(
                            label: "VMG",
                            value: recorder.metrics.vmg.map {
                                Format.speed(abs($0), unit: settings.units.speed,
                                             decimals: 1, includeSymbol: false)
                            } ?? "—"
                        )
                    }
                    Text(PointOfSail(trueWindAngle: twa).displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    // Honest about the gap rather than showing a fake compass.
                    VStack(spacing: 6) {
                        Image(systemName: "wind")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Set the wind direction to see your angles and VMG live.")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Text("openWater will also work it out from your track after the session.")
                            .font(.system(size: 10))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                }

                MetricPair(
                    label: "HEADING",
                    value: Format.bearing(recorder.metrics.heading)
                )
            }
            .padding(.horizontal, 2)
        }
        .containerBackground(.teal.gradient.opacity(0.18), for: .tabView)
    }
}

/// A compass rose showing heading against the wind axis, with the no-go sector
/// shaded so the geometry is readable in one glance.
struct WindRose: View {
    let heading: Double
    let windFrom: Double

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = size / 2 - 4

            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.3), lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)

                // No-go sector, drawn relative to the wind.
                Path { path in
                    path.move(to: centre)
                    path.addArc(
                        center: centre,
                        radius: radius,
                        startAngle: .degrees(windFrom - 35 - 90),
                        endAngle: .degrees(windFrom + 35 - 90),
                        clockwise: false
                    )
                    path.closeSubpath()
                }
                .fill(.red.opacity(0.18))

                // Wind arrow, pointing the way the wind is blowing.
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.blue)
                    .offset(y: -radius + 8)
                    .rotationEffect(.degrees(windFrom), anchor: .center)

                // Heading needle.
                Capsule()
                    .fill(.green)
                    .frame(width: 3, height: radius * 1.5)
                    .offset(y: -radius * 0.4)
                    .rotationEffect(.degrees(heading), anchor: .center)
            }
            .position(centre)
        }
    }
}

// MARK: - Foil

struct FoilPage: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: recorder.metrics.isFoiling ? "airplane" : "water.waves")
                        .foregroundStyle(recorder.metrics.isFoiling ? .green : .secondary)
                    Text(recorder.metrics.isFoiling ? "FLYING" : "ON THE WATER")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(recorder.metrics.isFoiling ? .green : .secondary)
                }

                BigStat(
                    label: "THIS FLIGHT",
                    value: Format.shortDuration(recorder.metrics.currentFlightDuration)
                )
                HStack(spacing: 12) {
                    MetricPair(
                        label: "LONGEST",
                        value: Format.shortDuration(recorder.metrics.longestFlight)
                    )
                    MetricPair(
                        label: "ON FOIL",
                        value: Format.duration(recorder.metrics.timeOnFoil)
                    )
                }
                if !recorder.motion.isAvailable {
                    Text("No motion sensor — flight detection is using speed only.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 2)
        }
        .containerBackground(.purple.gradient.opacity(0.18), for: .tabView)
    }
}

// MARK: - Controls

struct ControlsPage: View {

    @Binding var showingEndConfirmation: Bool

    @Environment(SessionRecorder.self) private var recorder

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if recorder.state == .paused {
                    Button {
                        recorder.resume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                } else {
                    Button {
                        recorder.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.orange)
                }

                Button {
                    showingEndConfirmation = true
                } label: {
                    Label("End", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)

                Button {
                    WKInterfaceDevice.current().enableWaterLock()
                } label: {
                    Label("Water Lock", systemImage: "drop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.blue)
            }
            .font(.caption)
            .padding(.horizontal, 2)
        }
        .containerBackground(.gray.gradient.opacity(0.2), for: .tabView)
    }
}

// MARK: - Shared bits

struct MetricPair: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }
}

struct BigStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
