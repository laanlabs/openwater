import MapKit
import OpenWaterCore
import SwiftUI

/// The waves a rider caught, measured against the swell they set.
///
/// Anchored on the swell arrow and deliberately not the wind — a wave day is
/// exactly the day the two disagree, a side-shore breeze over a groundswell,
/// and every wind-anchored screen calls that riding across. See
/// `WaveRideFinder` for the rules. Nothing here touches how runs, legs or
/// glides are worked out; this is another reading of the same track.
struct WaveDetailView: View {

    let session: Session
    let summary: SessionSummary
    var onSetWind: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var waves: WaveRideSummary?
    @State private var selectedRide: Int?

    /// The replay. `elapsed` is on whichever clock `ridesOnly` selects — the
    /// riding time with the paddling cut out, or the session's own.
    @State private var elapsed: TimeInterval = 0
    @State private var isPlaying = false
    @State private var ridesOnly = true
    @State private var speedMultiplier: Double = 4
    @State private var timeline = RideTimeline(rides: [])

    /// How the rows are stacked. Time order is the default because the list
    /// reads like the session; the other two answer "which was my best wave"
    /// without scanning seventy-eight rows. A ride keeps its number whatever
    /// the order — the number is its badge on the map, not its rank.
    private enum Order: String, CaseIterable, Identifiable {
        case time = "In order"
        case longest = "Longest"
        case fastest = "Fastest"
        var id: String { rawValue }
    }

    @State private var order: Order = .time

    /// The map with the screen to itself — by the button on the card, or by
    /// turning the phone on its side.
    @State private var isMapFullScreen = false

    /// The rules that decide what is on this screen at all.
    @State private var isEditingRules = false

    private func ordered(_ waves: WaveRideSummary) -> [WaveRide] {
        switch order {
        case .time: waves.rides
        case .longest: waves.rides.sorted { $0.duration > $1.duration }
        case .fastest: waves.rides.sorted { $0.peakSpeed > $1.peakSpeed }
        }
    }

    private var units: UnitPreferences { settings.units }

    private var thresholds: SportThresholds {
        settings.thresholds(for: session.sport)
    }

    /// What a re-find depends on: the arrow everything is measured from, and
    /// the rules it is measured by.
    private struct FindingRules: Equatable {
        let swell: Double?
        let thresholds: SportThresholds
    }

    /// The swell's colour everywhere in the app, so the arrow on the
    /// conditions dial and the rides on this map read as one thing.
    private static let waveColour = Color.teal

    /// A height under five centimetres is the slider never having moved.
    private var missingHeight: Bool { (session.swellHeight ?? 0) <= 0.05 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if session.swellDirection == nil {
                    needsSwellCard
                } else if let waves, waves.count > 0 {
                    if missingHeight { needsHeightCard }
                    summaryCard(waves)
                    mapCard(waves)
                    ridesCard(waves)
                } else if waves != nil {
                    if missingHeight { needsHeightCard }
                    nothingFound
                }

                footer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .readableContentColumn()
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wave Rides")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Session · Waves")
        .sheet(isPresented: $isEditingRules) {
            if let swellFrom = session.swellDirection {
                WaveRulesSheet(session: session, summary: summary, swellFrom: swellFrom)
            }
        }
        .task(id: isPlaying) { await runPlayback() }
        // Keyed on the rules as well as the swell. A rider who widens the
        // cone or lets the board rattle is asking this screen a different
        // question, and it has to be re-asked of the track — which is cheap,
        // because rides are found on demand and never stored.
        .task(id: FindingRules(swell: session.swellDirection, thresholds: thresholds)) {
            isPlaying = false
            elapsed = 0
            guard let swellFrom = session.swellDirection else {
                waves = nil
                timeline = RideTimeline(rides: [])
                return
            }
            let found = WaveRideFinder(thresholds: thresholds)
                .rides(in: session.track, flights: summary.flights, swellFrom: swellFrom)
            waves = found
            timeline = RideTimeline(rides: found.rides)
        }
    }

    // MARK: - Nothing to measure from

    /// The one thing this screen cannot do without, asked for with the same
    /// card-and-button shape the Runs tab uses for a missing wind.
    private var needsSwellCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Which way were the waves going?", systemImage: "water.waves")
                .font(.subheadline.weight(.semibold))
            Text("Wave rides are measured against the swell — deliberately "
                 + "not the wind, because on a wave day the two often disagree. "
                 + "Point the swell arrow, set its height while you're there, "
                 + "and this screen fills in. \"Look up that day's conditions\" "
                 + "can fetch both for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onSetWind) {
                Text("Set the swell")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Self.waveColour, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .cardChrome()
    }

    /// The direction is enough to *find* the rides, so nothing is withheld —
    /// but a wave day without a size is half a story, and this is the screen
    /// where the rider is thinking about the waves. Asked here, loudly,
    /// rather than silently tolerated.
    private var needsHeightCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("How big was it?", systemImage: "water.waves")
                .font(.subheadline.weight(.semibold))
            Text("The swell height isn't set. The rides below are found from "
                 + "the swell's direction alone — add the height so the day "
                 + "reads whole, or let the lookup fetch it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onSetWind) {
                Text("Set the swell height")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Self.waveColour, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .cardChrome()
    }

    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No wave rides found")
                .font(.subheadline.weight(.semibold))
            Text("Nothing accelerated while pointed the way the swell was "
                 + "travelling. If that reads wrong, check the swell arrow — "
                 + "every ride here is measured against it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Check the swell direction", action: onSetWind)
                Button("Loosen what counts") { isEditingRules = true }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(14)
        .cardChrome()
    }

    // MARK: - Summary

    private func summaryCard(_ waves: WaveRideSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(waves.count == 1 ? "1 wave" : "\(waves.count) waves")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 8)
                    Text("\(Format.distance(waves.distance, unit: units.distance)) · \(Format.shortDuration(waves.timeOnWaves)) riding")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 18) {
                    measure("Longest", Format.shortDuration(waves.longest?.duration ?? 0))
                    measure("Fastest", Format.speed(waves.fastest?.peakSpeed ?? 0,
                                                    unit: units.speed, decimals: 1))
                    measure("Typical", Format.shortDuration(waves.averageDuration))
                }
            }

            rulesButton
        }
        .padding(14)
        .cardChrome()
    }

    /// The way into the rules, against the numbers they produced.
    ///
    /// It began life as a gear in the navigation bar, which is where an app
    /// puts a setting nobody is expected to touch. These are not that: every
    /// number on this card is the output of six adjustable rules, and a rider
    /// whose thirty-second ride is being called twenty-five has no reason to
    /// suspect a toolbar. Beside the count, it reads as what it is — the
    /// count is *this* answer, and here is where you change the question.
    private var rulesButton: some View {
        Button {
            isEditingRules = true
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                Text("Rules")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Self.waveColour)
            .frame(width: 54, height: 50)
            .background(Self.waveColour.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What counts as a wave ride")
        .accessibilityHint("Adjust the rules these numbers come from")
    }

    private func measure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    // MARK: - Map

    private func mapCard(_ waves: WaveRideSummary) -> some View {
        VStack(spacing: 0) {
            map(waves)
                .frame(height: 260)
                // Bottom trailing, the same corner and the same glyph as the
                // Upwind and Glides maps: expanding a map should be the one
                // gesture wherever a session is being read.
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        isMapFullScreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .accessibilityLabel("Expand map")
                }
                .overlay(alignment: .topLeading) {
                    conditionsDial(size: 44)
                        .padding(8)
                }
            replayBar
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // On this card and not on the screen, so that a session with no swell
        // set — where there is no map at all — stays upright.
        .fullScreenInLandscape($isMapFullScreen)
        .fullScreenCover(isPresented: $isMapFullScreen) {
            fullScreenMap(waves)
        }
    }

    /// The same map, the same replay, without the page around it.
    ///
    /// Not a second screen: `map` and `replayBar` are the card's own, so a
    /// wave chosen here is chosen there, and closing this lands back on a
    /// card already showing whichever wave was being watched.
    private func fullScreenMap(_ waves: WaveRideSummary) -> some View {
        map(waves)
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) { replayBar }
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 10) {
                    MapChromeButton {
                        isMapFullScreen = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                    }
                    // Beside the ✕ rather than under it: the dial is 64 points
                    // and a column of the two would reach a third of the way
                    // down a sideways phone.
                    conditionsDial(size: 64)
                }
                .padding(.leading, 16)
                .padding(.top, 8)
            }
            .closesInPortrait()
    }

    /// The day's wind, swell and current, in the corner of the map they
    /// describe.
    ///
    /// The Map tab and the Runs tab both carry this dial in this corner, and
    /// this is the screen where the swell arrow matters most: every ride
    /// below was found by it, and a ride list that reads wrong is usually an
    /// arrow pointing the wrong way. Correcting it should not mean leaving
    /// the picture it produced — tapping opens the same conditions sheet the
    /// cards below open.
    @ViewBuilder
    private func conditionsDial(size: CGFloat) -> some View {
        if let wind = session.effectiveWind {
            Button(action: onSetWind) {
                WindDial(wind: wind,
                         swell: session.swellHeight,
                         swellFrom: session.swellDirection,
                         current: session.currentSpeed,
                         currentToward: session.currentDirectionToward,
                         units: units,
                         size: size)
            }
            .buttonStyle(.plain)
        } else {
            // Nothing to draw a dial from. The same capsule the Map tab
            // offers, so the way in is the same wherever it is met.
            Button(action: onSetWind) {
                Label("Set wind", systemImage: "wind")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func map(_ waves: WaveRideSummary) -> some View {
        Map {
            MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                .stroke(.gray.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // The others first, the chosen one last — same as every map that
            // draws runs, and for the same reason.
            ForEach(waves.rides.filter { $0.id != focusedRide }) { ride in
                MapPolyline(coordinates: coordinates(of: ride))
                    .stroke(focusedRide == nil ? Self.waveColour
                            : Color.secondary.opacity(0.22),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(waves.rides.filter { $0.id == focusedRide }) { ride in
                MapPolyline(coordinates: coordinates(of: ride))
                    .stroke(Self.waveColour,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }

            // Once one is chosen — by tap, or by the replay reaching it —
            // only its own badge stays.
            ForEach(waves.rides.filter { focusedRide == nil || $0.id == focusedRide }) { ride in
                Annotation("", coordinate: midpoint(of: ride), anchor: .center) {
                    Button { select(ride) } label: {
                        rideBadge(ride)
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }

            // The chosen ride also wears an arrow at its kick-out, so the end
            // it finished on is visible and not just inferred from the badge.
            ForEach(waves.rides.filter { $0.id == focusedRide }) { ride in
                Annotation("", coordinate: endpoint(of: ride), anchor: .center) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(ride.netBearing))
                        .frame(width: 22, height: 22)
                        .background(Self.waveColour, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .annotationTitles(.hidden)
            }

            // The replay's dot. The camera is deliberately left alone: a map
            // that follows a playhead re-lays itself out on every frame, and
            // this one lives inside a scroll view.
            if let position = playheadCoordinate {
                Annotation("", coordinate: position, anchor: .center) {
                    Playhead(speed: session.track.speed(atElapsed: sessionElapsed),
                             maxSpeed: max(summary.maxSpeed, 1))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(settings.mapStyle.mapStyle)
        .overlay(alignment: .bottomLeading) {
            // Offered whenever *anything* is singled out, not just when a
            // wave was tapped: pausing mid-replay also leaves one wave lit,
            // and a highlight with no way out is a trap.
            if focusedRide != nil {
                Button("Show all") { showAll() }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
            }
        }
    }

    /// A ride's marker: its number, and a pointer on the rim turned the way
    /// the ride made ground.
    ///
    /// The direction belongs *on* the badge rather than beside it. Teal lines
    /// crossing each other have no direction until something says which end is
    /// the finish, and a session's kick-outs all converge on the same downwind
    /// corner — a second puck per ride there would bury the numbers it was
    /// meant to clarify. One marker, both facts, at the ride's midpoint.
    private func rideBadge(_ ride: WaveRide) -> some View {
        let lead = focusedRide == ride.id
        let size: CGFloat = lead ? 24 : 18
        return ZStack {
            // White under teal, so the pointer keeps its edge over the ride
            // lines on a dark map and over open water on a light one.
            ZStack {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: lead ? 13 : 11))
                    .foregroundStyle(.white)
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: lead ? 9 : 7.5))
                    .foregroundStyle(Self.waveColour)
            }
            .offset(y: -(size / 2 + (lead ? 7 : 6)))
            .rotationEffect(.degrees(ride.netBearing))

            Text("\(ride.id + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Self.waveColour, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
        }
        .frame(width: size + 28, height: size + 28)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .accessibilityLabel("Wave \(ride.id + 1), ran \(Format.cardinal(ride.netBearing))")
    }

    private func coordinates(of ride: WaveRide) -> [CLLocationCoordinate2D] {
        guard ride.startIndex <= ride.endIndex,
              ride.endIndex < session.track.points.count else { return [] }
        return session.track.points[ride.startIndex...ride.endIndex].map(\.clCoordinate)
    }

    private func midpoint(of ride: WaveRide) -> CLLocationCoordinate2D {
        session.track.points[min(ride.midIndex, session.track.points.count - 1)].clCoordinate
    }

    private func endpoint(of ride: WaveRide) -> CLLocationCoordinate2D {
        session.track.points[min(ride.endIndex, session.track.points.count - 1)].clCoordinate
    }

    // MARK: - Replay

    /// A scrubber for the waves, not a second playback screen.
    ///
    /// The session already has a full-screen replay with every readout on it;
    /// what is wanted here is smaller — watch the waves go by on the map that
    /// is already showing them. Ticked, the paddling between rides is cut out
    /// and the waves play back to back; unticked, the whole session runs and
    /// the waves arrive where they actually did.
    private var replayBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if elapsed >= replayRange.upperBound - 0.05 {
                        elapsed = replayRange.lowerBound
                    }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Self.waveColour)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause replay" : "Play replay")

                // Scrubbing takes the wheel: playing on under a dragging
                // thumb fights the finger.
                Slider(value: scrub, in: 0...1) { editing in
                    if editing { isPlaying = false }
                }
                .tint(Self.waveColour)

                Button {
                    let i = Self.rates.firstIndex(of: speedMultiplier) ?? 0
                    speedMultiplier = Self.rates[(i + 1) % Self.rates.count]
                } label: {
                    Text("\(Int(speedMultiplier))×")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 32)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replay speed \(Int(speedMultiplier)) times")
            }

            HStack(spacing: 8) {
                Button {
                    let atSession = sessionElapsed
                    ridesOnly.toggle()
                    // The two clocks measure different things, so the playhead
                    // is carried across rather than reset: scrubbed to wave six
                    // and then ticked, it should still be wave six.
                    elapsed = ridesOnly
                        ? timeline.compressed(atSessionElapsed: atSession)
                        : atSession
                } label: {
                    Label {
                        Text("Waves only")
                    } icon: {
                        Image(systemName: ridesOnly ? "checkmark.square.fill" : "square")
                    }
                    .font(.caption)
                    .foregroundStyle(ridesOnly ? Self.waveColour : Color.secondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 6)

                Text(replayLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background)
    }

    /// Choosing a wave aims the replay at it: the playhead drops to that
    /// ride's takeoff and the transport is bounded by it, so play means play
    /// *this wave* rather than resume the session from wherever the playhead
    /// was left. Letting the wave go hands the whole clock back, and leaves
    /// the playhead where it stopped rather than rewinding the session.
    private func select(_ ride: WaveRide) {
        guard selectedRide != ride.id else { return showAll() }
        withAnimation(.snappy) { selectedRide = ride.id }
        isPlaying = false
        elapsed = replayRange.lowerBound
    }

    /// Back to the whole session: no wave singled out, and the playhead
    /// rewound so it cannot quietly single one out again.
    ///
    /// Clearing the selection alone is not enough — a playhead parked inside a
    /// wave still names it, so the map would keep showing that one wave while
    /// the control that clears it has already gone.
    private func showAll() {
        withAnimation(.snappy) { selectedRide = nil }
        isPlaying = false
        elapsed = 0
    }

    /// What the transport covers: the chosen wave, or the whole clock.
    private var replayRange: ClosedRange<TimeInterval> {
        guard let window = selectedWindow else { return 0...replayDuration }
        let lower = ridesOnly ? window.offset : window.start
        let upper = ridesOnly ? window.offset + window.duration : window.end
        return lower...max(upper, lower + 0.1)
    }

    /// The slider's position within whatever the transport covers, as a
    /// fraction — never in seconds.
    ///
    /// Its bounds must not move. A `Slider` whose range and value change in
    /// the same update hands the new value to a control still holding the old
    /// range, which clamps it and writes the clamped number back through the
    /// binding: rewinding the playhead while clearing a selection was undone
    /// on the spot, leaving the map stuck on one wave. Fractions keep the
    /// bounds fixed at 0...1 for the life of the screen, so there is nothing
    /// to clamp against.
    private var scrub: Binding<Double> {
        Binding(
            get: {
                let range = replayRange
                let span = range.upperBound - range.lowerBound
                return span > 0 ? (elapsed - range.lowerBound) / span : 0
            },
            set: { fraction in
                let range = replayRange
                elapsed = range.lowerBound
                    + fraction * (range.upperBound - range.lowerBound)
            }
        )
    }

    private static let rates: [Double] = [1, 2, 4, 8, 16]

    /// 20 Hz — a playhead that moves smoothly without waking the CPU more
    /// than the display needs.
    private static let tick: TimeInterval = 1.0 / 20.0

    /// The clock the slider runs on: the riding time when the paddling is cut
    /// out, the session's own when it is not.
    private var replayDuration: TimeInterval {
        max(1, ridesOnly ? timeline.duration : session.track.duration)
    }

    /// Where the playhead is on the session's own clock, whichever clock the
    /// slider happens to be showing.
    ///
    /// A chosen wave reads through its own window rather than through the
    /// timeline: its kick-out instant is also the next wave's takeoff, and the
    /// timeline-wide lookup would answer with the next wave — sending the dot
    /// across the bay the moment the ride finished.
    private var sessionElapsed: TimeInterval {
        guard ridesOnly else { return elapsed }
        if let window = selectedWindow { return window.sessionElapsed(at: elapsed) }
        return timeline.sessionElapsed(at: elapsed)
    }

    private var selectedWindow: RideTimeline.Window? {
        selectedRide.flatMap(timeline.window(forRide:))
    }

    /// The replay has been used — pressed, or scrubbed off zero. Until then
    /// the map is the map it always was and the playhead stays out of it.
    private var replayEngaged: Bool {
        isPlaying || selectedRide != nil || elapsed > 0
    }

    private var playheadRide: Int? {
        guard replayEngaged else { return nil }
        // While a wave is chosen the playhead is that wave's, all the way to
        // its last instant.
        if let id = selectedRide { return id }
        return ridesOnly ? timeline.rideID(at: elapsed)
                         : timeline.rideID(atSessionElapsed: elapsed)
    }

    private var playheadCoordinate: CLLocationCoordinate2D? {
        guard replayEngaged else { return nil }
        return session.track.coordinate(atElapsed: sessionElapsed)?.clCoordinate
    }

    /// The ride the map draws boldly: the rider's own choice, or — once the
    /// replay is running — whichever wave the playhead is on.
    private var focusedRide: Int? { selectedRide ?? playheadRide }

    /// What the playhead is on, and where in the replay it sits.
    private var replayLabel: String {
        let range = replayRange
        let clock = "\(Format.duration(elapsed - range.lowerBound)) / "
            + "\(Format.duration(range.upperBound - range.lowerBound))"
        guard replayEngaged else { return clock }
        if let ride = playheadRide { return "Wave \(ride + 1) · \(clock)" }
        return "Between waves · \(clock)"
    }

    private func runPlayback() async {
        guard isPlaying else { return }
        while isPlaying, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.tick))
            guard isPlaying else { return }
            let end = replayRange.upperBound
            elapsed = min(end, elapsed + Self.tick * speedMultiplier)
            if elapsed >= end {
                isPlaying = false
                return
            }
        }
    }

    // MARK: - The rides

    private func ridesCard(_ waves: WaveRideSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Order", selection: $order) {
                ForEach(Order.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 8)

            ForEach(ordered(waves)) { ride in
                Button { select(ride) } label: {
                    HStack(spacing: 10) {
                        Text("\(ride.id + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(focusedRide == nil || focusedRide == ride.id
                                        ? Self.waveColour
                                        : Color.secondary.opacity(0.35), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Format.distance(ride.distance, unit: units.distance)) · \(Format.shortDuration(ride.duration))")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text("\(Format.speed(ride.averageSpeed, unit: units.speed, decimals: 1)) avg · \(Format.speed(ride.peakSpeed, unit: units.speed, decimals: 1)) peak")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Spacer(minLength: 8)

                        // How square to the swell it was ridden: small is
                        // straight down the face, forty is down the line.
                        Text("\(Int(ride.offSwell.rounded()))° off")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(ride.offSwell <= 30 ? .green : .secondary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(focusedRide == ride.id
                                ? AnyShapeStyle(Self.waveColour.opacity(0.12))
                                : AnyShapeStyle(.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .cardChrome()
    }

    // MARK: - Footer

    /// How the rides are found, said plainly — and where the anchor is, so a
    /// wrong swell arrow gets corrected instead of distrusted.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let swellFrom = session.swellDirection {
                Text("Measured against swell from \(Format.cardinal(swellFrom)) \(Int(swellFrom.rounded()))°"
                     + (session.swellHeight.map { $0 > 0.05 ? " · \(Format.height($0, unit: units.distance))" : "" } ?? "")
                     + ", as you set it.")
                    .font(.caption.weight(.medium))
            }
            Text("A wave ride is a stretch on the foil, at or above your own "
                 + "pace for the day, where the speed *rose* while you pointed "
                 + "within \(Int(WaveRideFinder(thresholds: thresholds).coneAngle))° of the way the swell "
                 + "was travelling — and the whole ride, takeoff to kick-out, "
                 + "made ground that way. The wind is not consulted: waves keep "
                 + "their own direction. Runs and glides are unchanged by any "
                 + "of this. Each ride's number carries a pointer turned the "
                 + "way that ride made ground, and the one you tap also shows "
                 + "an arrow where it kicked out. Press play under the map to "
                 + "watch them in the order they came.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Adjust the swell", action: onSetWind)
                // Every number above comes out of rules that are a guess
                // about water we were not in. Said here, where a rider who
                // has just read the rules and disagreed with them is looking.
                Button("What counts as a ride") { isEditingRules = true }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}
