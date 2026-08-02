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

    /// The lane the rider has tapped, driving the map's run isolation.
    @Binding var selectedLane: Int?

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

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
                    legend
                        .padding(.bottom, 8)

                    ForEach(Array(ribbon.lanes.enumerated()), id: \.element.id) { index, lane in
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
                            isSelected: selectedLane == lane.runIndex
                        )
                        .onTapGesture {
                            withAnimation(.snappy) {
                                selectedLane = selectedLane == lane.runIndex ? nil : lane.runIndex
                            }
                        }

                        if let connector = connector(after: lane.id) {
                            ConnectorRow(connector: connector)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        }
    }

    private func connector(after laneID: Int) -> SessionRibbon.Connector? {
        ribbon.connectors.first { $0.fromLane == laneID }
    }

    /// The legend has to describe what is actually drawn.
    ///
    /// Colour is the *speed* ramp, not the state — a slow flight is blue and a
    /// fast one is red. State is carried by saturation (riding is washed out
    /// against flying) and by the two flat colours for slow and fall. Labelling
    /// green as "flying" would be wrong and would make every lane look mislabelled.
    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                LinearGradient(
                    colors: (0...6).map { i in
                        Color(hue: 0.58 - 0.58 * (Double(i) / 6), saturation: 0.85, brightness: 0.95)
                    },
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 44, height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                Text("slow → fast")
            }
            LegendSwatch(colour: .gray.opacity(0.45), label: "Slow")
            LegendSwatch(colour: .red, label: "Fall")
            Text("· pale = on the water, solid = flying")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Lane

struct LaneRow: View {

    let lane: SessionRibbon.Lane
    let widthFraction: Double
    let maxSpeed: Double
    let units: UnitPreferences
    let isSelected: Bool

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
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }

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

            if lane.foilingFraction > 0.05 {
                Text("\(Int(lane.foilingFraction * 100))% foil")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // The compass heading, not the wind angle. On a session of matched
            // reaches every lane has the *same* |TWA| — showing it puts the
            // identical number on every row, which is noise. The heading is
            // what actually differs, and the tack dot already carries the side.
            Text(Format.cardinal(lane.heading))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .trailing)

            if let point = lane.pointOfSail {
                Text(point.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 78, alignment: .trailing)
            }
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
