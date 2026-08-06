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

    /// The lane the rider has tapped, driving the map's run isolation.
    @Binding var selectedLane: Int?

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var order: Order = .time
    @State private var showsManeuvers = false
    @State private var showingKey = false

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
        switch order {
        case .time: ribbon.lanes
        case .fastest: ribbon.lanes.sorted { $0.averageSpeed > $1.averageSpeed }
        case .longest: ribbon.lanes.sorted { $0.distance > $1.distance }
        }
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
                    ForEach(lanes, id: \.id) { lane in
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
            .safeAreaInset(edge: .top, spacing: 0) { controls }
            .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
            .sheet(isPresented: $showingKey) {
                RibbonKeySheet()
                    .presentationDetents([.medium])
            }
        }
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

            Button {
                showingKey = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What the colours mean")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
                    Text("Tap a run to see its detail and isolate it on the map.")
                } header: {
                    Text("The rest of the row")
                }
            }
            .navigationTitle("What you're looking at")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Lane

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
