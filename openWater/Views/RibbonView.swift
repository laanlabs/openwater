import MapKit
import OpenWaterCore
import SwiftUI

/// The session unrolled into lanes.
///
/// This is the answer to "I can't read my own track". The map answers *where*;
/// this answers *what happened*. Each run is a horizontal lane, stacked in time
/// order, so nothing overlaps — because time never overlaps. Within a lane,
/// position is distance along the run, colour is speed, and the fill pattern is
/// ride state. Between lanes, a connector shows what joined them: a gybe, a
/// tack, or a fall.
///
/// A session reads top to bottom like a score: you can see which runs were clean
/// flights, which ones dropped, and exactly where the falls were, all without
/// untangling anything.
struct RibbonView: View {

    let ribbon: SessionRibbon
    let maxSpeed: Double
    let units: UnitPreferences

    /// The run index of the session's fastest run, chipped so it can be found
    /// without reading forty rows.
    var bestRunIndex: Int?

    /// What this session was segmented with, so the explanation quotes the
    /// rider's own numbers rather than the defaults.
    var thresholds: SportThresholds = SportThresholds.forSport(.wingfoil)

    /// Said out loud when the point-of-sail filters rest on a guess, or cannot
    /// exist at all. Upwind and Downwind are the run's angle to the wind, so
    /// without one they are not there — and a rider who does not know that
    /// reads their absence as the session having none.
    var windWarning: String?
    var onSetWind: () -> Void = {}

    /// The session's own runs — the whole way down a river, rather than the
    /// stretches between turns. Empty unless the session went somewhere.
    var legs: [SessionLeg] = []
    var isPointToPoint = false

    /// The track, so this tab can draw the runs rather than only list them.
    ///
    /// A rider who wanted to see where the downwind legs were had to leave
    /// the list, open Analysis and pick a screen. The map belongs where the
    /// runs are.
    var track: Track?
    var mapStyle: MapStyleOption = .standard

    /// The session's flights, so a run ends where the rider came off the foil.
    ///
    /// Without these the list groups on point of sail alone, and a session
    /// with seven swims in it reads as one thirty-six-minute reach.
    var flights: [Flight] = []

    /// The lane the rider has tapped, driving the map's run isolation.
    @Binding var selectedLane: Int?

    /// The grouped run singled out on this tab's own map.
    @State private var selectedRun: Int?
    @State private var camera: MapCameraPosition = .automatic

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var order: Order = .time
    @State private var showsManeuvers = false
    @State private var showingKey = false
    @State private var filter: Leg = .all
    @State private var showsControls = false
    @State private var expandedLeg: Int?

    /// Which way a run was going, in the three groups riders actually talk in.
    ///
    /// `PointOfSail` has five cases and the two extremes are rare enough to be
    /// confusing on a filter: nobody looks for their no-go runs. Close-hauled
    /// and pinching are both "upwind", broad reach and running are both
    /// "downwind", and everything between is a reach.
    enum Leg: String, CaseIterable, Identifiable {
        case all = "All"
        case upwind = "Upwind"
        case reaching = "Reaching"
        case downwind = "Downwind"

        var id: String { rawValue }

        /// The filter, applied to a whole run rather than one stretch.
        func matchesKind(_ kind: GroupedRun.Kind) -> Bool {
            switch self {
            case .all: true
            case .upwind: kind == .upwind
            case .reaching: kind == .reaching
            case .downwind: kind == .downwind
            }
        }

        func matches(_ point: PointOfSail?) -> Bool {
            switch self {
            case .all: true
            case .upwind: point == .noGo || point == .closeHauled
            case .reaching: point == .reaching
            case .downwind: point == .broadReach || point == .running
            }
        }

        /// Legs take their colour from the run kind they are, so a downwind
        /// leg and a downwind run are the same orange on the same map.
        var colour: Color {
            switch self {
            case .upwind: GroupedRun.Kind.upwind.colour
            case .downwind: GroupedRun.Kind.downwind.colour
            case .all, .reaching: GroupedRun.Kind.reaching.colour
            }
        }
    }

    /// One thing the map draws.
    ///
    /// The map and the list are one screen and have to be showing the same
    /// unit — legs when the list is showing legs, runs when it is showing
    /// runs. Drawing runs beneath a list of legs is how this tab came to say
    /// "1 run" above a map with sixteen numbered ones on it.
    private struct Drawn: Identifiable {
        let id: Int
        let title: String
        let number: Int
        let distance: Double
        let colour: Color
        let startElapsed: TimeInterval
        let endElapsed: TimeInterval
    }

    /// How the lanes are stacked.
    ///
    /// Time order is the default because the ribbon is meant to read like a
    /// score. The other two exist because "which was my best run" was a
    /// question the screen could not answer without scanning every row.
    enum Order: String, CaseIterable, Identifiable {
        case time = "In order"
        case fastest = "Fastest"
        case longest = "Longest"

        var id: String { rawValue }
    }

    private var lanes: [SessionRibbon.Lane] {
        let matching = ribbon.lanes.filter { filter.matches($0.pointOfSail) }
        switch order {
        case .time: return matching
        case .fastest: return matching.sorted { $0.averageSpeed > $1.averageSpeed }
        case .longest: return matching.sorted { $0.distance > $1.distance }
        }
    }

    /// Which filters would actually show something. A flat-water session has no
    /// point of sail at all, and offering three empty filters is worse than
    /// offering none.
    private var availableFilters: [Leg] {
        let present = Leg.allCases.filter { leg in
            leg == .all || ribbon.lanes.contains { leg.matches($0.pointOfSail) }
        }
        return present.count > 1 ? present : []
    }

    /// Whether to show the session's runs rather than every stretch between
    /// turns.
    ///
    /// A rider who trimmed a recording down to one run down the river means
    /// *one run*. The segmenter is not wrong to find eighteen — a parawinger
    /// weaves across the bumps and each weave really is a change of direction —
    /// but eighteen rows is an answer to a question nobody asked. So the top
    /// level is the run, and the stretches inside it are one tap down.
    ///
    /// Only when there is more than one leg. A single leg spans the whole
    /// session, so the row reads "Downwind run · 8.03 km · 1:08:03" — the
    /// header said twice, in place of the list of runs the rider opened this
    /// tab to see. Legs earn their keep on a shuttle day and nowhere else.
    private var showsLegs: Bool {
        isPointToPoint && legs.count > 1 && order == .time && filter == .all
    }

    /// The session as a rider counts it: consecutive stretches on the same
    /// point of sail merged into one run.
    ///
    /// Sixty-seven stretches on a lapping afternoon is the segmenter being
    /// accurate and the screen being useless. Grouped, the same session is six
    /// downwinders and five beats back — which is what a rider would say if
    /// you asked them about it.
    private var groupedRuns: [GroupedRun] {
        GroupedRun.group(ribbon.lanes, flights: flights)
    }

    private var showsGrouped: Bool {
        !showsLegs && order == .time && groupedRuns.count < ribbon.lanes.count
    }

    /// What kind of run a leg is, from the point of sail its stretches were
    /// mostly sailed on.
    private func type(of leg: SessionLeg) -> Leg {
        let inside = lanes(in: leg)
        let upwind = inside.filter { Leg.upwind.matches($0.pointOfSail) }.count
        let downwind = inside.filter { Leg.downwind.matches($0.pointOfSail) }.count
        if downwind > upwind, downwind > 0 { return .downwind }
        if upwind > 0 { return .upwind }
        return .reaching
    }

    /// Whether the pieces inside a leg are worth showing.
    ///
    /// On an upwind leg they are tacks — each one a real, deliberate change of
    /// side, and the thing a rider wants to count. On a downwind leg they are
    /// weaves across the bumps, which the segmenter is right to notice and
    /// nobody asked to see: eighteen rows under a single river crossing was
    /// the noise this screen kept being told about.
    private func hasTacks(_ leg: SessionLeg) -> Bool {
        type(of: leg) == .upwind && lanes(in: leg).count > 1
    }

    private func lanes(in leg: SessionLeg) -> [SessionRibbon.Lane] {
        ribbon.lanes.filter { $0.startElapsed >= leg.startElapsed - 1
                           && $0.endElapsed <= leg.endElapsed + 1 }
    }

    /// Maneuvers describe what joined one run to the *next one in time*, so
    /// they are meaningless once the rows are reordered — a gybe drawn between
    /// the fastest run and the second fastest never happened.
    private var showsConnectors: Bool { order == .time && showsManeuvers }

    var body: some View {
        if ribbon.isEmpty {
            ContentUnavailableView(
                "No runs to show",
                systemImage: "chart.bar.doc.horizontal",
                description: Text("This session did not contain any stretches long enough to count as runs.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if track != nil, showsGrouped || showsLegs {
                        runsMap
                            .frame(height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .bottomLeading) {
                                if selection != nil {
                                    Button("Show all") { select(nil) }
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.regularMaterial, in: Capsule())
                                        .padding(8)
                                }
                            }
                            .padding(.top, 10)
                    }

                    if lanes.isEmpty {
                        ContentUnavailableView(
                            "No \(filter.rawValue.lowercased()) runs",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("This session has no runs on that point of sail.")
                        )
                        .padding(.top, 40)
                    }

                    if showsLegs {
                        // Grouped by type, because that is how a rider thinks
                        // about a mixed day: these were my downwind runs,
                        // those were the beats back up.
                        ForEach([Leg.downwind, .reaching, .upwind], id: \.self) { kind in
                            let group = legs.filter { type(of: $0) == kind }
                            if !group.isEmpty {
                                if legs.count > group.count {
                                    Text(kind == .downwind ? "Downwind"
                                         : kind == .upwind ? "Upwind" : "Reaching")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 12)
                                }
                                ForEach(Array(group.enumerated()), id: \.element.id) { index, leg in
                                    legRow(leg, number: index + 1, of: group.count)
                                    if expandedLeg == leg.id, hasTacks(leg) {
                                        ForEach(lanes(in: leg), id: \.id) { lane in
                                            laneRow(lane)
                                                .padding(.leading, 14)
                                        }
                                        .transition(.opacity)
                                    }
                                }
                            }
                        }
                    }

                    if showsGrouped {
                        ForEach(GroupedRun.Kind.allCases, id: \.self) { kind in
                            let group = groupedRuns.filter { $0.kind == kind && filter.matchesKind(kind) }
                            if !group.isEmpty {
                                Text("\(kind.title) · \(group.count)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 12)
                                ForEach(group) { run in
                                    groupedRow(run)
                                }
                            }
                        }
                    }

                    ForEach(showsLegs || showsGrouped ? [] : lanes, id: \.id) { lane in
                        LaneRow(
                            lane: lane,
                            // Lanes are scaled to the longest run so their
                            // lengths are directly comparable — a short run
                            // looks short, which is information.
                            widthFraction: ribbon.maxLaneDistance > 0
                                ? lane.distance / ribbon.maxLaneDistance
                                : 1,
                            maxSpeed: maxSpeed,
                            units: units,
                            isSelected: selectedLane == lane.runIndex,
                            isBest: bestRunIndex == lane.runIndex
                        )
                        .onTapGesture {
                            withAnimation(.snappy) {
                                selectedLane = selectedLane == lane.runIndex ? nil : lane.runIndex
                            }
                        }

                        if showsConnectors, let connector = connector(after: lane.id) {
                            ConnectorRow(connector: connector)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    summaryBar
                    if showsControls {
                        controls
                        if !availableFilters.isEmpty { filterRow }
                    }
                    if let windWarning { windNotice(windWarning) }
                }
                .background(.bar)
            }
            .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
            .sheet(isPresented: $showingKey) {
                RibbonKeySheet(thresholds: thresholds)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - The map

    /// The session's runs drawn where they happened, coloured by kind.
    ///
    /// Laid out like the Upwind and Downwind maps on purpose — faded track
    /// underneath, the runs over it, numbered dots that open into a label,
    /// and everything else dimmed when one is chosen. Three screens draw runs
    /// on a map and they should be the same picture.
    @ViewBuilder
    private var runsMap: some View {
        if let track {
            Map(position: $camera) {
                MapPolyline(coordinates: track.points.map(\.clCoordinate))
                    .stroke(.gray.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                ForEach(drawn) { run in
                    let chosen = selection == nil || selection == run.id
                    MapPolyline(coordinates: coordinates(of: run, in: track))
                        .stroke(chosen ? run.colour : Color.secondary.opacity(0.22),
                                style: StrokeStyle(lineWidth: selection == run.id ? 6 : 4,
                                                   lineCap: .round, lineJoin: .round))
                }

                ForEach(drawn) { run in
                    if let middle = midpoint(of: run, in: track) {
                        let chosen = selection == nil || selection == run.id
                        Annotation("", coordinate: middle, anchor: .center) {
                            Button { select(selection == run.id ? nil : run.id) } label: {
                                if selection == run.id {
                                    Text("\(run.title) \(run.number) · \(Format.distance(run.distance, unit: units.distance))")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(run.colour, in: Capsule())
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                } else {
                                    Text("\(run.number)")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.white)
                                        .frame(width: 18, height: 18)
                                        .background(chosen ? run.colour
                                                    : Color.secondary.opacity(0.35), in: Circle())
                                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            .mapStyle(mapStyle.mapStyle)
        }
    }

    /// The runs the map draws — the filter applies here too, so choosing
    /// "Downwind" leaves the downwind legs alone on the water.
    /// How many the chip is offering to show.
    private func count(for leg: Leg) -> Int {
        if showsGrouped {
            return leg == .all
                ? groupedRuns.count
                : groupedRuns.filter { leg.matchesKind($0.kind) }.count
        }
        return ribbon.lanes.filter { leg.matches($0.pointOfSail) }.count
    }

    private var mappedRuns: [GroupedRun] {
        groupedRuns.filter { filter.matchesKind($0.kind) }
    }

    /// What the map draws, taken from whichever unit the list is showing.
    private var drawn: [Drawn] {
        guard showsLegs else {
            return mappedRuns.map {
                Drawn(id: $0.id, title: $0.kind.title, number: $0.number,
                      distance: $0.distance, colour: $0.kind.colour,
                      startElapsed: $0.startElapsed, endElapsed: $0.endElapsed)
            }
        }
        // Numbered within their own type, exactly as the rows below are.
        var seen: [Leg: Int] = [:]
        return legs.enumerated().map { index, leg in
            let kind = type(of: leg)
            seen[kind, default: 0] += 1
            return Drawn(id: index, title: kind.rawValue, number: seen[kind]!,
                         distance: leg.distance, colour: kind.colour,
                         startElapsed: leg.startElapsed, endElapsed: leg.endElapsed)
        }
    }

    /// The selection, but only while it still refers to something drawn.
    ///
    /// Legs and runs number themselves separately, so a selection made in one
    /// mode can survive into the other and match nothing — which dims every
    /// line on the map and leaves no way back except "Show all".
    private var selection: Int? {
        guard let selectedRun, drawn.contains(where: { $0.id == selectedRun }) else { return nil }
        return selectedRun
    }

    private func coordinates(of item: Drawn, in track: Track) -> [CLLocationCoordinate2D] {
        track.points.indices
            .filter { track.elapsed[$0] >= item.startElapsed && track.elapsed[$0] <= item.endElapsed }
            .map { track.points[$0].clCoordinate }
    }

    private func midpoint(of run: Drawn, in track: Track) -> CLLocationCoordinate2D? {
        let line = coordinates(of: run, in: track)
        guard !line.isEmpty else { return nil }
        return line[line.count / 2]
    }

    /// Choosing a run frames it, the way the Downwind screen does.
    private func select(_ id: Int?) {
        withAnimation(.snappy) {
            selectedRun = id
            guard let id, let track,
                  let run = drawn.first(where: { $0.id == id })
            else {
                camera = .automatic
                return
            }
            let line = coordinates(of: run, in: track)
            guard !line.isEmpty else { return }
            let latitudes = line.map(\.latitude), longitudes = line.map(\.longitude)
            let centre = CLLocationCoordinate2D(
                latitude: (latitudes.min()! + latitudes.max()!) / 2,
                longitude: (longitudes.min()! + longitudes.max()!) / 2
            )
            camera = .region(MKCoordinateRegion(
                center: centre,
                span: MKCoordinateSpan(
                    latitudeDelta: max(0.004, (latitudes.max()! - latitudes.min()!) * 1.5),
                    longitudeDelta: max(0.004, (longitudes.max()! - longitudes.min()!) * 1.5)
                )
            ))
        }
    }

    /// What the screen says before a rider asks it anything.
    ///
    /// The sort, the filters and the maneuver toggle were all on screen at
    /// once, which is four controls above a list somebody opened to look at a
    /// list. They are worth having and they are not worth meeting first, so
    /// they are one tap away behind a button that says what it opens.
    private var summaryBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(showsGrouped
                     ? summaryLine
                     : showsLegs
                     ? "\(legs.count) run\(legs.count == 1 ? "" : "s")"
                     : "\(lanes.count) stretch\(lanes.count == 1 ? "" : "es")")
                    .font(.subheadline.weight(.semibold))
                if filter != .all || order != .time {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }

            Spacer(minLength: 0)

            Button {
                showingKey = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How runs are worked out")

            Button {
                withAnimation(.snappy) { showsControls.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(showsControls ? "Done" : "Filter & sort")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: showsControls ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// What has been narrowed, so a filtered list never looks like the session.
    private var subtitle: String {
        var parts: [String] = []
        if filter != .all { parts.append(filter.rawValue.lowercased()) }
        if order != .time { parts.append(order.rawValue.lowercased() + " first") }
        return parts.joined(separator: " · ")
    }

    /// Sort, maneuvers, and the key — the three things the screen needed and
    /// did not have. The legend used to live here as a permanent line of
    /// six-point text explaining a colour ramp most riders had already worked
    /// out; it is behind the ⓘ now.
    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Order", selection: $order) {
                ForEach(Order.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Button {
                withAnimation(.snappy) { showsManeuvers.toggle() }
            } label: {
                Image(systemName: showsManeuvers
                      ? "arrow.triangle.swap.circle.fill"
                      : "arrow.triangle.swap")
                    .font(.body)
                    .foregroundStyle(showsConnectors ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .disabled(order != .time)
            .accessibilityLabel(showsManeuvers ? "Hide maneuvers" : "Show maneuvers")

        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Four chips fit the width, so this is a plain row.
    ///
    /// It was a horizontal `ScrollView`, which has no intrinsic height and grew
    /// to fill the safe-area inset — a hand's width of grey between the chips
    /// and the runs, and then a collapsed overlap when that was pinned.
    private var filterRow: some View {
        HStack(spacing: 6) {
            ForEach(availableFilters) { leg in
                Button {
                    withAnimation(.snappy) { filter = leg }
                } label: {
                    HStack(spacing: 4) {
                        Text(leg.rawValue)
                        if leg != .all {
                            // Runs when the list shows runs, stretches when it
                            // shows stretches. The chip said 34 downwind while
                            // the heading two lines above said 5 — the same
                            // session counted two ways, on one screen.
                            Text("\(count(for: leg))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    // "Downwind" with a count was eliding to "Downwi… 34" at
                    // 0.8 on the narrowest phone. Smaller beats truncated:
                    // a shrunk word is still readable, half a word is not.
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(filter == leg ? AnyShapeStyle(.tint.opacity(0.18))
                                              : AnyShapeStyle(.quaternary.opacity(0.5)),
                                in: Capsule())
                    .foregroundStyle(filter == leg ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// One run: how far, how long, how fast — and its tacks, when it has any.
    private func legRow(_ leg: SessionLeg, number: Int, of total: Int) -> some View {
        let kind = type(of: leg)
        let tacks = hasTacks(leg) ? lanes(in: leg).count : 0
        return Button {
            guard tacks > 0 else { return }
            withAnimation(.snappy) {
                expandedLeg = expandedLeg == leg.id ? nil : leg.id
            }
        } label: {
            HStack(spacing: 10) {
                if tacks > 0 {
                    Image(systemName: expandedLeg == leg.id ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title(kind, number: number, of: total))
                            .font(.subheadline.weight(.semibold))
                        if let alignment = leg.alignment, leg.isRun, kind == .downwind {
                            Text("\(Int(alignment.rounded()))° off downwind")
                                .font(.caption2)
                                .foregroundStyle(alignment <= 20 ? .green : .secondary)
                        }
                    }
                    Text("\(Format.distance(leg.distance, unit: units.distance)) · \(Format.shortDuration(leg.duration)) · \(Format.speed(leg.averageSpeed, unit: units.speed, decimals: 1)) avg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                // Only tacks are worth counting. A downwind run's stretches
                // are weaves, and saying "18" about one river crossing told
                // the rider nothing they wanted.
                if tacks > 0 {
                    Text("\(tacks) tacks")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(tacks == 0)
    }

    private func title(_ kind: Leg, number: Int, of total: Int) -> String {
        let name = switch kind {
        case .downwind: "Downwind run"
        case .upwind: "Upwind run"
        default: "Run"
        }
        return total > 1 ? "\(name) \(number)" : name
    }

    /// How many of each, which is the whole question a rider brings here.
    private var summaryLine: String {
        let counts = GroupedRun.Kind.allCases.compactMap { kind -> String? in
            let n = groupedRuns.filter { $0.kind == kind }.count
            return n > 0 ? "\(n) \(kind.title.lowercased())" : nil
        }
        return counts.joined(separator: " · ")
    }

    /// One grouped run. Upwind runs open to their tacks; nothing else does,
    /// because nothing else has pieces worth counting.
    private func groupedRow(_ run: GroupedRun) -> some View {
        let tacks = run.kind == .upwind ? run.lanes.count : 0
        return Button {
            // A tap picks the run out on the map. Expanding an upwind run's
            // tacks is the chevron's job — one tap, one meaning.
            select(selectedRun == run.id ? nil : run.id)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if tacks > 1 {
                        Button {
                            withAnimation(.snappy) {
                                expandedLeg = expandedLeg == run.id ? nil : run.id
                            }
                        } label: {
                            Image(systemName: expandedLeg == run.id ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 20)
                    }

                    Text("\(run.number)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(selectedRun == nil || selectedRun == run.id
                                    ? run.kind.colour
                                    : Color.secondary.opacity(0.35), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Format.distance(run.distance, unit: units.distance)) · \(Format.shortDuration(run.duration))")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text("\(Format.speed(run.averageSpeed, unit: units.speed, decimals: 1)) avg · \(Format.speed(run.maxSpeed, unit: units.speed, decimals: 1)) max"
                             + (tacks > 1 ? " · \(tacks) tacks" : ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 8)

                    if run.kind == .downwind, let alignment = run.alignment {
                        Text("\(Int(alignment.rounded()))° off")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(alignment <= 20 ? .green : .secondary)
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 6)
                .background(selectedRun == run.id
                            ? AnyShapeStyle(run.kind.colour.opacity(0.12))
                            : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 10))

                if expandedLeg == run.id, tacks > 1 {
                    ForEach(run.lanes, id: \.id) { lane in
                        laneRow(lane).padding(.leading, 28)
                    }
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func laneRow(_ lane: SessionRibbon.Lane) -> some View {
        LaneRow(
            lane: lane,
            widthFraction: ribbon.maxLaneDistance > 0 ? lane.distance / ribbon.maxLaneDistance : 1,
            maxSpeed: maxSpeed,
            units: units,
            isSelected: selectedLane == lane.runIndex,
            isBest: bestRunIndex == lane.runIndex
        )
        .onTapGesture {
            withAnimation(.snappy) {
                selectedLane = selectedLane == lane.runIndex ? nil : lane.runIndex
            }
        }
    }

    private func windNotice(_ text: String) -> some View {
        Button(action: onSetWind) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text(text)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func connector(after laneID: Int) -> SessionRibbon.Connector? {
        ribbon.connectors.first { $0.fromLane == laneID }
    }
}

/// What the colours mean, on demand.
///
/// Colour is the *speed* ramp, not the state — a slow flight is blue and a
/// fast one is red. State is carried by saturation (riding is washed out
/// against flying) and by the two flat colours for slow and fall. Labelling
/// green as "flying" would be wrong and would make every lane look mislabelled.
struct RibbonKeySheet: View {

    /// The rules the segmenter actually applies, so the sheet cannot drift
    /// from the code as the defaults move.
    var thresholds: SportThresholds = SportThresholds.forSport(.wingfoil)

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("A run is one continuous stretch in roughly one direction. It ends when you turn — the moment your heading holds far enough off the run's own average for long enough to mean it.")
                    Text("So a lap of the bay is two runs and a gybe, not one. Wobbles, luffs and a wave knocking you off line do not end a run; committing to a new direction does.")
                } header: {
                    Text("What a run is")
                }

                Section {
                    rule("Turns at", "\(Int(thresholds.maneuverHeadingChange))° off the run's average heading",
                         detail: "Held long enough to be a decision rather than a wobble.")
                    rule("Riding above", Format.speed(thresholds.movingSpeed, unit: .knots, decimals: 1),
                         detail: "Below this you are drifting, and drifting is not a run.")
                    rule("Discards runs under", "a few seconds and a few tens of metres",
                         detail: "Otherwise every water start becomes an entry.")
                } header: {
                    Text("The numbers behind it")
                } footer: {
                    Text("The turn angle is the one worth moving. It is on the Turns screen, under Analysis, and changing it re-reads the session.")
                }

                Section {
                    HStack(spacing: 10) {
                        LinearGradient(
                            colors: (0...6).map { i in
                                Color(hue: 0.58 - 0.58 * (Double(i) / 6),
                                      saturation: 0.85, brightness: 0.95)
                            },
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 60, height: 8)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        Text("Slow → fast")
                    }
                    LegendSwatch(colour: .gray.opacity(0.45), label: "Below your moving speed")
                    LegendSwatch(colour: .red, label: "A fall")
                } header: {
                    Text("Colour is speed")
                } footer: {
                    Text("Pale is on the water, solid is flying. A slow flight is still blue and a fast one still red — the colour never means the state.")
                }

                Section {
                    Text("Bar length is how far that run went, scaled to the longest run of the session.")
                    Text("The dot is the tack: red for port, green for starboard.")
                    Text("Upwind, Reaching and Downwind are the run's average angle to the wind, so they need a wind direction to exist at all.")
                    Text("Tap a run to see its detail and isolate it on the map.")
                } header: {
                    Text("The rest of the row")
                }
            }
            .navigationTitle("How runs are worked out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func rule(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct LaneRow: View {

    let lane: SessionRibbon.Lane
    let widthFraction: Double
    let maxSpeed: Double
    let units: UnitPreferences
    let isSelected: Bool
    var isBest: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header

            GeometryReader { geometry in
                let fullWidth = geometry.size.width * max(0.06, widthFraction)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(width: fullWidth)

                    ForEach(Array(lane.cells.enumerated()), id: \.offset) { _, cell in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(fill(for: cell))
                            .frame(width: max(1, fullWidth * cell.width))
                            .offset(x: fullWidth * cell.start)
                    }
                }
                .frame(height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 16)

            if isSelected { detail }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }

    /// Four things and a bar.
    ///
    /// This row used to carry eight fields. Every one of them was true and
    /// forty rows of them were a wall — the percentage foiled and the point of
    /// sail are what you read about *one* run you have already picked out, not
    /// what you scan a session by. They moved below, onto the row you tapped.
    private var header: some View {
        HStack(spacing: 6) {
            Text("\(lane.runIndex + 1)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            if let tack = lane.tack {
                // Port and starboard are conventionally red and green, and using
                // that here makes an asymmetric session visible at a glance.
                Circle()
                    .fill(tack == .port ? Color.red : Color.green)
                    .frame(width: 6, height: 6)
            }

            Text(Format.speed(lane.averageSpeed, unit: units.speed, decimals: 1))
                .font(.system(size: 11, design: .rounded).weight(.medium))
                .monospacedDigit()

            Text(Format.distance(lane.distance, unit: units.distance))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if isBest {
                Text("BEST")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }

            Spacer(minLength: 0)
        }
    }

    /// The rest of the row, once you have picked this one out.
    private var detail: some View {
        HStack(spacing: 10) {
            // The compass heading, not the wind angle. On a session of matched
            // reaches every lane has the *same* |TWA| — showing it puts the
            // identical number on every row, which is noise. The heading is
            // what actually differs, and the tack dot already carries the side.
            detailItem("Heading", Format.cardinal(lane.heading))
            if let point = lane.pointOfSail {
                detailItem("Point", point.displayName)
            }
            if lane.foilingFraction > 0.05 {
                detailItem("On foil", "\(Int(lane.foilingFraction * 100))%")
            }
            detailItem("Time", Format.shortDuration(lane.duration))
            detailItem("Top", Format.speed(lane.maxSpeed, unit: units.speed, decimals: 1))
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.leading, 24)
        .transition(.opacity)
    }

    private func detailItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// State picks the hue family; speed modulates it within the lane.
    private func fill(for cell: SessionRibbon.Cell) -> Color {
        switch cell.state {
        case .foiling:
            return speedColour(cell.averageSpeed)
        case .riding:
            return speedColour(cell.averageSpeed).opacity(0.55)
        case .slow:
            return .gray.opacity(0.45)
        case .stopped:
            return .gray.opacity(0.3)
        case .fall:
            return .red
        }
    }

    private func speedColour(_ speed: Double) -> Color {
        let top = max(maxSpeed, 1)
        let bottom = top * 0.35
        let t = max(0, min(1, (speed - bottom) / max(0.1, top - bottom)))
        return Color(hue: 0.58 - 0.58 * t, saturation: 0.85, brightness: 0.95)
    }
}

// MARK: - Connector

struct ConnectorRow: View {

    let connector: SessionRibbon.Connector

    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: 12)
                .padding(.leading, 26)

            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(tint)

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .frame(height: 14)
    }

    private var symbol: String {
        switch connector.kind {
        case .gybe: "arrow.triangle.turn.up.right.diamond"
        case .tack: "arrow.triangle.swap"
        case .carve, .turn: "arrow.triangle.branch"
        case .drop: "arrow.down.to.line"
        case .fall: "figure.fall"
        case .gap: "pause"
        }
    }

    private var tint: Color {
        switch connector.kind {
        case .fall: .red
        case .drop: .orange
        case .gap: .secondary
        default: connector.stayedOnFoil == true ? .green : .orange
        }
    }

    private var label: String {
        var parts = [connector.kind.displayName]
        if connector.kind == .gybe || connector.kind == .tack {
            if connector.stayedOnFoil == true { parts.append("dry") }
            if let score = connector.score { parts.append("\(Int(score))") }
        }
        if connector.kind == .gap || connector.kind == .drop || connector.kind == .fall {
            parts.append(Format.shortDuration(connector.duration))
        }
        return parts.joined(separator: " · ")
    }
}

struct LegendSwatch: View {
    let colour: Color
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(colour)
                .frame(width: 10, height: 6)
            Text(label)
        }
    }
}
