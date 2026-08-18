import OpenWaterCore
import SwiftUI
import UIKit

/// The hourly cursor every conditions tab shares.
///
/// One strip of hours, one draggable cursor, and a bubble saying when the
/// cursor is. The tabs render their own charts against their own axes and
/// resolve this strip's selected instant to their own nearest index — the
/// axes genuinely differ (the wind outlook starts at local midnight, the
/// waves series at the current hour), so the shared thing is the *instant*,
/// never an index.
///
/// A horizontal drag inside a sheet that resizes on vertical drags is safe
/// here only because SpotsSheet moves exclusively from its grab bar — the
/// two gestures live on different views and cannot fight. If content
/// dragging ever lands on the sheet (its phase-3 note), this scrubber needs
/// an exclusivity story before shipping.
struct HourScrubber: View {

    let hours: [Date]
    /// The place's own clock — sunset in Maui is a fact about Maui.
    let timeZone: TimeZone?
    /// The chosen instant; nil means "now", which is also what tapping
    /// the bubble returns to.
    @Binding var selection: Date?

    private var zone: TimeZone { timeZone ?? .current }

    private var selectedIndex: Int? {
        guard let selection, !hours.isEmpty else { return nil }
        return nearestIndex(to: selection)
    }

    private func nearestIndex(to instant: Date) -> Int {
        var best = 0
        var bestGap = TimeInterval.greatestFiniteMagnitude
        for (index, hour) in hours.enumerated() {
            let gap = abs(hour.timeIntervalSince(instant))
            if gap < bestGap { best = index; bestGap = gap }
        }
        return best
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let step = width / CGFloat(max(1, hours.count - 1))
            let cursorIndex = selectedIndex ?? nearestIndex(to: Date())

            ZStack(alignment: .topLeading) {
                // Hour ticks, labelled every six in the spot's own clock.
                ForEach(hours.indices, id: \.self) { index in
                    let x = CGFloat(index) * step
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1, height: index.isMultiple(of: 6) ? 10 : 5)
                        .offset(x: x, y: 26)
                    if index.isMultiple(of: 6) {
                        Text(hourLabel(hours[index]))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: max(0, min(width - 24, x - 9)), y: 38)
                    }
                }

                // The cursor and its bubble.
                Capsule()
                    .fill(selection == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.8)))
                    .frame(width: 2, height: 18)
                    .offset(x: CGFloat(cursorIndex) * step - 1, y: 22)
                Text(selection == nil ? "Now" : bubbleLabel(hours[cursorIndex]))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(selection == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.85)),
                                in: Capsule())
                    .fixedSize()
                    .offset(x: bubbleOffset(cursorIndex: cursorIndex, step: step, width: width), y: 0)
                    .onTapGesture { withAnimation(.snappy) { selection = nil } }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = max(0, min(hours.count - 1, Int((value.location.x / step).rounded())))
                        guard index != selectedIndex else { return }
                        selection = hours[index]
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
            )
        }
        .frame(height: 54)
        .accessibilityElement()
        .accessibilityLabel("Forecast hour")
        .accessibilityValue(selection.map { bubbleLabel($0) } ?? "Now")
    }

    /// Keeps the bubble on the strip when the cursor is near either edge.
    private func bubbleOffset(cursorIndex: Int, step: CGFloat, width: CGFloat) -> CGFloat {
        let x = CGFloat(cursorIndex) * step
        return max(0, min(width - 52, x - 24))
    }

    private func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "HH"
        return formatter.string(from: date)
    }

    private func bubbleLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "EE HH:mm"
        return formatter.string(from: date)
    }
}

/// Per-hour direction arrows on the same equal-column axis as a bar chart.
///
/// `pointsToward` is the load-bearing flag: currents state their direction
/// as the set — where the water is going — and draw as-is; wind and waves
/// state where they come *from* and draw +180, the streamline way. Getting
/// this wrong flips a river.
struct DirectionTicksRow: View {

    let directions: [Double?]
    var pointsToward = false

    /// Every nth arrow, chosen so the row never crowds — the columns stay
    /// aligned with the chart because the spacer count never changes.
    private var stride: Int { max(1, directions.count / 24) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(directions.indices, id: \.self) { index in
                Group {
                    if index.isMultiple(of: stride), let degrees = directions[index] {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 8, weight: .heavy))
                            .rotationEffect(.degrees(pointsToward ? degrees : degrees + 180))
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 12)
            }
        }
    }
}
