import OpenWaterCore
import SwiftUI
import WatchKit

/// The live session: swipeable pages, each answering one question.
///
/// Horizontal paging, and the order is deliberate. The stats land first because
/// that is what a glance mid-run is for. Controls sit one page to the *left*,
/// which is the direction a thumb travels to get back — stop and pause should
/// be one deliberate swipe away, never on the page you are reading. Everything
/// else is to the right, in the order it gets checked: splits between runs,
/// then the session totals, then the sport-specific detail.
///
/// The crown turns those same pages, one notch a page, and the swipe stays.
/// Not fashion: a swipe needs a dry fingertip and a still wrist, and this app
/// is used by people holding a wing in twenty knots with cold, wet hands.
/// The crown works through all of that, and it works with the wrist held
/// where a rider can actually read it. Apple's own Workout app pages with the
/// crown for the same reason; the only difference here is the axis, because
/// these pages already read left to right and moving them would move the one
/// thing riders have learned.
struct LiveSessionView: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings
    @Environment(WatchSyncClient.self) private var sync

    @State private var page: Page = WatchScreenshotRoute.page ?? .speed
    @State private var showingEndConfirmation = false

    /// Set only when stopping could not put the session anywhere safe. A rider
    /// who pressed stop and was dropped back on the start screen has no way to
    /// tell "saved" from "gone", so silence is not an option here.
    @State private var saveFailure: SaveFailure?

    /// Stopping is not re-entrant: the dialog can be tapped twice on a wet
    /// screen, and the second pass would find the engine already finishing and
    /// report a failure for a session that saved perfectly well.
    @State private var isEnding = false

    /// Where the crown is, in pages. Kept in step with `page` in both
    /// directions so a swipe and a notch never disagree about where the rider
    /// is — a crown left behind by a swipe would jump the page back the
    /// moment it was touched.
    @State private var crown: Double = 0
    @FocusState private var crownFocused: Bool

    enum Page: Int, CaseIterable, Hashable {
        case controls, speed, splits, session, angles, foil, countdown
    }

    /// The pages this sport actually shows, in the order a swipe crosses
    /// them. The crown's track has to be this list rather than `allCases`:
    /// angles exist only under a wing and foil only on a foil, so a notch
    /// counted against every case would land on a page that is not there.
    private var pages: [Page] {
        var out: [Page] = [.controls, .speed, .splits, .session]
        if recorder.sport.isWindPowered { out.append(.angles) }
        if recorder.sport.isFoiling { out.append(.foil) }
        out.append(.countdown)
        return out
    }

    var body: some View {
        TabView(selection: $page) {
            ControlsPage(showingEndConfirmation: $showingEndConfirmation).tag(Page.controls)
            SpeedPage().tag(Page.speed)
            SplitsPage().tag(Page.splits)
            SessionPage().tag(Page.session)
            if recorder.sport.isWindPowered {
                AnglesPage().tag(Page.angles)
            }
            if recorder.sport.isFoiling {
                FoilPage().tag(Page.foil)
            }
            CountdownPage().tag(Page.countdown)
        }
        .tabViewStyle(.page)
        // The crown drives the same pages the finger does. Focus is what
        // routes crown input, so the strip claims it on appear and takes it
        // back whenever the page changes — a tap on a control inside a page
        // can move focus, and a crown that has quietly stopped working is
        // worse than one that never did.
        .focusable(true)
        .focused($crownFocused)
        .digitalCrownRotation(
            $crown,
            from: 0,
            through: Double(max(1, pages.count - 1)),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crown) { _, value in
            let index = min(max(0, Int(value.rounded())), pages.count - 1)
            guard pages[index] != page else { return }
            withAnimation(.snappy) { page = pages[index] }
        }
        .onChange(of: page) { _, value in
            crownFocused = true
            guard let index = pages.firstIndex(of: value),
                  Int(crown.rounded()) != index else { return }
            crown = Double(index)
        }
        .onAppear {
            crownFocused = true
            if let index = pages.firstIndex(of: page) { crown = Double(index) }
        }
        // Ending saves. Discard used to sit right underneath, on a screen the
        // size of a stamp, tapped by a wet finger — the single easiest way in
        // the whole app to destroy a session. It is gone: the session syncs to
        // the phone, and anything unwanted is deleted there, where it lands in
        // Recently Deleted and can come back.
        .confirmationDialog("End session?", isPresented: $showingEndConfirmation) {
            Button("End & Save") { Task { await end() } }
            Button("Keep Recording", role: .cancel) {}
        }
        .sheet(item: $saveFailure) { failure in
            SaveFailureView(failure: failure)
        }
    }

    /// Stop, and say so plainly if the session did not get anywhere safe.
    ///
    /// The old version was `if let session = await recorder.finish() { send }`,
    /// which did nothing at all when the session could not be built and nothing
    /// when the write failed — the rider was returned to the start screen with
    /// no session and no explanation, which is indistinguishable from having
    /// saved. Every outcome now ends in either a saved session or a sheet.
    private func end() async {
        guard !isEnding else { return }
        isEnding = true
        defer { isEnding = false }

        var saved = false
        let session = await recorder.finish { session in
            saved = sync.send(session)
            return saved
        }

        guard let session else {
            // Nothing was built. Either there were too few fixes to make a
            // session, or this is a second press — and a second press has
            // nothing to report.
            if recorder.state == .idle, !saved { saveFailure = .tooShort }
            return
        }
        if !saved { saveFailure = .notWritten(session) }
    }
}

/// Why stopping could not save, in the rider's terms.
enum SaveFailure: Identifiable {
    /// Too few fixes to build a session at all.
    case tooShort
    /// The session exists but could not be written to the outbox.
    case notWritten(Session)

    var id: String {
        switch self {
        case .tooShort: "tooShort"
        case .notWritten(let session): session.id.uuidString
        }
    }
}

struct SaveFailureView: View {

    let failure: SaveFailure

    @Environment(WatchSyncClient.self) private var sync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text(explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if case .notWritten(let session) = failure {
                    Button("Try Again") {
                        if sync.send(session) { dismiss() }
                    }
                    .tint(.green)
                }

                Button("OK") { dismiss() }
            }
            .padding(.horizontal, 4)
        }
    }

    private var title: String {
        switch failure {
        case .tooShort: "Nothing to save"
        case .notWritten: "Couldn't save"
        }
    }

    /// The second case deliberately promises the recovery prompt: the engine
    /// keeps the track log whenever the save says no, so the session really is
    /// still on the watch and really will be offered back.
    private var explanation: String {
        switch failure {
        case .tooShort:
            "That session was too short to record — openWater never got enough fixes to build a track."
        case .notWritten:
            "openWater couldn't write this session to your watch's storage. The track is still here and will be offered back next time you open the app."
        }
    }
}

// MARK: - Speed

/// The glanceable page. One enormous number and nothing that competes with it.
struct SpeedPage: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    @State private var showingHeartRateHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Elapsed time first. On the water the question is rarely "how fast
            // am I *now*" alone — it is that against how long you have been out.
            Text(Format.duration(recorder.metrics.duration))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Divider().padding(.vertical, 2)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.speed(
                    recorder.metrics.currentSpeed,
                    unit: settings.units.speed,
                    decimals: 1,
                    includeSymbol: false
                ))
                // Rounded, monospaced digits: rounded reads at a glance in
                // spray, monospaced stops the layout jittering as the digits
                // change at 1 Hz.
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(recorder.state == .paused ? .secondary : .primary)

                Spacer(minLength: 0)

                Text(settings.units.speed.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Heading, which is what tells a downwinder whether they are still
            // on the line they meant to be on.
            Text(headingText)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if recorder.state == .paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)

            // Always-on dimming strips everything but the essentials, which is
            // what makes a three-hour session survivable on one charge.
            if !isLuminanceReduced {
                Divider().padding(.bottom, 3)
                HStack {
                    // A blank beat is worth a word. Nothing here used to
                    // separate "no heart rate yet" from "no heart rate ever",
                    // so a rider who declined the Health prompt at the start
                    // watched a zero for three hours and found out on the
                    // phone afterwards.
                    if recorder.workout.heartRateUnavailable {
                        Button { showingHeartRateHelp = true } label: {
                            HStack(spacing: 3) {
                                Text("Off")
                                Image(systemName: "heart.slash")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.pink.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 3) {
                            Text(heartRateText)
                                .monospacedDigit()
                            Image(systemName: "heart.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.pink)
                        }
                    }
                    Spacer()
                    Text(Format.distance(recorder.metrics.distance, unit: settings.units.distance))
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // watchOS cannot open its own Settings from an app, so the help is
        // the instructions themselves rather than a button that pretends to
        // take a rider somewhere.
        .sheet(isPresented: $showingHeartRateHelp) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Heart rate is off", systemImage: "heart.slash")
                        .font(.headline)
                    Text("This session will have none.")
                        .font(.body)
                    // On a screen this size the temptation is to shrink the
                    // type until everything fits. The route is the whole
                    // point of the sheet, so it keeps body size and the sheet
                    // scrolls instead.
                    Text("On your iPhone:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Health app ▸ profile ▸ Privacy ▸ Apps ▸ openWater ▸ Heart Rate")
                        .font(.body.weight(.medium))
                    Text("Applies to your next session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    /// `116°SE`, or an em dash until the receiver has a heading to give — a
    /// bearing of 000° that means "unknown" is worse than no bearing at all.
    private var headingText: String {
        let course = recorder.metrics.heading
        guard course.isFinite, course >= 0 else { return "—" }
        return "\(Format.bearing(course, includeCardinal: false))\(Format.cardinal(course))"
    }

    private var heartRateText: String {
        guard let bpm = recorder.metrics.heartRate, bpm > 0 else { return "0" }
        return String(Int(bpm.rounded()))
    }
}

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
        .containerBackground(Color.accentColor.gradient.opacity(0.18), for: .tabView)
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
            // How often fixes are actually landing, which is a different
            // failure from how good they are.
            if let interval = recorder.metrics.fixInterval {
                Text(String(format: "· %.1f s", interval))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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
    @Environment(WatchSettings.self) private var settings

    @State private var showingSettings = false

    var body: some View {
        // A 2×2 grid of targets rather than a list. Every one of these is
        // pressed with a cold wet finger, often through a wetsuit sleeve, and
        // the difference between "stop" and "pause" being mistaken is an hour
        // of session — so they are large, far apart, and coloured differently.
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                controlButton("Stop", systemImage: "xmark", tint: .red) {
                    showingEndConfirmation = true
                }
                if recorder.state == .paused {
                    controlButton("Resume", systemImage: "play.fill", tint: .green) {
                        recorder.resume()
                    }
                } else {
                    controlButton("Pause", systemImage: "pause.fill", tint: .green) {
                        recorder.pause()
                    }
                }
            }
            GridRow {
                controlButton("Lock", systemImage: "drop.fill", tint: .cyan) {
                    // Water Lock. On a wrist that is about to be underwater
                    // every few seconds this is not a nicety — without it the
                    // screen takes taps from the water and the session ends by
                    // itself.
                    WKInterfaceDevice.current().enableWaterLock()
                }
                // A sheet rather than a NavigationLink: the live pages are a
                // bare TabView with no navigation stack around them, and a link
                // with nowhere to push is a button that silently does nothing.
                controlButton("Settings", systemImage: "gearshape.fill", tint: .blue) {
                    showingSettings = true
                }
            }
        }
        .padding(.horizontal, 2)
        .sheet(isPresented: $showingSettings) {
            NavigationStack { WatchSettingsView() }
        }
    }

    private func controlButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            controlLabel(title, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func controlLabel(_ title: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

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
